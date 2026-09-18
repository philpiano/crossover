#include "SplitCore.h"

#include <mach/mach_time.h>
#include <math.h>
#include <stdatomic.h>
#include <stdlib.h>
#include <string.h>

// Work in blocks so the scratch buffers are fixed-size, whatever buffer size
// the hardware hands us.
#define SC_BLOCK 256
// Gain changes and mutes: long enough to never click, short enough to feel instant.
#define SC_GAIN_SMOOTH_S 0.010f
// Frequency changes glide over about this long (exponentially, in octaves).
#define SC_FREQ_GLIDE_S 0.030f
// A slope change fades the outputs out over this long, swaps the filters, and
// fades them back in over the same time.
#define SC_SWAP_FADE_S 0.005f
#define SC_MAX_GAIN 16.0f
// Anything louder than this on the input is garbage (or NaN/Inf) and is dropped.
#define SC_INPUT_SANITY 64.0f
// The output safety clipper is transparent below this level and soft above it.
#define SC_CLIP_KNEE 0.95f
// Biquad sections per filter: an 8th-order Linkwitz-Riley is 4 of them.
#define SC_MAX_SECTIONS 4

#define RLX memory_order_relaxed

typedef struct { int32_t buf, ch; } sc_ref;
typedef struct { int32_t n; sc_ref c[SC_MAX_SLOT_CHANNELS]; } sc_map;

// One second-order section, transposed direct form II, normalised so a0 = 1.
typedef struct { double b0, b1, b2, a1, a2; } sc_biquad;
// A cascade of sections, then a sign (-1 for the phase-inverted side of an LR2/LR6).
typedef struct { int32_t n; double sign; sc_biquad s[SC_MAX_SECTIONS]; } sc_chain;
typedef struct { double z1[SC_MAX_SECTIONS], z2[SC_MAX_SECTIONS]; } sc_state;

// The filters of the crossover tree (see SplitCore.h).
enum {
    F_LP1, F_HP1,     // crossover 1: low | mid
    F_LP2, F_HP2,     // crossover 2: mid | mid-high
    F_LP3, F_HP3,     // crossover 3: mid-high | high
    F_EDGE_LOW,       // high-pass on the low band
    F_EDGE_HIGH,      // low-pass on the high band
    F_AP2_LOW,        // the low band's share of crossover 2's phase shift
    F_AP3_LOW,        // … and of crossover 3's
    F_AP3_MID,        // the mid band's share of crossover 3's
    F_COUNT
};

enum { KIND_LP, KIND_HP, KIND_AP };

struct sc_engine {
    // Topology: written only while stopped, read by the audio thread.
    sc_map in_map;
    sc_map band_map[SC_BANDS];
    float sample_rate;

    // Parameters: written by the UI, read by the audio thread.
    _Atomic float edge_hz[SC_EDGES];
    _Atomic int32_t edge_slope[SC_EDGES];
    _Atomic float band_gain[SC_BANDS];
    _Atomic bool band_mute[SC_BANDS];

    // Audio-thread state.
    sc_edge cur_edge[SC_EDGES];   // frequencies as they glide, slopes as running
    bool designed;                // filters match cur_edge at sample_rate
    sc_chain chain[F_COUNT];
    sc_state state[F_COUNT][SC_MAX_SLOT_CHANNELS];
    float cur_gain[SC_BANDS];
    float swap_gain;              // 1 normally; dips to 0 while slopes are swapped
    float in_buf[SC_MAX_SLOT_CHANNELS][SC_BLOCK];
    double work[SC_MAX_SLOT_CHANNELS][SC_BLOCK];
    double band_buf[SC_BANDS][SC_MAX_SLOT_CHANNELS][SC_BLOCK];

    // Spectrum display: recent input, mono. Written by the audio thread only.
    float scope[SC_SCOPE_SIZE];
    _Atomic uint64_t scope_written;

    // Meters and counters: written by the audio thread, taken by the UI.
    _Atomic float in_peak[SC_MAX_SLOT_CHANNELS];
    _Atomic float band_peak[SC_BANDS][SC_MAX_SLOT_CHANNELS];
    _Atomic uint64_t callbacks;
    _Atomic uint64_t clip_events;
    _Atomic uint64_t missing_buffers;
    _Atomic uint64_t last_cb_time;
    _Atomic uint64_t max_process_time;

    AudioObjectID device;
    AudioDeviceIOProcID proc;
    _Atomic bool running;
};

static inline float ldf(_Atomic float *p) { return atomic_load_explicit(p, RLX); }
static inline void stf(_Atomic float *p, float v) { atomic_store_explicit(p, v, RLX); }

// NaN, negative and absurd gains all become something safe.
static inline float clean_gain(float g) {
    if (!(g > 0.0f)) return 0.0f;
    return g > SC_MAX_GAIN ? SC_MAX_GAIN : g;
}

static inline bool valid_band(int b) { return b >= 0 && b < SC_BANDS; }
static inline bool valid_edge(int k) { return k >= 0 && k < SC_EDGES; }
static inline bool valid_ch(int c) { return c >= 0 && c < SC_MAX_SLOT_CHANNELS; }
static inline bool is_outer(int k) { return k == SC_EDGE_LOW || k == SC_EDGE_HIGH; }

static inline bool valid_slope(int edge, int slope) {
    switch (slope) {
        case 6: case 12: case 24: case 36: case 48: return true;
        case 0: return is_outer(edge);
        default: return false;
    }
}

static double clamp_hz(double hz, double fs) {
    const double top = fmin(SC_MAX_HZ, 0.45 * fs);
    if (!(hz >= SC_MIN_HZ)) return SC_MIN_HZ; // also NaN
    return hz > top ? top : hz;
}

// ---------------------------------------------------------------------------
// Filter design
//
// Every filter is an analog prototype mapped with the bilinear transform,
// pre-warped to its frequency (K = tan(pi f / fs)). Because low-pass, high-pass
// and all-pass of one crossover share that same mapping, the identity that makes
// a Linkwitz-Riley pair sum to an all-pass holds exactly in the digital domain too.

// The sections of an n-th order Butterworth: a first-order one if n is odd, then
// second-order ones with these Qs.
static int butterworth(int n, bool *first, double q[2]) {
    switch (n) {
        case 1: *first = true;  return 0;
        case 2: *first = false; q[0] = M_SQRT1_2; return 1;
        case 3: *first = true;  q[0] = 1.0; return 1;
        case 4: *first = false; q[0] = 0.54119610014619698; q[1] = 1.3065629648763766; return 2;
        default: *first = false; return 0;
    }
}

static sc_biquad first_order(int kind, double k) {
    const double norm = 1.0 / (1.0 + k), p = (k - 1.0) * norm;
    switch (kind) {
        case KIND_LP: return (sc_biquad){ k * norm, k * norm, 0.0, p, 0.0 };
        case KIND_HP: return (sc_biquad){ norm, -norm, 0.0, p, 0.0 };
        default:      return (sc_biquad){ p, 1.0, 0.0, p, 0.0 };
    }
}

static sc_biquad second_order(int kind, double k, double q) {
    const double kk = k * k, norm = 1.0 / (1.0 + k / q + kk);
    const double a1 = 2.0 * (kk - 1.0) * norm, a2 = (1.0 - k / q + kk) * norm;
    switch (kind) {
        case KIND_LP: return (sc_biquad){ kk * norm, 2.0 * kk * norm, kk * norm, a1, a2 };
        case KIND_HP: return (sc_biquad){ norm, -2.0 * norm, norm, a1, a2 };
        default:      return (sc_biquad){ a2, a1, 1.0, a1, a2 };
    }
}

// Designs one filter. `crossover` means it's one side of a crossover (so an
// LR2/LR6 high-pass is phase-inverted), rather than an outer band limit.
static void design(sc_chain *c, int kind, double hz, int slope, double fs, bool crossover) {
    c->n = 0;
    c->sign = 1.0;
    if (slope <= 0) return;
    const double k = tan(M_PI * clamp_hz(hz, fs) / fs);
    if (slope == 6) {
        // First order: low + high is exactly the input, so no all-pass is needed.
        if (kind != KIND_AP) c->s[c->n++] = first_order(kind, k);
        return;
    }
    const int order = slope / 12; // Linkwitz-Riley 2n = Butterworth n, squared
    bool first;
    double q[2];
    const int nq = butterworth(order, &first, q);
    // LP and HP run the Butterworth twice; the matching all-pass runs it once.
    const int passes = kind == KIND_AP ? 1 : 2;
    for (int p = 0; p < passes; p++) {
        if (first) c->s[c->n++] = first_order(kind, k);
        for (int j = 0; j < nq; j++) c->s[c->n++] = second_order(kind, k, q[j]);
    }
    if (crossover && kind == KIND_HP && (order % 2) == 1) c->sign = -1.0;
}

static void design_all(sc_chain chain[F_COUNT], const sc_edge edges[SC_EDGES], double fs) {
    const sc_edge *x1 = &edges[SC_EDGE_X1], *x2 = &edges[SC_EDGE_X2], *x3 = &edges[SC_EDGE_X3];
    design(&chain[F_LP1], KIND_LP, x1->hz, x1->slope, fs, true);
    design(&chain[F_HP1], KIND_HP, x1->hz, x1->slope, fs, true);
    design(&chain[F_LP2], KIND_LP, x2->hz, x2->slope, fs, true);
    design(&chain[F_HP2], KIND_HP, x2->hz, x2->slope, fs, true);
    design(&chain[F_LP3], KIND_LP, x3->hz, x3->slope, fs, true);
    design(&chain[F_HP3], KIND_HP, x3->hz, x3->slope, fs, true);
    design(&chain[F_EDGE_LOW], KIND_HP, edges[SC_EDGE_LOW].hz, edges[SC_EDGE_LOW].slope, fs, false);
    design(&chain[F_EDGE_HIGH], KIND_LP, edges[SC_EDGE_HIGH].hz, edges[SC_EDGE_HIGH].slope, fs, false);
    design(&chain[F_AP2_LOW], KIND_AP, x2->hz, x2->slope, fs, true);
    design(&chain[F_AP3_LOW], KIND_AP, x3->hz, x3->slope, fs, true);
    design(&chain[F_AP3_MID], KIND_AP, x3->hz, x3->slope, fs, true);
}

// |H(e^jw)| of one filter.
static double chain_magnitude(const sc_chain *c, double w) {
    const double cw = cos(w), sw = sin(w), c2 = cos(2.0 * w), s2 = sin(2.0 * w);
    double mag = 1.0;
    for (int j = 0; j < c->n; j++) {
        const sc_biquad *s = &c->s[j];
        const double nr = s->b0 + s->b1 * cw + s->b2 * c2, ni = -(s->b1 * sw + s->b2 * s2);
        const double dr = 1.0 + s->a1 * cw + s->a2 * c2, di = -(s->a1 * sw + s->a2 * s2);
        mag *= sqrt((nr * nr + ni * ni) / (dr * dr + di * di));
    }
    return mag;
}

double sc_band_response_db(const sc_edge edges[SC_EDGES], double fs, int band, double hz) {
    if (!valid_band(band) || !(fs > 0.0)) return -200.0;
    if (!(hz > 0.0) || hz >= fs / 2.0) return -200.0;
    sc_edge e[SC_EDGES];
    for (int k = 0; k < SC_EDGES; k++) {
        e[k] = edges[k];
        if (!valid_slope(k, e[k].slope)) e[k].slope = is_outer(k) ? 0 : 24;
    }
    sc_chain c[F_COUNT];
    design_all(c, e, fs);
    const double w = 2.0 * M_PI * hz / fs;
    // The all-passes don't change the magnitude, so they're left out.
    double mag;
    switch (band) {
        case 0:  mag = chain_magnitude(&c[F_LP1], w) * chain_magnitude(&c[F_EDGE_LOW], w); break;
        case 1:  mag = chain_magnitude(&c[F_HP1], w) * chain_magnitude(&c[F_LP2], w); break;
        case 2:  mag = chain_magnitude(&c[F_HP1], w) * chain_magnitude(&c[F_HP2], w) * chain_magnitude(&c[F_LP3], w); break;
        default: mag = chain_magnitude(&c[F_HP1], w) * chain_magnitude(&c[F_HP2], w) * chain_magnitude(&c[F_HP3], w)
                       * chain_magnitude(&c[F_EDGE_HIGH], w); break;
    }
    return mag > 1e-10 ? 20.0 * log10(mag) : -200.0;
}

// ---------------------------------------------------------------------------
// Lifecycle

static const sc_edge default_edges[SC_EDGES] = {
    { 20.0f, 24 }, { 100.0f, 24 }, { 1000.0f, 24 }, { 5000.0f, 24 }, { 20000.0f, 24 },
};

sc_engine *sc_engine_create(void) {
    sc_engine *e = calloc(1, sizeof *e);
    if (!e) return NULL;
    e->sample_rate = 48000.0f;
    for (int k = 0; k < SC_EDGES; k++) {
        atomic_init(&e->edge_hz[k], default_edges[k].hz);
        atomic_init(&e->edge_slope[k], default_edges[k].slope);
        e->cur_edge[k] = default_edges[k];
    }
    for (int b = 0; b < SC_BANDS; b++) {
        atomic_init(&e->band_gain[b], 1.0f);
        atomic_init(&e->band_mute[b], false);
        for (int c = 0; c < SC_MAX_SLOT_CHANNELS; c++) atomic_init(&e->band_peak[b][c], 0.0f);
    }
    for (int c = 0; c < SC_MAX_SLOT_CHANNELS; c++) atomic_init(&e->in_peak[c], 0.0f);
    e->swap_gain = 1.0f;
    atomic_init(&e->scope_written, 0);
    atomic_init(&e->callbacks, 0);
    atomic_init(&e->clip_events, 0);
    atomic_init(&e->missing_buffers, 0);
    atomic_init(&e->last_cb_time, 0);
    atomic_init(&e->max_process_time, 0);
    atomic_init(&e->running, false);
    return e;
}

void sc_engine_destroy(sc_engine *e) {
    if (!e) return;
    sc_engine_stop(e);
    free(e);
}

// ---------------------------------------------------------------------------
// Topology

bool sc_engine_clear_topology(sc_engine *e) {
    if (atomic_load(&e->running)) return false;
    memset(&e->in_map, 0, sizeof e->in_map);
    memset(e->band_map, 0, sizeof e->band_map);
    // Start every band from silence so a new topology fades in, and start the
    // filters from rest.
    memset(e->cur_gain, 0, sizeof e->cur_gain);
    memset(e->state, 0, sizeof e->state);
    for (int c = 0; c < SC_MAX_SLOT_CHANNELS; c++) stf(&e->in_peak[c], 0.0f);
    for (int b = 0; b < SC_BANDS; b++)
        for (int c = 0; c < SC_MAX_SLOT_CHANNELS; c++) stf(&e->band_peak[b][c], 0.0f);
    return true;
}

static bool set_map(sc_engine *e, sc_map *m, int n, int b0, int c0, int b1, int c1) {
    if (atomic_load(&e->running)) return false;
    m->n = (n == 1 || n == 2) ? n : 0;
    m->c[0] = (sc_ref){ b0, c0 };
    m->c[1] = (sc_ref){ b1, c1 };
    if (m->n >= 1 && (b0 < 0 || c0 < 0)) m->n = 0;
    if (m->n == 2 && (b1 < 0 || c1 < 0)) m->n = 0;
    return true;
}

bool sc_engine_set_input_map(sc_engine *e, int n, int b0, int c0, int b1, int c1) {
    return set_map(e, &e->in_map, n, b0, c0, b1, c1);
}

bool sc_engine_set_band_map(sc_engine *e, int band, int n, int b0, int c0, int b1, int c1) {
    return valid_band(band) && set_map(e, &e->band_map[band], n, b0, c0, b1, c1);
}

bool sc_engine_set_sample_rate(sc_engine *e, double sr) {
    if (atomic_load(&e->running) || !(sr >= 8000.0 && sr <= 768000.0)) return false;
    e->sample_rate = (float)sr;
    e->designed = false;
    return true;
}

// ---------------------------------------------------------------------------
// Parameters

void sc_engine_set_edge(sc_engine *e, int edge, float hz, int slope) {
    if (!valid_edge(edge)) return;
    if (hz == hz) stf(&e->edge_hz[edge], hz < SC_MIN_HZ ? SC_MIN_HZ : hz > SC_MAX_HZ ? SC_MAX_HZ : hz);
    if (valid_slope(edge, slope)) atomic_store_explicit(&e->edge_slope[edge], slope, RLX);
}
void sc_engine_set_band_gain(sc_engine *e, int band, float g) {
    if (valid_band(band)) stf(&e->band_gain[band], clean_gain(g));
}
void sc_engine_set_band_mute(sc_engine *e, int band, bool m) {
    if (valid_band(band)) atomic_store_explicit(&e->band_mute[band], m, RLX);
}

// ---------------------------------------------------------------------------
// Meters

float sc_engine_take_input_peak(sc_engine *e, int ch) {
    return valid_ch(ch) ? atomic_exchange_explicit(&e->in_peak[ch], 0.0f, RLX) : 0.0f;
}
float sc_engine_take_band_peak(sc_engine *e, int band, int ch) {
    if (!valid_band(band) || !valid_ch(ch)) return 0.0f;
    return atomic_exchange_explicit(&e->band_peak[band][ch], 0.0f, RLX);
}
uint64_t sc_engine_callback_count(sc_engine *e) { return atomic_load_explicit(&e->callbacks, RLX); }
uint64_t sc_engine_clip_count(sc_engine *e) { return atomic_load_explicit(&e->clip_events, RLX); }
uint64_t sc_engine_missing_buffer_count(sc_engine *e) { return atomic_load_explicit(&e->missing_buffers, RLX); }
uint64_t sc_engine_take_max_process_time(sc_engine *e) { return atomic_exchange_explicit(&e->max_process_time, 0, RLX); }
uint64_t sc_engine_last_callback_time(sc_engine *e) { return atomic_load_explicit(&e->last_cb_time, RLX); }

uint64_t sc_engine_read_scope(sc_engine *e, float *dst, uint32_t count) {
    if (count > SC_SCOPE_SIZE) count = SC_SCOPE_SIZE;
    const uint64_t written = atomic_load_explicit(&e->scope_written, memory_order_acquire);
    for (uint32_t k = 0; k < count; k++) {
        const uint64_t age = count - k; // 1 = the newest sample
        dst[k] = age <= written ? e->scope[(written - age) & (SC_SCOPE_SIZE - 1)] : 0.0f;
    }
    return written;
}

static inline void raise_peak(_Atomic float *p, float v) {
    if (v > ldf(p)) stf(p, v);
}

static inline void raise_u64(_Atomic uint64_t *p, uint64_t v) {
    if (v > atomic_load_explicit(p, RLX)) atomic_store_explicit(p, v, RLX);
}

// ---------------------------------------------------------------------------
// Rendering

static inline uint32_t buf_frames(const AudioBuffer *b) {
    if (!b->mData || b->mNumberChannels == 0) return 0;
    return b->mDataByteSize / (uint32_t)(sizeof(float) * b->mNumberChannels);
}

static uint32_t list_frames(const AudioBufferList *l) {
    uint32_t f = 0;
    if (!l) return 0;
    for (UInt32 i = 0; i < l->mNumberBuffers; i++) {
        uint32_t n = buf_frames(&l->mBuffers[i]);
        if (n > f) f = n;
    }
    return f;
}

// Looks up a channel reference, returning NULL if the layout doesn't have it.
static inline const AudioBuffer *resolve(const AudioBufferList *l, sc_ref r) {
    if (!l || r.buf < 0 || (UInt32)r.buf >= l->mNumberBuffers) return NULL;
    const AudioBuffer *b = &l->mBuffers[r.buf];
    if (!b->mData || r.ch < 0 || (UInt32)r.ch >= b->mNumberChannels) return NULL;
    return b;
}

static inline float smooth_toward(float cur, float target, float coef) {
    float next = cur + (target - cur) * coef;
    if (fabsf(target - next) < 1e-5f) next = target;
    return next;
}

static inline void settle(double *z) {
    if (!isfinite(*z) || fabs(*z) < 1e-25) *z = 0.0;
}

// Runs a filter over a block, in place, carrying its state.
static void run_chain(const sc_chain *c, sc_state *st, double *x, uint32_t n) {
    for (int j = 0; j < c->n; j++) {
        const sc_biquad s = c->s[j];
        double z1 = st->z1[j], z2 = st->z2[j];
        for (uint32_t k = 0; k < n; k++) {
            const double in = x[k];
            const double y = s.b0 * in + z1;
            z1 = s.b1 * in - s.a1 * y + z2;
            z2 = s.b2 * in - s.a2 * y;
            x[k] = y;
        }
        settle(&z1);
        settle(&z2);
        st->z1[j] = z1;
        st->z2[j] = z2;
    }
    if (c->n > 0 && c->sign != 1.0)
        for (uint32_t k = 0; k < n; k++) x[k] = -x[k];
}

// De-interleave the input into in_buf, dropping garbage samples, and feed the
// spectrum display.
static void gather_input(sc_engine *e, const AudioBufferList *in, uint32_t offset, uint32_t n, bool *missing) {
    const sc_map *m = &e->in_map;
    float peak[SC_MAX_SLOT_CHANNELS] = { 0.0f, 0.0f };
    for (int c = 0; c < m->n; c++) {
        float *dst = e->in_buf[c];
        const AudioBuffer *b = resolve(in, m->c[c]);
        if (!b) {
            memset(dst, 0, n * sizeof(float));
            *missing = true;
            continue;
        }
        const uint32_t stride = b->mNumberChannels;
        const uint32_t avail = buf_frames(b);
        if (avail < offset + n) *missing = true;
        const float *src = (const float *)b->mData + m->c[c].ch;
        for (uint32_t k = 0; k < n; k++) {
            const uint32_t f = offset + k;
            float x = (f < avail) ? src[(size_t)f * stride] : 0.0f;
            if (!(fabsf(x) <= SC_INPUT_SANITY)) x = 0.0f; // also catches NaN/Inf
            dst[k] = x;
            const float a = fabsf(x);
            if (a > peak[c]) peak[c] = a;
        }
    }
    for (int c = 0; c < m->n; c++) raise_peak(&e->in_peak[c], peak[c]);

    uint64_t w = atomic_load_explicit(&e->scope_written, RLX);
    const float scale = m->n == 2 ? 0.5f : 1.0f;
    for (uint32_t k = 0; k < n; k++, w++) {
        float v = 0.0f;
        for (int c = 0; c < m->n; c++) v += e->in_buf[c][k];
        e->scope[w & (SC_SCOPE_SIZE - 1)] = v * scale;
    }
    atomic_store_explicit(&e->scope_written, w, memory_order_release);
}

// Moves the running edges toward what the UI asked for. Frequencies glide; a
// slope change waits until the outputs have faded out (swap_gain reaches 0),
// then swaps the filters and starts them from rest. Returns the swap gain to
// ramp to over this block.
static float update_filters(sc_engine *e, uint32_t n) {
    const double fs = e->sample_rate > 0.0f ? e->sample_rate : 48000.0;
    bool slopes_differ = false;
    int32_t want_slope[SC_EDGES];
    for (int k = 0; k < SC_EDGES; k++) {
        want_slope[k] = atomic_load_explicit(&e->edge_slope[k], RLX);
        if (want_slope[k] != e->cur_edge[k].slope) slopes_differ = true;
    }
    bool changed = !e->designed;
    if (slopes_differ && e->swap_gain <= 0.0f) {
        for (int k = 0; k < SC_EDGES; k++) e->cur_edge[k].slope = want_slope[k];
        memset(e->state, 0, sizeof e->state);
        slopes_differ = false;
        changed = true;
    }
    // Glide in octaves, so a sweep across the range sounds even.
    const float glide = 1.0f - expf(-(float)n / (SC_FREQ_GLIDE_S * (float)fs));
    for (int k = 0; k < SC_EDGES; k++) {
        const float target = ldf(&e->edge_hz[k]);
        const float cur = e->cur_edge[k].hz;
        if (cur == target) continue;
        float next = cur * expf(logf(target / cur) * glide);
        if (!(fabsf(next / target - 1.0f) > 1e-4f)) next = target; // close enough, or NaN
        e->cur_edge[k].hz = next;
        changed = true;
    }
    if (changed) {
        design_all(e->chain, e->cur_edge, fs);
        e->designed = true;
    }
    const float step = (float)n / (SC_SWAP_FADE_S * (float)fs);
    return slopes_differ ? fmaxf(e->swap_gain - step, 0.0f) : fminf(e->swap_gain + step, 1.0f);
}

// Splits the gathered input into the four bands (band_buf).
static void split(sc_engine *e, uint32_t n) {
    for (int c = 0; c < e->in_map.n; c++) {
        double *low = e->band_buf[0][c], *mid = e->band_buf[1][c], *mh = e->band_buf[2][c], *high = e->band_buf[3][c];
        double *rest = e->work[c];
        for (uint32_t k = 0; k < n; k++) low[k] = rest[k] = e->in_buf[c][k];
        run_chain(&e->chain[F_LP1], &e->state[F_LP1][c], low, n);
        run_chain(&e->chain[F_HP1], &e->state[F_HP1][c], rest, n);
        memcpy(mid, rest, n * sizeof(double));
        run_chain(&e->chain[F_LP2], &e->state[F_LP2][c], mid, n);
        run_chain(&e->chain[F_HP2], &e->state[F_HP2][c], rest, n);
        memcpy(mh, rest, n * sizeof(double));
        memcpy(high, rest, n * sizeof(double));
        run_chain(&e->chain[F_LP3], &e->state[F_LP3][c], mh, n);
        run_chain(&e->chain[F_HP3], &e->state[F_HP3][c], high, n);

        run_chain(&e->chain[F_EDGE_LOW], &e->state[F_EDGE_LOW][c], low, n);
        run_chain(&e->chain[F_AP2_LOW], &e->state[F_AP2_LOW][c], low, n);
        run_chain(&e->chain[F_AP3_LOW], &e->state[F_AP3_LOW][c], low, n);
        run_chain(&e->chain[F_AP3_MID], &e->state[F_AP3_MID][c], mid, n);
        run_chain(&e->chain[F_EDGE_HIGH], &e->state[F_EDGE_HIGH][c], high, n);
    }
}

// Applies a band's gain and adds it into its output channels.
static void write_band(sc_engine *e, int b, AudioBufferList *out, uint32_t offset, uint32_t n,
                       float g0, float g1, float s0, float s1, bool *missing) {
    const sc_map *om = &e->band_map[b];
    const int ni = e->in_map.n, no = om->n;
    float peak[SC_MAX_SLOT_CHANNELS] = { 0.0f, 0.0f };
    const float inv = 1.0f / (float)n;
    const float dg = (g1 - g0) * inv, ds = (s1 - s0) * inv;

    for (int c = 0; c < no; c++) {
        const AudioBuffer *cb = resolve(out, om->c[c]);
        if (!cb) {
            *missing = true;
            continue;
        }
        const uint32_t stride = cb->mNumberChannels;
        const uint32_t avail = buf_frames(cb);
        if (avail < offset + n) *missing = true;
        float *dst = (float *)cb->mData + om->c[c].ch;
        // A mono band feeds both sides of a stereo output; a stereo band feeding
        // a mono output is averaged.
        const double *l = e->band_buf[b][0];
        const double *r = ni > 1 ? e->band_buf[b][1] : l;
        const double *src = (ni > 1 && no > 1 && c == 1) ? r : l;
        const bool average = ni > 1 && no == 1;
        float g = g0, s = s0;
        for (uint32_t k = 0; k < n; k++) {
            g += dg; s += ds;
            const float v = (float)(average ? 0.5 * (l[k] + r[k]) : src[k]) * g * s;
            const float a = fabsf(v);
            if (a > peak[c]) peak[c] = a;
            const uint32_t f = offset + k;
            if (f < avail) dst[(size_t)f * stride] += v;
        }
    }
    for (int c = 0; c < no; c++) raise_peak(&e->band_peak[b][c], peak[c] > 1.0f ? 1.0f : peak[c]);
}

// Transparent below the knee, smooth tanh saturation above it, never past 1.0.
// The last line of defence: boosted bands, or two bands on the same output.
static void safety_clip(sc_engine *e, AudioBufferList *out) {
    bool clipped = false;
    for (UInt32 b = 0; b < out->mNumberBuffers; b++) {
        float *d = out->mBuffers[b].mData;
        if (!d) continue;
        const uint32_t count = out->mBuffers[b].mDataByteSize / sizeof(float);
        for (uint32_t j = 0; j < count; j++) {
            const float x = d[j];
            const float a = fabsf(x);
            if (a > SC_CLIP_KNEE) {
                if (a > 1.0f) clipped = true;
                const float over = (a - SC_CLIP_KNEE) / (1.0f - SC_CLIP_KNEE);
                d[j] = copysignf(SC_CLIP_KNEE + (1.0f - SC_CLIP_KNEE) * tanhf(over), x);
            }
        }
    }
    if (clipped) atomic_fetch_add_explicit(&e->clip_events, 1, RLX);
}

static void render(sc_engine *e, const AudioBufferList *in, AudioBufferList *out) {
    // The HAL does not promise zeroed output buffers. Every channel we don't
    // write must be silence.
    if (out) {
        for (UInt32 b = 0; b < out->mNumberBuffers; b++)
            if (out->mBuffers[b].mData) memset(out->mBuffers[b].mData, 0, out->mBuffers[b].mDataByteSize);
    }

    uint32_t frames = list_frames(out);
    if (frames == 0) frames = list_frames(in);
    if (frames == 0 || e->in_map.n == 0) return;

    const float sr = e->sample_rate > 0.0f ? e->sample_rate : 48000.0f;
    bool missing = false;
    for (uint32_t offset = 0; offset < frames; offset += SC_BLOCK) {
        const uint32_t n = (frames - offset) < SC_BLOCK ? (frames - offset) : SC_BLOCK;
        const float coef = 1.0f - expf(-(float)n / (SC_GAIN_SMOOTH_S * sr));

        const float s0 = e->swap_gain;
        const float s1 = update_filters(e, n);
        e->swap_gain = s1;
        gather_input(e, in, offset, n, &missing);
        split(e, n);
        for (int b = 0; b < SC_BANDS; b++) {
            const float target = atomic_load_explicit(&e->band_mute[b], RLX) ? 0.0f : clean_gain(ldf(&e->band_gain[b]));
            const float g0 = e->cur_gain[b];
            const float g1 = smooth_toward(g0, target, coef);
            e->cur_gain[b] = g1;
            if (e->band_map[b].n == 0) continue;
            write_band(e, b, out, offset, n, g0, g1, s0, s1, &missing);
        }
    }

    if (missing) atomic_fetch_add_explicit(&e->missing_buffers, 1, RLX);
    if (out) safety_clip(e, out);
}

void sc_engine_process(sc_engine *e, const AudioBufferList *in, AudioBufferList *out) {
    if (!e) return;
    // mach_absolute_time is a plain register read: safe on the audio thread.
    const uint64_t began = mach_absolute_time();
    atomic_store_explicit(&e->last_cb_time, began, RLX);
    atomic_fetch_add_explicit(&e->callbacks, 1, RLX);
    render(e, in, out);
    const uint64_t ended = mach_absolute_time();
    if (ended > began) raise_u64(&e->max_process_time, ended - began);
}

// ---------------------------------------------------------------------------
// Hardware glue

static OSStatus sc_ioproc(AudioObjectID device, const AudioTimeStamp *now,
                          const AudioBufferList *inData, const AudioTimeStamp *inTime,
                          AudioBufferList *outData, const AudioTimeStamp *outTime,
                          void *ctx) {
    (void)device; (void)now; (void)inTime; (void)outTime;
    sc_engine_process((sc_engine *)ctx, inData, outData);
    return noErr;
}

OSStatus sc_engine_start(sc_engine *e, AudioObjectID device) {
    if (atomic_load(&e->running)) return kAudioHardwareIllegalOperationError;
    AudioDeviceIOProcID proc = NULL;
    OSStatus s = AudioDeviceCreateIOProcID(device, sc_ioproc, e, &proc);
    if (s != noErr) return s;
    e->device = device;
    e->proc = proc;
    atomic_store(&e->running, true); // before start, so topology setters refuse
    s = AudioDeviceStart(device, proc);
    if (s != noErr) {
        AudioDeviceDestroyIOProcID(device, proc);
        e->proc = NULL;
        e->device = kAudioObjectUnknown;
        atomic_store(&e->running, false);
    }
    return s;
}

OSStatus sc_engine_stop(sc_engine *e) {
    if (!atomic_load(&e->running)) return noErr;
    // Called from outside the IOProc, AudioDeviceStop returns once the proc has
    // stopped running. If the device has vanished it may fail; clean up anyway.
    OSStatus s = AudioDeviceStop(e->device, e->proc);
    AudioDeviceDestroyIOProcID(e->device, e->proc);
    e->proc = NULL;
    e->device = kAudioObjectUnknown;
    atomic_store(&e->running, false);
    return s;
}

bool sc_engine_is_running(sc_engine *e) { return atomic_load(&e->running); }
