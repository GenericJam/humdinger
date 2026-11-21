/*
 * c_src/hum_io.c: Humdinger's two mob_audio_io processors, plain C (no BEAM,
 * no platform API). hum_audio.c includes it and registers them when the NIF
 * loads; c_src/test/hum_io_host.c drives them on the host.
 *
 *   "hum_mic"    input. capture() copies the microphone's samples (folded to
 *                mono) into a lock-free ring that hum_audio.c's listen thread
 *                reads, and notes when each block arrived. Nothing else: no
 *                lock, no allocation, no call but atomics.
 *   "hum_piano"  output. render() plays the phrase hum_piano_prepare() set up
 *                on the sampled piano (piano.c) and publishes when the
 *                block's first frame will be heard (mai_time.present_ns);
 *                hum_piano_progress() turns that into the playhead and the
 *                end. The synth is built at STARTED (a normal thread, at the
 *                stream's rate), so render() allocates nothing.
 *
 * stream_event() runs on a normal thread, never beside render() or capture()
 * of the same stream. Each processor counts its started streams (STARTED
 * minus STOPPED), so a phrase or a listening is never reset under a running
 * stream.
 */

#include <pthread.h>
#include <stdatomic.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "../deps/mob_audio_io/priv/include/mob_audio_io.h"
#include "piano.c"

/* ── A pair of values for one writer and other readers (a seqlock) ─────── */

typedef struct {
    _Atomic uint32_t seq; /* odd while written; 0 until the first write */
    _Atomic int64_t a, b;
} hum_pair;

/* One writer at a time (the audio thread, or a normal thread while no
 * stream runs). Real-time safe. */
static void hum_pair_write(hum_pair *p, int64_t a, int64_t b) {
    uint32_t s = atomic_load_explicit(&p->seq, memory_order_relaxed);
    atomic_store_explicit(&p->seq, s + 1, memory_order_relaxed);
    atomic_thread_fence(memory_order_release);
    atomic_store_explicit(&p->a, a, memory_order_relaxed);
    atomic_store_explicit(&p->b, b, memory_order_relaxed);
    atomic_store_explicit(&p->seq, s + 2, memory_order_release);
}

/* False before the first write (or if a writer kept it busy throughout,
 * which the audio thread's few stores never do for long). */
static bool hum_pair_read(hum_pair *p, int64_t *a, int64_t *b) {
    for (int tries = 0; tries < 1000; tries++) {
        uint32_t s = atomic_load_explicit(&p->seq, memory_order_acquire);
        if (s == 0) return false;
        if (s & 1u) continue;
        int64_t x = atomic_load_explicit(&p->a, memory_order_relaxed);
        int64_t y = atomic_load_explicit(&p->b, memory_order_relaxed);
        atomic_thread_fence(memory_order_acquire);
        if (atomic_load_explicit(&p->seq, memory_order_relaxed) == s) {
            *a = x;
            *b = y;
            return true;
        }
    }
    return false;
}

/* No writer may run. */
static void hum_pair_clear(hum_pair *p) {
    atomic_store(&p->a, 0);
    atomic_store(&p->b, 0);
    atomic_store(&p->seq, 0);
}

/* ── "hum_mic": the microphone into a ring ─────────────────────────────── */

#define HUM_MIC_RING (1 << 16) /* mono samples, a power of two (1.4 s at 48 kHz) */
#define HUM_MIC_ARRIVALS 64    /* recent blocks: the ring index they filled up to, and when */

typedef struct {
    _Atomic int32_t open;   /* streams started and not stopped */
    _Atomic int32_t rate;   /* the stream's, from STARTED */
    _Atomic bool capturing; /* the listen thread takes samples */
    _Atomic bool rebase;    /* the next block starts a new stretch (after an open or a reopen) */
    float ring[HUM_MIC_RING];
    _Atomic int64_t written; /* samples written since the reset */
    /* A stretch's first ring index and when that sample was captured
     * (mai_now_ns's clock). A reopen starts a new stretch: the time between
     * two is a gap the ring doesn't hold. */
    hum_pair base;
    struct {
        _Atomic int64_t end, ns;
    } arrivals[HUM_MIC_ARRIVALS];
    _Atomic int64_t arrivals_n;
    _Atomic int64_t callbacks, last_frames;
} hum_mic;

/* A new listening: empty ring, no arrivals, and the next block (once
 * capturing) starts the first stretch. No stream may run (open == 0), or
 * capture() would race the reset. */
static void hum_mic_reset(hum_mic *m) {
    atomic_store(&m->capturing, false);
    atomic_store(&m->written, 0);
    atomic_store(&m->rebase, true);
    hum_pair_clear(&m->base);
    for (int i = 0; i < HUM_MIC_ARRIVALS; i++) {
        atomic_store(&m->arrivals[i].end, 0);
        atomic_store(&m->arrivals[i].ns, 0);
    }
    atomic_store(&m->arrivals_n, 0);
    atomic_store(&m->callbacks, 0);
    atomic_store(&m->last_frames, 0);
}

static void hum_mic_capture(void *ctx, const float *in, int32_t frames, const mai_time *t) {
    hum_mic *m = ctx;
    if (frames <= 0 || t->rate <= 0 || !atomic_load_explicit(&m->capturing, memory_order_acquire)) return;
    int32_t ch = t->channels > 0 ? t->channels : 1;
    int64_t w = atomic_load_explicit(&m->written, memory_order_relaxed);
    /* The block's first sample was captured about a block before the
     * callback began. Published before `written`, so a reader that sees
     * these samples sees their stretch. */
    if (atomic_exchange_explicit(&m->rebase, false, memory_order_relaxed))
        hum_pair_write(&m->base, w, t->host_ns - (int64_t)frames * 1000000000LL / t->rate);
    for (int32_t i = 0; i < frames; i++) {
        float x = in[(size_t)i * (size_t)ch];
        for (int32_t c = 1; c < ch; c++) x += in[(size_t)i * (size_t)ch + (size_t)c];
        m->ring[(w + i) & (HUM_MIC_RING - 1)] = ch > 1 ? x / (float)ch : x;
    }
    atomic_store_explicit(&m->written, w + frames, memory_order_release);
    int64_t k = atomic_fetch_add_explicit(&m->arrivals_n, 1, memory_order_relaxed) & (HUM_MIC_ARRIVALS - 1);
    atomic_store_explicit(&m->arrivals[k].end, w + frames, memory_order_relaxed);
    atomic_store_explicit(&m->arrivals[k].ns, t->host_ns, memory_order_relaxed);
    atomic_fetch_add_explicit(&m->callbacks, 1, memory_order_relaxed);
    atomic_store_explicit(&m->last_frames, frames, memory_order_relaxed);
}

static void hum_mic_event(void *ctx, int32_t stream, int32_t event, const mai_time *t) {
    (void)stream;
    hum_mic *m = ctx;
    if (event == MAI_EVENT_STARTED) {
        atomic_fetch_add(&m->open, 1);
        atomic_store(&m->rate, t->rate);
        atomic_store(&m->rebase, true);
    } else if (event == MAI_EVENT_STOPPED) {
        atomic_fetch_sub(&m->open, 1);
    }
}

/* ── "hum_piano": a phrase on the sampled piano ────────────────────────── */

#define HUM_PIANO_MIN_ROOT 22
#define HUM_PIANO_MAX_ROOT 106
#define HUM_PIANO_ROOT_STEP 3
#define HUM_PIANO_ROOT_COUNT 29
#define HUM_PIANO_SAMPLE_RATE 22050
#define HUM_PIANO_MAX_WAV_BYTES (2 * 1024 * 1024)
#define HUM_PIANO_CHECK_RATE 48000 /* prepare checks the notes at this rate */
#define HUM_PIANO_CHUNK 256        /* frames rendered at once for a stereo stream */

/* A note as the BEAM sends it. */
typedef struct {
    double start_ms;
    double dur_ms;
    int32_t midi;
    float gain;
} piano_raw_note;

typedef enum {
    HUM_PIANO_IDLE,     /* nothing armed: no stream started on the prepared phrase */
    HUM_PIANO_PLAYING,  /* `ms` is the playhead */
    HUM_PIANO_FINISHED, /* the phrase's last frame has been heard */
    HUM_PIANO_FAILED,   /* the stream started but couldn't play it (see `failed`) */
} hum_piano_state;

typedef struct {
    pthread_mutex_t lock; /* prepare against stream_event (normal threads only) */
    _Atomic int32_t open;
    /* Under `lock`, no stream started. */
    piano_bank bank;
    bool bank_loaded;
    piano_raw_note *raw; /* the prepared phrase, made frames at STARTED */
    int32_t raw_n;
    double phrase_end_ms;
    /* Built at STARTED, then the audio thread's. */
    piano_synth synth;
    int32_t rate;
    int64_t total_frames, phrase_end_frames;
    _Atomic bool armed;            /* render() plays; publishes the fields above */
    _Atomic(const char *) failed;  /* why STARTED couldn't arm, or NULL */
    _Atomic int64_t rendered;      /* synth frames handed to the stream */
    _Atomic bool done;             /* every synth frame was handed over */
    hum_pair anchor;               /* (synth frame, when it is heard): a block's first */
} hum_piano;

static uint16_t hum_le16(const uint8_t *p) { return (uint16_t)p[0] | ((uint16_t)p[1] << 8); }

static uint32_t hum_le32(const uint8_t *p) {
    return (uint32_t)p[0] | ((uint32_t)p[1] << 8) | ((uint32_t)p[2] << 16) | ((uint32_t)p[3] << 24);
}

static void hum_free_samples(piano_sample *samples, int count) {
    if (!samples) return;
    for (int i = 0; i < count; i++) free((void *)samples[i].pcm);
    free(samples);
}

/* A mono 16-bit WAV at HUM_PIANO_SAMPLE_RATE. */
static bool hum_load_wav(const char *path, int16_t **pcm_out, int64_t *frames_out) {
    FILE *f = fopen(path, "rb");
    if (!f) return false;
    if (fseek(f, 0, SEEK_END) != 0) {
        fclose(f);
        return false;
    }
    long len = ftell(f);
    if (len < 44 || len > HUM_PIANO_MAX_WAV_BYTES || fseek(f, 0, SEEK_SET) != 0) {
        fclose(f);
        return false;
    }
    size_t sz = (size_t)len;
    uint8_t *buf = malloc(sz);
    if (!buf || fread(buf, 1, sz, f) != sz) {
        free(buf);
        fclose(f);
        return false;
    }
    fclose(f);
    if (memcmp(buf, "RIFF", 4) != 0 || memcmp(buf + 8, "WAVE", 4) != 0) {
        free(buf);
        return false;
    }

    bool have_fmt = false, have_data = false;
    size_t pos = 12;
    const uint8_t *data_ptr = NULL;
    uint32_t data_sz = 0;
    while (pos + 8 <= sz) {
        const uint8_t *hdr = buf + pos;
        uint32_t chunk_sz = hum_le32(hdr + 4);
        size_t payload = pos + 8;
        if ((uint64_t)chunk_sz > (uint64_t)(sz - payload)) break;
        if (memcmp(hdr, "fmt ", 4) == 0) {
            if (chunk_sz < 16) break;
            uint16_t audio_fmt = hum_le16(buf + payload);
            uint16_t channels = hum_le16(buf + payload + 2);
            uint32_t rate = hum_le32(buf + payload + 4);
            uint16_t bits = hum_le16(buf + payload + 14);
            if (audio_fmt != 1 || channels != 1 || rate != HUM_PIANO_SAMPLE_RATE || bits != 16) break;
            have_fmt = true;
        } else if (memcmp(hdr, "data", 4) == 0) {
            if (chunk_sz < 4 || (chunk_sz & 1u) != 0) break;
            data_ptr = buf + payload;
            data_sz = chunk_sz;
            have_data = true;
        }
        size_t padded = (size_t)chunk_sz + (chunk_sz & 1u);
        if (padded > sz - payload) break;
        pos = payload + padded;
    }
    if (!have_fmt || !have_data) {
        free(buf);
        return false;
    }

    int64_t frames = (int64_t)(data_sz / 2);
    int16_t *pcm = malloc((size_t)data_sz);
    if (!pcm) {
        free(buf);
        return false;
    }
    for (int64_t i = 0; i < frames; i++) pcm[i] = (int16_t)hum_le16(data_ptr + (size_t)i * 2);
    free(buf);
    *pcm_out = pcm;
    *frames_out = frames;
    return true;
}

/* The bank priv/piano holds: mf_022.wav … mf_106.wav, every third note. */
static bool hum_piano_load_bank(hum_piano *p, const char *dir) {
    if (p->bank_loaded) return true;
    piano_sample *samples = calloc(HUM_PIANO_ROOT_COUNT, sizeof(piano_sample));
    if (!samples) return false;
    int count = 0;
    for (int midi = HUM_PIANO_MIN_ROOT; midi <= HUM_PIANO_MAX_ROOT && count < HUM_PIANO_ROOT_COUNT;
         midi += HUM_PIANO_ROOT_STEP) {
        char path[1024];
        int n = snprintf(path, sizeof(path), "%s/mf_%03d.wav", dir, midi);
        int16_t *pcm = NULL;
        int64_t frames = 0;
        if (n < 0 || (size_t)n >= sizeof(path) || !hum_load_wav(path, &pcm, &frames)) {
            hum_free_samples(samples, count);
            return false;
        }
        samples[count++] = (piano_sample){.pcm = pcm, .frames = frames, .root_midi = midi};
    }
    if (count != HUM_PIANO_ROOT_COUNT) {
        hum_free_samples(samples, count);
        return false;
    }
    p->bank = (piano_bank){.rate = HUM_PIANO_SAMPLE_RATE, .count = count, .samples = samples};
    p->bank_loaded = true;
    return true;
}

/* The phrase's notes at `rate`, or NULL (no memory). */
static piano_note *hum_piano_notes(const piano_raw_note *raw, int32_t n, int rate) {
    piano_note *notes = calloc((size_t)n, sizeof(piano_note));
    if (!notes) return NULL;
    int64_t max_frames = piano_ms_to_frames((double)PIANO_MAX_DURATION_MS, rate);
    for (int32_t i = 0; i < n; i++) {
        int64_t sf = piano_ms_to_frames(raw[i].start_ms, rate);
        int64_t rf = piano_ms_to_frames(raw[i].start_ms + raw[i].dur_ms, rate);
        if (rf <= sf) rf = sf + 1;
        if (rf > max_frames) rf = max_frames;
        notes[i] = (piano_note){.start_frame = sf, .release_frame = rf, .midi = raw[i].midi, .gain = raw[i].gain};
    }
    return notes;
}

/* Build the synth for the prepared phrase at `rate`: 0, or -1 for notes it
 * refuses, -2 for no memory. */
static int hum_piano_build(hum_piano *p, piano_synth *synth, int rate) {
    piano_note *notes = hum_piano_notes(p->raw, p->raw_n, rate);
    if (!notes) return -2;
    int r = piano_synth_init(synth, &p->bank, notes, p->raw_n, rate);
    free(notes);
    return r == 0 ? 0 : -1;
}

/* Set up `raw` (`n` notes, ending at `end_ms`; taken over, freed here on
 * failure) for the next stream to start on "hum_piano". NULL, or the error:
 * "busy" (a stream still plays the last phrase), "samples_unavailable"
 * (the bank in `dir` is missing or damaged), "invalid_notes", "alloc". */
static const char *hum_piano_prepare(hum_piano *p, const char *dir, piano_raw_note *raw, int32_t n, double end_ms) {
    pthread_mutex_lock(&p->lock);
    const char *failure = NULL;
    if (atomic_load(&p->open) > 0) {
        free(raw);
        failure = "busy";
    } else if (!hum_piano_load_bank(p, dir)) {
        free(raw);
        failure = "samples_unavailable";
    } else {
        free(p->raw);
        piano_synth_free(&p->synth);
        p->raw = raw;
        p->raw_n = n;
        p->phrase_end_ms = end_ms;
        atomic_store(&p->armed, false);
        atomic_store(&p->failed, NULL);
        atomic_store(&p->rendered, 0);
        atomic_store(&p->done, false);
        hum_pair_clear(&p->anchor);
        /* Refuse what STARTED would refuse, now, while the caller can hear it. */
        piano_synth check;
        int r = hum_piano_build(p, &check, HUM_PIANO_CHECK_RATE);
        piano_synth_free(&check);
        if (r != 0) {
            free(p->raw);
            p->raw = NULL;
            p->raw_n = 0;
            failure = r == -2 ? "alloc" : "invalid_notes";
        }
    }
    pthread_mutex_unlock(&p->lock);
    return failure;
}

/* A stream started (under `lock`): build the prepared phrase at its rate
 * and arm render(). */
static void hum_piano_start(hum_piano *p, int32_t rate) {
    if (atomic_load(&p->armed)) {
        /* Reopened: the phrase goes on where it was, unless the rate moved
         * under its frame counts. */
        if (rate != p->rate) {
            atomic_store(&p->armed, false);
            atomic_store(&p->failed, "output_error");
        }
        return;
    }
    if (!p->raw || atomic_load(&p->failed)) return;
    int r = hum_piano_build(p, &p->synth, rate);
    if (r != 0) {
        atomic_store(&p->failed, r == -2 ? "alloc" : "invalid_notes");
        return;
    }
    p->rate = rate;
    p->total_frames = p->synth.total_frames;
    p->phrase_end_frames = p->synth.phrase_end_frame;
    atomic_store(&p->rendered, 0);
    atomic_store(&p->done, false);
    hum_pair_clear(&p->anchor);
    atomic_store_explicit(&p->armed, true, memory_order_release);
}

static void hum_piano_event(void *ctx, int32_t stream, int32_t event, const mai_time *t) {
    (void)stream;
    hum_piano *p = ctx;
    pthread_mutex_lock(&p->lock);
    if (event == MAI_EVENT_STOPPED) {
        atomic_fetch_sub(&p->open, 1);
    } else if (event == MAI_EVENT_STARTED) {
        atomic_fetch_add(&p->open, 1);
        hum_piano_start(p, t->rate);
    }
    pthread_mutex_unlock(&p->lock);
}

static void hum_piano_render(void *ctx, float *out, int32_t frames, const mai_time *t) {
    hum_piano *p = ctx;
    if (frames <= 0 || !atomic_load_explicit(&p->armed, memory_order_acquire) ||
        atomic_load_explicit(&p->done, memory_order_relaxed))
        return;
    int32_t ch = t->channels > 0 ? t->channels : 1;
    int64_t before = atomic_load_explicit(&p->rendered, memory_order_relaxed);
    int32_t got = 0;
    if (ch == 1) {
        got = piano_synth_render_block(&p->synth, &p->bank, out, frames);
    } else {
        float block[HUM_PIANO_CHUNK];
        while (got < frames) {
            int32_t want = frames - got < HUM_PIANO_CHUNK ? frames - got : HUM_PIANO_CHUNK;
            int32_t n = piano_synth_render_block(&p->synth, &p->bank, block, want);
            for (int32_t i = 0; i < n; i++)
                for (int32_t c = 0; c < ch; c++) out[(size_t)(got + i) * (size_t)ch + (size_t)c] = block[i];
            got += n;
            if (n < want) break;
        }
    }
    if (got > 0) {
        /* Unknown for a stream's first callbacks on Android 12+: about two
         * blocks ahead, the stream's default double buffering. */
        int64_t heard = t->present_ns > 0 ? t->present_ns
                                          : t->host_ns + 2LL * frames * 1000000000LL / (t->rate > 0 ? t->rate : 1);
        hum_pair_write(&p->anchor, before, heard);
        atomic_store_explicit(&p->rendered, before + got, memory_order_release);
    }
    if (p->synth.cursor_frame >= p->total_frames) atomic_store_explicit(&p->done, true, memory_order_release);
}

/* Played ms for synth frame `frames`: the phrase's own end once the notes
 * are over (the release tail isn't part of the phrase's time). */
static int64_t hum_piano_ms(const hum_piano *p, int64_t frames) {
    if (frames <= 0 || p->rate <= 0) return 0;
    int64_t cap = (int64_t)llround(p->phrase_end_ms);
    if (cap < 0) cap = 0;
    if (frames >= p->phrase_end_frames) return cap;
    int64_t ms = (int64_t)llround((double)frames * 1000.0 / (double)p->rate);
    return ms < 0 ? 0 : ms > cap ? cap : ms;
}

/* Where the prepared phrase is at `now` (mai_now_ns's clock): `*ms` the
 * playhead; `*finish_in_ns` how long until its last frame is heard, once
 * it's all been handed over (else -1); `*why` the reason when FAILED. */
static hum_piano_state hum_piano_progress(hum_piano *p, int64_t now, int64_t *ms, int64_t *finish_in_ns,
                                          const char **why) {
    *ms = 0;
    *finish_in_ns = -1;
    *why = atomic_load(&p->failed);
    if (*why) return HUM_PIANO_FAILED;
    if (!atomic_load_explicit(&p->armed, memory_order_acquire)) return HUM_PIANO_IDLE;
    bool done = atomic_load_explicit(&p->done, memory_order_acquire);
    int64_t rendered = atomic_load_explicit(&p->rendered, memory_order_acquire);
    int64_t frame, at;
    if (!hum_pair_read(&p->anchor, &frame, &at)) return done ? HUM_PIANO_FINISHED : HUM_PIANO_PLAYING;
    double heard = (double)frame + (double)(now - at) * (double)p->rate / 1e9;
    int64_t presented = heard <= 0.0 ? 0 : heard >= (double)rendered ? rendered : (int64_t)heard;
    *ms = hum_piano_ms(p, presented);
    if (done && rendered >= p->total_frames) {
        int64_t end = at + (p->total_frames - frame) * 1000000000LL / p->rate;
        if (now >= end) {
            *ms = hum_piano_ms(p, p->total_frames);
            return HUM_PIANO_FINISHED;
        }
        *finish_in_ns = end - now;
    }
    return HUM_PIANO_PLAYING;
}
