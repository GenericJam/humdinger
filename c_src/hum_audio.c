/*
 * c_src/hum_audio.c: Humdinger's DSP as a static NIF on top of mob_audio_io,
 * which owns the audio streams, the devices and file decoding. This file
 * and what it includes are plain C over erl_nif and the plugin's C ABI
 * (../deps/mob_audio_io/priv/include/mob_audio_io.h): no platform API.
 *
 *   load              registers the processors of hum_io.c with the plugin:
 *                     "hum_mic" (capture into a ring) and "hum_piano"
 *                     (render a phrase). Humdinger.Audio.Native opens their
 *                     streams with MobAudioIo.open/3.
 *   listen thread     YIN (pitch_yin.c) every hop (~5.3 ms) over a 42 ms
 *                     window of the ring, and a spectrum column (spectrum.c)
 *                     every 1/30 s while asked for. Readings go to the owner
 *                     in batches as soon as two are ready (or one has waited
 *                     6 ms), so each message leaves within ~12 ms of the
 *                     newest sample's arrival. A thread that falls behind
 *                     restarts on the newest audio rather than deliver late
 *                     readings.
 *   analysis          analysis_new/push/finish: YIN and a peak waveform over
 *                     a file's PCM, pushed chunk by chunk as
 *                     MobAudioIo.decode_stream/3 delivers it.
 *   piano             piano_prepare/2 sets up a phrase for the next
 *                     "hum_piano" stream; piano_position/0 reads its playhead.
 *
 * The listen thread builds its messages in their final shape (see
 * Humdinger.Audio), so the BEAM does no per-reading work beyond receiving
 * them:
 *
 *   {hum_audio, Ref, {readings, [#{t, hz, clarity, db}]}}
 *   {hum_audio, Ref, {spectrum, #{t, bins}}}
 *   {hum_audio, Ref, {error, alloc}}
 *
 * One listener at a time: listen/3 stops the previous one first, and its
 * reference goes stale. The stream's own events (a lost device) and the
 * owner's death are Humdinger.Audio.Native's: it stops the listener here.
 *
 * Locks, always taken in this order: lock → send_lock. `lock` serialises
 * listen and stop (joining the listen thread); `send_lock` guards the
 * listener's owner and reference, so no message of a stopped listener
 * starts once stop has returned. The audio thread takes neither.
 */

#include <erl_nif.h>
#include <math.h>
#include <pthread.h>
#include <stdatomic.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#if defined(__APPLE__)
#include <pthread/qos.h>
#else
#include <sys/resource.h>
#endif

/* Android's armeabi-v7a has VFPv3 and NEON. Built for a generic ARMv7 (zig's
 * default), every float operation becomes a library call and the detector
 * runs far slower than real time on a moto e 2020: refuse to build that way. */
#if defined(__arm__) && defined(__SOFTFP__)
#error "hum_audio needs hardware floating point on 32-bit ARM: compile armeabi-v7a with -mfloat-abi=softfp (android/app/src/main/jni/build.zig)"
#endif

#include "pitch_yin.c"
#include "spectrum.c"
#include "hum_io.c"

/* The detector's range: a low bass hum to a high whistle. */
#define MIN_HZ 60.0f
#define MAX_HZ 1600.0f
#define LIVE_HOP_S 0.0053  /* live readings: ~5.3 ms apart */
#define FILE_HOP_S 0.010   /* file readings: 10 ms apart */
#define BATCH_WAIT_NS 6000000LL /* a lone reading waits at most this for a partner */
#define SPECTRUM_PER_S 30
#define WAVEFORM_MS 50
#define BATCH_MAX 64
/* Unread audio beyond this (or two blocks and a hop, or a window and a hop,
 * whichever is more) means the listen thread is behind: it skips to the
 * newest audio rather than deliver stale readings. */
#define MAX_BACKLOG_MS 30

typedef struct {
    int64_t t;
    float hz, clarity, db;
} reading;

typedef struct {
    _Atomic int64_t sum_ns, max_ns, count;
} cost;

/* Batch lag histogram: LAG_BUCKET_US wide, the last bucket is "more". */
#define LAG_BUCKETS 200
#define LAG_BUCKET_US 500

static hum_mic MIC;
static hum_piano PIANO;

static struct {
    pthread_mutex_t lock;
    pthread_mutex_t send_lock;

    /* Bumps whenever listening starts or stops: the listen thread carries
     * the one it belongs to. */
    _Atomic uint64_t generation;
    pthread_t thread;
    _Atomic bool run;
    _Atomic bool spectrum_on;
    int64_t listen_ns; /* when listen/3 was called (mai_now_ns) */

    /* Under send_lock: where this listening's messages go. */
    bool active;
    ErlNifPid owner;
    ErlNifEnv *ref_env;
    ERL_NIF_TERM ref;

    /* Diagnostics for info/0, reset on listen. */
    _Atomic int64_t readings_sent, batches_sent, spectra_sent;
    _Atomic int64_t lag_sum_ns, lag_max_ns;
    _Atomic int64_t lag_hist[LAG_BUCKETS];
    cost detect_cost, column_cost;  /* one pitch reading, one spectrum column */
    _Atomic int64_t skipped, skips; /* audio dropped to catch up */
    _Atomic bool priority_raised;
} E;

static ERL_NIF_TERM atom(ErlNifEnv *env, const char *name) { return enif_make_atom(env, name); }

static ERL_NIF_TERM error_tuple(ErlNifEnv *env, const char *reason) {
    return enif_make_tuple2(env, atom(env, "error"), atom(env, reason));
}

/* The listen thread's priority: Android's THREAD_PRIORITY_AUDIO, iOS's
 * user-interactive QoS, so the UI and the BEAM's schedulers don't hold the
 * readings up. Best effort. */
static bool raise_priority(void) {
#if defined(__APPLE__)
    return pthread_set_qos_class_self_np(QOS_CLASS_USER_INTERACTIVE, 0) == 0;
#else
    return setpriority(PRIO_PROCESS, (id_t)gettid(), -16) == 0;
#endif
}

/* The detector's hop for a rate: about `seconds`, a whole number of
 * decimation steps so every reading sees the same decimation phase. */
static int hop_for(const pitch_detector *p, int rate, double seconds) {
    int h = (int)(rate * seconds / p->factor + 0.5) * p->factor;
    return h > 0 ? h : p->factor;
}

static ERL_NIF_TERM reading_term(ErlNifEnv *env, const reading *r, ERL_NIF_TERM keys[4]) {
    ERL_NIF_TERM vals[4] = {
        enif_make_int64(env, r->t),
        r->hz > 0.0f ? enif_make_double(env, r->hz) : atom(env, "nil"),
        enif_make_double(env, r->clarity),
        enif_make_double(env, r->db),
    };
    ERL_NIF_TERM map;
    enif_make_map_from_arrays(env, keys, vals, 4, &map);
    return map;
}

static void reading_keys(ErlNifEnv *env, ERL_NIF_TERM keys[4]) {
    keys[0] = atom(env, "t");
    keys[1] = atom(env, "hz");
    keys[2] = atom(env, "clarity");
    keys[3] = atom(env, "db");
}

/* Send {hum_audio, Ref, Payload} to the listener if `generation` is still
 * listening; `env` holds the payload and is freed. */
static void send_to_listener(uint64_t generation, ErlNifEnv *env, ERL_NIF_TERM payload) {
    pthread_mutex_lock(&E.send_lock);
    if (E.active && generation == atomic_load(&E.generation)) {
        ERL_NIF_TERM msg = enif_make_tuple3(env, atom(env, "hum_audio"), enif_make_copy(env, E.ref), payload);
        enif_send(NULL, &E.owner, env, msg);
    }
    pthread_mutex_unlock(&E.send_lock);
    enif_free_env(env);
}

/* ── The listen thread ───────────────────────────────────────────────────── */

typedef struct {
    reading items[BATCH_MAX];
    int count;
    int64_t first_at_ns; /* when the oldest pending reading was made */
} batch;

static void send_batch(uint64_t generation, batch *b, int64_t newest_sample) {
    if (b->count == 0) return;
    ErlNifEnv *env = enif_alloc_env();
    ERL_NIF_TERM keys[4];
    reading_keys(env, keys);
    ERL_NIF_TERM list = enif_make_list(env, 0);
    for (int i = b->count - 1; i >= 0; i--) list = enif_make_list_cell(env, reading_term(env, &b->items[i], keys), list);
    send_to_listener(generation, env, enif_make_tuple2(env, atom(env, "readings"), list));

    /* Lag: from the capture callback that delivered the newest sample
     * analysed to the send (what this engine adds; the stream's own
     * buffering, a block at most, comes before). Diagnostics: a callback
     * overwriting an entry mid-read only skews one batch. */
    int64_t now = mai_now_ns(), arrived = -1, n = atomic_load_explicit(&MIC.arrivals_n, memory_order_relaxed);
    for (int64_t k = n - 1; k >= 0 && k >= n - HUM_MIC_ARRIVALS; k--) {
        if (atomic_load_explicit(&MIC.arrivals[k & (HUM_MIC_ARRIVALS - 1)].end, memory_order_relaxed) < newest_sample)
            break;
        arrived = atomic_load_explicit(&MIC.arrivals[k & (HUM_MIC_ARRIVALS - 1)].ns, memory_order_relaxed);
    }
    if (arrived > 0 && arrived <= now) {
        int64_t lag = now - arrived;
        atomic_fetch_add(&E.lag_sum_ns, lag);
        if (lag > atomic_load(&E.lag_max_ns)) atomic_store(&E.lag_max_ns, lag);
        int64_t bucket = lag / (LAG_BUCKET_US * 1000LL);
        atomic_fetch_add_explicit(&E.lag_hist[bucket < LAG_BUCKETS ? bucket : LAG_BUCKETS - 1], 1, memory_order_relaxed);
    }
    atomic_fetch_add(&E.batches_sent, 1);
    atomic_fetch_add(&E.readings_sent, b->count);
    b->count = 0;
}

static void send_spectrum(uint64_t generation, int64_t t_ms, const uint8_t bins[SPEC_BINS]) {
    ErlNifEnv *env = enif_alloc_env();
    ERL_NIF_TERM bin;
    memcpy(enif_make_new_binary(env, SPEC_BINS, &bin), bins, SPEC_BINS);
    ERL_NIF_TERM keys[2] = {atom(env, "t"), atom(env, "bins")};
    ERL_NIF_TERM vals[2] = {enif_make_int64(env, t_ms), bin};
    ERL_NIF_TERM map;
    enif_make_map_from_arrays(env, keys, vals, 2, &map);
    send_to_listener(generation, env, enif_make_tuple2(env, atom(env, "spectrum"), map));
    atomic_fetch_add(&E.spectra_sent, 1);
}

/* Time one piece of work took (diagnostics). */
static void count_cost(cost *c, int64_t ns) {
    atomic_fetch_add_explicit(&c->sum_ns, ns, memory_order_relaxed);
    atomic_fetch_add_explicit(&c->count, 1, memory_order_relaxed);
    if (ns > atomic_load_explicit(&c->max_ns, memory_order_relaxed))
        atomic_store_explicit(&c->max_ns, ns, memory_order_relaxed);
}

/* The listen thread's detector and spectrum, for one rate. */
typedef struct {
    int rate, hop, window, spectrum_every;
    pitch_detector *p;
    spectrum *sp;
    float *chunk, *column_in;
} listen_dsp;

static void dsp_free(listen_dsp *d) {
    free(d->chunk);
    free(d->column_in);
    spectrum_free(d->sp);
    pitch_free(d->p);
    memset(d, 0, sizeof(*d));
}

static bool dsp_init(listen_dsp *d, int rate) {
    dsp_free(d);
    d->rate = rate;
    d->p = pitch_new(rate, MIN_HZ, MAX_HZ);
    d->sp = spectrum_new(rate);
    if (!d->p || !d->sp) return false;
    d->hop = hop_for(d->p, rate, LIVE_HOP_S);
    d->window = pitch_window_input_samples(d->p);
    d->spectrum_every = rate / SPECTRUM_PER_S;
    d->chunk = malloc(sizeof(float) * (size_t)d->hop);
    d->column_in = malloc(sizeof(float) * (size_t)d->sp->n);
    return d->chunk && d->column_in;
}

/* Ms since listen/3 at which ring sample `index` of the stretch that began
 * at `base_index` (captured at `base_ns`) was captured. */
static int64_t sample_ms(int64_t base_index, int64_t base_ns, int rate, double index) {
    double ms = (double)(base_ns - E.listen_ns) / 1e6 + 1000.0 * (index - (double)base_index) / rate;
    return ms > 0 ? (int64_t)(ms + 0.5) : 0;
}

static void *listen_main(void *arg) {
    uint64_t generation = (uint64_t)(uintptr_t)arg;
    atomic_store(&E.priority_raised, raise_priority());
    listen_dsp d;
    memset(&d, 0, sizeof(d));
    /* The stretch being analysed (see hum_mic.base): none until the stream's
     * first block. Readings need a window of audio pushed since `valid_from`. */
    int64_t base_index = -1, base_ns = 0;
    int64_t read = 0, next_column = 0, valid_from = 0;
    batch b = {.count = 0};

    while (atomic_load(&E.run)) {
        int64_t written = atomic_load_explicit(&MIC.written, memory_order_acquire);
        int64_t bi, bn;
        if (hum_pair_read(&MIC.base, &bi, &bn) && (bi != base_index || bn != base_ns)) {
            /* The first audio, or a reopened stream (a gap in time, perhaps
             * a new rate): the analysis starts over on the new stretch. */
            send_batch(generation, &b, read);
            int rate = atomic_load(&MIC.rate);
            if (rate != d.rate && !dsp_init(&d, rate)) {
                ErlNifEnv *env = enif_alloc_env();
                send_to_listener(generation, env, enif_make_tuple2(env, atom(env, "error"), atom(env, "alloc")));
                break;
            }
            base_index = bi;
            base_ns = bn;
            read = valid_from = next_column = bi;
        }
        if (!d.p) {
            usleep(1000);
            continue;
        }

        /* More unread audio than this and the thread is behind, not just
         * handed a block: it drops to the newest audio (see below). */
        int64_t max_backlog = (int64_t)d.rate * MAX_BACKLOG_MS / 1000;
        int64_t block = atomic_load_explicit(&MIC.last_frames, memory_order_relaxed);
        if (max_backlog < 2 * block + d.hop) max_backlog = 2 * block + d.hop;
        if (max_backlog < (int64_t)d.window + d.hop) max_backlog = (int64_t)d.window + d.hop;
        if (written - read > max_backlog) {
            /* Behind (a slow phone, the thread starved): never queue stale
             * audio. Restart the detector on the newest window; the
             * readings in between are lost, not late. */
            int64_t to = written - d.window;
            if (to < base_index) to = base_index;
            if (to > read) {
                atomic_fetch_add(&E.skipped, to - read);
                atomic_fetch_add(&E.skips, 1);
                read = valid_from = to;
            }
        }
        while (written - read >= d.hop) {
            for (int i = 0; i < d.hop; i++) d.chunk[i] = MIC.ring[(read + i) & (HUM_MIC_RING - 1)];
            read += d.hop;
            pitch_push(d.p, d.chunk, d.hop);
            if (read - valid_from >= d.window) {
                int64_t t0 = mai_now_ns();
                pitch_reading pr = pitch_detect(d.p);
                count_cost(&E.detect_cost, mai_now_ns() - t0);
                if (b.count == 0) b.first_at_ns = mai_now_ns();
                b.items[b.count++] =
                    (reading){sample_ms(base_index, base_ns, d.rate, read - d.window / 2.0), pr.hz, pr.clarity, pr.rms_db};
                if (b.count >= 2) send_batch(generation, &b, read);
            }
            /* A column only once the readings have caught up: the spectrum
             * is for looking at, the readings drive the MIDI. */
            if (atomic_load(&E.spectrum_on) && read - d.sp->n >= base_index && read >= next_column &&
                written - read < d.hop) {
                int64_t t0 = mai_now_ns();
                for (int i = 0; i < d.sp->n; i++) d.column_in[i] = MIC.ring[(read - d.sp->n + i) & (HUM_MIC_RING - 1)];
                uint8_t bins[SPEC_BINS];
                spectrum_column(d.sp, d.column_in, bins);
                count_cost(&E.column_cost, mai_now_ns() - t0);
                send_spectrum(generation, sample_ms(base_index, base_ns, d.rate, read - d.sp->n / 2.0), bins);
                next_column = next_column + d.spectrum_every > read ? next_column + d.spectrum_every
                                                                    : read + d.spectrum_every;
            }
        }
        if (b.count == 1 && mai_now_ns() - b.first_at_ns >= BATCH_WAIT_NS) send_batch(generation, &b, read);
        usleep(1000);
    }

    dsp_free(&d);
    return NULL;
}

/* Stop the listen thread and the capture; the reference goes stale. Caller
 * holds `lock`. */
static void stop_listening_locked(void) {
    atomic_fetch_add(&E.generation, 1);
    if (atomic_exchange(&E.run, false)) pthread_join(E.thread, NULL);
    atomic_store(&MIC.capturing, false);
    pthread_mutex_lock(&E.send_lock);
    E.active = false;
    if (E.ref_env) {
        enif_free_env(E.ref_env);
        E.ref_env = NULL;
    }
    pthread_mutex_unlock(&E.send_lock);
}

/* Whether `ref` is the current listener's. Caller holds send_lock. */
static bool current_ref(ERL_NIF_TERM ref) { return E.active && enif_compare(E.ref, ref) == 0; }

/* ── File analysis ───────────────────────────────────────────────────────── */

typedef struct {
    pitch_detector *p;
    int rate, hop, window;
    float *chunk;
    int chunk_n;
    int64_t frames; /* mono samples analysed */
    reading *readings;
    size_t n_readings, cap_readings;
    uint8_t *waveform;
    size_t n_wave, cap_wave;
    int wave_every;
    int wave_n;
    float wave_peak;
} file_analysis;

static void fa_free(file_analysis *a) {
    pitch_free(a->p);
    free(a->chunk);
    free(a->readings);
    free(a->waveform);
    memset(a, 0, sizeof(*a));
}

static bool fa_init(file_analysis *a, int rate) {
    a->rate = rate;
    a->p = pitch_new(rate, MIN_HZ, MAX_HZ);
    if (!a->p) return false;
    a->hop = hop_for(a->p, rate, FILE_HOP_S);
    a->window = pitch_window_input_samples(a->p);
    a->chunk = malloc(sizeof(float) * (size_t)a->hop);
    a->wave_every = rate * WAVEFORM_MS / 1000;
    a->cap_readings = 4096;
    a->readings = malloc(sizeof(reading) * a->cap_readings);
    a->cap_wave = 1024;
    a->waveform = malloc(a->cap_wave);
    return a->chunk && a->readings && a->waveform && a->wave_every > 0;
}

static bool fa_wave_flush(file_analysis *a) {
    if (a->n_wave == a->cap_wave) {
        uint8_t *w = realloc(a->waveform, a->cap_wave * 2);
        if (!w) return false;
        a->waveform = w;
        a->cap_wave *= 2;
    }
    float v = a->wave_peak > 1.0f ? 1.0f : a->wave_peak;
    a->waveform[a->n_wave++] = (uint8_t)(v * 255.0f + 0.5f);
    a->wave_n = 0;
    a->wave_peak = 0.0f;
    return true;
}

/* One mono sample. False when out of memory. */
static bool fa_push(file_analysis *a, float x) {
    float m = fabsf(x);
    if (m > a->wave_peak) a->wave_peak = m;
    if (++a->wave_n == a->wave_every && !fa_wave_flush(a)) return false;

    a->chunk[a->chunk_n++] = x;
    if (a->chunk_n < a->hop) return true;
    pitch_push(a->p, a->chunk, a->hop);
    a->chunk_n = 0;
    a->frames += a->hop;
    if (a->frames < a->window) return true;
    if (a->n_readings == a->cap_readings) {
        reading *r = realloc(a->readings, sizeof(reading) * a->cap_readings * 2);
        if (!r) return false;
        a->readings = r;
        a->cap_readings *= 2;
    }
    pitch_reading pr = pitch_detect(a->p);
    double centre_ms = 1000.0 * ((double)a->frames - a->window / 2.0) / a->rate;
    a->readings[a->n_readings++] = (reading){(int64_t)(centre_ms + 0.5), pr.hz, pr.clarity, pr.rms_db};
    return true;
}

static int64_t fa_total_frames(const file_analysis *a) { return a->frames + a->chunk_n; }

/* An analysis in progress: one caller at a time pushes to it (the lock
 * only keeps a careless second caller from corrupting it). */
typedef struct {
    pthread_mutex_t lock;
    file_analysis a;
    bool failed; /* out of memory: the rest is ignored */
} analysis_res;

static ErlNifResourceType *analysis_type;

static void analysis_dtor(ErlNifEnv *env, void *obj) {
    (void)env;
    analysis_res *r = obj;
    fa_free(&r->a);
    pthread_mutex_destroy(&r->lock);
}

/* analysis_new(Rate) -> {ok, Analysis} | {error, alloc}. */
static ERL_NIF_TERM nif_analysis_new(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
    (void)argc;
    int rate;
    if (!enif_get_int(env, argv[0], &rate) || rate < 8000 || rate > 384000) return enif_make_badarg(env);
    analysis_res *r = enif_alloc_resource(analysis_type, sizeof(analysis_res));
    if (!r) return error_tuple(env, "alloc");
    memset(r, 0, sizeof(*r));
    pthread_mutex_init(&r->lock, NULL);
    bool ok = fa_init(&r->a, rate);
    ERL_NIF_TERM term = enif_make_resource(env, r);
    enif_release_resource(r); /* the term keeps it (and the destructor frees what fa_init got) */
    return ok ? enif_make_tuple2(env, atom(env, "ok"), term) : error_tuple(env, "alloc");
}

/* analysis_push(Analysis, Pcm) -> ok | {error, alloc}. Pcm: mono 32-bit
 * floats in the machine's byte order, as MobAudioIo.decode_stream/3's chunks
 * come. A dirty CPU job (a 4096-frame chunk at 48 kHz is ~8 readings, but
 * nothing caps a chunk's size). */
static ERL_NIF_TERM nif_analysis_push(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
    (void)argc;
    analysis_res *r;
    ErlNifBinary pcm;
    if (!enif_get_resource(env, argv[0], analysis_type, (void **)&r) || !enif_inspect_binary(env, argv[1], &pcm) ||
        pcm.size % sizeof(float) != 0)
        return enif_make_badarg(env);
    pthread_mutex_lock(&r->lock);
    size_t n = pcm.size / sizeof(float);
    for (size_t i = 0; i < n && !r->failed; i++) {
        float x;
        memcpy(&x, pcm.data + i * sizeof(float), sizeof(float)); /* a sub-binary needn't be aligned */
        if (!fa_push(&r->a, x)) r->failed = true;
    }
    bool failed = r->failed;
    pthread_mutex_unlock(&r->lock);
    return failed ? error_tuple(env, "alloc") : atom(env, "ok");
}

/* analysis_finish(Analysis) -> #{duration_ms, waveform, readings} |
 * {error, alloc}. A dirty CPU job (builds every reading's map). */
static ERL_NIF_TERM nif_analysis_finish(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
    (void)argc;
    analysis_res *r;
    if (!enif_get_resource(env, argv[0], analysis_type, (void **)&r)) return enif_make_badarg(env);
    pthread_mutex_lock(&r->lock);
    file_analysis *a = &r->a;
    if (!r->failed && a->wave_n > 0 && !fa_wave_flush(a)) r->failed = true;
    ERL_NIF_TERM result;
    if (r->failed) {
        result = error_tuple(env, "alloc");
    } else {
        ERL_NIF_TERM keys[4], list = enif_make_list(env, 0);
        reading_keys(env, keys);
        for (size_t i = a->n_readings; i-- > 0;) list = enif_make_list_cell(env, reading_term(env, &a->readings[i], keys), list);
        ERL_NIF_TERM wave;
        memcpy(enif_make_new_binary(env, a->n_wave, &wave), a->waveform, a->n_wave);
        int64_t duration_ms = (int64_t)(1000.0 * (double)fa_total_frames(a) / a->rate + 0.5);
        ERL_NIF_TERM mkeys[3] = {atom(env, "duration_ms"), atom(env, "waveform"), atom(env, "readings")};
        ERL_NIF_TERM mvals[3] = {enif_make_int64(env, duration_ms), wave, list};
        enif_make_map_from_arrays(env, mkeys, mvals, 3, &result);
    }
    pthread_mutex_unlock(&r->lock);
    return result;
}

/* ── NIFs: listening ─────────────────────────────────────────────────────── */

/* listen(Owner, Ref, Spectrum) -> ok | {error, microphone_unavailable |
 * thread}: arm the "hum_mic" processor and start the listen thread, which
 * waits for the stream's first block. Stops whatever was listening. Dirty
 * IO (joins the old thread). */
static ERL_NIF_TERM nif_listen(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
    (void)argc;
    int64_t called_ns = mai_now_ns(); /* readings' t counts from here: opening the stream takes a while */
    ErlNifPid owner;
    if (!enif_get_local_pid(env, argv[0], &owner) || !enif_is_ref(env, argv[1])) return enif_make_badarg(env);
    bool spectrum_on = enif_is_identical(argv[2], atom(env, "true"));

    pthread_mutex_lock(&E.lock);
    stop_listening_locked();
    if (atomic_load(&MIC.open) > 0) {
        /* A stream still captures into the ring (the caller closes the last
         * one before listening again). */
        pthread_mutex_unlock(&E.lock);
        return error_tuple(env, "microphone_unavailable");
    }
    uint64_t generation = atomic_fetch_add(&E.generation, 1) + 1;
    hum_mic_reset(&MIC);
    atomic_store(&E.spectrum_on, spectrum_on);
    atomic_store(&E.readings_sent, 0);
    atomic_store(&E.batches_sent, 0);
    atomic_store(&E.spectra_sent, 0);
    atomic_store(&E.lag_sum_ns, 0);
    atomic_store(&E.lag_max_ns, 0);
    for (int i = 0; i < LAG_BUCKETS; i++) atomic_store(&E.lag_hist[i], 0);
    atomic_store(&E.detect_cost.sum_ns, 0);
    atomic_store(&E.detect_cost.max_ns, 0);
    atomic_store(&E.detect_cost.count, 0);
    atomic_store(&E.column_cost.sum_ns, 0);
    atomic_store(&E.column_cost.max_ns, 0);
    atomic_store(&E.column_cost.count, 0);
    atomic_store(&E.skipped, 0);
    atomic_store(&E.skips, 0);
    E.listen_ns = called_ns;

    pthread_mutex_lock(&E.send_lock);
    E.owner = owner;
    E.ref_env = enif_alloc_env();
    E.ref = enif_make_copy(E.ref_env, argv[1]);
    E.active = true;
    pthread_mutex_unlock(&E.send_lock);

    atomic_store(&E.run, true);
    bool started = pthread_create(&E.thread, NULL, listen_main, (void *)(uintptr_t)generation) == 0;
    if (started) {
        atomic_store_explicit(&MIC.capturing, true, memory_order_release);
    } else {
        atomic_store(&E.run, false);
        stop_listening_locked();
    }
    pthread_mutex_unlock(&E.lock);
    return started ? atom(env, "ok") : error_tuple(env, "thread");
}

/* stop(Ref) -> ok. Stops listening if Ref is the current listener's: no
 * message for it starts once this returns. Dirty IO. */
static ERL_NIF_TERM nif_stop(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
    (void)argc;
    if (!enif_is_ref(env, argv[0])) return enif_make_badarg(env);
    pthread_mutex_lock(&E.lock);
    pthread_mutex_lock(&E.send_lock);
    bool mine = current_ref(argv[0]);
    pthread_mutex_unlock(&E.send_lock);
    if (mine) stop_listening_locked();
    pthread_mutex_unlock(&E.lock);
    return atom(env, "ok");
}

/* set_spectrum(Ref, Bool) -> ok. Ignored for a stale Ref. */
static ERL_NIF_TERM nif_set_spectrum(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
    (void)argc;
    if (!enif_is_ref(env, argv[0])) return enif_make_badarg(env);
    bool on = enif_is_identical(argv[1], atom(env, "true"));
    pthread_mutex_lock(&E.send_lock);
    if (current_ref(argv[0])) atomic_store(&E.spectrum_on, on);
    pthread_mutex_unlock(&E.send_lock);
    return atom(env, "ok");
}

/* The lag below which `share` of the batches since listen were sent (the
 * histogram bucket's upper edge), ms; −1 before any. */
static double lag_percentile(double share) {
    int64_t total = 0, seen = 0;
    for (int i = 0; i < LAG_BUCKETS; i++) total += atomic_load_explicit(&E.lag_hist[i], memory_order_relaxed);
    if (total == 0) return -1.0;
    for (int i = 0; i < LAG_BUCKETS; i++) {
        seen += atomic_load_explicit(&E.lag_hist[i], memory_order_relaxed);
        if (seen >= share * total) return (i + 1) * LAG_BUCKET_US / 1000.0;
    }
    return LAG_BUCKETS * LAG_BUCKET_US / 1000.0;
}

/* info() -> map: how the readings have been made and delivered since
 * listen. The stream's own figures are MobAudioIo.status/1's. */
static ERL_NIF_TERM nif_info(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
    (void)argc;
    (void)argv;
    enum { N = 19 };
    int rate = atomic_load(&MIC.rate);
    int64_t batches = atomic_load(&E.batches_sent);
    int64_t detect_n = atomic_load(&E.detect_cost.count), column_n = atomic_load(&E.column_cost.count);
    int64_t lag_n = 0;
    for (int i = 0; i < LAG_BUCKETS; i++) lag_n += atomic_load_explicit(&E.lag_hist[i], memory_order_relaxed);
    ERL_NIF_TERM keys[N] = {atom(env, "listening"),      atom(env, "rate"),           atom(env, "callbacks"),
                            atom(env, "last_callback_frames"), atom(env, "readings"), atom(env, "batches"),
                            atom(env, "spectra"),        atom(env, "lag_mean_ms"),    atom(env, "lag_max_ms"),
                            atom(env, "lag_p50_ms"),     atom(env, "lag_p95_ms"),     atom(env, "detect_us_mean"),
                            atom(env, "detect_us_max"),  atom(env, "column_us_mean"), atom(env, "column_us_max"),
                            atom(env, "skipped_ms"),     atom(env, "skips"),          atom(env, "priority_raised"),
                            atom(env, "mic_streams")};
    ERL_NIF_TERM vals[N] = {
        atom(env, atomic_load(&E.run) ? "true" : "false"),
        enif_make_int(env, rate),
        enif_make_int64(env, atomic_load(&MIC.callbacks)),
        enif_make_int64(env, atomic_load(&MIC.last_frames)),
        enif_make_int64(env, atomic_load(&E.readings_sent)),
        enif_make_int64(env, batches),
        enif_make_int64(env, atomic_load(&E.spectra_sent)),
        enif_make_double(env, lag_n ? atomic_load(&E.lag_sum_ns) / 1e6 / lag_n : 0.0),
        enif_make_double(env, atomic_load(&E.lag_max_ns) / 1e6),
        enif_make_double(env, lag_percentile(0.50)),
        enif_make_double(env, lag_percentile(0.95)),
        enif_make_double(env, detect_n ? atomic_load(&E.detect_cost.sum_ns) / 1e3 / detect_n : 0.0),
        enif_make_double(env, atomic_load(&E.detect_cost.max_ns) / 1e3),
        enif_make_double(env, column_n ? atomic_load(&E.column_cost.sum_ns) / 1e3 / column_n : 0.0),
        enif_make_double(env, atomic_load(&E.column_cost.max_ns) / 1e3),
        enif_make_double(env, rate > 0 ? 1000.0 * atomic_load(&E.skipped) / rate : 0.0),
        enif_make_int64(env, atomic_load(&E.skips)),
        atom(env, atomic_load(&E.priority_raised) ? "true" : "false"),
        enif_make_int(env, atomic_load(&MIC.open)),
    };
    ERL_NIF_TERM map;
    enif_make_map_from_arrays(env, keys, vals, N, &map);
    return map;
}

/* ── NIFs: the piano ─────────────────────────────────────────────────────── */

static bool get_erlang_number(ErlNifEnv *env, ERL_NIF_TERM term, double *out) {
    double d = 0.0;
    ErlNifSInt64 i = 0;
    if (enif_get_double(env, term, &d)) {
        if (!isfinite(d)) return false;
        *out = d;
        return true;
    }
    if (enif_get_int64(env, term, &i)) {
        *out = (double)i;
        return true;
    }
    return false;
}

static bool parse_piano_notes(ErlNifEnv *env, ERL_NIF_TERM list, piano_raw_note **out, int32_t *count_out,
                              double *max_end_ms, const char **err_reason, bool *badarg) {
    unsigned len = 0;
    if (!enif_get_list_length(env, list, &len)) {
        *badarg = true;
        return false;
    }
    if (len == 0) {
        *err_reason = "empty";
        return false;
    }
    if (len > PIANO_MAX_NOTES) {
        *err_reason = "too_many_notes";
        return false;
    }

    piano_raw_note *raw = calloc(len, sizeof(piano_raw_note));
    if (!raw) {
        *err_reason = "alloc";
        return false;
    }

    ERL_NIF_TERM k_start = atom(env, "start_ms");
    ERL_NIF_TERM k_dur = atom(env, "dur_ms");
    ERL_NIF_TERM k_midi = atom(env, "midi");
    ERL_NIF_TERM k_vel = atom(env, "velocity");
    ERL_NIF_TERM a_nil = atom(env, "nil");

    ERL_NIF_TERM head, tail = list;
    double end_max = 0.0;

    for (unsigned i = 0; i < len; i++) {
        if (!enif_get_list_cell(env, tail, &head, &tail) || !enif_is_map(env, head)) {
            free(raw);
            *err_reason = "invalid_notes";
            return false;
        }
        ERL_NIF_TERM v_start, v_dur, v_midi, v_vel;
        double start_ms = 0.0, dur_ms = 0.0;
        int midi = 0, vel = PIANO_DEFAULT_VELOCITY;

        if (!enif_get_map_value(env, head, k_start, &v_start) || !enif_get_map_value(env, head, k_dur, &v_dur) ||
            !enif_get_map_value(env, head, k_midi, &v_midi) || !get_erlang_number(env, v_start, &start_ms) ||
            !get_erlang_number(env, v_dur, &dur_ms) || !enif_get_int(env, v_midi, &midi) || start_ms < 0.0 ||
            dur_ms <= 0.0 || midi < 0 || midi > 127) {
            free(raw);
            *err_reason = "invalid_notes";
            return false;
        }
        if (enif_get_map_value(env, head, k_vel, &v_vel) && !enif_is_identical(v_vel, a_nil)) {
            if (!enif_get_int(env, v_vel, &vel) || vel < 1 || vel > 127) {
                free(raw);
                *err_reason = "invalid_notes";
                return false;
            }
        }
        double end_ms = start_ms + dur_ms;
        if (!isfinite(end_ms) || end_ms > (double)PIANO_MAX_DURATION_MS) {
            free(raw);
            *err_reason = "too_long";
            return false;
        }
        if (end_ms > end_max) end_max = end_ms;

        raw[i] = (piano_raw_note){
            .start_ms = start_ms,
            .dur_ms = dur_ms,
            .midi = (int32_t)midi,
            .gain = (float)vel / 127.0f,
        };
    }

    *out = raw;
    *count_out = (int32_t)len;
    *max_end_ms = end_max;
    return true;
}

/* piano_prepare(Notes, SamplesDir) -> ok | {error, Reason}: the phrase the
 * next "hum_piano" stream plays. Reasons: empty, too_many_notes,
 * invalid_notes, too_long, samples_unavailable, busy (a stream still plays
 * the last phrase), alloc. Dirty IO (reads the bank the first time). */
static ERL_NIF_TERM nif_piano_prepare(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
    (void)argc;
    ErlNifBinary dir_bin;
    if (!enif_is_list(env, argv[0]) || !enif_inspect_binary(env, argv[1], &dir_bin) || dir_bin.size == 0 ||
        dir_bin.size >= 900 || memchr(dir_bin.data, 0, dir_bin.size))
        return enif_make_badarg(env);

    piano_raw_note *raw = NULL;
    int32_t note_count = 0;
    double max_end_ms = 0.0;
    const char *err_reason = NULL;
    bool badarg = false;
    if (!parse_piano_notes(env, argv[0], &raw, &note_count, &max_end_ms, &err_reason, &badarg)) {
        if (badarg) return enif_make_badarg(env);
        return error_tuple(env, err_reason ? err_reason : "invalid_notes");
    }

    char dir[901];
    memcpy(dir, dir_bin.data, dir_bin.size);
    dir[dir_bin.size] = '\0';
    const char *failure = hum_piano_prepare(&PIANO, dir, raw, note_count, max_end_ms);
    return failure ? error_tuple(env, failure) : atom(env, "ok");
}

/* piano_position() -> idle | {playing, Ms, FinishInMs | nil} | {finished, Ms}
 * | {failed, Reason}: the prepared phrase's playhead (what has been heard),
 * and once all of it is in the stream, how long until its end is heard. */
static ERL_NIF_TERM nif_piano_position(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
    (void)argc;
    (void)argv;
    int64_t ms, finish_in_ns;
    const char *why;
    switch (hum_piano_progress(&PIANO, mai_now_ns(), &ms, &finish_in_ns, &why)) {
    case HUM_PIANO_PLAYING:
        return enif_make_tuple3(env, atom(env, "playing"), enif_make_int64(env, ms),
                                finish_in_ns >= 0 ? enif_make_double(env, finish_in_ns / 1e6) : atom(env, "nil"));
    case HUM_PIANO_FINISHED:
        return enif_make_tuple2(env, atom(env, "finished"), enif_make_int64(env, ms));
    case HUM_PIANO_FAILED:
        return enif_make_tuple2(env, atom(env, "failed"), atom(env, why));
    default:
        return atom(env, "idle");
    }
}

/* ── Load ────────────────────────────────────────────────────────────────── */

static int on_load(ErlNifEnv *env, void **priv, ERL_NIF_TERM info) {
    (void)priv;
    (void)info;
    if (mai_abi_version() != MAI_ABI_VERSION) return 1;
    pthread_mutex_init(&E.lock, NULL);
    pthread_mutex_init(&E.send_lock, NULL);
    pthread_mutex_init(&PIANO.lock, NULL);
    ErlNifResourceTypeInit init = {.dtor = analysis_dtor, .stop = NULL, .down = NULL, .members = 3};
    analysis_type = enif_init_resource_type(env, "hum_audio_analysis", &init, ERL_NIF_RT_CREATE, NULL);
    if (!analysis_type) return 2;
    static const mai_processor mic = {.render = NULL, .capture = hum_mic_capture, .stream_event = hum_mic_event};
    static const mai_processor piano = {.render = hum_piano_render, .capture = NULL, .stream_event = hum_piano_event};
    if (mai_register("hum_mic", &mic, &MIC) != MAI_OK) return 3;
    if (mai_register("hum_piano", &piano, &PIANO) != MAI_OK) return 4;
    return 0;
}

static ErlNifFunc nif_funcs[] = {
    {"listen", 3, nif_listen, ERL_NIF_DIRTY_JOB_IO_BOUND},
    {"stop", 1, nif_stop, ERL_NIF_DIRTY_JOB_IO_BOUND},
    {"set_spectrum", 2, nif_set_spectrum, 0},
    {"info", 0, nif_info, 0},
    {"analysis_new", 1, nif_analysis_new, 0},
    {"analysis_push", 2, nif_analysis_push, ERL_NIF_DIRTY_JOB_CPU_BOUND},
    {"analysis_finish", 1, nif_analysis_finish, ERL_NIF_DIRTY_JOB_CPU_BOUND},
    {"piano_prepare", 2, nif_piano_prepare, ERL_NIF_DIRTY_JOB_IO_BOUND},
    {"piano_position", 0, nif_piano_position, 0},
};

ERL_NIF_INIT(Elixir.Humdinger.Audio.Nif, nif_funcs, on_load, NULL, NULL, NULL)
