// Deterministic tests for the split engine. No audio hardware needed.
//
// Signals are fed through sc_engine_process exactly as Core Audio would call it,
// in 128-frame callbacks at 48 kHz.

#include "SplitCore.h"

#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define FS 48000.0
#define FRAMES 128
#define OUT_CH 8

static int failures = 0;
static int checks = 0;

#define CHECK(cond, ...) do { \
    checks++; \
    if (!(cond)) { failures++; printf("  FAIL %s:%d: ", __FILE__, __LINE__); printf(__VA_ARGS__); printf("\n"); } \
} while (0)

// A test rig: one interleaved input buffer and one interleaved 8-channel output buffer.
typedef struct {
    int in_ch;
    float in[FRAMES * 2];
    float out[FRAMES * OUT_CH];
    AudioBufferList in_list;
    AudioBufferList out_list;
} rig;

static void rig_init(rig *r, int in_ch) {
    memset(r, 0, sizeof *r);
    r->in_ch = in_ch;
    r->in_list.mNumberBuffers = 1;
    r->in_list.mBuffers[0] = (AudioBuffer){ (UInt32)in_ch, (UInt32)(FRAMES * in_ch * sizeof(float)), r->in };
    r->out_list.mNumberBuffers = 1;
    r->out_list.mBuffers[0] = (AudioBuffer){ OUT_CH, FRAMES * OUT_CH * sizeof(float), r->out };
}

static void run(sc_engine *e, rig *r) { sc_engine_process(e, &r->in_list, &r->out_list); }

static double db(double x) { return 20.0 * log10(x > 1e-12 ? x : 1e-12); }

static sc_engine *make(int in_ch) {
    sc_engine *e = sc_engine_create();
    sc_engine_set_sample_rate(e, FS);
    sc_engine_set_input_map(e, in_ch, 0, 0, in_ch == 2 ? 0 : -1, in_ch == 2 ? 1 : -1);
    return e;
}

static void set_edges(sc_engine *e, const sc_edge edges[SC_EDGES]) {
    for (int k = 0; k < SC_EDGES; k++) sc_engine_set_edge(e, k, edges[k].hz, edges[k].slope);
}

// Feeds a sine for `settle_s`, then measures the RMS of each output channel
// (and of the input) over `measure_s`.
static void sine_rms(sc_engine *e, rig *r, double hz, double amp, double settle_s, double measure_s,
                     double rms_out[OUT_CH], double *rms_in) {
    double acc[OUT_CH] = { 0 }, acc_in = 0;
    long count = 0;
    const long total = (long)((settle_s + measure_s) * FS / FRAMES);
    const long settle = (long)(settle_s * FS / FRAMES);
    static long phase = 0;
    for (long cb = 0; cb < total; cb++) {
        for (int k = 0; k < FRAMES; k++, phase++) {
            const float v = (float)(amp * sin(2.0 * M_PI * hz * (double)phase / FS));
            for (int c = 0; c < r->in_ch; c++) r->in[k * r->in_ch + c] = v;
            if (cb >= settle) acc_in += (double)v * v;
        }
        run(e, r);
        if (cb >= settle) {
            for (int k = 0; k < FRAMES; k++)
                for (int c = 0; c < OUT_CH; c++) acc[c] += (double)r->out[k * OUT_CH + c] * r->out[k * OUT_CH + c];
            count += FRAMES;
        }
    }
    for (int c = 0; c < OUT_CH; c++) rms_out[c] = sqrt(acc[c] / (double)count);
    if (rms_in) *rms_in = sqrt(acc_in / (double)count);
}

static const sc_edge defaults[SC_EDGES] = { { 20, 24 }, { 100, 24 }, { 1000, 24 }, { 5000, 24 }, { 20000, 24 } };

// ---------------------------------------------------------------------------

// With the outer edges off, the four bands must add back up to the input at
// every frequency, for every slope. This is the property that lets the speakers
// sum flat in the room.
static void test_bands_sum_flat(void) {
    printf("Bands sum flat (outer edges off)\n");
    const int slopes[] = { 6, 12, 24, 36, 48 };
    const double freqs[] = { 25, 60, 100, 180, 400, 1000, 2200, 5000, 9000, 16000 };
    for (size_t si = 0; si < sizeof slopes / sizeof *slopes; si++) {
        sc_engine *e = make(1);
        rig r; rig_init(&r, 1);
        sc_edge ed[SC_EDGES] = { { 20, 0 }, { 100, slopes[si] }, { 1000, slopes[si] }, { 5000, slopes[si] }, { 20000, 0 } };
        set_edges(e, ed);
        for (int b = 0; b < SC_BANDS; b++) sc_engine_set_band_map(e, b, 1, 0, 0, -1, -1); // all onto channel 1
        double worst = 0;
        for (size_t fi = 0; fi < sizeof freqs / sizeof *freqs; fi++) {
            double out[OUT_CH], in;
            sine_rms(e, &r, freqs[fi], 0.5, 0.6, 0.4, out, &in);
            const double err = fabs(db(out[0] / in));
            if (err > worst) worst = err;
            CHECK(err < 0.05, "slope %d: sum at %.0f Hz is %+.3f dB", slopes[si], freqs[fi], db(out[0] / in));
        }
        printf("  %2d dB/oct: worst deviation %.4f dB\n", slopes[si], worst);
        sc_engine_destroy(e);
    }
}

// The engine's measured band levels match sc_band_response_db, which the
// display draws. Checked for every band, several slopes, with the outer edges on.
static void test_response_matches_engine(void) {
    printf("Display response matches the engine\n");
    const int slopes[] = { 6, 12, 48 };
    const double freqs[] = { 15, 40, 100, 300, 1000, 3000, 5000, 12000, 21000 };
    for (size_t si = 0; si < sizeof slopes / sizeof *slopes; si++) {
        sc_engine *e = make(1);
        rig r; rig_init(&r, 1);
        sc_edge ed[SC_EDGES] = { { 30, slopes[si] }, { 120, slopes[si] }, { 800, slopes[si] }, { 4000, slopes[si] }, { 16000, slopes[si] } };
        set_edges(e, ed);
        for (int b = 0; b < SC_BANDS; b++) sc_engine_set_band_map(e, b, 1, 0, b, -1, -1);
        for (size_t fi = 0; fi < sizeof freqs / sizeof *freqs; fi++) {
            double out[OUT_CH], in;
            sine_rms(e, &r, freqs[fi], 0.5, 0.8, 0.4, out, &in);
            for (int b = 0; b < SC_BANDS; b++) {
                const double measured = db(out[b] / in);
                const double predicted = sc_band_response_db(ed, FS, b, freqs[fi]);
                if (predicted < -70) continue; // below the measurement's noise
                CHECK(fabs(measured - predicted) < 0.1, "slope %d band %d at %.0f Hz: engine %+.2f dB, display %+.2f dB",
                      slopes[si], b, freqs[fi], measured, predicted);
            }
        }
        sc_engine_destroy(e);
    }
}

// The textbook numbers: Linkwitz-Riley is -6 dB on both sides at the crossover,
// first order -3 dB; one octave out, LR4 is about -24.6 dB and LR8 about -48.2 dB.
static void test_crossover_shapes(void) {
    printf("Crossover shapes\n");
    sc_edge ed[SC_EDGES];
    memcpy(ed, defaults, sizeof ed);
    ed[0].slope = 0; ed[4].slope = 0;
    const int slopes[] = { 12, 24, 36, 48 };
    for (size_t i = 0; i < 4; i++) {
        ed[2].slope = slopes[i];
        const double lo = sc_band_response_db(ed, FS, 1, 1000), hi = sc_band_response_db(ed, FS, 2, 1000);
        CHECK(fabs(lo + 6.02) < 0.1 && fabs(hi + 6.02) < 0.1, "LR%d at the crossover: %.2f / %.2f dB", slopes[i] / 6, lo, hi);
    }
    ed[2].slope = 6;
    CHECK(fabs(sc_band_response_db(ed, FS, 1, 1000) + 3.01) < 0.1, "first order at the crossover: %.2f dB", sc_band_response_db(ed, FS, 1, 1000));
    ed[1].slope = 24;
    double v = sc_band_response_db(ed, FS, 0, 200);
    CHECK(fabs(v + 24.6) < 0.4, "LR4 one octave above 100 Hz: %.2f dB", v);
    ed[1].slope = 48;
    v = sc_band_response_db(ed, FS, 0, 200);
    CHECK(fabs(v + 48.2) < 0.4, "LR8 one octave above 100 Hz: %.2f dB", v);
    // In the middle of its range each default band is within 1 dB of flat. (Not
    // exactly flat: 20-100 Hz is only 2.3 octaves, so the two 24 dB skirts overlap.)
    memcpy(ed, defaults, sizeof ed);
    const double centre[SC_BANDS] = { 45, 316, 2236, 10000 };
    for (int b = 0; b < SC_BANDS; b++) {
        v = sc_band_response_db(ed, FS, b, centre[b]);
        printf("  default band %d at %.0f Hz: %+.2f dB\n", b, centre[b], v);
        CHECK(v > -1.0 && v < 0.01, "band %d at %.0f Hz: %.2f dB", b, centre[b], v);
    }
    // The subsonic edge cuts the low band below 20 Hz.
    CHECK(sc_band_response_db(ed, FS, 0, 10) < -20, "low band at 10 Hz: %.2f dB", sc_band_response_db(ed, FS, 0, 10));
    // Frequencies past the top are clamped, never unstable.
    ed[4].hz = 40000;
    v = sc_band_response_db(ed, FS, 3, 10000);
    CHECK(isfinite(v) && fabs(v) < 0.5, "high edge clamped: %.2f dB at 10 kHz", v);
}

// A 50 Hz tone goes to the subs, not the small speakers.
static void test_separation(void) {
    printf("Separation\n");
    sc_engine *e = make(1);
    rig r; rig_init(&r, 1);
    set_edges(e, defaults);
    for (int b = 0; b < SC_BANDS; b++) sc_engine_set_band_map(e, b, 1, 0, b, -1, -1);
    double out[OUT_CH], in;
    sine_rms(e, &r, 50, 0.5, 0.6, 0.4, out, &in);
    printf("  50 Hz: low %+.1f, mid %+.1f, mid-high %+.1f, high %+.1f dB\n",
           db(out[0] / in), db(out[1] / in), db(out[2] / in), db(out[3] / in));
    CHECK(db(out[0] / in) > -1.0, "low band passes 50 Hz");
    CHECK(db(out[1] / in) < -20, "mid band rejects 50 Hz");
    CHECK(db(out[2] / in) < -60 && db(out[3] / in) < -60, "upper bands reject 50 Hz");
    sine_rms(e, &r, 10000, 0.5, 0.3, 0.2, out, &in);
    CHECK(db(out[3] / in) > -0.5, "high band passes 10 kHz (%+.2f dB)", db(out[3] / in));
    CHECK(db(out[0] / in) < -90, "low band rejects 10 kHz (%+.1f dB)", db(out[0] / in));
    for (int c = 4; c < OUT_CH; c++) CHECK(out[c] == 0.0, "unused channel %d is silent", c + 1);
    sc_engine_destroy(e);
}

// Stereo in, stereo, mono and doubled-up outputs.
static void test_routing(void) {
    printf("Routing\n");
    sc_engine *e = make(2);
    rig r; rig_init(&r, 2);
    sc_edge ed[SC_EDGES] = { { 20, 0 }, { 100, 6 }, { 1000, 6 }, { 5000, 6 }, { 20000, 0 } };
    set_edges(e, ed);
    // Only the high band, so what comes out is easy to predict at 10 kHz.
    sc_engine_set_band_map(e, 3, 2, 0, 0, 0, 1);  // stereo to channels 1+2
    sc_engine_set_band_map(e, 2, 1, 0, 2, -1, -1); // mono to channel 3
    for (int i = 0; i < 400; i++) {
        for (int k = 0; k < FRAMES; k++) { r.in[k * 2] = 0.5f; r.in[k * 2 + 1] = -0.25f; } // DC: all in the low band…
        run(e, &r);
    }
    CHECK(fabsf(r.out[0]) < 1e-3f && fabsf(r.out[2]) < 1e-3f, "DC doesn't reach the upper bands");

    // Left and right stay apart.
    double accL = 0, accR = 0, acc3 = 0;
    long phase = 0;
    for (int i = 0; i < 400; i++) {
        for (int k = 0; k < FRAMES; k++, phase++) {
            const float s = (float)sin(2.0 * M_PI * 12000.0 * (double)phase / FS);
            r.in[k * 2] = 0.5f * s;
            r.in[k * 2 + 1] = 0.0f;
        }
        run(e, &r);
        if (i >= 200)
            for (int k = 0; k < FRAMES; k++) {
                accL += (double)r.out[k * OUT_CH] * r.out[k * OUT_CH];
                accR += (double)r.out[k * OUT_CH + 1] * r.out[k * OUT_CH + 1];
                acc3 += (double)r.out[k * OUT_CH + 2] * r.out[k * OUT_CH + 2];
            }
    }
    CHECK(accL > 1000 * accR + 1e-9, "left stays on the left (L %.3g, R %.3g)", accL, accR);
    (void)acc3;
    sc_engine_destroy(e);

    // Mono input to a stereo output: both sides. Two bands on one channel add.
    e = make(1);
    rig m; rig_init(&m, 1);
    sc_edge flat[SC_EDGES] = { { 20, 0 }, { 100, 24 }, { 1000, 24 }, { 5000, 24 }, { 20000, 0 } };
    set_edges(e, flat);
    sc_engine_set_band_map(e, 1, 2, 0, 4, 0, 5);
    sc_engine_set_band_map(e, 0, 1, 0, 6, -1, -1);
    sc_engine_set_band_map(e, 1, 2, 0, 4, 0, 5);
    double out[OUT_CH], in;
    sine_rms(e, &m, 316, 0.5, 0.5, 0.3, out, &in);
    CHECK(fabs(out[4] - out[5]) < 1e-9 && out[4] > 0.9 * in, "mono band fills both sides of a stereo output");
    sc_engine_destroy(e);

    // Stereo input into a mono output is averaged.
    e = make(2);
    rig s; rig_init(&s, 2);
    set_edges(e, flat);
    sc_engine_set_band_map(e, 1, 1, 0, 0, -1, -1);
    sine_rms(e, &s, 316, 0.5, 0.5, 0.3, out, &in); // same signal both sides: average = the signal
    CHECK(fabs(db(out[0] / in)) < 0.3, "stereo to mono keeps the level (%+.2f dB)", db(out[0] / in));
    sc_engine_destroy(e);
}

static void test_gain_and_mute(void) {
    printf("Gain and mute\n");
    sc_engine *e = make(1);
    rig r; rig_init(&r, 1);
    set_edges(e, defaults);
    sc_engine_set_band_map(e, 1, 1, 0, 0, -1, -1);
    double out[OUT_CH], in;
    sine_rms(e, &r, 316, 0.5, 0.3, 0.2, out, &in);
    const double unity = out[0];
    sc_engine_set_band_gain(e, 1, 0.5f);
    sine_rms(e, &r, 316, 0.5, 0.3, 0.2, out, &in);
    CHECK(fabs(db(out[0] / unity) + 6.02) < 0.05, "gain 0.5 is -6 dB (%+.2f)", db(out[0] / unity));
    sc_engine_set_band_mute(e, 1, true);
    sine_rms(e, &r, 316, 0.5, 0.2, 0.1, out, &in);
    CHECK(out[0] == 0.0, "muted band is silent");
    sc_engine_set_band_gain(e, 1, NAN);
    sc_engine_set_band_mute(e, 1, false);
    sine_rms(e, &r, 316, 0.5, 0.2, 0.1, out, &in);
    CHECK(out[0] == 0.0, "NaN gain is treated as silence");
    sc_engine_destroy(e);
}

// Largest jump between consecutive output samples on one channel while a
// callback-sized change happens mid-stream.
static float max_step_during(sc_engine *e, rig *r, double hz, int callbacks_before, void (*change)(sc_engine *), int callbacks_after) {
    float prev = 0, worst = 0;
    long phase = 0;
    for (int cb = 0; cb < callbacks_before + callbacks_after; cb++) {
        if (cb == callbacks_before) change(e);
        for (int k = 0; k < FRAMES; k++, phase++) r->in[k] = (float)(0.5 * sin(2.0 * M_PI * hz * (double)phase / FS));
        run(e, r);
        for (int k = 0; k < FRAMES; k++) {
            const float v = r->out[k * OUT_CH];
            if (cb > 20 && fabsf(v - prev) > worst) worst = fabsf(v - prev);
            prev = v;
        }
    }
    return worst;
}

static void change_slope(sc_engine *e) { sc_engine_set_edge(e, SC_EDGE_X1, 100, 48); }
static void jump_frequency(sc_engine *e) { sc_engine_set_edge(e, SC_EDGE_X1, 1500, 24); sc_engine_set_edge(e, SC_EDGE_X2, 3000, 24); }
static void nothing(sc_engine *e) { (void)e; }

// Changing a slope or yanking a frequency never clicks: no step in the output
// is much bigger than the tone's own steepest step.
static void test_no_clicks(void) {
    printf("Changes don't click\n");
    const double hz = 150;
    const float natural = (float)(2.0 * M_PI * hz * 0.5 / FS); // steepest step of the input sine

    sc_engine *e = make(1);
    rig r; rig_init(&r, 1);
    set_edges(e, defaults);
    sc_engine_set_band_map(e, 0, 1, 0, 0, -1, -1);
    const float base = max_step_during(e, &r, hz, 200, nothing, 200);
    sc_engine_destroy(e);

    e = make(1); rig_init(&r, 1); set_edges(e, defaults);
    sc_engine_set_band_map(e, 0, 1, 0, 0, -1, -1);
    const float slope = max_step_during(e, &r, hz, 200, change_slope, 200);
    printf("  steepest step: steady %.4f, slope change %.4f (tone alone %.4f)\n", base, slope, natural);
    CHECK(slope < 1.5f * natural, "slope change step %.4f", slope);
    sc_engine_destroy(e);

    e = make(1); rig_init(&r, 1); set_edges(e, defaults);
    sc_engine_set_band_map(e, 1, 1, 0, 0, -1, -1); // the mid band, whose lower edge moves from 100 Hz to 1.5 kHz
    const float glide = max_step_during(e, &r, hz, 200, jump_frequency, 400);
    printf("  frequency jump %.4f\n", glide);
    CHECK(glide < 1.5f * natural, "frequency jump step %.4f", glide);
    sc_engine_destroy(e);
}

// The engine ends up exactly where it was told, after a glide.
static void test_glide_lands(void) {
    printf("Glides land on the target\n");
    sc_engine *e = make(1);
    rig r; rig_init(&r, 1);
    set_edges(e, defaults);
    sc_engine_set_band_map(e, 0, 1, 0, 0, -1, -1);
    sc_engine_set_edge(e, SC_EDGE_X1, 200, 24);
    double out[OUT_CH], in;
    sine_rms(e, &r, 200, 0.5, 0.5, 0.3, out, &in);
    CHECK(fabs(db(out[0] / in) + 6.02) < 0.1, "low band is -6 dB at its new 200 Hz crossover (%+.2f)", db(out[0] / in));
    sc_engine_destroy(e);
}

static void test_garbage_and_safety(void) {
    printf("Garbage in, safety out\n");
    sc_engine *e = make(1);
    rig r; rig_init(&r, 1);
    set_edges(e, defaults);
    for (int b = 0; b < SC_BANDS; b++) { sc_engine_set_band_map(e, b, 1, 0, 0, -1, -1); sc_engine_set_band_gain(e, b, 16.0f); }
    bool finite = true;
    float worst = 0;
    for (int cb = 0; cb < 200; cb++) {
        for (int k = 0; k < FRAMES; k++) {
            const int j = cb * FRAMES + k;
            r.in[k] = (j % 97 == 0) ? NAN : (j % 89 == 0) ? INFINITY : (j % 83 == 0) ? 1e9f : (float)(0.9 * sin(j * 0.05));
        }
        run(e, &r);
        for (int k = 0; k < FRAMES * OUT_CH; k++) {
            if (!isfinite(r.out[k])) finite = false;
            if (fabsf(r.out[k]) > worst) worst = fabsf(r.out[k]);
        }
    }
    CHECK(finite, "output stays finite");
    CHECK(worst <= 1.0f, "output never passes full scale (%.4f)", worst);
    CHECK(sc_engine_clip_count(e) > 0, "clips are counted");

    // Silence afterwards decays to true silence (no denormal hum, no runaway).
    memset(r.in, 0, sizeof r.in);
    for (int cb = 0; cb < 3000; cb++) run(e, &r);
    float tail = 0;
    for (int k = 0; k < FRAMES * OUT_CH; k++) if (fabsf(r.out[k]) > tail) tail = fabsf(r.out[k]);
    CHECK(tail < 1e-7f, "silence settles (%.3g)", tail);
    sc_engine_destroy(e);
}

static void test_bad_maps(void) {
    printf("Bad channel maps\n");
    sc_engine *e = make(1);
    rig r; rig_init(&r, 1);
    sc_engine_set_band_map(e, 0, 2, 0, 0, 3, 0);  // buffer 3 doesn't exist
    sc_engine_set_band_map(e, 1, 1, 0, 42, -1, -1); // channel 43 doesn't exist
    for (int k = 0; k < FRAMES; k++) r.in[k] = 0.3f;
    run(e, &r);
    CHECK(sc_engine_missing_buffer_count(e) == 1, "missing channels are counted");
    CHECK(!sc_engine_set_band_map(e, 9, 1, 0, 0, -1, -1), "band 9 is refused");
    sc_engine_destroy(e);

    // No input mapped: every output stays silent.
    e = sc_engine_create();
    rig_init(&r, 1);
    sc_engine_set_band_map(e, 0, 1, 0, 0, -1, -1);
    for (int k = 0; k < FRAMES; k++) r.in[k] = 0.3f;
    for (int k = 0; k < FRAMES * OUT_CH; k++) r.out[k] = 0.7f; // the HAL's leftovers
    run(e, &r);
    bool silent = true;
    for (int k = 0; k < FRAMES * OUT_CH; k++) if (r.out[k] != 0.0f) silent = false;
    CHECK(silent, "no input: outputs are silence, not leftovers");
    sc_engine_destroy(e);
}

static void test_meters_and_scope(void) {
    printf("Meters and spectrum feed\n");
    sc_engine *e = make(2);
    rig r; rig_init(&r, 2);
    sc_engine_set_band_map(e, 3, 2, 0, 0, 0, 1);
    float first[FRAMES];
    for (int cb = 0; cb < 3; cb++) {
        for (int k = 0; k < FRAMES; k++) {
            r.in[k * 2] = (float)(cb * FRAMES + k) / 1000.0f;
            r.in[k * 2 + 1] = 0.0f;
        }
        if (cb == 0) for (int k = 0; k < FRAMES; k++) first[k] = r.in[k * 2] * 0.5f;
        run(e, &r);
    }
    CHECK(fabsf(sc_engine_take_input_peak(e, 0) - (3 * FRAMES - 1) / 1000.0f) < 1e-6f, "input peak");
    CHECK(sc_engine_take_input_peak(e, 0) == 0.0f, "peak resets when taken");
    CHECK(sc_engine_take_input_peak(e, 1) == 0.0f, "silent side reads 0");
    float scope[4 * FRAMES];
    const uint64_t written = sc_engine_read_scope(e, scope, 4 * FRAMES);
    CHECK(written == 3 * FRAMES, "scope counts samples (%llu)", (unsigned long long)written);
    CHECK(scope[0] == 0.0f && fabsf(scope[FRAMES + 5] - first[5]) < 1e-7f, "scope is oldest first, zero-filled, mono");
    CHECK(fabsf(scope[4 * FRAMES - 1] - (3 * FRAMES - 1) / 2000.0f) < 1e-7f, "newest sample is last");
    CHECK(sc_engine_callback_count(e) == 3, "callbacks counted");
    sc_engine_destroy(e);
}

int main(void) {
    test_bands_sum_flat();
    test_response_matches_engine();
    test_crossover_shapes();
    test_separation();
    test_routing();
    test_gain_and_mute();
    test_no_clicks();
    test_glide_lands();
    test_garbage_and_safety();
    test_bad_maps();
    test_meters_and_scope();
    printf("\n%d checks, %d failed\n", checks, failures);
    return failures ? 1 : 0;
}
