#include "RouterCore.h"

#include <mach/mach_time.h>
#include <math.h>
#include <stdatomic.h>
#include <stdlib.h>
#include <string.h>

// Work in blocks so the scratch buffers are fixed-size, whatever buffer size
// the hardware hands us.
#define AR_BLOCK 256
// Time constant for gain changes and effect switches. Long enough to never
// click, short enough that a mute feels instant.
#define AR_SMOOTH_SECONDS 0.010f
#define AR_MAX_GAIN 16.0f
// Anything louder than this on an input is garbage (or NaN/Inf) and is dropped.
#define AR_INPUT_SANITY 64.0f
// The output safety clipper is transparent below this level and soft above it.
#define AR_CLIP_KNEE 0.95f

// Channel-strip effects. Deliberately fixed, conventional settings.
#define AR_LOWCUT_HZ 80.0            // the standard mixing-desk low-cut
#define AR_COMP_THRESHOLD_DB (-24.0f)
#define AR_COMP_RATIO 2.0f
#define AR_COMP_KNEE_DB 10.0f
#define AR_COMP_ATTACK_S 0.010f
#define AR_COMP_RELEASE_S 0.150f
#define AR_COMP_MAKEUP_DB 2.0f       // normal speech nets out near 0 dB
#define AR_LIMIT_CEILING 0.8912509f  // -1 dBFS
#define AR_LIMIT_RELEASE_S 0.100f

// Effect amounts (the knobs), 0..AR_AMOUNT_MAX, 100% = the effect as specified.
#define AR_AMOUNT_MAX 1.5f
#define AR_LOWCUT_MIN_AMOUNT 0.25f   // low-cut: cutoff = 80 Hz x amount, never below 20 Hz; below 25% it fades out
#define AR_LIMIT_DB_PER_AMOUNT 10.0f // limiter above 100%: the ceiling drops 1 dB per 10% (150% -> -6 dBFS)

// Noise gate: a hard gate whose threshold sits a margin above an automatic
// estimate of the steady noise floor.
//
// Floor estimate ("minimum statistics"): a 50 ms level is tracked, and the
// floor is the quietest that level has been. It drops to any new minimum at
// once. It may only rise when the sound has been *steady* (no moment more than
// AR_GATE_STEADY_DB above the quietest) for the whole last 4 s: constant noise
// is steady, speech and piano never are. So playing cannot drag the floor up,
// but a fan switching on is absorbed after a few seconds of it.
#define AR_GATE_LEVEL_S 0.050f         // the level the floor is estimated from
#define AR_GATE_DET_ATTACK_S 0.001f    // detector: rises within ~1 ms, so an onset opens the gate at once
#define AR_GATE_DET_RELEASE_S 0.020f
#define AR_GATE_SUB_S 0.5f             // the window is 8 of these
#define AR_GATE_SUBS 8                 // → a 4 s window
#define AR_GATE_STEADY_DB 4.0f         // a half-second is "steady" if its loudest moment is within this of its quietest
#define AR_GATE_RISE_DB_S 20.0f        // how fast the floor may rise once it's allowed to (steadiness is the safeguard)
#define AR_GATE_FLOOR_MIN 1e-9f        // -90 dBFS
#define AR_GATE_FLOOR_MAX 1e-4f        // -40 dBFS: anything louder is never treated as noise
#define AR_GATE_MARGIN_DB 8.0f         // threshold above the floor estimate
#define AR_GATE_BIAS_DB_PER_AMOUNT 24.0f // the knob: the threshold moves 2.4 dB per 10% (0% = 24 dB more lenient, 150% = 12 dB stricter)
#define AR_GATE_ATTACK_S 0.0005f       // gate opening ramp (spec: <= 1 ms)
#define AR_GATE_HOLD_S 0.70f           // stays open after the signal falls below threshold (spec: ~600-800 ms)
#define AR_GATE_RELEASE_S 0.010f       // short, clean close once the hold expires

// Auto level ("Hard Compressor" in the design doc). Two regimes, both measured
// in RMS so they compare like with like:
//   quiet: when the student plays or speaks well below their normal level,
//          boost it back most of the way.
//   loud:  when the (boosted) level jumps well above normal, pull it straight
//          down to a ceiling above normal.
// "Normal" is a slow average of the level while the student is actually making
// sound. It freezes during silence, so a pause changes nothing: hiss isn't
// boosted, and playing afterwards comes back at the same level.
#define AR_AL_LEVEL_S 0.100f           // level the boost decision is based on
#define AR_AL_DET_ATTACK_S 0.002f      // loud-jump detector (spec: < 1-3 ms)
#define AR_AL_DET_RELEASE_S 0.150f
#define AR_AL_REF_RISE_S 4.0f          // "normal" follows a louder student over ~4 s…
#define AR_AL_REF_FALL_S 15.0f         // …and a quieter one only over ~15 s
#define AR_AL_REF_COLD_S 0.5f          // at first, learn "normal" quickly…
#define AR_AL_REF_WARM_S 2.0f          // …for this long, before acting at all
#define AR_AL_PRESENT_ABS_DB (-65.0f)  // quieter than this is never "the student playing"
#define AR_AL_PRESENT_BELOW_DB 26.0f   // nor is anything this far below normal (room noise)
#define AR_AL_DEADZONE_DB 4.0f         // no boost until this far below normal
#define AR_AL_BOOST_RATIO 0.4f         // share of the shortfall restored: this at strength 0…
#define AR_AL_BOOST_RATIO_PER_STRENGTH 0.35f // …plus this per unit of strength (100% → 3/4)
#define AR_AL_MAX_BOOST_DB 12.0f       // at the default strength; scales with the knob, capped below
#define AR_AL_BOOST_CAP_DB 18.0f
#define AR_AL_BOOST_UP_S 1.0f          // boost fades in gently…
#define AR_AL_BOOST_DOWN_S 0.080f      // …and gets out of the way fast when the level comes back
#define AR_AL_BOOST_IDLE_S 0.300f      // and fades out during silence
#define AR_AL_HEADROOM_DB 12.0f        // ceiling above normal at the gentlest setting…
#define AR_AL_HEADROOM_PER_STRENGTH 3.0f // …tightening by this much per unit of strength (100% → 9 dB)

#define RLX memory_order_relaxed

typedef struct { int32_t buf, ch; } ar_ref;
typedef struct { int32_t n; ar_ref c[AR_MAX_SLOT_CHANNELS]; } ar_map;

// Index into an input's fx_level[] array. Matches signal order.
enum { AR_FXI_LOWCUT = 0, AR_FXI_NOISEGATE, AR_FXI_AUTOLEVEL, AR_FXI_COMPRESSOR, AR_FXI_LIMITER, AR_FX_COUNT };

static inline int fx_index(uint32_t effect) {
    switch (effect) {
        case AR_FX_LOWCUT:     return AR_FXI_LOWCUT;
        case AR_FX_NOISEGATE:  return AR_FXI_NOISEGATE;
        case AR_FX_AUTOLEVEL:  return AR_FXI_AUTOLEVEL;
        case AR_FX_COMPRESSOR: return AR_FXI_COMPRESSOR;
        case AR_FX_LIMITER:    return AR_FXI_LIMITER;
        default: return -1;
    }
}

// Per-input effect state, touched only by the audio thread.
typedef struct {
    double z1[AR_MAX_SLOT_CHANNELS], z2[AR_MAX_SLOT_CHANNELS]; // low-cut biquad
    double lc_b0, lc_b1, lc_b2, lc_a1, lc_a2;                 // its coefficients, for lc_amount at lc_rate
    float lc_amount, lc_rate;
    float comp_env;   // mean-square level
    float lim_env;    // peak level
    float mix_lowcut, mix_comp, mix_limit; // on/off crossfades: 0 = bypassed, 1 = fully in

    // Noise gate. Levels are mean-square.
    float gate_level;   // 50 ms level, for the floor estimate
    float gate_det;     // fast detector, for opening and closing
    float gate_floor;   // noise floor estimate
    float gate_sub_min, gate_sub_max; // this half-second's quietest and loudest level
    int32_t gate_sub_count;
    float gate_win_min;               // quietest level over the last AR_GATE_SUBS half-seconds
    uint8_t gate_steady[AR_GATE_SUBS];
    float gate_mins[AR_GATE_SUBS];
    int32_t gate_sub_pos, gate_subs_filled;
    bool gate_all_steady;
    float gate_gain;    // 0 (closed) .. 1 (open)
    int32_t gate_hold;  // samples of hold remaining
    float mix_gate;     // on/off crossfade

    // Auto level.
    float al_level;     // mean-square, AR_AL_LEVEL_S
    float al_det;       // mean-square, fast attack
    float al_ref_db;    // the student's normal level
    int32_t al_warm;    // samples of sound heard so far, up to the warm-up length
    float al_boost_db;
    float mix_autolevel; // on/off crossfade
} ar_fx;

// Output-bus limiter state (the one effect an output slot can run).
typedef struct {
    float lim_env;
    float mix_limit;
} ar_out_fx;

struct ar_engine {
    // Topology: written only while stopped, read by the audio thread.
    ar_map in_map[AR_MAX_INPUTS];
    ar_map out_map[AR_MAX_OUTPUTS];
    float sample_rate;
    float comp_attack, comp_release, limit_release;
    float gate_level_coef, gate_det_attack, gate_det_release, gate_rise, gate_attack_coef, gate_release_coef;
    float gate_steady_ratio;
    int32_t gate_hold_samples, gate_sub_samples;
    float al_level_coef, al_det_attack, al_det_release, al_ref_rise, al_ref_fall, al_ref_cold;
    float al_boost_up, al_boost_down, al_boost_idle;
    int32_t al_warm_samples;

    // Parameters: written by the UI, read by the audio thread.
    _Atomic float route[AR_MAX_INPUTS][AR_MAX_OUTPUTS];
    _Atomic float in_gain[AR_MAX_INPUTS];
    _Atomic float out_gain[AR_MAX_OUTPUTS];
    _Atomic bool in_mute[AR_MAX_INPUTS];
    _Atomic bool out_mute[AR_MAX_OUTPUTS];
    _Atomic uint32_t fx_flags[AR_MAX_INPUTS];
    _Atomic float fx_level[AR_MAX_INPUTS][AR_FX_COUNT];
    _Atomic uint32_t out_fx_flags[AR_MAX_OUTPUTS];
    _Atomic float out_fx_level[AR_MAX_OUTPUTS];

    // Audio-thread state.
    float cur_in[AR_MAX_INPUTS];
    float cur_route[AR_MAX_INPUTS][AR_MAX_OUTPUTS];
    ar_fx fx[AR_MAX_INPUTS];
    ar_out_fx out_fx[AR_MAX_OUTPUTS];
    float in_buf[AR_MAX_INPUTS][AR_MAX_SLOT_CHANNELS][AR_BLOCK];
    float mix_buf[AR_MAX_SLOT_CHANNELS][AR_BLOCK];

    // Meters and counters: written by the audio thread, taken by the UI.
    _Atomic float in_peak[AR_MAX_INPUTS][AR_MAX_SLOT_CHANNELS];
    _Atomic float out_peak[AR_MAX_OUTPUTS][AR_MAX_SLOT_CHANNELS];
    _Atomic float limit_gr[AR_MAX_INPUTS];
    _Atomic float comp_gr[AR_MAX_INPUTS];
    _Atomic float gate_gr[AR_MAX_INPUTS];
    _Atomic float al_lift[AR_MAX_INPUTS]; // auto level: most dB boosted
    _Atomic float al_cap[AR_MAX_INPUTS];  // auto level: most dB pulled down
    _Atomic float out_limit_gr[AR_MAX_OUTPUTS];
    // Peak-hold: the loudest peak (linear) since the last explicit reset, and
    // whether it reached 0 dBFS before the final safety clip. Never taken.
    _Atomic float in_peak_hold[AR_MAX_INPUTS][AR_MAX_SLOT_CHANNELS];
    _Atomic bool in_clipped[AR_MAX_INPUTS][AR_MAX_SLOT_CHANNELS];
    _Atomic float out_peak_hold[AR_MAX_OUTPUTS][AR_MAX_SLOT_CHANNELS];
    _Atomic bool out_clipped[AR_MAX_OUTPUTS][AR_MAX_SLOT_CHANNELS];
    _Atomic uint64_t callbacks;
    _Atomic uint64_t clip_events;

    // Diagnostics: written by the audio thread, taken by the diagnostic log.
    _Atomic uint64_t last_cb_time;
    _Atomic uint64_t first_cb_time;
    _Atomic uint64_t max_cb_interval;
    _Atomic uint64_t max_process_time;
    _Atomic uint64_t missing_buffers;
    uint32_t in_zero_run[AR_MAX_INPUTS];   // audio thread only
    uint32_t out_zero_run[AR_MAX_OUTPUTS]; // audio thread only
    _Atomic uint32_t in_max_zero_run[AR_MAX_INPUTS];
    _Atomic uint32_t out_max_zero_run[AR_MAX_OUTPUTS];

    AudioObjectID device;
    AudioDeviceIOProcID proc;
    _Atomic bool running;
};

static inline float ldf(_Atomic float *p) { return atomic_load_explicit(p, RLX); }
static inline void stf(_Atomic float *p, float v) { atomic_store_explicit(p, v, RLX); }

// NaN, negative and absurd gains all become something safe.
static inline float clean_gain(float g) {
    if (!(g > 0.0f)) return 0.0f;
    return g > AR_MAX_GAIN ? AR_MAX_GAIN : g;
}

static inline bool valid_in(int i) { return i >= 0 && i < AR_MAX_INPUTS; }
static inline bool valid_out(int o) { return o >= 0 && o < AR_MAX_OUTPUTS; }
static inline bool valid_ch(int c) { return c >= 0 && c < AR_MAX_SLOT_CHANNELS; }

static void update_coefficients(ar_engine *e) {
    const double fs = e->sample_rate;
    e->comp_attack = 1.0f - expf(-1.0f / (AR_COMP_ATTACK_S * (float)fs));
    e->comp_release = 1.0f - expf(-1.0f / (AR_COMP_RELEASE_S * (float)fs));
    e->limit_release = expf(-1.0f / (AR_LIMIT_RELEASE_S * (float)fs));

    #define ONE_POLE(seconds) (1.0f - expf(-1.0f / ((seconds) * (float)fs)))
    e->gate_level_coef = ONE_POLE(AR_GATE_LEVEL_S);
    e->gate_det_attack = ONE_POLE(AR_GATE_DET_ATTACK_S);
    e->gate_det_release = ONE_POLE(AR_GATE_DET_RELEASE_S);
    e->gate_rise = powf(10.0f, AR_GATE_RISE_DB_S / 10.0f / (float)fs); // per sample, mean-square
    e->gate_attack_coef = ONE_POLE(AR_GATE_ATTACK_S);
    e->gate_release_coef = ONE_POLE(AR_GATE_RELEASE_S);
    e->gate_steady_ratio = powf(10.0f, AR_GATE_STEADY_DB / 10.0f); // mean-square
    e->gate_hold_samples = (int32_t)(AR_GATE_HOLD_S * (float)fs + 0.5f);
    e->gate_sub_samples = (int32_t)(AR_GATE_SUB_S * (float)fs + 0.5f);

    e->al_level_coef = ONE_POLE(AR_AL_LEVEL_S);
    e->al_det_attack = ONE_POLE(AR_AL_DET_ATTACK_S);
    e->al_det_release = ONE_POLE(AR_AL_DET_RELEASE_S);
    e->al_ref_rise = ONE_POLE(AR_AL_REF_RISE_S);
    e->al_ref_fall = ONE_POLE(AR_AL_REF_FALL_S);
    e->al_ref_cold = ONE_POLE(AR_AL_REF_COLD_S);
    e->al_boost_up = ONE_POLE(AR_AL_BOOST_UP_S);
    e->al_boost_down = ONE_POLE(AR_AL_BOOST_DOWN_S);
    e->al_boost_idle = ONE_POLE(AR_AL_BOOST_IDLE_S);
    e->al_warm_samples = (int32_t)(AR_AL_REF_WARM_S * (float)fs + 0.5f);
    #undef ONE_POLE
}

// ---------------------------------------------------------------------------
// Lifecycle

ar_engine *ar_engine_create(void) {
    ar_engine *e = calloc(1, sizeof *e);
    if (!e) return NULL;
    e->sample_rate = 48000.0f;
    update_coefficients(e);
    for (int i = 0; i < AR_MAX_INPUTS; i++) {
        atomic_init(&e->in_gain[i], 1.0f);
        atomic_init(&e->in_mute[i], false);
        atomic_init(&e->fx_flags[i], 0u);
        atomic_init(&e->limit_gr[i], 0.0f);
        atomic_init(&e->comp_gr[i], 0.0f);
        atomic_init(&e->gate_gr[i], 0.0f);
        atomic_init(&e->al_lift[i], 0.0f);
        atomic_init(&e->al_cap[i], 0.0f);
        atomic_init(&e->fx_level[i][AR_FXI_LOWCUT], 1.0f);
        atomic_init(&e->fx_level[i][AR_FXI_NOISEGATE], 1.0f);
        atomic_init(&e->fx_level[i][AR_FXI_AUTOLEVEL], 1.0f);
        atomic_init(&e->fx_level[i][AR_FXI_COMPRESSOR], 1.0f);
        atomic_init(&e->fx_level[i][AR_FXI_LIMITER], 1.0f);
        for (int o = 0; o < AR_MAX_OUTPUTS; o++) atomic_init(&e->route[i][o], 0.0f);
        for (int c = 0; c < AR_MAX_SLOT_CHANNELS; c++) {
            atomic_init(&e->in_peak[i][c], 0.0f);
            atomic_init(&e->in_peak_hold[i][c], 0.0f);
            atomic_init(&e->in_clipped[i][c], false);
        }
    }
    for (int o = 0; o < AR_MAX_OUTPUTS; o++) {
        atomic_init(&e->out_gain[o], 1.0f);
        atomic_init(&e->out_mute[o], false);
        atomic_init(&e->out_fx_flags[o], 0u);
        atomic_init(&e->out_fx_level[o], 1.0f);
        atomic_init(&e->out_limit_gr[o], 0.0f);
        for (int c = 0; c < AR_MAX_SLOT_CHANNELS; c++) {
            atomic_init(&e->out_peak[o][c], 0.0f);
            atomic_init(&e->out_peak_hold[o][c], 0.0f);
            atomic_init(&e->out_clipped[o][c], false);
        }
    }
    atomic_init(&e->callbacks, 0);
    atomic_init(&e->clip_events, 0);
    atomic_init(&e->last_cb_time, 0);
    atomic_init(&e->first_cb_time, 0);
    atomic_init(&e->max_cb_interval, 0);
    atomic_init(&e->max_process_time, 0);
    atomic_init(&e->missing_buffers, 0);
    for (int i = 0; i < AR_MAX_INPUTS; i++) atomic_init(&e->in_max_zero_run[i], 0u);
    for (int o = 0; o < AR_MAX_OUTPUTS; o++) atomic_init(&e->out_max_zero_run[o], 0u);
    atomic_init(&e->running, false);
    return e;
}

void ar_engine_destroy(ar_engine *e) {
    if (!e) return;
    ar_engine_stop(e);
    free(e);
}

// ---------------------------------------------------------------------------
// Topology

bool ar_engine_clear_topology(ar_engine *e) {
    if (atomic_load(&e->running)) return false;
    memset(e->in_map, 0, sizeof e->in_map);
    memset(e->out_map, 0, sizeof e->out_map);
    // Start every gain from silence so a new topology fades in, and give the
    // effects fresh state.
    memset(e->cur_in, 0, sizeof e->cur_in);
    memset(e->cur_route, 0, sizeof e->cur_route);
    memset(e->fx, 0, sizeof e->fx);
    memset(e->out_fx, 0, sizeof e->out_fx);
    for (int i = 0; i < AR_MAX_INPUTS; i++)
        for (int c = 0; c < AR_MAX_SLOT_CHANNELS; c++) stf(&e->in_peak[i][c], 0.0f);
    for (int o = 0; o < AR_MAX_OUTPUTS; o++)
        for (int c = 0; c < AR_MAX_SLOT_CHANNELS; c++) stf(&e->out_peak[o][c], 0.0f);
    return true;
}

static bool set_map(ar_engine *e, ar_map *m, int n, int b0, int c0, int b1, int c1) {
    if (atomic_load(&e->running)) return false;
    m->n = (n == 1 || n == 2) ? n : 0;
    m->c[0] = (ar_ref){ b0, c0 };
    m->c[1] = (ar_ref){ b1, c1 };
    if (m->n >= 1 && (b0 < 0 || c0 < 0)) m->n = 0;
    if (m->n == 2 && (b1 < 0 || c1 < 0)) m->n = 0;
    return true;
}

bool ar_engine_set_input_map(ar_engine *e, int slot, int n, int b0, int c0, int b1, int c1) {
    return valid_in(slot) && set_map(e, &e->in_map[slot], n, b0, c0, b1, c1);
}

bool ar_engine_set_output_map(ar_engine *e, int slot, int n, int b0, int c0, int b1, int c1) {
    return valid_out(slot) && set_map(e, &e->out_map[slot], n, b0, c0, b1, c1);
}

bool ar_engine_set_sample_rate(ar_engine *e, double sr) {
    if (atomic_load(&e->running) || !(sr >= 8000.0 && sr <= 768000.0)) return false;
    e->sample_rate = (float)sr;
    update_coefficients(e);
    return true;
}

// ---------------------------------------------------------------------------
// Parameters

void ar_engine_set_route(ar_engine *e, int in, int out, float g) {
    if (valid_in(in) && valid_out(out)) stf(&e->route[in][out], clean_gain(g));
}
void ar_engine_set_input_gain(ar_engine *e, int in, float g) {
    if (valid_in(in)) stf(&e->in_gain[in], clean_gain(g));
}
void ar_engine_set_input_mute(ar_engine *e, int in, bool m) {
    if (valid_in(in)) atomic_store_explicit(&e->in_mute[in], m, RLX);
}
void ar_engine_set_input_effects(ar_engine *e, int in, uint32_t flags) {
    if (valid_in(in)) atomic_store_explicit(&e->fx_flags[in], flags, RLX);
}
static inline float clean_level(float v) { return !(v >= 0.0f) ? 0.0f : (v > AR_AMOUNT_MAX ? AR_AMOUNT_MAX : v); }
void ar_engine_set_input_fx_level(ar_engine *e, int in, uint32_t effect, float level) {
    int idx = fx_index(effect);
    if (valid_in(in) && idx >= 0) stf(&e->fx_level[in][idx], clean_level(level));
}
void ar_engine_set_output_gain(ar_engine *e, int out, float g) {
    if (valid_out(out)) stf(&e->out_gain[out], clean_gain(g));
}
void ar_engine_set_output_mute(ar_engine *e, int out, bool m) {
    if (valid_out(out)) atomic_store_explicit(&e->out_mute[out], m, RLX);
}
void ar_engine_set_output_effects(ar_engine *e, int out, uint32_t flags) {
    if (valid_out(out)) atomic_store_explicit(&e->out_fx_flags[out], flags, RLX);
}
void ar_engine_set_output_fx_level(ar_engine *e, int out, uint32_t effect, float level) {
    if (valid_out(out) && effect == AR_FX_LIMITER) stf(&e->out_fx_level[out], clean_level(level));
}

// ---------------------------------------------------------------------------
// Meters

float ar_engine_take_input_peak(ar_engine *e, int in, int ch) {
    if (!valid_in(in) || !valid_ch(ch)) return 0.0f;
    return atomic_exchange_explicit(&e->in_peak[in][ch], 0.0f, RLX);
}
float ar_engine_take_output_peak(ar_engine *e, int out, int ch) {
    if (!valid_out(out) || !valid_ch(ch)) return 0.0f;
    return atomic_exchange_explicit(&e->out_peak[out][ch], 0.0f, RLX);
}
float ar_engine_take_input_reduction(ar_engine *e, int in, uint32_t effect) {
    if (!valid_in(in)) return 0.0f;
    if (effect == AR_FX_LIMITER) return atomic_exchange_explicit(&e->limit_gr[in], 0.0f, RLX);
    if (effect == AR_FX_COMPRESSOR) return atomic_exchange_explicit(&e->comp_gr[in], 0.0f, RLX);
    if (effect == AR_FX_NOISEGATE) return atomic_exchange_explicit(&e->gate_gr[in], 0.0f, RLX);
    if (effect == AR_FX_AUTOLEVEL) return atomic_exchange_explicit(&e->al_cap[in], 0.0f, RLX);
    return 0.0f;
}
float ar_engine_take_input_lift(ar_engine *e, int in) {
    return valid_in(in) ? atomic_exchange_explicit(&e->al_lift[in], 0.0f, RLX) : 0.0f;
}
float ar_engine_take_output_reduction(ar_engine *e, int out, uint32_t effect) {
    if (!valid_out(out) || effect != AR_FX_LIMITER) return 0.0f;
    return atomic_exchange_explicit(&e->out_limit_gr[out], 0.0f, RLX);
}
uint64_t ar_engine_callback_count(ar_engine *e) { return atomic_load_explicit(&e->callbacks, RLX); }
uint64_t ar_engine_clip_count(ar_engine *e) { return atomic_load_explicit(&e->clip_events, RLX); }

float ar_engine_input_peak_hold(ar_engine *e, int in, int ch) {
    return (valid_in(in) && valid_ch(ch)) ? ldf(&e->in_peak_hold[in][ch]) : 0.0f;
}
bool ar_engine_input_clipped(ar_engine *e, int in, int ch) {
    return (valid_in(in) && valid_ch(ch)) && atomic_load_explicit(&e->in_clipped[in][ch], RLX);
}
void ar_engine_reset_input_peak_hold(ar_engine *e, int in, int ch) {
    if (!valid_in(in) || !valid_ch(ch)) return;
    stf(&e->in_peak_hold[in][ch], 0.0f);
    atomic_store_explicit(&e->in_clipped[in][ch], false, RLX);
}
float ar_engine_output_peak_hold(ar_engine *e, int out, int ch) {
    return (valid_out(out) && valid_ch(ch)) ? ldf(&e->out_peak_hold[out][ch]) : 0.0f;
}
bool ar_engine_output_clipped(ar_engine *e, int out, int ch) {
    return (valid_out(out) && valid_ch(ch)) && atomic_load_explicit(&e->out_clipped[out][ch], RLX);
}
void ar_engine_reset_output_peak_hold(ar_engine *e, int out, int ch) {
    if (!valid_out(out) || !valid_ch(ch)) return;
    stf(&e->out_peak_hold[out][ch], 0.0f);
    atomic_store_explicit(&e->out_clipped[out][ch], false, RLX);
}

// Compare-and-swap, so a reset from the UI landing between our read and our
// write isn't silently undone by writing the old peak back.
static inline void raise_peak_hold(_Atomic float *hold, _Atomic bool *clip, float v) {
    float cur = ldf(hold);
    while (v > cur && !atomic_compare_exchange_weak_explicit(hold, &cur, v, RLX, RLX)) {}
    if (v >= 1.0f) atomic_store_explicit(clip, true, RLX);
}

uint64_t ar_engine_last_callback_time(ar_engine *e) { return atomic_load_explicit(&e->last_cb_time, RLX); }
uint64_t ar_engine_first_callback_time(ar_engine *e) { return atomic_load_explicit(&e->first_cb_time, RLX); }
uint64_t ar_engine_take_max_callback_interval(ar_engine *e) { return atomic_exchange_explicit(&e->max_cb_interval, 0, RLX); }
uint64_t ar_engine_take_max_process_time(ar_engine *e) { return atomic_exchange_explicit(&e->max_process_time, 0, RLX); }
uint64_t ar_engine_missing_buffer_count(ar_engine *e) { return atomic_load_explicit(&e->missing_buffers, RLX); }

uint32_t ar_engine_take_input_zero_run(ar_engine *e, int in) {
    return valid_in(in) ? atomic_exchange_explicit(&e->in_max_zero_run[in], 0u, RLX) : 0u;
}
uint32_t ar_engine_take_output_zero_run(ar_engine *e, int out) {
    return valid_out(out) ? atomic_exchange_explicit(&e->out_max_zero_run[out], 0u, RLX) : 0u;
}

static inline void raise_u64(_Atomic uint64_t *p, uint64_t v) {
    if (v > atomic_load_explicit(p, RLX)) atomic_store_explicit(p, v, RLX);
}

static inline void track_zero_run(uint32_t *run, _Atomic uint32_t *max, bool silent, uint32_t n) {
    *run = silent ? (*run > UINT32_MAX - n ? UINT32_MAX : *run + n) : 0u;
    if (*run > atomic_load_explicit(max, RLX)) atomic_store_explicit(max, *run, RLX);
}

static inline void raise_peak(_Atomic float *p, float v) {
    if (v > ldf(p)) stf(p, v);
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
static inline const AudioBuffer *resolve(const AudioBufferList *l, ar_ref r) {
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

// De-interleave one input slot into in_buf, dropping garbage samples.
// Flags a missing or short buffer, and tracks runs of exact digital silence.
static void gather_input(ar_engine *e, int i, const AudioBufferList *in, uint32_t offset, uint32_t n,
                         bool *missing) {
    const ar_map *m = &e->in_map[i];
    bool silent = true;
    for (int c = 0; c < m->n; c++) {
        float *dst = e->in_buf[i][c];
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
            if (!(fabsf(x) <= AR_INPUT_SANITY)) x = 0.0f; // also catches NaN/Inf
            if (x != 0.0f) silent = false;
            dst[k] = x;
        }
    }
    track_zero_run(&e->in_zero_run[i], &e->in_max_zero_run[i], silent, n);
}

// Compressor static curve: gain change in dB for a level in dB (soft knee).
static inline float comp_curve_db(float level_db) {
    const float over = level_db - AR_COMP_THRESHOLD_DB;
    const float slope = 1.0f / AR_COMP_RATIO - 1.0f;
    if (2.0f * over < -AR_COMP_KNEE_DB) return 0.0f;
    if (2.0f * fabsf(over) <= AR_COMP_KNEE_DB) {
        const float t = over + AR_COMP_KNEE_DB / 2.0f;
        return slope * t * t / (2.0f * AR_COMP_KNEE_DB);
    }
    return slope * over;
}

static inline void settle(double *z) {
    if (!isfinite(*z) || fabs(*z) < 1e-25) *z = 0.0;
}

// Low-cut coefficients for this strip's amount: RBJ cookbook high-pass,
// Q = 1/sqrt(2) (Butterworth), at 80 Hz x amount. Recomputed only when the
// amount or the sample rate changes.
static void lowcut_coefficients(ar_fx *s, float amount, float fs) {
    if (s->lc_rate == fs && s->lc_amount == amount) return;
    const double hz = AR_LOWCUT_HZ * (amount < AR_LOWCUT_MIN_AMOUNT ? AR_LOWCUT_MIN_AMOUNT : amount);
    const double w0 = 2.0 * M_PI * hz / fs;
    const double cw = cos(w0), alpha = sin(w0) * M_SQRT1_2;
    const double a0 = 1.0 + alpha;
    s->lc_b0 = (1.0 + cw) / 2.0 / a0;
    s->lc_b1 = -(1.0 + cw) / a0;
    s->lc_b2 = s->lc_b0;
    s->lc_a1 = -2.0 * cw / a0;
    s->lc_a2 = (1.0 - alpha) / a0;
    s->lc_amount = amount;
    s->lc_rate = fs;
}

// Limiter amount: up to 100% it blends the limiter in; above, the ceiling drops.
static inline float limit_mix(float amount) { return amount < 1.0f ? amount : 1.0f; }
static inline float limit_ceiling(float amount) {
    return amount <= 1.0f ? AR_LIMIT_CEILING
                          : AR_LIMIT_CEILING * expf(-(amount - 1.0f) * AR_LIMIT_DB_PER_AMOUNT * 0.11512925f);
}

// One sample of the noise gate: level tracking, floor estimate and the gate
// itself. `power` is the strip's mean-square after the low-cut, so rumble below
// the low-cut can't hold the gate open. Returns the gate gain, 0..1.
static inline float gate_step(const ar_engine *e, ar_fx *s, float power, float threshold_ratio) {
    s->gate_level += e->gate_level_coef * (power - s->gate_level);
    s->gate_det += (power > s->gate_det ? e->gate_det_attack : e->gate_det_release) * (power - s->gate_det);
    const float level = s->gate_level;

    // Half-second summaries: the quietest level, and whether it held steady.
    // "Steady" compares the fast detector's loudest moment with the slow level's
    // quietest: every note attack or syllable is a jump the detector catches,
    // even in dense legato playing whose slow level barely moves.
    if (s->gate_sub_count == 0) {
        s->gate_sub_min = level;
        s->gate_sub_max = s->gate_det;
    } else {
        if (level < s->gate_sub_min) s->gate_sub_min = level;
        if (s->gate_det > s->gate_sub_max) s->gate_sub_max = s->gate_det;
    }
    if (++s->gate_sub_count >= e->gate_sub_samples) {
        const int32_t p = s->gate_sub_pos;
        s->gate_mins[p] = s->gate_sub_min;
        s->gate_steady[p] = s->gate_sub_max <= s->gate_sub_min * e->gate_steady_ratio;
        s->gate_sub_pos = (p + 1) % AR_GATE_SUBS;
        if (s->gate_subs_filled < AR_GATE_SUBS) s->gate_subs_filled++;
        float quietest = s->gate_mins[0];
        bool steady = s->gate_subs_filled == AR_GATE_SUBS;
        for (int32_t j = 0; j < s->gate_subs_filled; j++) {
            if (s->gate_mins[j] < quietest) quietest = s->gate_mins[j];
            steady = steady && s->gate_steady[j];
        }
        s->gate_win_min = quietest;
        s->gate_all_steady = steady;
        s->gate_sub_count = 0;
    }

    // Floor: down to any new minimum at once; up only through steady noise.
    float floor = s->gate_floor < AR_GATE_FLOOR_MIN ? AR_GATE_FLOOR_MIN : s->gate_floor;
    if (level < floor) {
        floor = level;
    } else if (s->gate_all_steady && floor < s->gate_win_min) {
        floor *= e->gate_rise;
        if (floor > s->gate_win_min) floor = s->gate_win_min;
    }
    floor = floor < AR_GATE_FLOOR_MIN ? AR_GATE_FLOOR_MIN : floor > AR_GATE_FLOOR_MAX ? AR_GATE_FLOOR_MAX : floor;
    s->gate_floor = floor;

    // The gate: open the moment the detector crosses the threshold, hold, then close.
    if (s->gate_det > floor * threshold_ratio) s->gate_hold = e->gate_hold_samples;
    else if (s->gate_hold > 0) s->gate_hold--;
    const float target = s->gate_hold > 0 ? 1.0f : 0.0f;
    s->gate_gain += (target > s->gate_gain ? e->gate_attack_coef : e->gate_release_coef) * (target - s->gate_gain);
    return s->gate_gain;
}

// One sample of auto level. `power` is the mean-square after the gate, before
// auto level itself. Returns the gain to apply, in dB.
static inline float autolevel_step(const ar_engine *e, ar_fx *s, float power, bool gate_closed, float strength) {
    s->al_level += e->al_level_coef * (power - s->al_level);
    s->al_det += (power > s->al_det ? e->al_det_attack : e->al_det_release) * (power - s->al_det);
    const float level_db = 10.0f * log10f(s->al_level + 1e-12f);
    const bool warm = s->al_warm >= e->al_warm_samples;

    // Is the student actually making sound? Not while the gate is shut, not
    // below an absolute floor, and not far below their normal level (that's
    // the room, not the student).
    const bool present = !gate_closed && level_db > AR_AL_PRESENT_ABS_DB
                         && (!warm || level_db > s->al_ref_db - AR_AL_PRESENT_BELOW_DB);

    float target = 0.0f;
    if (present) {
        if (!warm) {
            s->al_ref_db = s->al_warm == 0 ? level_db : s->al_ref_db + e->al_ref_cold * (level_db - s->al_ref_db);
            s->al_warm++;
        } else {
            s->al_ref_db += (level_db > s->al_ref_db ? e->al_ref_rise : e->al_ref_fall) * (level_db - s->al_ref_db);
            const float shortfall = s->al_ref_db - AR_AL_DEADZONE_DB - level_db;
            if (shortfall > 0.0f)
                target = fminf(shortfall * fminf(AR_AL_BOOST_RATIO + AR_AL_BOOST_RATIO_PER_STRENGTH * strength, 1.0f),
                               fminf(AR_AL_MAX_BOOST_DB * strength, AR_AL_BOOST_CAP_DB));
        }
    }
    const float rate = !present ? e->al_boost_idle : target > s->al_boost_db ? e->al_boost_up : e->al_boost_down;
    s->al_boost_db += rate * (target - s->al_boost_db);

    float gain_db = s->al_boost_db;
    if (warm) {
        // Loud regime: the boosted level may never run more than the headroom above normal.
        const float ceiling_db = s->al_ref_db + AR_AL_HEADROOM_DB - AR_AL_HEADROOM_PER_STRENGTH * strength;
        const float det_db = 10.0f * log10f(s->al_det + 1e-12f) + gain_db;
        if (det_db > ceiling_db) gain_db -= det_db - ceiling_db;
    }
    return gain_db;
}

// The channel strip, in signal order:
//   low-cut -> noise gate -> auto level -> compress (and the fader) -> limiter
// Every effect runs all the time and is crossfaded in or out via its mix_*
// (driven by on/off and, for low-cut/compress/limiter, scaled by its level
// knob too), so switching one never clicks and its state is always warm.
// Each effect's detector reads the signal as it leaves the effect before it.
static void process_strip(ar_engine *e, int i, uint32_t n, float g0, float g1, float coef) {
    const int nc = e->in_map[i].n;
    ar_fx *s = &e->fx[i];
    const uint32_t flags = atomic_load_explicit(&e->fx_flags[i], RLX);
    const float lv_lowcut = ldf(&e->fx_level[i][AR_FXI_LOWCUT]);
    const float lv_gate = ldf(&e->fx_level[i][AR_FXI_NOISEGATE]);
    const float lv_al = ldf(&e->fx_level[i][AR_FXI_AUTOLEVEL]);
    const float lv_comp = ldf(&e->fx_level[i][AR_FXI_COMPRESSOR]);
    const float lv_limit = ldf(&e->fx_level[i][AR_FXI_LIMITER]);

    const float h0 = s->mix_lowcut, gt0 = s->mix_gate, al0 = s->mix_autolevel, c0 = s->mix_comp, l0 = s->mix_limit;
    const float h1 = smooth_toward(h0, (flags & AR_FX_LOWCUT) ? fminf(1.0f, lv_lowcut / AR_LOWCUT_MIN_AMOUNT) : 0.0f, coef);
    const float gt1 = smooth_toward(gt0, (flags & AR_FX_NOISEGATE) ? 1.0f : 0.0f, coef);
    const float al1 = smooth_toward(al0, (flags & AR_FX_AUTOLEVEL) ? 1.0f : 0.0f, coef);
    const float c1 = smooth_toward(c0, (flags & AR_FX_COMPRESSOR) ? 1.0f : 0.0f, coef);
    const float l1 = smooth_toward(l0, (flags & AR_FX_LIMITER) ? limit_mix(lv_limit) : 0.0f, coef);
    const float ceiling = limit_ceiling(lv_limit);
    s->mix_lowcut = h1; s->mix_gate = gt1; s->mix_autolevel = al1; s->mix_comp = c1; s->mix_limit = l1;

    const float inv = 1.0f / (float)n;
    const float dg = (g1 - g0) * inv, dh = (h1 - h0) * inv, dgt = (gt1 - gt0) * inv,
                dal = (al1 - al0) * inv, dc = (c1 - c0) * inv, dl = (l1 - l0) * inv;
    float g = g0, h = h0, gtm = gt0, alm = al0, cm = c0, lm = l0;

    lowcut_coefficients(s, lv_lowcut, e->sample_rate);
    const double b0 = s->lc_b0, b1 = s->lc_b1, b2 = s->lc_b2, a1 = s->lc_a1, a2 = s->lc_a2;
    float comp_env = s->comp_env, lim_env = s->lim_env;
    // Amounts: the gate's moves its threshold; auto level's is its strength.
    const float gate_ratio = expf((AR_GATE_MARGIN_DB + (lv_gate - 1.0f) * AR_GATE_BIAS_DB_PER_AMOUNT) * 0.23025851f);
    const float al_strength = lv_al;
    float peak[AR_MAX_SLOT_CHANNELS] = { 0.0f, 0.0f };
    float most_comp = 0.0f, least_lim = 1.0f, most_gate_cut = 0.0f, most_lift = 0.0f, most_cap = 0.0f;

    for (uint32_t k = 0; k < n; k++) {
        g += dg; h += dh; gtm += dgt; alm += dal; cm += dc; lm += dl;
        float x[AR_MAX_SLOT_CHANNELS];
        float power = 0.0f;

        // --- Low-cut ---------------------------------------------------------
        for (int c = 0; c < nc; c++) {
            const double in = e->in_buf[i][c][k];
            const double y = b0 * in + s->z1[c];
            s->z1[c] = b1 * in - a1 * y + s->z2[c];
            s->z2[c] = b2 * in - a2 * y;
            const float v = (float)in + h * ((float)y - (float)in);
            x[c] = v;
            power += v * v;
        }
        power /= (float)nc;

        // --- Noise gate --------------------------------------------------------
        const float gate_gain = gate_step(e, s, power, gate_ratio);
        const float gfac = 1.0f - gtm * (1.0f - gate_gain);
        if (gtm > 0.5f) {
            const float att_db = gate_gain > 1e-6f ? -20.0f * log10f(gate_gain) : 60.0f;
            if (att_db > most_gate_cut) most_gate_cut = att_db;
        }
        power *= gfac * gfac;
        for (int c = 0; c < nc; c++) x[c] *= gfac;

        // --- Auto level --------------------------------------------------------
        const float al_db = autolevel_step(e, s, power, gtm > 0.5f && gate_gain < 0.5f, al_strength);
        if (alm > 0.5f) {
            if (s->al_boost_db > most_lift) most_lift = s->al_boost_db;       // lifting a quiet passage
            if (s->al_boost_db - al_db > most_cap) most_cap = s->al_boost_db - al_db; // capping a jump
        }
        const float alfac = 1.0f + alm * (expf(al_db * 0.11512925f) - 1.0f); // dB -> linear
        power *= alfac * alfac;
        for (int c = 0; c < nc; c++) x[c] *= alfac;

        // --- Compress --------------------------------------------------------
        comp_env += ((power > comp_env) ? e->comp_attack : e->comp_release) * (power - comp_env);
        float gain = g;
        if (cm > 0.0f) {
            // The amount scales the whole curve: 50% is half the gain change, 150% half as much again.
            const float curve = comp_curve_db(10.0f * log10f(comp_env + 1e-12f)) * lv_comp;
            if (-curve > most_comp) most_comp = -curve;
            const float gc = expf((curve + AR_COMP_MAKEUP_DB * lv_comp) * 0.11512925f); // dB -> linear
            gain *= 1.0f + cm * (gc - 1.0f);
        }

        float pk = 0.0f;
        for (int c = 0; c < nc; c++) {
            x[c] *= gain;
            const float a = fabsf(x[c]);
            if (a > pk) pk = a;
        }

        // --- Limiter -----------------------------------------------------------
        // Instant attack: the envelope is never below this sample's peak, so
        // with the limiter fully in, nothing can pass the ceiling.
        lim_env *= e->limit_release;
        if (pk > lim_env) lim_env = pk;
        const float gl = lim_env > ceiling ? ceiling / lim_env : 1.0f;
        if (lm > 0.5f && gl < least_lim) least_lim = gl;
        const float glim = 1.0f + lm * (gl - 1.0f);

        for (int c = 0; c < nc; c++) {
            const float v = x[c] * glim;
            e->in_buf[i][c][k] = v;
            const float a = fabsf(v);
            if (a > peak[c]) peak[c] = a;
        }
    }

    for (int c = 0; c < nc; c++) {
        settle(&s->z1[c]);
        settle(&s->z2[c]);
        raise_peak(&e->in_peak[i][c], peak[c]);
        raise_peak_hold(&e->in_peak_hold[i][c], &e->in_clipped[i][c], peak[c]);
    }
    s->comp_env = isfinite(comp_env) ? comp_env : 0.0f;
    s->lim_env = isfinite(lim_env) ? lim_env : 0.0f;
    // A NaN can't reach here (inputs are sanitised), but if one ever did, start the dynamics afresh.
    if (!isfinite(s->gate_level) || !isfinite(s->gate_det) || !isfinite(s->gate_floor) || !isfinite(s->gate_gain)) {
        s->gate_level = s->gate_det = s->gate_floor = 0.0f;
        s->gate_gain = 1.0f;
    }
    if (!isfinite(s->al_level) || !isfinite(s->al_det) || !isfinite(s->al_ref_db) || !isfinite(s->al_boost_db)) {
        s->al_level = s->al_det = s->al_boost_db = 0.0f;
        s->al_warm = 0;
    }
    if (most_comp > 0.0f) raise_peak(&e->comp_gr[i], most_comp);
    if (least_lim < 1.0f) raise_peak(&e->limit_gr[i], -20.0f * log10f(least_lim));
    if (most_gate_cut > 0.0f) raise_peak(&e->gate_gr[i], most_gate_cut);
    if (most_lift > 0.0f) raise_peak(&e->al_lift[i], most_lift);
    if (most_cap > 0.0f) raise_peak(&e->al_cap[i], most_cap);
}

// Mix every routed input into one output slot, apply the output-bus limiter
// if it's on, and add the result to the hardware buffer.
static void mix_output(ar_engine *e, int o, AudioBufferList *out,
                       uint32_t offset, uint32_t n, float coef, bool *missing) {
    const ar_map *om = &e->out_map[o];
    const int no = om->n;
    const float og = atomic_load_explicit(&e->out_mute[o], RLX) ? 0.0f : clean_gain(ldf(&e->out_gain[o]));

    for (int c = 0; c < no; c++) memset(e->mix_buf[c], 0, n * sizeof(float));

    for (int i = 0; i < AR_MAX_INPUTS; i++) {
        const int ni = e->in_map[i].n;
        float target = 0.0f;
        if (ni > 0 && !atomic_load_explicit(&e->in_mute[i], RLX))
            target = clean_gain(ldf(&e->route[i][o])) * og;
        const float g0 = e->cur_route[i][o];
        const float g1 = smooth_toward(g0, target, coef);
        e->cur_route[i][o] = g1;
        if (ni == 0 || (g0 == 0.0f && g1 == 0.0f)) continue;

        const float dg = (g1 - g0) / (float)n;
        const float *l = e->in_buf[i][0];
        const float *r = ni > 1 ? e->in_buf[i][1] : l; // mono feeds both sides
        float g = g0;
        if (no == 1) {
            float *d = e->mix_buf[0];
            if (ni == 1) {
                for (uint32_t k = 0; k < n; k++) { g += dg; d[k] += l[k] * g; }
            } else {
                for (uint32_t k = 0; k < n; k++) { g += dg; d[k] += 0.5f * (l[k] + r[k]) * g; }
            }
        } else {
            float *dl = e->mix_buf[0], *dr = e->mix_buf[1];
            for (uint32_t k = 0; k < n; k++) { g += dg; dl[k] += l[k] * g; dr[k] += r[k] * g; }
        }
    }

    // Output limiter: a final safety ceiling on this bus, after every input has
    // summed into it. Same instant-attack/exponential-release technique as the
    // input limiter, one shared envelope across the bus's channels so stereo
    // content ducks together rather than shifting balance.
    ar_out_fx *ofx = &e->out_fx[o];
    const uint32_t oflags = atomic_load_explicit(&e->out_fx_flags[o], RLX);
    const float olevel = ldf(&e->out_fx_level[o]);
    const float ol0 = ofx->mix_limit;
    const float ol1 = smooth_toward(ol0, (oflags & AR_FX_LIMITER) ? limit_mix(olevel) : 0.0f, coef);
    const float oceiling = limit_ceiling(olevel);
    ofx->mix_limit = ol1;
    if (no > 0) {
        const float dol = (ol1 - ol0) / (float)n;
        float olm = ol0;
        float lim_env = ofx->lim_env;
        float least = 1.0f;
        for (uint32_t k = 0; k < n; k++) {
            olm += dol;
            float pk = 0.0f;
            for (int c = 0; c < no; c++) { const float a = fabsf(e->mix_buf[c][k]); if (a > pk) pk = a; }
            lim_env *= e->limit_release;
            if (pk > lim_env) lim_env = pk;
            const float gl = lim_env > oceiling ? oceiling / lim_env : 1.0f;
            if (olm > 0.5f && gl < least) least = gl;
            const float glim = 1.0f + olm * (gl - 1.0f);
            for (int c = 0; c < no; c++) e->mix_buf[c][k] *= glim;
        }
        ofx->lim_env = isfinite(lim_env) ? lim_env : 0.0f;
        if (least < 1.0f) raise_peak(&e->out_limit_gr[o], -20.0f * log10f(least));
    }

    bool silent = true;
    for (int c = 0; c < no; c++) {
        const float *s = e->mix_buf[c];
        float peak = 0.0f;
        for (uint32_t k = 0; k < n; k++) {
            const float a = fabsf(s[k]);
            if (a > peak) peak = a;
        }
        if (peak != 0.0f) silent = false;
        raise_peak(&e->out_peak[o][c], peak > 1.0f ? 1.0f : peak);
        raise_peak_hold(&e->out_peak_hold[o][c], &e->out_clipped[o][c], peak);

        const AudioBuffer *cb = resolve(out, om->c[c]);
        if (!cb) {
            *missing = true;
            continue;
        }
        const uint32_t stride = cb->mNumberChannels;
        const uint32_t avail = buf_frames(cb);
        if (avail < offset + n) *missing = true;
        float *dst = (float *)cb->mData + om->c[c].ch;
        for (uint32_t k = 0; k < n; k++) {
            const uint32_t f = offset + k;
            if (f < avail) dst[(size_t)f * stride] += s[k];
        }
    }
    track_zero_run(&e->out_zero_run[o], &e->out_max_zero_run[o], silent, n);
}

// Transparent below the knee, smooth tanh saturation above it, never past 1.0.
// The last line of defence: several limited inputs can still sum past full scale.
static void safety_clip(ar_engine *e, AudioBufferList *out) {
    bool clipped = false;
    for (UInt32 b = 0; b < out->mNumberBuffers; b++) {
        float *d = out->mBuffers[b].mData;
        if (!d) continue;
        const uint32_t count = out->mBuffers[b].mDataByteSize / sizeof(float);
        for (uint32_t j = 0; j < count; j++) {
            const float x = d[j];
            const float a = fabsf(x);
            if (a > AR_CLIP_KNEE) {
                if (a > 1.0f) clipped = true;
                const float over = (a - AR_CLIP_KNEE) / (1.0f - AR_CLIP_KNEE);
                d[j] = copysignf(AR_CLIP_KNEE + (1.0f - AR_CLIP_KNEE) * tanhf(over), x);
            }
        }
    }
    if (clipped) atomic_fetch_add_explicit(&e->clip_events, 1, RLX);
}

static void render(ar_engine *e, const AudioBufferList *in, AudioBufferList *out);

void ar_engine_process(ar_engine *e, const AudioBufferList *in, AudioBufferList *out) {
    if (!e) return;
    // mach_absolute_time is a plain register read: safe on the audio thread.
    const uint64_t began = mach_absolute_time();
    const uint64_t previous = atomic_load_explicit(&e->last_cb_time, RLX);
    atomic_store_explicit(&e->last_cb_time, began, RLX);
    if (previous != 0 && began > previous) raise_u64(&e->max_cb_interval, began - previous);
    if (atomic_load_explicit(&e->first_cb_time, RLX) == 0) atomic_store_explicit(&e->first_cb_time, began, RLX);
    atomic_fetch_add_explicit(&e->callbacks, 1, RLX);

    render(e, in, out);

    const uint64_t ended = mach_absolute_time();
    if (ended > began) raise_u64(&e->max_process_time, ended - began);
}

static void render(ar_engine *e, const AudioBufferList *in, AudioBufferList *out) {

    // The HAL does not promise zeroed output buffers. Every channel we don't
    // write (including loopback devices we only read from) must be silence.
    if (out) {
        for (UInt32 b = 0; b < out->mNumberBuffers; b++)
            if (out->mBuffers[b].mData) memset(out->mBuffers[b].mData, 0, out->mBuffers[b].mDataByteSize);
    }

    uint32_t frames = list_frames(out);
    if (frames == 0) frames = list_frames(in);
    if (frames == 0) return;

    const float sr = e->sample_rate > 0.0f ? e->sample_rate : 48000.0f;
    bool missing = false;
    for (uint32_t offset = 0; offset < frames; offset += AR_BLOCK) {
        const uint32_t n = (frames - offset) < AR_BLOCK ? (frames - offset) : AR_BLOCK;
        const float coef = 1.0f - expf(-(float)n / (AR_SMOOTH_SECONDS * sr));

        for (int i = 0; i < AR_MAX_INPUTS; i++) {
            if (e->in_map[i].n == 0) continue;
            const float g0 = e->cur_in[i];
            const float g1 = smooth_toward(g0, clean_gain(ldf(&e->in_gain[i])), coef);
            e->cur_in[i] = g1;
            gather_input(e, i, in, offset, n, &missing);
            process_strip(e, i, n, g0, g1, coef);
        }
        for (int o = 0; o < AR_MAX_OUTPUTS; o++) {
            if (e->out_map[o].n == 0) continue;
            mix_output(e, o, out, offset, n, coef, &missing);
        }
    }

    if (missing) atomic_fetch_add_explicit(&e->missing_buffers, 1, RLX);
    if (out) safety_clip(e, out);
}

// ---------------------------------------------------------------------------
// Hardware glue

static OSStatus ar_ioproc(AudioObjectID device, const AudioTimeStamp *now,
                          const AudioBufferList *inData, const AudioTimeStamp *inTime,
                          AudioBufferList *outData, const AudioTimeStamp *outTime,
                          void *ctx) {
    (void)device; (void)now; (void)inTime; (void)outTime;
    ar_engine_process((ar_engine *)ctx, inData, outData);
    return noErr;
}

OSStatus ar_engine_start(ar_engine *e, AudioObjectID device) {
    if (atomic_load(&e->running)) return kAudioHardwareIllegalOperationError;
    AudioDeviceIOProcID proc = NULL;
    OSStatus s = AudioDeviceCreateIOProcID(device, ar_ioproc, e, &proc);
    if (s != noErr) return s;
    e->device = device;
    e->proc = proc;
    atomic_store(&e->first_cb_time, 0);
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

OSStatus ar_engine_stop(ar_engine *e) {
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

bool ar_engine_is_running(ar_engine *e) { return atomic_load(&e->running); }
