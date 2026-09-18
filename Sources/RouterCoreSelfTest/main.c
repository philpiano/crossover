// Hardware-free tests for the mixing engine: feed hand-built buffer lists
// through ar_engine_process and check what comes out.
//
//   ./build.sh test

#include "RouterCore.h"

#include <mach/mach_time.h>
#include <math.h>
#include <stddef.h>
#include <unistd.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static int failures = 0;

#define CHECK(cond, msg)                                   \
    do {                                                   \
        if (cond) printf("  ok    %s\n", msg);             \
        else { printf("  FAIL  %s  (line %d)\n", msg, __LINE__); failures++; } \
    } while (0)

static bool near(float a, float b) { return fabsf(a - b) < 1e-3f; }

static AudioBufferList *make_list(int nbuf, const int *chans, int frames) {
    AudioBufferList *l = calloc(1, offsetof(AudioBufferList, mBuffers) + sizeof(AudioBuffer) * (size_t)nbuf);
    l->mNumberBuffers = (UInt32)nbuf;
    for (int b = 0; b < nbuf; b++) {
        l->mBuffers[b].mNumberChannels = (UInt32)chans[b];
        l->mBuffers[b].mDataByteSize = (UInt32)(frames * chans[b] * (int)sizeof(float));
        l->mBuffers[b].mData = calloc((size_t)(frames * chans[b]), sizeof(float));
    }
    return l;
}

static void free_list(AudioBufferList *l) {
    for (UInt32 b = 0; b < l->mNumberBuffers; b++) free(l->mBuffers[b].mData);
    free(l);
}

static void fill(AudioBufferList *l, int buf, int ch, float v) {
    AudioBuffer *b = &l->mBuffers[buf];
    int frames = (int)(b->mDataByteSize / (sizeof(float) * b->mNumberChannels));
    float *d = b->mData;
    for (int f = 0; f < frames; f++) d[f * (int)b->mNumberChannels + ch] = v;
}

static float at(AudioBufferList *l, int buf, int ch, int frame) {
    AudioBuffer *b = &l->mBuffers[buf];
    return ((float *)b->mData)[frame * (int)b->mNumberChannels + ch];
}

static float last(AudioBufferList *l, int buf, int ch) {
    AudioBuffer *b = &l->mBuffers[buf];
    int frames = (int)(b->mDataByteSize / (sizeof(float) * b->mNumberChannels));
    return at(l, buf, ch, frames - 1);
}

static void run(ar_engine *e, AudioBufferList *in, AudioBufferList *out, int callbacks) {
    for (int i = 0; i < callbacks; i++) ar_engine_process(e, in, out);
}

// --- Effects ------------------------------------------------------------------
// One mono input straight to one stereo output, fed sines or DC at 48 kHz.

enum { FX_FRAMES = 480 }; // 10 ms per callback

typedef struct { ar_engine *e; AudioBufferList *in, *out; double phase; } fx_rig;

static fx_rig fx_rig_make(uint32_t flags) {
    const int one[] = { 1 }, two[] = { 2 };
    fx_rig r = { ar_engine_create(), make_list(1, one, FX_FRAMES), make_list(1, two, FX_FRAMES), 0.0 };
    ar_engine_set_sample_rate(r.e, 48000);
    ar_engine_set_input_map(r.e, 0, 1, 0, 0, -1, -1);
    ar_engine_set_output_map(r.e, 0, 2, 0, 0, 0, 1);
    ar_engine_set_route(r.e, 0, 0, 1.0f);
    ar_engine_set_input_effects(r.e, 0, flags);
    return r;
}

static void fx_rig_free(fx_rig *r) {
    ar_engine_destroy(r->e);
    free_list(r->in);
    free_list(r->out);
}

// Runs `callbacks` callbacks of a sine (freq > 0) or DC (freq == 0) and
// returns the output's peak over the last 100 ms (or all of it, if shorter):
// long enough to hold two full cycles of 20 Hz.
static float fx_run(fx_rig *r, double freq, float amp, int callbacks) {
    float peak = 0.0f;
    const int measureFrom = callbacks > 10 ? callbacks - 10 : 0;
    for (int cb = 0; cb < callbacks; cb++) {
        float *d = r->in->mBuffers[0].mData;
        for (int f = 0; f < FX_FRAMES; f++) {
            d[f] = freq > 0 ? amp * (float)sin(r->phase) : amp;
            r->phase += 2.0 * M_PI * freq / 48000.0;
        }
        ar_engine_process(r->e, r->in, r->out);
        if (cb >= measureFrom) {
            for (int f = 0; f < FX_FRAMES; f++) {
                float a = fabsf(at(r->out, 0, 0, f));
                if (a > peak) peak = a;
            }
        }
    }
    return peak;
}

static float db(float x) { return 20.0f * log10f(x); }

// --- Realistic signals ---------------------------------------------------------
// Constant DC hides how dynamics behave on real sound (it has no gap between its
// peak and its average), so the gate and auto level are tested on these: room
// noise, piano-like notes (three partials, 2 ms attack, exponential decay) and
// speech-like bursts. Deterministic, so a test never flakes.

typedef struct {
    double t, note_t, freq, amp;
    double noise;       // RMS of the room noise
    double note_every;  // seconds between notes; 0 = no notes
    double note_amp;    // peak amplitude of each note
    double decay;       // note decay time constant, seconds
    double burst_on, burst_off; // if set, notes only sound in bursts (speech-like)
    uint32_t seed;
} sig;

static double sig_noise(sig *s) {
    s->seed = s->seed * 1664525u + 1013904223u;
    return ((double)s->seed / 4294967296.0 * 2.0 - 1.0) * 1.7320508; // uniform, unit RMS
}

static float sig_next(sig *s) {
    if (s->note_every > 0 && s->note_t >= s->note_every) {
        s->note_t = 0;
        s->seed = s->seed * 1664525u + 1013904223u;
        s->freq = 110.0 * pow(2.0, (double)(s->seed >> 8 & 0x1f) / 12.0);
        s->amp = s->note_amp;
    }
    double v = 0;
    bool sounding = true;
    if (s->burst_on > 0) sounding = fmod(s->t, s->burst_on + s->burst_off) < s->burst_on;
    if (s->note_every > 0 && sounding) {
        double env = exp(-s->note_t / s->decay) * (1.0 - exp(-s->note_t / 0.002));
        double w = 2.0 * M_PI * s->freq * s->t;
        v = s->amp * env * (0.6 * sin(w) + 0.3 * sin(2 * w) + 0.1 * sin(3 * w));
    }
    v += s->noise * sig_noise(s);
    s->t += 1.0 / 48000.0;
    s->note_t += 1.0 / 48000.0;
    return (float)v;
}

typedef struct { double in_rms, out_rms, in_peak, out_peak; } span;

// Runs `seconds` of the signal through a one-input rig and measures it.
static span sig_run(fx_rig *r, sig *s, double seconds) {
    span m = { 0, 0, 0, 0 };
    long count = 0;
    const int callbacks = (int)(seconds * 48000.0 / FX_FRAMES + 0.5);
    for (int cb = 0; cb < callbacks; cb++) {
        float *d = r->in->mBuffers[0].mData;
        for (int f = 0; f < FX_FRAMES; f++) d[f] = sig_next(s);
        ar_engine_process(r->e, r->in, r->out);
        for (int f = 0; f < FX_FRAMES; f++) {
            const double a = d[f], b = at(r->out, 0, 0, f);
            m.in_rms += a * a; m.out_rms += b * b;
            if (fabs(a) > m.in_peak) m.in_peak = fabs(a);
            if (fabs(b) > m.out_peak) m.out_peak = fabs(b);
            count++;
        }
    }
    m.in_rms = sqrt(m.in_rms / (double)count);
    m.out_rms = sqrt(m.out_rms / (double)count);
    return m;
}

static double dbd(double x) { return 20.0 * log10(x > 1e-12 ? x : 1e-12); }
static double rms_gain(span m) { return dbd(m.out_rms) - dbd(m.in_rms); }

static fx_rig sig_rig(uint32_t flags, float gate_level, float al_level) {
    fx_rig r = fx_rig_make(flags);
    ar_engine_set_input_fx_level(r.e, 0, AR_FX_NOISEGATE, gate_level);
    ar_engine_set_input_fx_level(r.e, 0, AR_FX_AUTOLEVEL, al_level);
    return r;
}

static const sig ROOM = { .noise = 0.00316, .seed = 1 };                         // -50 dBFS RMS room noise
static const sig PLAYING = { .noise = 0.00316, .note_every = 0.25, .note_amp = 0.25, .decay = 0.4, .seed = 2 };

static void test_noise_gate(void) {
    printf("noise gate (realistic signals)\n");
    {
        fx_rig r = sig_rig(AR_FX_NOISEGATE, 1.0f, 1.0f);
        sig s = ROOM;
        sig_run(&r, &s, 13);
        span m = sig_run(&r, &s, 2);
        CHECK(dbd(m.out_rms) < -80.0, "steady room noise is silenced within ~15 s of a cold start");

        // An onset from a closed gate: the first milliseconds must come through.
        float *d = r.in->mBuffers[0].mData;
        for (int f = 0; f < FX_FRAMES; f++) d[f] = 0.1f * (float)sin(2.0 * M_PI * 440.0 * f / 48000.0) + (float)(0.00316 * sig_noise(&s));
        ar_engine_process(r.e, r.in, r.out);
        double in_sum = 0, out_sum = 0;
        for (int f = 48; f < 144; f++) { in_sum += fabs(d[f]); out_sum += fabs(at(r.out, 0, 0, f)); }
        CHECK(out_sum > 0.9 * in_sum, "a sound starting from a closed gate is at full level 1 ms in");
        fx_rig_free(&r);
    }
    {
        fx_rig r = sig_rig(AR_FX_NOISEGATE, 1.0f, 1.0f);
        sig s = PLAYING;
        span loud = sig_run(&r, &s, 120);
        CHECK(fabs(rms_gain(loud)) < 0.1, "two minutes of continuous playing pass untouched");
        s.note_amp = 0.018; // 23 dB softer: only ~15 dB above the room noise
        sig_run(&r, &s, 1);
        span soft = sig_run(&r, &s, 10);
        CHECK(rms_gain(soft) > -0.5, "…and a soft passage straight after is not gated: playing can't drag the floor up");
        s.note_every = 0;
        sig_run(&r, &s, 8);
        span quiet = sig_run(&r, &s, 2);
        CHECK(dbd(quiet.out_rms) < -80.0, "the first long pause afterwards is silenced within ~10 s");
        CHECK(ar_engine_take_input_reduction(r.e, 0, AR_FX_NOISEGATE) > 20.0f, "noise gate reports how many dB it is cutting");
    }
    {
        // The hardest case for the floor: dense legato with the pedal down,
        // whose level hardly moves. Then a soft passage.
        fx_rig r = sig_rig(AR_FX_NOISEGATE, 1.0f, 1.0f);
        sig s = PLAYING;
        s.note_every = 0.125; s.decay = 1.5;
        sig_run(&r, &s, 120);
        s.note_every = 0.25; s.decay = 0.4; s.note_amp = 0.018;
        sig_run(&r, &s, 2);
        span soft = sig_run(&r, &s, 10);
        CHECK(rms_gain(soft) > -0.5, "…nor after two minutes of pedalled legato");
        fx_rig_free(&r);
    }
    {
        // A fan switching on mid-lesson: the new, louder noise is absorbed.
        fx_rig r = sig_rig(AR_FX_NOISEGATE, 1.0f, 1.0f);
        sig s = ROOM;
        s.noise = 0.001; // -60 dBFS
        sig_run(&r, &s, 15);
        s.noise = 0.00316; // the fan: -50 dBFS
        sig_run(&r, &s, 13);
        span fan = sig_run(&r, &s, 2);
        CHECK(dbd(fan.out_rms) < -80.0, "a fan switching on is absorbed into the floor within ~15 s");
        fx_rig_free(&r);
    }
    {
        fx_rig r = sig_rig(AR_FX_NOISEGATE, 1.0f, 1.0f);
        sig s = ROOM;
        sig_run(&r, &s, 15); // the floor is learnt
        s.note_every = 0.12; s.note_amp = 0.05; s.decay = 0.15; s.burst_on = 0.3; s.burst_off = 0.4;
        span speech = sig_run(&r, &s, 10);
        CHECK(rms_gain(speech) > -0.5, "speech-like bursts with short gaps are never chopped (the hold bridges the gaps)");
        fx_rig_free(&r);
    }
    {
        fx_rig r = sig_rig(AR_FX_NOISEGATE, 0.0f, 1.0f);
        sig s = ROOM;
        sig_run(&r, &s, 15);
        CHECK(fabs(rms_gain(sig_run(&r, &s, 2))) < 0.5, "at the most lenient setting, the room noise passes");
        fx_rig_free(&r);

        fx_rig off = sig_rig(0, 1.0f, 1.0f);
        s = ROOM;
        sig_run(&off, &s, 15);
        CHECK(fabs(rms_gain(sig_run(&off, &s, 2))) < 0.05, "with the gate off, room noise is untouched");
        fx_rig_free(&off);
    }
}

static void test_auto_level(void) {
    printf("auto level (realistic signals)\n");
    sig quiet_room = PLAYING;
    quiet_room.noise = 0.0003; // -70 dBFS
    {
        fx_rig r = sig_rig(AR_FX_AUTOLEVEL, 1.0f, 1.0f);
        sig s = quiet_room;
        sig_run(&r, &s, 20);
        span normal = sig_run(&r, &s, 10);
        CHECK(fabs(rms_gain(normal)) < 0.5, "normal playing is left alone (level)");
        CHECK(fabs(dbd(normal.out_peak) - dbd(normal.in_peak)) < 1.0, "normal playing is left alone (note attacks)");

        s.note_amp = 0.025; // 10% of normal, the design doc's own scenario
        sig_run(&r, &s, 3);
        span dropped = sig_run(&r, &s, 5);
        CHECK(rms_gain(dropped) > 6.0, "a passage at 10% of normal is boosted by more than 6 dB");
        CHECK(dbd(dropped.out_rms) < dbd(normal.out_rms) - 2.0, "…but conservatively, not all the way back");
        CHECK(ar_engine_take_input_lift(r.e, 0) > 3.0f, "auto level reports that it's lifting");

        s.note_amp = 0.25;
        span jump = sig_run(&r, &s, 0.5);
        CHECK(dbd(jump.out_peak) < dbd(normal.out_peak) + 4.0, "jumping back to normal never comes out more than 4 dB above normal");
        CHECK(ar_engine_take_input_reduction(r.e, 0, AR_FX_AUTOLEVEL) > 3.0f, "auto level reports that it's capping the jump");

        sig_run(&r, &s, 5);
        s.note_every = 0;
        span pause = sig_run(&r, &s, 10);
        CHECK(rms_gain(pause) < 1.0, "during a pause the room hiss is not pumped up");
        s.note_every = 0.25; s.note_t = 1;
        span back = sig_run(&r, &s, 1);
        CHECK(fabs(rms_gain(back)) < 1.0, "after a pause, playing comes back at its normal level");
        fx_rig_free(&r);
    }
    {
        double boost[3];
        const float amounts[3] = { 0.0f, 1.0f, 1.5f };
        for (int k = 0; k < 3; k++) {
            fx_rig r = sig_rig(AR_FX_AUTOLEVEL, 1.0f, amounts[k]);
            sig s = quiet_room;
            sig_run(&r, &s, 20);
            s.note_amp = 0.025;
            sig_run(&r, &s, 3);
            boost[k] = rms_gain(sig_run(&r, &s, 5));
            fx_rig_free(&r);
        }
        CHECK(fabs(boost[0]) < 1.0, "at 0%, auto level does nothing");
        CHECK(boost[2] > boost[1] + 1.0, "at 150%, it boosts more than at 100%");
    }
    {
        // Compress reads the signal after auto level: when auto level pulls a
        // sudden +20 dB jump down to its ceiling, Compress sees the lowered
        // level and doesn't squash it a second time as if it were still loud.
        fx_rig r = sig_rig(AR_FX_AUTOLEVEL | AR_FX_COMPRESSOR, 1.0f, 1.0f);
        sig s = quiet_room;
        sig_run(&r, &s, 20);
        s.note_amp = 2.5;
        sig_run(&r, &s, 0.2);
        ar_engine_take_input_reduction(r.e, 0, AR_FX_COMPRESSOR);
        sig_run(&r, &s, 0.3);
        CHECK(ar_engine_take_input_reduction(r.e, 0, AR_FX_COMPRESSOR) < 8.0f, "compress reacts to auto level's output, not its input");
        fx_rig_free(&r);
    }
}

static void test_effects(void) {
    printf("low-cut\n");
    {
        fx_rig r = fx_rig_make(AR_FX_LOWCUT);
        float p = fx_run(&r, 20, 0.5f, 100);
        CHECK(p < 0.5f * 0.1f, "20 Hz rumble is cut by more than 20 dB");
        p = fx_run(&r, 80, 0.5f, 100);
        CHECK(fabsf(db(p / 0.5f) + 3.0f) < 0.5f, "80 Hz is the -3 dB point");
        p = fx_run(&r, 1000, 0.5f, 50);
        CHECK(fabsf(db(p / 0.5f)) < 0.1f, "1 kHz passes untouched");
        p = fx_run(&r, 0, 0.5f, 100);
        CHECK(p < 0.001f, "DC offset is removed");
        fx_rig_free(&r);

        fx_rig off = fx_rig_make(0);
        p = fx_run(&off, 20, 0.5f, 100);
        CHECK(fabsf(p - 0.5f) < 0.005f, "with low-cut off, 20 Hz passes");
        fx_rig_free(&off);
    }

    printf("compressor\n");
    {
        fx_rig r = fx_rig_make(AR_FX_COMPRESSOR);
        // DC makes the RMS detector exact: -6 dBFS is 18 dB over, 2:1 takes 9, +2 make-up.
        float p = fx_run(&r, 0, 0.5f, 100);
        CHECK(fabsf(db(p / 0.5f) + 7.0f) < 0.1f, "a loud -6 dBFS input comes down 7 dB");
        p = fx_run(&r, 0, 0.01f, 150);
        CHECK(fabsf(db(p / 0.01f) - 2.0f) < 0.1f, "a quiet -40 dBFS input comes up 2 dB");
        p = fx_run(&r, 0, 0.1f, 150);
        CHECK(fabsf(db(p / 0.1f)) < 0.5f, "speech level (-20 dBFS) is left about where it was");
        fx_run(&r, 0, 0.5f, 100);
        CHECK(ar_engine_take_input_reduction(r.e, 0, AR_FX_COMPRESSOR) > 8.5f, "compressor reports its gain reduction");
        fx_rig_free(&r);
    }

    printf("limiter\n");
    {
        fx_rig r = fx_rig_make(AR_FX_LIMITER);
        ar_engine_set_input_gain(r.e, 0, 4.0f); // a 0.5 sine becomes 2.0: 6 dB over full scale
        fx_run(&r, 440, 0.5f, 20);
        uint64_t clips = ar_engine_clip_count(r.e);
        float p = fx_run(&r, 440, 0.5f, 50);
        CHECK(p <= 0.8913f, "nothing passes the -1 dBFS ceiling");
        CHECK(p > 0.85f, "and it isn't pumping far below it");
        CHECK(ar_engine_clip_count(r.e) == clips, "so the output never clips");
        CHECK(ar_engine_take_input_reduction(r.e, 0, AR_FX_LIMITER) > 6.0f, "limiter reports its gain reduction");
        CHECK(ar_engine_take_input_reduction(r.e, 0, AR_FX_LIMITER) == 0.0f, "taking the reduction resets it");

        ar_engine_set_input_gain(r.e, 0, 1.0f);
        fx_run(&r, 440, 0.5f, 100);                             // let it recover…
        ar_engine_take_input_reduction(r.e, 0, AR_FX_LIMITER); // …forget the recovery…
        fx_run(&r, 440, 0.5f, 20);                              // …then listen
        CHECK(ar_engine_take_input_reduction(r.e, 0, AR_FX_LIMITER) == 0.0f, "below the ceiling it does nothing");
        p = fx_run(&r, 440, 0.5f, 1);
        CHECK(fabsf(p - 0.5f) < 0.002f, "and the signal is untouched");
        fx_rig_free(&r);
    }

    printf("switching effects\n");
    {
        fx_rig r = fx_rig_make(0);
        fx_run(&r, 1000, 0.5f, 50);
        ar_engine_set_input_effects(r.e, 0, AR_FX_LIMITER | AR_FX_COMPRESSOR | AR_FX_LOWCUT);
        fx_run(&r, 1000, 0.5f, 1);
        float worst = 0.0f;
        for (int f = 1; f < FX_FRAMES; f++) {
            float jump = fabsf(at(r.out, 0, 0, f) - at(r.out, 0, 0, f - 1));
            if (jump > worst) worst = jump;
        }
        // A 1 kHz sine at 0.5 moves at most 0.065 per sample at 48 kHz.
        CHECK(worst < 0.07f, "switching all effects on mid-signal doesn't click");
        fx_rig_free(&r);
    }

    printf("effect amounts\n");
    {
        fx_rig r = fx_rig_make(AR_FX_COMPRESSOR);
        ar_engine_set_input_fx_level(r.e, 0, AR_FX_COMPRESSOR, 0.5f);
        float p = fx_run(&r, 0, 0.5f, 100);
        CHECK(fabsf(db(p / 0.5f) + 3.5f) < 0.15f, "Compress at 50% does half as much (-3.5 dB instead of -7)");
        fx_rig_free(&r);
    }
    {
        fx_rig r = fx_rig_make(AR_FX_LIMITER);
        ar_engine_set_input_gain(r.e, 0, 4.0f);
        ar_engine_set_input_fx_level(r.e, 0, AR_FX_LIMITER, 1.5f);
        fx_run(&r, 440, 0.5f, 20);
        float p = fx_run(&r, 440, 0.5f, 50);
        CHECK(p <= 0.5012f && p > 0.47f, "the limiter at 150% holds a -6 dBFS ceiling");
        ar_engine_set_input_fx_level(r.e, 0, AR_FX_LIMITER, 0.5f);
        fx_run(&r, 440, 0.5f, 20);
        p = fx_run(&r, 440, 0.5f, 50);
        CHECK(p > 0.95f, "the limiter below 100% lets some of an over through");
        fx_rig_free(&r);
    }
    {
        fx_rig r = fx_rig_make(AR_FX_LOWCUT);
        float normal = fx_run(&r, 100, 0.5f, 100);
        ar_engine_set_input_fx_level(r.e, 0, AR_FX_LOWCUT, 1.5f);
        float higher = fx_run(&r, 100, 0.5f, 100);
        CHECK(higher < normal * 0.8f, "Low-cut at 150% moves the cutoff up, so 100 Hz is cut harder");
        ar_engine_set_input_fx_level(r.e, 0, AR_FX_LOWCUT, 0.0f);
        float off = fx_run(&r, 20, 0.5f, 100);
        CHECK(fabsf(off - 0.5f) < 0.01f, "Low-cut at 0% lets 20 Hz through");
        fx_rig_free(&r);
    }

    printf("output limiter\n");
    {
        AudioBufferList *in = make_list(1, (int[]){ 1 }, FX_FRAMES);
        AudioBufferList *out = make_list(1, (int[]){ 2 }, FX_FRAMES);
        ar_engine *e = ar_engine_create();
        ar_engine_set_sample_rate(e, 48000);
        ar_engine_set_input_map(e, 0, 1, 0, 0, -1, -1);
        ar_engine_set_output_map(e, 0, 2, 0, 0, 0, 1);
        ar_engine_set_route(e, 0, 0, 4.0f); // deliberately hot: 6 dB over full scale
        ar_engine_set_output_effects(e, 0, AR_FX_LIMITER);
        float *d = in->mBuffers[0].mData;
        for (int f = 0; f < FX_FRAMES; f++) d[f] = (float)sin(2.0 * M_PI * 440.0 * f / 48000.0) * 0.5f;
        for (int cb = 0; cb < 30; cb++) ar_engine_process(e, in, out);
        float peak = 0.0f;
        for (int f = 0; f < FX_FRAMES; f++) { float a = fabsf(at(out, 0, 0, f)); if (a > peak) peak = a; }
        CHECK(peak <= 0.8913f, "the output limiter keeps a hot bus under -1 dBFS");
        CHECK(peak > 0.85f, "and doesn't pump far below it");
        CHECK(ar_engine_take_output_reduction(e, 0, AR_FX_LIMITER) > 4.0f, "the output limiter reports its gain reduction");
        ar_engine_destroy(e);
        free_list(in);
        free_list(out);
    }

    printf("peak hold\n");
    {
        fx_rig r = fx_rig_make(0);
        CHECK(ar_engine_input_peak_hold(r.e, 0, 0) == 0.0f, "peak hold starts at zero");
        CHECK(!ar_engine_input_clipped(r.e, 0, 0), "not clipped at start");
        fx_run(&r, 0, 0.3f, 30); // long enough for the input-gain smoothing ramp to settle
        CHECK(near(ar_engine_input_peak_hold(r.e, 0, 0), 0.3f), "peak hold captures the level");
        fx_run(&r, 0, 0.1f, 5); // a quieter signal afterwards
        CHECK(near(ar_engine_input_peak_hold(r.e, 0, 0), 0.3f), "peak hold does NOT reset on its own, unlike the live meter");
        CHECK(!ar_engine_input_clipped(r.e, 0, 0), "0.3 amplitude never reached 0 dBFS");
        ar_engine_set_input_gain(r.e, 0, 4.0f); // 0.3 * 4 = 1.2: over 0 dBFS
        fx_run(&r, 0, 0.3f, 5);
        CHECK(ar_engine_input_clipped(r.e, 0, 0), "reaching 0 dBFS sets the clip flag");
        ar_engine_reset_input_peak_hold(r.e, 0, 0);
        CHECK(ar_engine_input_peak_hold(r.e, 0, 0) == 0.0f && !ar_engine_input_clipped(r.e, 0, 0),
              "resetting clears both the hold and the clip flag");
        fx_rig_free(&r);
    }
}

// --- Diagnostics ----------------------------------------------------------------

static void test_diagnostics(void) {
    printf("diagnostics\n");
    fx_rig r = fx_rig_make(0);
    CHECK(ar_engine_last_callback_time(r.e) == 0, "no callback time before the first callback");

    fx_run(&r, 0, 0.0f, 1);
    uint64_t t1 = ar_engine_last_callback_time(r.e);
    CHECK(t1 != 0 && ar_engine_first_callback_time(r.e) == t1, "the first callback is timestamped");
    usleep(20000);
    fx_run(&r, 0, 0.0f, 1);
    CHECK(ar_engine_last_callback_time(r.e) > t1, "later callbacks move the timestamp on");
    CHECK(ar_engine_first_callback_time(r.e) == t1, "the first-callback time stays put");

    mach_timebase_info_data_t tb;
    mach_timebase_info(&tb);
    double gap_ms = (double)ar_engine_take_max_callback_interval(r.e) * tb.numer / tb.denom / 1e6;
    CHECK(gap_ms >= 19.0, "a 20 ms pause between callbacks is measured as the longest gap");
    CHECK(ar_engine_take_max_callback_interval(r.e) == 0, "taking the longest gap resets it");
    ar_engine_take_max_process_time(r.e);

    ar_engine_take_input_zero_run(r.e, 0);
    ar_engine_take_output_zero_run(r.e, 0);
    fx_run(&r, 0, 0.0f, 10);
    CHECK(ar_engine_take_input_zero_run(r.e, 0) == 12 * FX_FRAMES, "exact silence on an input is measured as a run");
    CHECK(ar_engine_take_output_zero_run(r.e, 0) >= 10 * FX_FRAMES, "and silence on an output too");
    fx_run(&r, 1000, 0.5f, 5);
    ar_engine_take_input_zero_run(r.e, 0);
    fx_run(&r, 1000, 0.5f, 5);
    CHECK(ar_engine_take_input_zero_run(r.e, 0) == 0, "real signal is never counted as silence");
    CHECK(ar_engine_missing_buffer_count(r.e) == 0, "a complete buffer list counts no missing buffers");
    fx_rig_free(&r);

    fx_rig bad = fx_rig_make(0);
    ar_engine_clear_topology(bad.e);
    ar_engine_set_input_map(bad.e, 0, 1, 3, 0, -1, -1); // buffer 3 doesn't exist
    ar_engine_set_output_map(bad.e, 0, 2, 0, 0, 0, 1);
    fx_run(&bad, 0, 0.5f, 4);
    CHECK(ar_engine_missing_buffer_count(bad.e) == 4, "every callback with a missing buffer is counted");
    fx_rig_free(&bad);
}

// Rig resembling the real thing (1500 frames: deliberately not a multiple of the block size):
//   in  buf0 2ch: interface  (ch0 = mic)
//   in  buf1 2ch: piano      (L, R)
//   in  buf2 2ch: Zoom loopback
//   out buf0 2ch: "To Zoom" loopback
//   out buf1 2ch: headphones
enum { FRAMES = 1500 };

int main(void) {
    const int inChans[] = { 2, 2, 2 };
    const int outChans[] = { 2, 2, 1 };
    AudioBufferList *in = make_list(3, inChans, FRAMES);
    AudioBufferList *out = make_list(3, outChans, FRAMES);
    fill(in, 0, 0, 0.5f);  // mic
    fill(in, 1, 0, 0.3f);  // piano L
    fill(in, 1, 1, 0.1f);  // piano R
    fill(in, 2, 0, 0.1f);  // zoom L
    fill(in, 2, 1, 0.1f);  // zoom R

    ar_engine *e = ar_engine_create();
    ar_engine_set_sample_rate(e, 48000);
    ar_engine_set_input_map(e, 0, 1, 0, 0, -1, -1); // mic, mono
    ar_engine_set_input_map(e, 1, 2, 1, 0, 1, 1);   // piano, stereo
    ar_engine_set_input_map(e, 2, 2, 2, 0, 2, 1);   // zoom, stereo
    ar_engine_set_output_map(e, 0, 2, 0, 0, 0, 1);  // to zoom
    ar_engine_set_output_map(e, 1, 2, 1, 0, 1, 1);  // headphones
    ar_engine_set_output_map(e, 2, 1, 2, 0, -1, -1); // a mono output

    printf("routing\n");
    run(e, in, out, 5);
    CHECK(last(out, 0, 0) == 0.0f && last(out, 1, 0) == 0.0f, "nothing routed -> silence");

    ar_engine_set_route(e, 0, 0, 1.0f); // mic -> to zoom
    ar_engine_process(e, in, out);
    CHECK(at(out, 0, 0, 0) < 0.05f && at(out, 0, 0, 0) >= 0.0f, "a new route fades in (no click)");
    run(e, in, out, 60);
    CHECK(near(last(out, 0, 0), 0.5f) && near(last(out, 0, 1), 0.5f), "mono mic lands on both sides of a stereo output");
    CHECK(near(at(out, 0, 0, 0), 0.5f), "settled gain is flat across the buffer");
    CHECK(last(out, 1, 0) == 0.0f, "unrouted output stays silent");

    ar_engine_set_route(e, 1, 1, 1.0f); // piano -> headphones
    run(e, in, out, 60);
    CHECK(near(last(out, 1, 0), 0.3f) && near(last(out, 1, 1), 0.1f), "stereo piano keeps left and right");

    ar_engine_set_route(e, 1, 2, 1.0f); // piano -> mono output
    run(e, in, out, 60);
    CHECK(near(last(out, 2, 0), 0.2f), "stereo into a mono output is averaged");

    ar_engine_set_route(e, 2, 0, 1.0f); // zoom -> to zoom (sums with mic)
    run(e, in, out, 60);
    CHECK(near(last(out, 0, 0), 0.6f), "two inputs into one output sum");
    ar_engine_set_route(e, 2, 0, 0.0f);

    printf("gain and mute\n");
    ar_engine_set_input_gain(e, 0, 0.5f);
    run(e, in, out, 60);
    CHECK(near(last(out, 0, 0), 0.25f), "input gain applies");
    ar_engine_set_input_gain(e, 0, 1.0f);
    ar_engine_set_output_gain(e, 0, 0.5f);
    run(e, in, out, 60);
    CHECK(near(last(out, 0, 0), 0.25f), "output gain applies");
    ar_engine_set_output_gain(e, 0, 1.0f);
    ar_engine_set_input_mute(e, 0, true);
    run(e, in, out, 60);
    CHECK(last(out, 0, 0) == 0.0f, "input mute silences it");
    ar_engine_set_input_mute(e, 0, false);
    ar_engine_set_output_mute(e, 1, true);
    run(e, in, out, 60);
    CHECK(last(out, 1, 0) == 0.0f, "output mute silences it");
    ar_engine_set_output_mute(e, 1, false);
    ar_engine_set_route(e, 0, 0, NAN);
    run(e, in, out, 60);
    CHECK(last(out, 0, 0) == 0.0f, "a NaN gain is treated as off");
    ar_engine_set_route(e, 0, 0, 1.0f);

    printf("meters\n");
    run(e, in, out, 60);
    float p = ar_engine_take_input_peak(e, 0, 0);
    CHECK(near(p, 0.5f), "input meter reads the mic level");
    CHECK(ar_engine_take_input_peak(e, 0, 0) == 0.0f, "taking a peak resets it");
    run(e, in, out, 1);
    CHECK(near(ar_engine_take_output_peak(e, 1, 1), 0.1f), "output meter reads the piano right channel");

    printf("safety\n");
    ar_engine_set_input_gain(e, 0, 4.0f); // 0.5 * 4 = 2.0 -> must be clipped
    uint64_t clipsBefore = ar_engine_clip_count(e);
    run(e, in, out, 60);
    CHECK(last(out, 0, 0) <= 1.0f && last(out, 0, 0) > 0.95f, "overs are soft-clipped to <= 1.0");
    CHECK(ar_engine_clip_count(e) > clipsBefore, "clip events are counted");
    ar_engine_set_input_gain(e, 0, 1.0f);

    fill(in, 0, 0, NAN);
    run(e, in, out, 5);
    CHECK(last(out, 0, 0) == 0.0f, "NaN on an input never reaches an output");
    fill(in, 0, 0, 0.5f);

    ar_engine_clear_topology(e);
    ar_engine_set_input_map(e, 0, 2, 7, 0, 0, 9);  // nonexistent buffer / channel
    ar_engine_set_output_map(e, 0, 2, 0, 0, 5, 0);
    ar_engine_set_route(e, 0, 0, 1.0f);
    run(e, in, out, 10);
    CHECK(last(out, 0, 0) == 0.0f, "bad channel references are silent, not a crash");

    ar_engine_process(e, NULL, out);
    ar_engine_process(e, in, NULL);
    ar_engine_process(e, NULL, NULL);
    CHECK(1, "missing buffer lists are survived");

    // Output buffer shorter than the input: must not write past its end.
    const int oneBuf[] = { 2 };
    AudioBufferList *shortOut = make_list(1, oneBuf, 100);
    ar_engine_clear_topology(e);
    ar_engine_set_input_map(e, 0, 1, 0, 0, -1, -1);
    ar_engine_set_output_map(e, 0, 2, 0, 0, 0, 1);
    run(e, in, shortOut, 60);
    CHECK(near(last(shortOut, 0, 0), 0.5f), "mismatched buffer sizes stay in bounds");
    free_list(shortOut);

    printf("topology\n");
    CHECK(ar_engine_set_input_map(e, 99, 1, 0, 0, -1, -1) == false, "out-of-range slot is refused");
    CHECK(ar_engine_callback_count(e) > 0, "callbacks are counted");

    ar_engine_destroy(e);
    free_list(in);
    free_list(out);

    test_effects();
    test_noise_gate();
    test_auto_level();
    test_diagnostics();

    if (failures) {
        printf("\n%d FAILED\n", failures);
        return 1;
    }
    printf("\nall passed\n");
    return 0;
}
