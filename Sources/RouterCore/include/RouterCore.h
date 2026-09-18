// RouterCore — the real-time part of Audio Angel.
//
// One Core Audio IOProc runs on a private aggregate device that contains every
// physical and loopback device in use. Each callback receives all inputs and all
// outputs on a single clock, so routing is a plain matrix mix with no ring buffers
// or resampling of our own in the path.
//
// Each input runs a fixed channel strip, in this order:
//   low-cut → noise gate → auto level → compress (with the fader) → limiter
// Each of the five effects has on/off plus an amount (0..1.5, 1.0 = the effect
// as specified) — see the flag comments below.
//
// Threading contract:
//   * Topology (which buffer/channel each slot reads or writes) may only be
//     changed while the engine is stopped. The setters refuse otherwise.
//   * Gains, mutes, routes and effect switches may be changed from any thread at
//     any time. They are lock-free atomics, and the audio thread smooths every
//     change (~10 ms) so nothing clicks.
//   * The audio thread never allocates, locks, logs or calls into Swift.

#ifndef ROUTER_CORE_H
#define ROUTER_CORE_H

#include <CoreAudio/CoreAudio.h>
#include <stdbool.h>
#include <stdint.h>

#define AR_MAX_INPUTS 8
#define AR_MAX_OUTPUTS 8
#define AR_MAX_SLOT_CHANNELS 2

// Input effects, combined as flags. Everything is off in a new engine.
//
// Amount (0..1.5, default 1.0 = 100%) meaning per effect:
//   LOWCUT     — the cutoff: 80 Hz x amount (120% = 96 Hz); below 25% it fades out.
//   NOISEGATE  — the threshold: 2.4 dB stricter per 10% above 100%, more lenient below.
//   AUTOLEVEL  — strength: how much is boosted and how tight the ceiling; 0% does nothing.
//   COMPRESSOR — scales the whole gain curve and make-up; 0% does nothing.
//   LIMITER    — up to 100% blends the limiter in (below 100% peaks get through);
//                above 100% the ceiling drops 1 dB per 10% (150% = -6 dBFS).
#define AR_FX_LIMITER    1u  // ceiling -1 dBFS, instant attack, 100 ms release
#define AR_FX_COMPRESSOR 2u  // "Compress": 2:1 above -24 dBFS (RMS), 10 dB soft knee, 10/150 ms, +2 dB make-up
#define AR_FX_LOWCUT     4u  // 80 Hz high-pass, 12 dB/octave Butterworth
#define AR_FX_NOISEGATE  8u  // "Noise gate": hard gate 8 dB over an automatic noise-floor estimate; opens in ~1 ms, 700 ms hold
#define AR_FX_AUTOLEVEL  16u // "Auto level": boosts passages well below the normal level, pulls sudden jumps down to a ceiling

typedef struct ar_engine ar_engine;

ar_engine *ar_engine_create(void);
void ar_engine_destroy(ar_engine *e);

// --- Topology (engine must be stopped) -------------------------------------
// A slot is mono (numChannels 1) or stereo (2). Each channel names a buffer
// index in the IOProc's AudioBufferList and a channel within that buffer.
// Pass -1 for unused references. Returns false if the engine is running.
bool ar_engine_clear_topology(ar_engine *e);
bool ar_engine_set_input_map(ar_engine *e, int slot, int numChannels, int buf0, int ch0, int buf1, int ch1);
bool ar_engine_set_output_map(ar_engine *e, int slot, int numChannels, int buf0, int ch0, int buf1, int ch1);
bool ar_engine_set_sample_rate(ar_engine *e, double sampleRate);

// --- Parameters (any thread, any time). Gains are linear. ------------------
void ar_engine_set_route(ar_engine *e, int in, int out, float gain); // 0 = not routed
void ar_engine_set_input_gain(ar_engine *e, int in, float gain);
void ar_engine_set_input_mute(ar_engine *e, int in, bool mute);
void ar_engine_set_input_effects(ar_engine *e, int in, uint32_t flags);
// amount is 0..1.5 (1.0 = 100%); see the flag comments above for what it does per effect.
void ar_engine_set_input_fx_level(ar_engine *e, int in, uint32_t effect, float level);
void ar_engine_set_output_gain(ar_engine *e, int out, float gain);
void ar_engine_set_output_mute(ar_engine *e, int out, bool mute);
// Outputs only ever support AR_FX_LIMITER (a final safety ceiling on the bus).
void ar_engine_set_output_effects(ar_engine *e, int out, uint32_t flags);
void ar_engine_set_output_fx_level(ar_engine *e, int out, uint32_t effect, float level);

// --- Metering (any thread). "take" returns the peak since the last call. ---
float ar_engine_take_input_peak(ar_engine *e, int in, int channel);
float ar_engine_take_output_peak(ar_engine *e, int out, int channel);
// Largest gain reduction in dB applied by that effect since the last call.
// Supported for AR_FX_LIMITER, AR_FX_COMPRESSOR, AR_FX_NOISEGATE (attenuation
// while closed) and AR_FX_AUTOLEVEL (pulling a jump down to its ceiling).
float ar_engine_take_input_reduction(ar_engine *e, int in, uint32_t effect);
// Largest boost in dB auto level gave a quiet passage since the last call.
float ar_engine_take_input_lift(ar_engine *e, int in);
float ar_engine_take_output_reduction(ar_engine *e, int out, uint32_t effect);
uint64_t ar_engine_callback_count(ar_engine *e);
uint64_t ar_engine_clip_count(ar_engine *e);

// --- Peak-hold (any thread). Unlike "take", these never reset themselves:
// they hold the loudest peak (linear amplitude) seen since the last explicit
// reset, and whether that peak reached 0 dBFS (before the final safety clip),
// so a clip caught while the window was in the background is still visible.
float ar_engine_input_peak_hold(ar_engine *e, int in, int channel);
bool ar_engine_input_clipped(ar_engine *e, int in, int channel);
void ar_engine_reset_input_peak_hold(ar_engine *e, int in, int channel);
float ar_engine_output_peak_hold(ar_engine *e, int out, int channel);
bool ar_engine_output_clipped(ar_engine *e, int out, int channel);
void ar_engine_reset_output_peak_hold(ar_engine *e, int out, int channel);

// --- Diagnostics (any thread). Times are mach_absolute_time() ticks. -------
// When the most recent callback began; 0 if there has never been one.
uint64_t ar_engine_last_callback_time(ar_engine *e);
// When the first callback after the latest ar_engine_start began; 0 until it happens.
uint64_t ar_engine_first_callback_time(ar_engine *e);
// Longest gap between the starts of two consecutive callbacks since the last call.
uint64_t ar_engine_take_max_callback_interval(ar_engine *e);
// Longest time spent inside one callback since the last call.
uint64_t ar_engine_take_max_process_time(ar_engine *e);
// Longest run of exact digital silence (every sample 0.0) since the last call, in
// frames. A run still going when taken counts from where it began.
uint32_t ar_engine_take_input_zero_run(ar_engine *e, int in);
uint32_t ar_engine_take_output_zero_run(ar_engine *e, int out);
// Callbacks in which a mapped input or output channel had no buffer, or a buffer
// too short for the callback. Should always stay 0.
uint64_t ar_engine_missing_buffer_count(ar_engine *e);

// --- The render function. Exposed so it can be tested without hardware. ----
void ar_engine_process(ar_engine *e, const AudioBufferList *in, AudioBufferList *out);

// --- Hardware glue ----------------------------------------------------------
OSStatus ar_engine_start(ar_engine *e, AudioObjectID device);
OSStatus ar_engine_stop(ar_engine *e);
bool ar_engine_is_running(ar_engine *e);

#endif
