// SplitCore: the real-time part of Crossover.
//
// One Core Audio IOProc runs on a private aggregate device holding every device
// in use, so the input and all four outputs share one clock and one callback.
// Nothing is buffered between them: what comes in is split and written out in
// the same callback.
//
// The split is a four-band Linkwitz-Riley crossover tree:
//
//                                    ┌─ LP(x1) ─ AP(x2) ─ AP(x3) ─────── band 0 (low)
//   input ─ [HP(low edge)] ─ [LP(high edge)] ─┤
//                                    └─ HP(x1) ─┬─ LP(x2) ─ AP(x3) ────── band 1 (mid)
//                                               └─ HP(x2) ─┬─ LP(x3) ─── band 2 (mid-high)
//                                                          └─ HP(x3) ─── band 3 (high)
//
// The all-pass stages (AP) give the lower bands the same phase shift the upper
// bands get from the later crossovers, so the bands add back up to the input
// with a flat frequency response, both electrically and between speakers in the
// room. The two outer edges (a low cut and a high cut) filter the input, so they
// always apply to whichever bands are lowest and highest, and can be switched off.
//
// Bands can be removed. A removed band's range goes to the next band up (or, for
// the top band, the next band down): its crossover stops filtering and passes
// everything to that side. So with Low and Mid-High left, Low keeps 20-100 Hz and
// Mid-High takes everything above 100 Hz. The remaining bands still sum flat.
//
// Crossover slopes (dB/octave):
//    6  first order; the two sides always sum exactly to the input
//   12  Linkwitz-Riley 2nd order; the upper side is phase-inverted, as in any
//       LR2 speaker crossover, so the two sides sum flat
//   24  Linkwitz-Riley 4th order (the standard)
//   36  Linkwitz-Riley 6th order; upper side phase-inverted, like LR2
//   48  Linkwitz-Riley 8th order
// An outer edge also accepts 0 (off). Every Linkwitz-Riley crossover is -6 dB on
// each side at its frequency; a first-order one is -3 dB.
//
// No latency is added: every filter is a recursive (IIR) filter run sample by
// sample inside the callback. The delay through the app is the device buffers
// alone.
//
// Threading contract:
//   * Topology (which buffer/channel the input and each band use) may only be
//     changed while the engine is stopped. The setters refuse otherwise.
//   * Frequencies, slopes, gains and mutes may be changed from any thread at any
//     time. They are lock-free atomics. The audio thread glides frequencies
//     (~30 ms) and gains (~10 ms), and a slope change dips the outputs for ~10 ms
//     while the filters are swapped, so nothing clicks.
//   * The audio thread never allocates, locks, logs or calls into Swift.

#ifndef SPLIT_CORE_H
#define SPLIT_CORE_H

#include <CoreAudio/CoreAudio.h>
#include <stdbool.h>
#include <stdint.h>

#define SC_BANDS 4
#define SC_EDGES 5              // low edge, crossovers 1-3, high edge
#define SC_MAX_SLOT_CHANNELS 2  // the input and each band are mono or stereo
#define SC_ALL_BANDS 0xFu
#define SC_SCOPE_SIZE 16384     // samples of recent input kept for the spectrum display (a power of two)

// Edge indices.
#define SC_EDGE_LOW   0  // low cut (high-pass) on the input
#define SC_EDGE_X1    1  // low | mid
#define SC_EDGE_X2    2  // mid | mid-high
#define SC_EDGE_X3    3  // mid-high | high
#define SC_EDGE_HIGH  4  // high cut (low-pass) on the input

#define SC_MIN_HZ 10.0f
#define SC_MAX_HZ 22000.0f  // also never above 45% of the sample rate

typedef struct sc_engine sc_engine;

// One edge as the filters see it.
typedef struct {
    float hz;
    int32_t slope; // 0 (outer edges only), 6, 12, 24, 36 or 48
} sc_edge;

sc_engine *sc_engine_create(void);
void sc_engine_destroy(sc_engine *e);

// --- Topology (engine must be stopped) -------------------------------------
// A slot is mono (numChannels 1) or stereo (2). Each channel names a buffer
// index in the IOProc's AudioBufferList and a channel within that buffer.
// Pass -1 for unused references. Returns false if the engine is running.
bool sc_engine_clear_topology(sc_engine *e);
bool sc_engine_set_input_map(sc_engine *e, int numChannels, int buf0, int ch0, int buf1, int ch1);
bool sc_engine_set_band_map(sc_engine *e, int band, int numChannels, int buf0, int ch0, int buf1, int ch1);
bool sc_engine_set_sample_rate(sc_engine *e, double sampleRate);

// --- Parameters (any thread, any time) -------------------------------------
// Frequencies are clamped to SC_MIN_HZ..SC_MAX_HZ (and 45% of the sample rate).
// An invalid slope leaves the edge's slope unchanged. The engine does not
// reorder edges: keeping them in order is the caller's job.
void sc_engine_set_edge(sc_engine *e, int edge, float hz, int slope);
void sc_engine_set_band_gain(sc_engine *e, int band, float gain); // linear, 0..16
void sc_engine_set_band_mute(sc_engine *e, int band, bool mute);
// Flips the band's polarity (its output is multiplied by -1). Crossfaded.
void sc_engine_set_band_invert(sc_engine *e, int band, bool invert);
// Which bands exist, as a bit mask (bit 0 = low). 0 is refused. A change is
// applied like a slope change: a ~10 ms dip while the filters are rewired.
void sc_engine_set_bands_enabled(sc_engine *e, uint32_t mask);

// --- Metering (any thread). "take" returns the peak since the last call. ---
float sc_engine_take_input_peak(sc_engine *e, int channel);
float sc_engine_take_band_peak(sc_engine *e, int band, int channel);
uint64_t sc_engine_callback_count(sc_engine *e);
uint64_t sc_engine_clip_count(sc_engine *e);
// Callbacks in which a mapped channel had no buffer or too short a buffer.
uint64_t sc_engine_missing_buffer_count(sc_engine *e);
// Longest time spent inside one callback since the last call (mach ticks).
uint64_t sc_engine_take_max_process_time(sc_engine *e);

// Copies the most recent `count` input samples (mono: the channels averaged),
// oldest first, into dst. count is capped at SC_SCOPE_SIZE. Returns the total
// number of samples the engine has ever written, so a caller can tell whether
// anything new arrived. For display only: a read racing the audio thread can
// see a few samples from the next callback, which a spectrum never shows.
uint64_t sc_engine_read_scope(sc_engine *e, float *dst, uint32_t count);

// --- Filter design (pure; any thread) --------------------------------------
// The magnitude response, in dB, of one band at `hz`, for the given edges,
// enabled bands (mask as above) and sample rate, before the band's gain. Uses
// exactly the filters the engine runs, so the display draws what is heard.
// A removed band returns -200.
double sc_band_response_db(const sc_edge edges[SC_EDGES], uint32_t enabledMask, double sampleRate, int band, double hz);

// Whether crossover `edge` (SC_EDGE_X1..X3) separates two remaining bands for
// this mask. An inactive crossover passes everything to one side.
bool sc_crossover_active(uint32_t enabledMask, int edge);

// --- The render function. Exposed so it can be tested without hardware. ----
void sc_engine_process(sc_engine *e, const AudioBufferList *in, AudioBufferList *out);

// --- Hardware glue ----------------------------------------------------------
OSStatus sc_engine_start(sc_engine *e, AudioObjectID device);
OSStatus sc_engine_stop(sc_engine *e);
bool sc_engine_is_running(sc_engine *e);
uint64_t sc_engine_last_callback_time(sc_engine *e);

#endif
