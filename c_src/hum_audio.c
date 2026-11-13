/*
 * c_src/hum_audio.c — the microphone's pitch, level and spectrum, offline
 * analysis of audio files, and the background-listening service (Android).
 *
 *   input callback   AAudio microphone, low-latency mode, mono float
 *                    (VOICE_RECOGNITION preset: no AGC or noise suppression
 *                    bending the pitch) into a lock-free ring.
 *   listen thread    YIN (pitch_yin.c) every hop (~5.3 ms) over a 42 ms
 *                    window, and a spectrum column (spectrum.c) every 1/30 s
 *                    while asked for. Readings go to the owner in batches as
 *                    soon as two are ready (or one has waited 6 ms), so each
 *                    message leaves within ~12 ms of the newest sample's
 *                    arrival.
 *   file threads     analyze_file/3: AMediaExtractor + AMediaCodec decode a
 *                    file, mixed down to mono and analysed as it decodes
 *                    (nothing but the readings is kept), one thread per file.
 *                    A job ends early, silently, on cancel_analysis/1, on a
 *                    newer analysis by the same owner, or when the owner
 *                    dies; at most MAX_ANALYSES owners analyse at once.
 *
 * Messages are built here in their final shape (see Humdinger.Audio), so the
 * BEAM does no per-reading work beyond receiving them:
 *
 *   {hum_audio, Ref, {readings, [#{t, hz, clarity, db}]}}
 *   {hum_audio, Ref, {spectrum, #{t, bins}}}
 *   {hum_audio, Ref, {error, device_lost | input_error}}
 *   {hum_audio, Ref, {analysis, #{duration_ms, waveform, readings}}}
 *   {hum_audio, Ref, {analysis_error, Reason}}
 *   {background, Action}           notification buttons (see below)
 *
 * One listener at a time: listen/4 stops the previous one first, and its
 * reference goes stale. The owner is monitored; when it dies the microphone
 * stops.
 *
 * Background: background_start/4 starts the host package's
 * HumListenService (android/app/src/main/java/.../HumListenService.kt), a
 * foreground service of type microphone with an ongoing notification, so the
 * microphone keeps running while another app (FMutate) is in front. Its
 * buttons call HumListenBridge.nativeAction, registered here with RegisterNatives, which
 * sends {background, Action} to the process that started it. That process
 * is monitored: when it dies, the service stops.
 *
 * AAudio and libmediandk are opened with dlopen: the app links against
 * android-24 headers, where AAudio (API 26) doesn't exist, while the app's
 * minSdk is 28, so both libraries are always present at run time. Java
 * (AudioManager, permissions, the service) is reached through the JVM and
 * activity Mob's JNI glue exports.
 *
 * Locks, always taken in this order: lock → send_lock → bg_lock. `lock`
 * serialises the control path (open, start, stop and close the stream, join
 * the listen thread) and is never taken by callbacks; `send_lock` guards
 * the listener's owner and reference, so no message of a stopped listener
 * starts once stop has returned; `bg_lock` guards the background owner and
 * the service's Java handles. The stream is closed only once it is quiet
 * (stopped, no callback running).
 */

#include <dlfcn.h>
#include <erl_nif.h>
#include <fcntl.h>
#include <jni.h>
#include <math.h>
#include <pthread.h>
#include <stdatomic.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <sys/resource.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <time.h>
#include <unistd.h>

#include <android/log.h>

#include "pitch_yin.c"
#include "spectrum.c"

#define LOG_TAG "hum_audio"
#define LOGI(...) __android_log_print(ANDROID_LOG_INFO, LOG_TAG, __VA_ARGS__)
#define LOGE(...) __android_log_print(ANDROID_LOG_ERROR, LOG_TAG, __VA_ARGS__)

/* Defined by the app's JNI glue (see deps/mob/android/jni/mob_beam.h). */
extern JavaVM *g_jvm;
extern jobject g_activity;

/* The detector's range: a low bass hum to a high whistle. */
#define MIN_HZ 60.0f
#define MAX_HZ 1600.0f
#define LIVE_HOP_S 0.0053  /* live readings: ~5.3 ms apart */
#define FILE_HOP_S 0.010   /* file readings: 10 ms apart */
#define BATCH_WAIT_NS 6000000LL /* a lone reading waits at most this for a partner */
#define SPECTRUM_PER_S 30
#define WAVEFORM_MS 50
#define MAX_FILE_MS (10 * 60 * 1000)
#define RING_SIZE (1 << 16) /* mono samples, power of two */
#define BATCH_MAX 64

#define SERVICE_CLASS "com.genericjam.humdinger.HumListenBridge"

/* ── AAudio, declared by hand (see header comment) ───────────────────────── */

typedef struct AAudioStreamBuilderStruct AAudioStreamBuilder;
typedef struct AAudioStreamStruct AAudioStream;
typedef int32_t aaudio_result_t;
typedef int32_t (*aa_data_cb)(AAudioStream *, void *, void *, int32_t);
typedef void (*aa_error_cb)(AAudioStream *, void *, aaudio_result_t);

enum {
    AA_OK = 0,
    AA_UNSPECIFIED = 0,
    AA_DIRECTION_INPUT = 1,
    AA_FORMAT_PCM_FLOAT = 2,
    AA_SHARING_SHARED = 1,
    AA_PERF_LOW_LATENCY = 12,
    AA_PRESET_VOICE_RECOGNITION = 6,
    AA_CALLBACK_CONTINUE = 0,
    AA_STATE_OPEN = 2,
    AA_STATE_STARTING = 3,
    AA_STATE_STARTED = 4,
    AA_STATE_PAUSED = 6,
    AA_STATE_FLUSHED = 8,
    AA_STATE_STOPPED = 10,
    AA_STATE_DISCONNECTED = 13,
    AA_ERROR_DISCONNECTED = -899,
};

static struct {
    aaudio_result_t (*createStreamBuilder)(AAudioStreamBuilder **);
    void (*setDirection)(AAudioStreamBuilder *, int32_t);
    void (*setDeviceId)(AAudioStreamBuilder *, int32_t);
    void (*setSampleRate)(AAudioStreamBuilder *, int32_t);
    void (*setChannelCount)(AAudioStreamBuilder *, int32_t);
    void (*setFormat)(AAudioStreamBuilder *, int32_t);
    void (*setSharingMode)(AAudioStreamBuilder *, int32_t);
    void (*setPerformanceMode)(AAudioStreamBuilder *, int32_t);
    void (*setInputPreset)(AAudioStreamBuilder *, int32_t);
    void (*setDataCallback)(AAudioStreamBuilder *, aa_data_cb, void *);
    void (*setErrorCallback)(AAudioStreamBuilder *, aa_error_cb, void *);
    aaudio_result_t (*openStream)(AAudioStreamBuilder *, AAudioStream **);
    aaudio_result_t (*builderDelete)(AAudioStreamBuilder *);
    aaudio_result_t (*close)(AAudioStream *);
    aaudio_result_t (*requestStart)(AAudioStream *);
    aaudio_result_t (*requestStop)(AAudioStream *);
    int32_t (*getDeviceId)(AAudioStream *);
    int32_t (*getSampleRate)(AAudioStream *);
    int32_t (*getFramesPerBurst)(AAudioStream *);
    int32_t (*getBufferSizeInFrames)(AAudioStream *);
    int32_t (*getXRunCount)(AAudioStream *);
    int32_t (*getPerformanceMode)(AAudioStream *);
    int32_t (*getSharingMode)(AAudioStream *);
    int64_t (*getFramesRead)(AAudioStream *);
    aaudio_result_t (*getTimestamp)(AAudioStream *, clockid_t, int64_t *, int64_t *);
    int32_t (*getState)(AAudioStream *);
    aaudio_result_t (*waitForStateChange)(AAudioStream *, int32_t, int32_t *, int64_t);
} aa;

/* ── libmediandk, declared by hand ───────────────────────────────────────── */

typedef struct AMediaExtractor AMediaExtractor;
typedef struct AMediaFormat AMediaFormat;
typedef struct AMediaCodec AMediaCodec;
typedef struct {
    int32_t offset;
    int32_t size;
    int64_t presentationTimeUs;
    uint32_t flags;
} codec_buffer_info;

#define CODEC_EOS 4
#define CODEC_TRY_AGAIN -1
#define CODEC_FORMAT_CHANGED -2
#define CODEC_BUFFERS_CHANGED -3
#define PCM_ENCODING_FLOAT 4

static struct {
    AMediaExtractor *(*exNew)(void);
    int (*exDelete)(AMediaExtractor *);
    int (*exSetDataSourceFd)(AMediaExtractor *, int, off64_t, off64_t);
    size_t (*exGetTrackCount)(AMediaExtractor *);
    AMediaFormat *(*exGetTrackFormat)(AMediaExtractor *, size_t);
    int (*exSelectTrack)(AMediaExtractor *, size_t);
    ssize_t (*exReadSampleData)(AMediaExtractor *, uint8_t *, size_t);
    int64_t (*exGetSampleTime)(AMediaExtractor *);
    bool (*exAdvance)(AMediaExtractor *);
    bool (*fmtGetString)(AMediaFormat *, const char *, const char **);
    bool (*fmtGetInt32)(AMediaFormat *, const char *, int32_t *);
    bool (*fmtGetInt64)(AMediaFormat *, const char *, int64_t *);
    int (*fmtDelete)(AMediaFormat *);
    AMediaCodec *(*codecCreateDecoderByType)(const char *);
    int (*codecConfigure)(AMediaCodec *, const AMediaFormat *, void *, void *, uint32_t);
    int (*codecStart)(AMediaCodec *);
    int (*codecStop)(AMediaCodec *);
    int (*codecDelete)(AMediaCodec *);
    ssize_t (*codecDequeueInputBuffer)(AMediaCodec *, int64_t);
    uint8_t *(*codecGetInputBuffer)(AMediaCodec *, size_t, size_t *);
    int (*codecQueueInputBuffer)(AMediaCodec *, size_t, off_t, size_t, uint64_t, uint32_t);
    ssize_t (*codecDequeueOutputBuffer)(AMediaCodec *, codec_buffer_info *, int64_t);
    uint8_t *(*codecGetOutputBuffer)(AMediaCodec *, size_t, size_t *);
    int (*codecReleaseOutputBuffer)(AMediaCodec *, size_t, bool);
    AMediaFormat *(*codecGetOutputFormat)(AMediaCodec *);
} md;

static const char *libs_error = NULL;
static bool libs_ok = false;

#define BIND(table, handle, field, name)              \
    do {                                              \
        *(void **)&table.field = dlsym(handle, name); \
        if (!table.field) {                           \
            libs_error = name;                        \
            return false;                             \
        }                                             \
    } while (0)

static bool bind_libraries(void) {
    void *a = dlopen("libaaudio.so", RTLD_NOW);
    void *m = dlopen("libmediandk.so", RTLD_NOW);
    if (!a) {
        libs_error = "libaaudio.so";
        return false;
    }
    if (!m) {
        libs_error = "libmediandk.so";
        return false;
    }

    BIND(aa, a, createStreamBuilder, "AAudio_createStreamBuilder");
    BIND(aa, a, setDirection, "AAudioStreamBuilder_setDirection");
    BIND(aa, a, setDeviceId, "AAudioStreamBuilder_setDeviceId");
    BIND(aa, a, setSampleRate, "AAudioStreamBuilder_setSampleRate");
    BIND(aa, a, setChannelCount, "AAudioStreamBuilder_setChannelCount");
    BIND(aa, a, setFormat, "AAudioStreamBuilder_setFormat");
    BIND(aa, a, setSharingMode, "AAudioStreamBuilder_setSharingMode");
    BIND(aa, a, setPerformanceMode, "AAudioStreamBuilder_setPerformanceMode");
    BIND(aa, a, setInputPreset, "AAudioStreamBuilder_setInputPreset");
    BIND(aa, a, setDataCallback, "AAudioStreamBuilder_setDataCallback");
    BIND(aa, a, setErrorCallback, "AAudioStreamBuilder_setErrorCallback");
    BIND(aa, a, openStream, "AAudioStreamBuilder_openStream");
    BIND(aa, a, builderDelete, "AAudioStreamBuilder_delete");
    BIND(aa, a, close, "AAudioStream_close");
    BIND(aa, a, requestStart, "AAudioStream_requestStart");
    BIND(aa, a, requestStop, "AAudioStream_requestStop");
    BIND(aa, a, getDeviceId, "AAudioStream_getDeviceId");
    BIND(aa, a, getSampleRate, "AAudioStream_getSampleRate");
    BIND(aa, a, getFramesPerBurst, "AAudioStream_getFramesPerBurst");
    BIND(aa, a, getBufferSizeInFrames, "AAudioStream_getBufferSizeInFrames");
    BIND(aa, a, getXRunCount, "AAudioStream_getXRunCount");
    BIND(aa, a, getPerformanceMode, "AAudioStream_getPerformanceMode");
    BIND(aa, a, getSharingMode, "AAudioStream_getSharingMode");
    BIND(aa, a, getFramesRead, "AAudioStream_getFramesRead");
    BIND(aa, a, getTimestamp, "AAudioStream_getTimestamp");
    BIND(aa, a, getState, "AAudioStream_getState");
    BIND(aa, a, waitForStateChange, "AAudioStream_waitForStateChange");

    BIND(md, m, exNew, "AMediaExtractor_new");
    BIND(md, m, exDelete, "AMediaExtractor_delete");
    BIND(md, m, exSetDataSourceFd, "AMediaExtractor_setDataSourceFd");
    BIND(md, m, exGetTrackCount, "AMediaExtractor_getTrackCount");
    BIND(md, m, exGetTrackFormat, "AMediaExtractor_getTrackFormat");
    BIND(md, m, exSelectTrack, "AMediaExtractor_selectTrack");
    BIND(md, m, exReadSampleData, "AMediaExtractor_readSampleData");
    BIND(md, m, exGetSampleTime, "AMediaExtractor_getSampleTime");
    BIND(md, m, exAdvance, "AMediaExtractor_advance");
    BIND(md, m, fmtGetString, "AMediaFormat_getString");
    BIND(md, m, fmtGetInt32, "AMediaFormat_getInt32");
    BIND(md, m, fmtGetInt64, "AMediaFormat_getInt64");
    BIND(md, m, fmtDelete, "AMediaFormat_delete");
    BIND(md, m, codecCreateDecoderByType, "AMediaCodec_createDecoderByType");
    BIND(md, m, codecConfigure, "AMediaCodec_configure");
    BIND(md, m, codecStart, "AMediaCodec_start");
    BIND(md, m, codecStop, "AMediaCodec_stop");
    BIND(md, m, codecDelete, "AMediaCodec_delete");
    BIND(md, m, codecDequeueInputBuffer, "AMediaCodec_dequeueInputBuffer");
    BIND(md, m, codecGetInputBuffer, "AMediaCodec_getInputBuffer");
    BIND(md, m, codecQueueInputBuffer, "AMediaCodec_queueInputBuffer");
    BIND(md, m, codecDequeueOutputBuffer, "AMediaCodec_dequeueOutputBuffer");
    BIND(md, m, codecGetOutputBuffer, "AMediaCodec_getOutputBuffer");
    BIND(md, m, codecReleaseOutputBuffer, "AMediaCodec_releaseOutputBuffer");
    BIND(md, m, codecGetOutputFormat, "AMediaCodec_getOutputFormat");
    return true;
}

/* ── Engine state ────────────────────────────────────────────────────────── */

typedef struct {
    int64_t t;
    float hz, clarity, db;
} reading;

/* Monitors the listener's owner: when it dies, the microphone stops. */
typedef struct {
    uint64_t generation;
} listener_res;

static ErlNifResourceType *listener_type;

static struct {
    pthread_mutex_t lock;
    pthread_mutex_t send_lock;

    /* Listening. `generation` bumps whenever listening starts or stops:
     * callbacks and the listen thread carry the one they belong to. */
    _Atomic uint64_t generation;
    AAudioStream *in;
    int in_rate;
    _Atomic bool capturing;  /* the input callback writes the ring */
    _Atomic bool in_failed;  /* the stream reported an error: drop its data */
    float ring[RING_SIZE];
    _Atomic int64_t written; /* samples ever written this listening */
    int64_t listen_ns;       /* when listen/4 was called */
    _Atomic int64_t first_ns; /* when the first sample was captured; −1 until then */
    _Atomic bool spectrum_on;
    pthread_t thread;
    _Atomic bool run;

    /* Under send_lock: where this listening's messages go. */
    bool active;
    ErlNifPid owner;
    ErlNifEnv *ref_env;
    ERL_NIF_TERM ref;
    listener_res *monitor; /* kept while listening; NULL if the monitor failed */

    /* Diagnostics for info/0, reset on listen. */
    _Atomic int64_t callbacks, last_burst;
    _Atomic int64_t readings_sent, batches_sent, spectra_sent;
    _Atomic int64_t lag_sum_ns, lag_max_ns;
} E;

static ERL_NIF_TERM atom(ErlNifEnv *env, const char *name) { return enif_make_atom(env, name); }

static ERL_NIF_TERM error_tuple(ErlNifEnv *env, const char *reason) {
    return enif_make_tuple2(env, atom(env, "error"), atom(env, reason));
}

static int64_t now_ns(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (int64_t)ts.tv_sec * 1000000000LL + ts.tv_nsec;
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

/* ── The microphone ──────────────────────────────────────────────────────── */

/* States in which AAudio runs no data callback. */
static bool stream_quiet(int32_t state) {
    return state == AA_STATE_OPEN || state == AA_STATE_PAUSED || state == AA_STATE_FLUSHED ||
           state == AA_STATE_STOPPED || state == AA_STATE_DISCONNECTED;
}

/* Stop a stream and wait until no callback can run. False if it was still
 * running after a second. */
static bool stop_stream(AAudioStream *s) {
    int64_t deadline = now_ns() + 1000000000LL;
    int32_t state = aa.getState(s);
    while (!stream_quiet(state) && now_ns() < deadline) {
        if (state == AA_STATE_STARTING || state == AA_STATE_STARTED) aa.requestStop(s);
        int32_t next = state;
        aa.waitForStateChange(s, state, &next, 100000000LL); /* times out or moves on */
        state = aa.getState(s);
    }
    if (!stream_quiet(state)) {
        LOGE("input stream still running (state %d): left open", state);
        return false;
    }
    return true;
}

/* Stop and close `*s`, then clear it. A stream that won't stop is never
 * closed (closing under a running callback isn't safe) and stays in `*s`;
 * its callback has nothing to do once `capturing` is off. */
static bool stop_and_close(AAudioStream **s) {
    if (!*s) return true;
    if (!stop_stream(*s)) return false;
    aa.close(*s);
    *s = NULL;
    return true;
}

static int32_t input_cb(AAudioStream *s, void *user, void *data, int32_t frames) {
    (void)s;
    (void)user;
    if (!atomic_load(&E.capturing) || atomic_load(&E.in_failed)) return AA_CALLBACK_CONTINUE;
    if (atomic_load_explicit(&E.first_ns, memory_order_relaxed) < 0)
        atomic_store(&E.first_ns, now_ns() - (int64_t)((double)frames * 1e9 / E.in_rate));
    const float *x = data;
    int64_t w = atomic_load_explicit(&E.written, memory_order_relaxed);
    for (int32_t i = 0; i < frames; i++) E.ring[(w + i) & (RING_SIZE - 1)] = x[i];
    atomic_store_explicit(&E.written, w + frames, memory_order_release);
    atomic_fetch_add_explicit(&E.callbacks, 1, memory_order_relaxed);
    atomic_store_explicit(&E.last_burst, frames, memory_order_relaxed);
    return AA_CALLBACK_CONTINUE;
}

/* The stream failed (headset unplugged, Bluetooth gone, the system took the
 * input). AAudio forbids closing it here: drop its data and tell the owner,
 * who listens again or stops. `user` is the listening's generation. */
static void input_error_cb(AAudioStream *s, void *user, aaudio_result_t err) {
    (void)s;
    LOGE("input stream error %d", err);
    uint64_t generation = (uint64_t)(uintptr_t)user;
    if (generation != atomic_load(&E.generation)) return;
    atomic_store(&E.in_failed, true);
    ErlNifEnv *env = enif_alloc_env();
    const char *reason = err == AA_ERROR_DISCONNECTED ? "device_lost" : "input_error";
    send_to_listener(generation, env, enif_make_tuple2(env, atom(env, "error"), atom(env, reason)));
}

static aaudio_result_t open_input_on(int32_t device, uint64_t generation) {
    AAudioStreamBuilder *b;
    aaudio_result_t r = aa.createStreamBuilder(&b);
    if (r != AA_OK) return r;
    aa.setDirection(b, AA_DIRECTION_INPUT);
    if (device > 0) aa.setDeviceId(b, device);
    aa.setChannelCount(b, 1);
    aa.setFormat(b, AA_FORMAT_PCM_FLOAT);
    aa.setSharingMode(b, AA_SHARING_SHARED);
    aa.setPerformanceMode(b, AA_PERF_LOW_LATENCY);
    aa.setInputPreset(b, AA_PRESET_VOICE_RECOGNITION);
    aa.setDataCallback(b, input_cb, NULL);
    aa.setErrorCallback(b, input_error_cb, (void *)(uintptr_t)generation);
    AAudioStream *s = NULL;
    r = aa.openStream(b, &s);
    aa.builderDelete(b);
    if (r == AA_OK) {
        E.in = s;
        E.in_rate = aa.getSampleRate(s);
        LOGI("input open: device %d, %d Hz, burst %d, buffer %d, perf %d, sharing %d", aa.getDeviceId(s),
             E.in_rate, aa.getFramesPerBurst(s), aa.getBufferSizeInFrames(s), aa.getPerformanceMode(s),
             aa.getSharingMode(s));
    }
    return r;
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

    /* Lag: from the arrival of the newest sample analysed to the send. */
    int64_t first = atomic_load(&E.first_ns);
    int64_t lag = now_ns() - (first + (int64_t)((double)newest_sample * 1e9 / E.in_rate));
    atomic_fetch_add(&E.lag_sum_ns, lag);
    if (lag > atomic_load(&E.lag_max_ns)) atomic_store(&E.lag_max_ns, lag);
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

/* Ms since listen/4 at which ring sample `index` was captured. */
static int64_t sample_ms(double index) {
    int64_t first = atomic_load(&E.first_ns);
    double ms = (double)(first - E.listen_ns) / 1e6 + 1000.0 * index / E.in_rate;
    return ms > 0 ? (int64_t)(ms + 0.5) : 0;
}

static void *listen_main(void *arg) {
    uint64_t generation = (uint64_t)(uintptr_t)arg;
    /* Audio priority (Android's THREAD_PRIORITY_AUDIO), so the UI and the
     * BEAM's schedulers don't hold the readings up. Best effort. */
    if (setpriority(PRIO_PROCESS, (id_t)gettid(), -16) != 0) LOGE("listen: could not raise the thread's priority");
    int rate = E.in_rate;
    pitch_detector *p = pitch_new(rate, MIN_HZ, MAX_HZ);
    spectrum *sp = spectrum_new(rate);
    float *chunk = NULL, *column_in = NULL;
    if (p && sp) {
        chunk = malloc(sizeof(float) * (size_t)hop_for(p, rate, LIVE_HOP_S));
        column_in = malloc(sizeof(float) * (size_t)sp->n);
    }
    if (!p || !sp || !chunk || !column_in) {
        LOGE("listen: out of memory");
        ErlNifEnv *env = enif_alloc_env();
        send_to_listener(generation, env, enif_make_tuple2(env, atom(env, "error"), atom(env, "alloc")));
        goto done;
    }

    int hop = hop_for(p, rate, LIVE_HOP_S);
    int window = pitch_window_input_samples(p);
    int spectrum_every = rate / SPECTRUM_PER_S;
    int64_t read = 0, next_column = 0;
    batch b = {.count = 0};

    while (atomic_load(&E.run)) {
        int64_t written = atomic_load_explicit(&E.written, memory_order_acquire);
        if (written - read > RING_SIZE - hop) {
            /* Fell a whole ring behind (the thread was starved): skip ahead. */
            LOGE("listen: fell behind by %lld samples", (long long)(written - read));
            read = written - window;
        }
        while (written - read >= hop) {
            for (int i = 0; i < hop; i++) chunk[i] = E.ring[(read + i) & (RING_SIZE - 1)];
            read += hop;
            pitch_push(p, chunk, hop);
            if (read >= window) {
                pitch_reading pr = pitch_detect(p);
                if (b.count == 0) b.first_at_ns = now_ns();
                b.items[b.count++] = (reading){sample_ms(read - window / 2.0), pr.hz, pr.clarity, pr.rms_db};
                if (b.count == BATCH_MAX) send_batch(generation, &b, read);
            }
            if (atomic_load(&E.spectrum_on) && read >= sp->n && read >= next_column) {
                for (int i = 0; i < sp->n; i++) column_in[i] = E.ring[(read - sp->n + i) & (RING_SIZE - 1)];
                uint8_t bins[SPEC_BINS];
                spectrum_column(sp, column_in, bins);
                send_spectrum(generation, sample_ms(read - sp->n / 2.0), bins);
                next_column = next_column + spectrum_every > read ? next_column + spectrum_every
                                                                    : read + spectrum_every;
            }
        }
        if (b.count >= 2 || (b.count == 1 && now_ns() - b.first_at_ns >= BATCH_WAIT_NS)) send_batch(generation, &b, read);
        usleep(1000);
    }

done:
    free(chunk);
    free(column_in);
    spectrum_free(sp);
    pitch_free(p);
    return NULL;
}

/* Stop the listen thread and the microphone; the reference goes stale.
 * Caller holds `lock`. */
static void stop_listening_locked(void) {
    atomic_fetch_add(&E.generation, 1);
    if (atomic_exchange(&E.run, false)) pthread_join(E.thread, NULL);
    atomic_store(&E.capturing, false);
    pthread_mutex_lock(&E.send_lock);
    listener_res *monitor = E.monitor;
    E.monitor = NULL;
    E.active = false;
    if (E.ref_env) {
        enif_free_env(E.ref_env);
        E.ref_env = NULL;
    }
    pthread_mutex_unlock(&E.send_lock);
    if (monitor) enif_release_resource(monitor); /* its down callback finds a stale generation */
    stop_and_close(&E.in);
}

/* The owner died: stop listening, unless it has stopped or restarted since.
 * Runs on a thread of its own (stopping the stream may take a moment). */
static void *owner_down_main(void *arg) {
    uint64_t generation = (uint64_t)(uintptr_t)arg;
    pthread_mutex_lock(&E.lock);
    if (generation == atomic_load(&E.generation)) {
        LOGI("listener died: microphone off");
        stop_listening_locked();
    }
    pthread_mutex_unlock(&E.lock);
    return NULL;
}

static void listener_down(ErlNifEnv *env, void *obj, ErlNifPid *pid, ErlNifMonitor *mon) {
    (void)env;
    (void)pid;
    (void)mon;
    listener_res *res = obj;
    pthread_t t;
    pthread_attr_t attr;
    pthread_attr_init(&attr);
    pthread_attr_setdetachstate(&attr, PTHREAD_CREATE_DETACHED);
    if (pthread_create(&t, &attr, owner_down_main, (void *)(uintptr_t)res->generation) != 0)
        LOGE("listener died, and no thread to stop the microphone");
    pthread_attr_destroy(&attr);
}

/* ── Java (permissions, devices, the service) ────────────────────────────── */

/* The calling thread's JNIEnv, attaching it if needed (dirty schedulers are
 * native threads the JVM doesn't know); `*attached` says to detach after. */
static JNIEnv *jni_env(bool *attached) {
    *attached = false;
    if (!g_jvm) return NULL;
    JNIEnv *jenv = NULL;
    jint rc = (*g_jvm)->GetEnv(g_jvm, (void **)&jenv, JNI_VERSION_1_6);
    if (rc == JNI_OK) return jenv;
    if (rc != JNI_EDETACHED || (*g_jvm)->AttachCurrentThread(g_jvm, &jenv, NULL) != JNI_OK) return NULL;
    *attached = true;
    return jenv;
}

static void jni_done(bool attached) {
    if (attached) (*g_jvm)->DetachCurrentThread(g_jvm);
}

static bool jni_failed(JNIEnv *j) {
    if (!(*j)->ExceptionCheck(j)) return false;
    (*j)->ExceptionClear(j);
    return true;
}

/* A method id, or NULL (exception cleared) if the class lacks it. */
static jmethodID method(JNIEnv *j, jclass cls, const char *name, const char *sig) {
    jmethodID id = cls ? (*j)->GetMethodID(j, cls, name, sig) : NULL;
    return jni_failed(j) ? NULL : id;
}

/* Whether the app holds RECORD_AUDIO. True off Android's activity (nothing
 * to ask), so a missing activity fails at the stream instead. */
static bool mic_permitted(void) {
    bool attached;
    JNIEnv *j = jni_env(&attached);
    if (!j || !g_activity) {
        jni_done(attached);
        return true;
    }
    bool ok = true;
    if ((*j)->PushLocalFrame(j, 8) == JNI_OK) {
        jmethodID check = method(j, (*j)->GetObjectClass(j, g_activity), "checkSelfPermission",
                                 "(Ljava/lang/String;)I");
        jstring name = (*j)->NewStringUTF(j, "android.permission.RECORD_AUDIO");
        if (check && name) {
            jint r = (*j)->CallIntMethod(j, g_activity, check, name);
            if (!jni_failed(j)) ok = r == 0; /* PERMISSION_GRANTED */
        }
        jni_failed(j);
        (*j)->PopLocalFrame(j, NULL);
    }
    jni_done(attached);
    return ok;
}

/* A Java string (or NULL) as a UTF-8 binary. Not GetStringUTFChars: that
 * is modified UTF-8, which turns an emoji in a headset's name into bytes
 * that aren't valid UTF-8. */
static ERL_NIF_TERM string_term(ErlNifEnv *env, JNIEnv *j, jstring s) {
    ERL_NIF_TERM term;
    jsize n = s ? (*j)->GetStringLength(j, s) : 0;
    const jchar *u = n > 0 ? (*j)->GetStringChars(j, s, NULL) : NULL;
    ErlNifBinary bin;
    if (!u || !enif_alloc_binary((size_t)n * 3, &bin)) { /* ≤ 3 bytes per UTF-16 unit */
        if (u) (*j)->ReleaseStringChars(j, s, u);
        enif_make_new_binary(env, 0, &term);
        return term;
    }
    size_t w = 0;
    for (jsize i = 0; i < n; i++) {
        uint32_t c = u[i];
        if (c >= 0xD800 && c < 0xDC00 && i + 1 < n && u[i + 1] >= 0xDC00 && u[i + 1] < 0xE000)
            c = 0x10000 + ((c - 0xD800) << 10) + (u[++i] - 0xDC00u);
        else if (c >= 0xD800 && c < 0xE000)
            c = 0xFFFD; /* a lone surrogate */
        if (c < 0x80) {
            bin.data[w++] = (unsigned char)c;
        } else if (c < 0x800) {
            bin.data[w++] = (unsigned char)(0xC0 | (c >> 6));
            bin.data[w++] = (unsigned char)(0x80 | (c & 0x3F));
        } else if (c < 0x10000) {
            bin.data[w++] = (unsigned char)(0xE0 | (c >> 12));
            bin.data[w++] = (unsigned char)(0x80 | ((c >> 6) & 0x3F));
            bin.data[w++] = (unsigned char)(0x80 | (c & 0x3F));
        } else {
            bin.data[w++] = (unsigned char)(0xF0 | (c >> 18));
            bin.data[w++] = (unsigned char)(0x80 | ((c >> 12) & 0x3F));
            bin.data[w++] = (unsigned char)(0x80 | ((c >> 6) & 0x3F));
            bin.data[w++] = (unsigned char)(0x80 | (c & 0x3F));
        }
    }
    (*j)->ReleaseStringChars(j, s, u);
    enif_realloc_binary(&bin, w);
    return enif_make_binary(env, &bin);
}

/* A UTF-8 binary as a Java string (UTF-16; invalid bytes become U+FFFD). */
static jstring java_string(JNIEnv *j, const ErlNifBinary *b) {
    jchar *u = malloc(sizeof(jchar) * (b->size * 2 + 1));
    if (!u) return NULL;
    size_t n = 0;
    for (size_t i = 0; i < b->size;) {
        unsigned char c = b->data[i];
        uint32_t cp = 0xFFFD;
        int len = c < 0x80 ? 1 : (c >> 5) == 6 ? 2 : (c >> 4) == 14 ? 3 : (c >> 3) == 30 ? 4 : 0;
        if (len == 0 || i + len > b->size) {
            i++;
        } else {
            cp = len == 1 ? c : len == 2 ? c & 0x1F : len == 3 ? c & 0x0F : c & 0x07;
            bool ok = true;
            for (int k = 1; k < len; k++) {
                unsigned char d = b->data[i + k];
                if ((d >> 6) != 2) ok = false;
                cp = (cp << 6) | (d & 0x3F);
            }
            i += ok ? (size_t)len : 1;
            if (!ok || cp > 0x10FFFF) cp = 0xFFFD;
        }
        if (cp >= 0x10000) {
            u[n++] = (jchar)(0xD800 + ((cp - 0x10000) >> 10));
            u[n++] = (jchar)(0xDC00 + ((cp - 0x10000) & 0x3FF));
        } else {
            u[n++] = (jchar)cp;
        }
    }
    jstring s = (*j)->NewString(j, u, (jsize)n);
    free(u);
    if (jni_failed(j)) return NULL;
    return s;
}

/* AudioDeviceInfo.TYPE_* → kind for a microphone; NULL for the system's
 * internal routes (telephony, remote submix, echo reference, …). */
static const char *input_kind(jint type) {
    switch (type) {
    case 15: return "builtin_mic";            /* BUILTIN_MIC */
    case 3: return "wired_headset";           /* WIRED_HEADSET */
    case 7: case 26: return "bluetooth";      /* BLUETOOTH_SCO, BLE_HEADSET */
    case 11: case 12: case 22: return "usb";  /* USB_DEVICE, USB_ACCESSORY, USB_HEADSET */
    case 16: case 17: case 18: case 25: case 28: /* FM_TUNER, TV_TUNER, TELEPHONY, REMOTE_SUBMIX, ECHO_REFERENCE */
        return NULL;
    default: return "other";
    }
}

/* The microphones AudioManager lists, in its order. [] if Java can't be reached. */
static ERL_NIF_TERM input_list(ErlNifEnv *env, JNIEnv *j) {
    ERL_NIF_TERM list = enif_make_list(env, 0);
    if (!g_activity) return list;
    jmethodID get_service =
        method(j, (*j)->GetObjectClass(j, g_activity), "getSystemService", "(Ljava/lang/String;)Ljava/lang/Object;");
    if (!get_service) return list;
    jobject manager = (*j)->CallObjectMethod(j, g_activity, get_service, (*j)->NewStringUTF(j, "audio"));
    if (jni_failed(j) || !manager) return list;
    jclass info_class = (*j)->FindClass(j, "android/media/AudioDeviceInfo");
    if (jni_failed(j)) return list;
    jclass object_class = (*j)->FindClass(j, "java/lang/Object");
    if (jni_failed(j)) return list;
    jmethodID get_devices =
        method(j, (*j)->GetObjectClass(j, manager), "getDevices", "(I)[Landroid/media/AudioDeviceInfo;");
    jmethodID get_id = method(j, info_class, "getId", "()I");
    jmethodID get_type = method(j, info_class, "getType", "()I");
    jmethodID get_name = method(j, info_class, "getProductName", "()Ljava/lang/CharSequence;");
    jmethodID to_string = method(j, object_class, "toString", "()Ljava/lang/String;");
    if (!get_devices || !get_id || !get_type || !get_name || !to_string) return list;

    jobjectArray devices = (jobjectArray)(*j)->CallObjectMethod(j, manager, get_devices, 1); /* GET_DEVICES_INPUTS */
    if (jni_failed(j) || !devices) return list;
    for (jsize i = (*j)->GetArrayLength(j, devices) - 1; i >= 0; i--) {
        jobject d = (*j)->GetObjectArrayElement(j, devices, i);
        if (jni_failed(j) || !d) continue;
        jint type = (*j)->CallIntMethod(j, d, get_type);
        const char *kind = jni_failed(j) ? NULL : input_kind(type);
        jint id = kind ? (*j)->CallIntMethod(j, d, get_id) : 0;
        if (kind && !jni_failed(j)) {
            jobject chars = (*j)->CallObjectMethod(j, d, get_name);
            if (jni_failed(j)) chars = NULL;
            jstring name = chars ? (jstring)(*j)->CallObjectMethod(j, chars, to_string) : NULL;
            if (jni_failed(j)) name = NULL;
            ERL_NIF_TERM keys[3] = {atom(env, "id"), atom(env, "name"), atom(env, "kind")};
            ERL_NIF_TERM vals[3] = {enif_make_int(env, id), string_term(env, j, name), atom(env, kind)};
            ERL_NIF_TERM map;
            enif_make_map_from_arrays(env, keys, vals, 3, &map);
            list = enif_make_list_cell(env, map, list);
            if (name) (*j)->DeleteLocalRef(j, name);
            if (chars) (*j)->DeleteLocalRef(j, chars);
        }
        (*j)->DeleteLocalRef(j, d);
    }
    return list;
}

/* ── The background service ──────────────────────────────────────────────── */

static struct {
    pthread_mutex_t lock;
    jclass cls; /* global ref to HumListenBridge, or NULL until found */
    jmethodID start, update, stop;
    bool running;
    ErlNifPid owner; /* where button taps go, while running */
    /* Monitors `owner`: when it dies the service stops, so the notification
     * never outlives the process its buttons talk to. `generation` bumps on
     * every start and stop; a monitor of an older one says nothing. */
    struct bg_watch *watch;
    uint64_t generation;
    /* The notice last handed to Java, to skip unchanged updates. */
    ErlNifBinary title, text;
    int state;
} BG;

enum { BG_LISTENING = 0, BG_PAUSED = 1, BG_RECORDING = 2 };

typedef struct bg_watch {
    uint64_t generation;
} bg_watch;

static ErlNifResourceType *bg_watch_type;

/* Drop the owner's monitor (freeing the resource removes it). Caller holds BG.lock. */
static void bg_forget_locked(void) {
    BG.generation++;
    if (BG.watch) {
        enif_release_resource(BG.watch);
        BG.watch = NULL;
    }
}

/* Monitor `owner` instead of whoever was. False if it is already dead.
 * Caller holds BG.lock. */
static bool bg_watch_locked(ErlNifEnv *env, const ErlNifPid *owner) {
    bg_forget_locked();
    bg_watch *w = enif_alloc_resource(bg_watch_type, sizeof(bg_watch));
    if (!w) return false;
    w->generation = BG.generation;
    if (enif_monitor_process(env, w, owner, NULL) != 0) {
        enif_release_resource(w);
        return false;
    }
    BG.watch = w;
    return true;
}

/* Stop the service (Java may be unreachable: `j` NULL) and forget the
 * owner. Caller holds BG.lock. */
static void bg_stop_locked(JNIEnv *j) {
    if (BG.cls && j) {
        (*j)->CallStaticVoidMethod(j, BG.cls, BG.stop, g_activity);
        jni_failed(j);
    }
    BG.running = false;
    bg_forget_locked();
}

/* The owner died: stop the service, unless it was stopped or restarted
 * since. On a thread of its own: a down callback mustn't call into Java. */
static void *bg_owner_down_main(void *arg) {
    uint64_t generation = (uint64_t)(uintptr_t)arg;
    bool attached = false;
    JNIEnv *j = jni_env(&attached);
    pthread_mutex_lock(&BG.lock);
    if (BG.running && generation == BG.generation) {
        LOGI("background owner died: service stopped");
        bg_stop_locked(j);
    }
    pthread_mutex_unlock(&BG.lock);
    if (j) jni_done(attached);
    return NULL;
}

static void bg_owner_down(ErlNifEnv *env, void *obj, ErlNifPid *pid, ErlNifMonitor *mon) {
    (void)env;
    (void)pid;
    (void)mon;
    bg_watch *w = obj;
    pthread_t t;
    pthread_attr_t attr;
    pthread_attr_init(&attr);
    pthread_attr_setdetachstate(&attr, PTHREAD_CREATE_DETACHED);
    if (pthread_create(&t, &attr, bg_owner_down_main, (void *)(uintptr_t)w->generation) != 0)
        LOGE("background owner died, and no thread to stop the service");
    pthread_attr_destroy(&attr);
}

/* HumListenBridge.nativeAction(action): a notification button. True if a
 * process was there to take it. */
static jboolean JNICALL native_action(JNIEnv *j, jclass cls, jstring action) {
    (void)cls;
    char name[32] = {0};
    jsize n = action ? (*j)->GetStringUTFLength(j, action) : 0;
    if (n <= 0 || n >= (jsize)sizeof(name)) return JNI_FALSE;
    (*j)->GetStringUTFRegion(j, action, 0, (*j)->GetStringLength(j, action), name);
    if (jni_failed(j)) return JNI_FALSE;

    jboolean delivered = JNI_FALSE;
    pthread_mutex_lock(&BG.lock);
    if (BG.running) {
        ErlNifEnv *env = enif_alloc_env();
        delivered = enif_send(NULL, &BG.owner, env, enif_make_tuple2(env, atom(env, "background"), atom(env, name)))
                        ? JNI_TRUE
                        : JNI_FALSE;
        enif_free_env(env);
        if (strcmp(name, "failed") == 0) {
            BG.running = false;
            bg_forget_locked();
        }
    }
    pthread_mutex_unlock(&BG.lock);
    return delivered;
}

/* Find HumListenBridge through the activity's class loader (FindClass on a
 * native thread only sees the system classes) and register nativeAction.
 * Caller holds BG.lock. */
static bool bg_bind(JNIEnv *j) {
    if (BG.cls) return true;
    if (!g_activity) return false;
    bool ok = false;
    if ((*j)->PushLocalFrame(j, 16) != JNI_OK) return false;
    jmethodID get_loader =
        method(j, (*j)->GetObjectClass(j, g_activity), "getClassLoader", "()Ljava/lang/ClassLoader;");
    jobject loader = get_loader ? (*j)->CallObjectMethod(j, g_activity, get_loader) : NULL;
    if (jni_failed(j)) loader = NULL;
    jmethodID load_class =
        loader ? method(j, (*j)->GetObjectClass(j, loader), "loadClass", "(Ljava/lang/String;)Ljava/lang/Class;")
               : NULL;
    jclass cls = load_class ? (jclass)(*j)->CallObjectMethod(j, loader, load_class, (*j)->NewStringUTF(j, SERVICE_CLASS))
                            : NULL;
    if (jni_failed(j)) cls = NULL;
    if (cls) {
        JNINativeMethod natives[] = {{"nativeAction", "(Ljava/lang/String;)Z", (void *)native_action}};
        BG.start = (*j)->GetStaticMethodID(j, cls, "start",
                                           "(Landroid/content/Context;Ljava/lang/String;Ljava/lang/String;I)Ljava/lang/String;");
        if (jni_failed(j)) BG.start = NULL;
        BG.update = (*j)->GetStaticMethodID(j, cls, "update", "(Ljava/lang/String;Ljava/lang/String;I)V");
        if (jni_failed(j)) BG.update = NULL;
        BG.stop = (*j)->GetStaticMethodID(j, cls, "stop", "(Landroid/content/Context;)V");
        if (jni_failed(j)) BG.stop = NULL;
        if (BG.start && BG.update && BG.stop && (*j)->RegisterNatives(j, cls, natives, 1) == 0 && !jni_failed(j)) {
            BG.cls = (jclass)(*j)->NewGlobalRef(j, cls);
            ok = BG.cls != NULL;
        }
    }
    if (!ok) LOGE("background: %s not usable", SERVICE_CLASS);
    (*j)->PopLocalFrame(j, NULL);
    return ok;
}

static bool same_binary(const ErlNifBinary *a, const ErlNifBinary *b) {
    return a->size == b->size && (a->size == 0 || memcmp(a->data, b->data, a->size) == 0);
}

/* Remember the notice handed to Java. Caller holds BG.lock. */
static void bg_remember(const ErlNifBinary *title, const ErlNifBinary *text, int state) {
    if (BG.title.data) enif_release_binary(&BG.title);
    if (BG.text.data) enif_release_binary(&BG.text);
    memset(&BG.title, 0, sizeof(BG.title));
    memset(&BG.text, 0, sizeof(BG.text));
    if (enif_alloc_binary(title->size, &BG.title)) memcpy(BG.title.data, title->data, title->size);
    if (enif_alloc_binary(text->size, &BG.text)) memcpy(BG.text.data, text->data, text->size);
    BG.state = state;
}

/* ── File analysis ───────────────────────────────────────────────────────── */

/* One analyze_file/3 job. It is in FJ.jobs while its thread runs.
 * `cancelled` is set (under FJ.lock) by cancel_analysis/1, by a newer
 * analysis from the same owner, or by the owner's death; the decoder then
 * stops at its next buffer and nothing is sent. */
typedef struct file_job {
    char *path;
    ErlNifPid owner;
    ErlNifEnv *env; /* holds ref */
    ERL_NIF_TERM ref;
    uint64_t id;
    _Atomic bool cancelled;
    struct analysis_watch *watch; /* monitors owner */
    struct file_job *next;
} file_job;

/* Monitors a job's owner; `id` names the job. */
typedef struct analysis_watch {
    uint64_t id;
} analysis_watch;

static ErlNifResourceType *analysis_watch_type;

/* Analyses running at once for different owners (each decodes a whole file
 * on a core of its own; the import screen needs one). */
#define MAX_ANALYSES 2

/* FJ.lock is taken alone, never with the other locks. */
static struct {
    pthread_mutex_t lock;
    file_job *jobs;
    uint64_t next_id;
} FJ;

/* Caller holds FJ.lock. */
static void cancel_job_locked(file_job *job) {
    if (!atomic_exchange(&job->cancelled, true)) LOGI("analyze_file %s: cancelling", job->path);
}

/* A job's owner died: cancel the job if it still runs. */
static void analysis_owner_down(ErlNifEnv *env, void *obj, ErlNifPid *pid, ErlNifMonitor *mon) {
    (void)env;
    (void)pid;
    (void)mon;
    analysis_watch *w = obj;
    pthread_mutex_lock(&FJ.lock);
    for (file_job *j = FJ.jobs; j; j = j->next)
        if (j->id == w->id) cancel_job_locked(j);
    pthread_mutex_unlock(&FJ.lock);
}

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

/* Decode `path` into `a`. NULL or an error reason. */
static const char *decode_file(file_job *job, file_analysis *a) {
    const char *path = job->path;
    int fd = open(path, O_RDONLY);
    if (fd < 0) return "not_found";
    struct stat st;
    if (fstat(fd, &st) != 0 || !S_ISREG(st.st_mode)) {
        close(fd);
        return "not_found";
    }

    AMediaExtractor *ex = md.exNew();
    if (!ex || md.exSetDataSourceFd(ex, fd, 0, st.st_size) != 0) {
        if (ex) md.exDelete(ex);
        close(fd);
        return "unsupported";
    }

    AMediaCodec *codec = NULL;
    int32_t rate = 0, channels = 0;
    int64_t duration_us = 0;
    bool found_audio = false;
    for (size_t i = 0; i < md.exGetTrackCount(ex) && !codec; i++) {
        AMediaFormat *f = md.exGetTrackFormat(ex, i);
        const char *mime = NULL;
        if (md.fmtGetString(f, "mime", &mime) && strncmp(mime, "audio/", 6) == 0) {
            found_audio = true;
            md.fmtGetInt32(f, "sample-rate", &rate);
            md.fmtGetInt32(f, "channel-count", &channels);
            md.fmtGetInt64(f, "durationUs", &duration_us);
            md.exSelectTrack(ex, i);
            codec = md.codecCreateDecoderByType(mime);
            if (codec && md.codecConfigure(codec, f, NULL, NULL, 0) != 0) {
                md.codecDelete(codec);
                codec = NULL;
            }
        }
        md.fmtDelete(f);
    }
    const char *failure = NULL;
    if (!found_audio) failure = "no_audio";
    else if (!codec || rate <= 0) failure = "unsupported";
    else if (duration_us > (int64_t)MAX_FILE_MS * 1000 + 500000) failure = "too_long";
    else if (md.codecStart(codec) != 0) failure = "decode_error";
    if (failure) {
        if (codec) md.codecDelete(codec);
        md.exDelete(ex);
        close(fd);
        return failure;
    }

    bool input_done = false, started = false, is_float = false;
    int out_channels = channels > 0 ? channels : 1;
    int out_rate = rate;
    int64_t max_frames = 0;

    while (!failure) {
        if (atomic_load_explicit(&job->cancelled, memory_order_relaxed)) {
            failure = "cancelled";
            break;
        }
        if (!input_done) {
            ssize_t in = md.codecDequeueInputBuffer(codec, 5000);
            if (in >= 0) {
                size_t size = 0;
                uint8_t *buf = md.codecGetInputBuffer(codec, (size_t)in, &size);
                ssize_t n = buf ? md.exReadSampleData(ex, buf, size) : -1;
                int queued;
                if (n < 0) { /* the end of the track */
                    queued = md.codecQueueInputBuffer(codec, (size_t)in, 0, 0, 0, CODEC_EOS);
                    input_done = true;
                } else {
                    queued = md.codecQueueInputBuffer(codec, (size_t)in, 0, (size_t)n,
                                                      (uint64_t)md.exGetSampleTime(ex), 0);
                    md.exAdvance(ex);
                }
                if (!buf || queued != 0) failure = "decode_error";
            } else if (in != CODEC_TRY_AGAIN) {
                failure = "decode_error";
            }
            if (failure) break;
        }

        codec_buffer_info info;
        ssize_t out = md.codecDequeueOutputBuffer(codec, &info, 5000);
        if (out == CODEC_FORMAT_CHANGED) {
            AMediaFormat *f = md.codecGetOutputFormat(codec);
            int32_t v = 0;
            if (md.fmtGetInt32(f, "channel-count", &v) && v > 0) out_channels = v;
            if (!started && md.fmtGetInt32(f, "sample-rate", &v) && v > 0) out_rate = v;
            if (md.fmtGetInt32(f, "pcm-encoding", &v)) is_float = v == PCM_ENCODING_FLOAT;
            md.fmtDelete(f);
            continue;
        }
        if (out == CODEC_TRY_AGAIN || out == CODEC_BUFFERS_CHANGED) continue;
        if (out < 0) {
            failure = "decode_error";
            break;
        }

        if (!started) {
            started = true;
            if (!fa_init(a, out_rate)) {
                md.codecReleaseOutputBuffer(codec, (size_t)out, false);
                failure = "alloc";
                break;
            }
            max_frames = (int64_t)out_rate * (MAX_FILE_MS / 1000);
        }
        size_t size = 0;
        uint8_t *buf = md.codecGetOutputBuffer(codec, (size_t)out, &size);
        if (!buf) {
            md.codecReleaseOutputBuffer(codec, (size_t)out, false);
            failure = "decode_error";
            break;
        }
        int stride = out_channels;
        int64_t frames = info.size / (int64_t)((is_float ? sizeof(float) : sizeof(int16_t)) * stride);
        for (int64_t f = 0; f < frames && !failure; f++) {
            float sum = 0.0f;
            for (int c = 0; c < stride; c++) {
                size_t at = (size_t)(f * stride + c);
                sum += is_float ? ((const float *)(buf + info.offset))[at]
                                : ((const int16_t *)(buf + info.offset))[at] / 32768.0f;
            }
            if (!fa_push(a, sum / (float)stride)) failure = "alloc";
        }
        bool eos = (info.flags & CODEC_EOS) != 0;
        md.codecReleaseOutputBuffer(codec, (size_t)out, false);
        if (!failure && fa_total_frames(a) > max_frames + out_rate / 2) failure = "too_long";
        if (eos) break;
    }

    md.codecStop(codec);
    md.codecDelete(codec);
    md.exDelete(ex);
    close(fd);
    if (!failure && !started) failure = "no_audio";
    if (!failure && a->wave_n > 0 && !fa_wave_flush(a)) failure = "alloc";
    return failure;
}

static void *file_main(void *arg) {
    file_job *job = arg;
    file_analysis a;
    memset(&a, 0, sizeof(a));
    const char *failure = decode_file(job, &a);
    bool cancelled = failure && strcmp(failure, "cancelled") == 0;

    ErlNifEnv *env = enif_alloc_env();
    ERL_NIF_TERM payload = 0;
    if (cancelled) {
        LOGI("analyze_file %s: stopped (cancelled)", job->path);
    } else if (failure) {
        LOGE("analyze_file %s: %s", job->path, failure);
        payload = enif_make_tuple2(env, atom(env, "analysis_error"), atom(env, failure));
    } else {
        ERL_NIF_TERM keys[4], list = enif_make_list(env, 0);
        reading_keys(env, keys);
        for (size_t i = a.n_readings; i-- > 0;) list = enif_make_list_cell(env, reading_term(env, &a.readings[i], keys), list);
        ERL_NIF_TERM wave;
        memcpy(enif_make_new_binary(env, a.n_wave, &wave), a.waveform, a.n_wave);
        int64_t duration_ms = (int64_t)(1000.0 * (double)fa_total_frames(&a) / a.rate + 0.5);
        ERL_NIF_TERM mkeys[3] = {atom(env, "duration_ms"), atom(env, "waveform"), atom(env, "readings")};
        ERL_NIF_TERM mvals[3] = {enif_make_int64(env, duration_ms), wave, list};
        ERL_NIF_TERM map;
        enif_make_map_from_arrays(env, mkeys, mvals, 3, &map);
        payload = enif_make_tuple2(env, atom(env, "analysis"), map);
        LOGI("analyze_file %s: %lld ms, %zu readings", job->path, (long long)duration_ms, a.n_readings);
    }
    fa_free(&a);

    /* Leave the list and send under FJ.lock: once cancel_analysis has
     * returned, nothing more arrives for the job's reference. */
    pthread_mutex_lock(&FJ.lock);
    for (file_job **p = &FJ.jobs; *p; p = &(*p)->next) {
        if (*p == job) {
            *p = job->next;
            break;
        }
    }
    if (!cancelled && !atomic_load(&job->cancelled)) {
        ERL_NIF_TERM msg = enif_make_tuple3(env, atom(env, "hum_audio"), enif_make_copy(env, job->ref), payload);
        enif_send(NULL, &job->owner, env, msg);
    }
    pthread_mutex_unlock(&FJ.lock);
    enif_free_env(env);

    if (job->watch) enif_release_resource(job->watch); /* drops the owner's monitor */
    enif_free_env(job->env);
    free(job->path);
    free(job);
    return NULL;
}

/* ── NIFs ────────────────────────────────────────────────────────────────── */

static ERL_NIF_TERM missing_libs(ErlNifEnv *env) {
    return enif_make_tuple2(env, atom(env, "error"),
                            enif_make_tuple2(env, atom(env, "missing"), atom(env, libs_error ? libs_error : "unknown")));
}

/* listen(Owner, Ref, Input, Spectrum) -> ok | {error, Reason}. Input is a
 * device id or nil (the system default). Stops whatever was listening. Dirty IO. */
static ERL_NIF_TERM nif_listen(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
    (void)argc;
    int64_t called_ns = now_ns(); /* readings' t counts from here: opening the stream takes ~100 ms */
    ErlNifPid owner;
    int device = 0;
    if (!enif_get_local_pid(env, argv[0], &owner) || !enif_is_ref(env, argv[1])) return enif_make_badarg(env);
    if (!enif_is_identical(argv[2], atom(env, "nil")) && (!enif_get_int(env, argv[2], &device) || device < 0))
        return enif_make_badarg(env);
    bool spectrum_on = enif_is_identical(argv[3], atom(env, "true"));
    if (!libs_ok) return missing_libs(env);
    if (!mic_permitted()) return error_tuple(env, "permission");

    pthread_mutex_lock(&E.lock);
    stop_listening_locked();
    if (E.in) { /* the last stream wouldn't stop */
        pthread_mutex_unlock(&E.lock);
        return error_tuple(env, "microphone_unavailable");
    }
    uint64_t generation = atomic_fetch_add(&E.generation, 1) + 1;
    aaudio_result_t r = open_input_on(device, generation);
    if (r != AA_OK && device > 0) {
        LOGE("input device %d unavailable (%d): using the default", device, r);
        r = open_input_on(AA_UNSPECIFIED, generation);
    }
    if (r != AA_OK) {
        LOGE("input open failed: %d", r);
        pthread_mutex_unlock(&E.lock);
        return error_tuple(env, "microphone_unavailable");
    }

    atomic_store(&E.written, 0);
    atomic_store(&E.first_ns, -1);
    atomic_store(&E.in_failed, false);
    atomic_store(&E.spectrum_on, spectrum_on);
    atomic_store(&E.callbacks, 0);
    atomic_store(&E.last_burst, 0);
    atomic_store(&E.readings_sent, 0);
    atomic_store(&E.batches_sent, 0);
    atomic_store(&E.spectra_sent, 0);
    atomic_store(&E.lag_sum_ns, 0);
    atomic_store(&E.lag_max_ns, 0);
    E.listen_ns = called_ns;

    listener_res *res = enif_alloc_resource(listener_type, sizeof(listener_res));
    res->generation = generation;
    if (enif_monitor_process(env, res, &owner, NULL) != 0) {
        /* The owner is already dead: nothing to listen for. */
        enif_release_resource(res);
        stop_and_close(&E.in);
        pthread_mutex_unlock(&E.lock);
        return error_tuple(env, "owner_dead");
    }
    pthread_mutex_lock(&E.send_lock);
    E.owner = owner;
    E.ref_env = enif_alloc_env();
    E.ref = enif_make_copy(E.ref_env, argv[1]);
    E.monitor = res;
    E.active = true;
    pthread_mutex_unlock(&E.send_lock);

    const char *failure = NULL;
    atomic_store(&E.capturing, true);
    atomic_store(&E.run, true);
    if (pthread_create(&E.thread, NULL, listen_main, (void *)(uintptr_t)generation) != 0) {
        atomic_store(&E.run, false);
        failure = "thread";
    } else if (aa.requestStart(E.in) != AA_OK) {
        LOGE("input start failed");
        failure = "microphone_unavailable";
    }
    if (failure) stop_listening_locked();
    pthread_mutex_unlock(&E.lock);
    return failure ? error_tuple(env, failure) : atom(env, "ok");
}

/* Whether `ref` is the current listener's. Caller holds send_lock. */
static bool current_ref(ERL_NIF_TERM ref) { return E.active && enif_compare(E.ref, ref) == 0; }

/* stop(Ref) -> ok. Stops listening if Ref is the current listener's. Dirty IO. */
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

/* inputs() -> [#{id, name, kind}]. Dirty IO. */
static ERL_NIF_TERM nif_inputs(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
    (void)argc;
    (void)argv;
    bool attached;
    JNIEnv *j = jni_env(&attached);
    ERL_NIF_TERM list = enif_make_list(env, 0);
    if (!j) {
        LOGE("inputs: no JNI environment");
        return list;
    }
    if ((*j)->PushLocalFrame(j, 64) == JNI_OK) {
        list = input_list(env, j);
        (*j)->PopLocalFrame(j, NULL);
    } else {
        jni_failed(j);
    }
    jni_done(attached);
    return list;
}

/* analyze_file(Owner, Ref, Path) -> ok | {error, busy | owner_dead | alloc
 * | thread}: the result arrives as a message. Path is a binary. Cancels the
 * owner's earlier analysis (one per owner); at most MAX_ANALYSES run for
 * different owners at once. */
static ERL_NIF_TERM nif_analyze_file(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
    (void)argc;
    ErlNifPid owner;
    ErlNifBinary path;
    if (!enif_get_local_pid(env, argv[0], &owner) || !enif_is_ref(env, argv[1]) ||
        !enif_inspect_binary(env, argv[2], &path) || path.size == 0 || memchr(path.data, 0, path.size))
        return enif_make_badarg(env);
    if (!libs_ok) return missing_libs(env);

    file_job *job = calloc(1, sizeof(*job));
    char *p = malloc(path.size + 1);
    if (!job || !p) {
        free(job);
        free(p);
        return error_tuple(env, "alloc");
    }
    memcpy(p, path.data, path.size);
    p[path.size] = 0;
    job->path = p;
    job->owner = owner;
    job->env = enif_alloc_env();
    job->ref = enif_make_copy(job->env, argv[1]);

    const char *failure = NULL;
    pthread_mutex_lock(&FJ.lock);
    int others = 0;
    for (file_job *j = FJ.jobs; j; j = j->next)
        if (enif_compare_pids(&j->owner, &owner) != 0 && !atomic_load(&j->cancelled)) others++;
    analysis_watch *w = NULL;
    if (others >= MAX_ANALYSES) {
        failure = "busy";
    } else if (!(w = enif_alloc_resource(analysis_watch_type, sizeof(analysis_watch)))) {
        failure = "alloc";
    } else {
        job->id = w->id = ++FJ.next_id;
        /* Under the lock: a down callback for this owner waits for the job
         * to be in the list. */
        if (enif_monitor_process(env, w, &owner, NULL) != 0) failure = "owner_dead";
    }
    if (!failure) {
        for (file_job *j = FJ.jobs; j; j = j->next)
            if (enif_compare_pids(&j->owner, &owner) == 0) cancel_job_locked(j);
        job->watch = w;
        job->next = FJ.jobs;
        FJ.jobs = job;
        pthread_t t;
        pthread_attr_t attr;
        pthread_attr_init(&attr);
        pthread_attr_setdetachstate(&attr, PTHREAD_CREATE_DETACHED);
        if (pthread_create(&t, &attr, file_main, job) != 0) {
            FJ.jobs = job->next;
            failure = "thread";
        }
        pthread_attr_destroy(&attr);
    }
    pthread_mutex_unlock(&FJ.lock);
    if (failure) {
        if (w) enif_release_resource(w); /* drops the monitor */
        enif_free_env(job->env);
        free(p);
        free(job);
        return error_tuple(env, failure);
    }
    return atom(env, "ok");
}

/* cancel_analysis(Ref) -> ok. The analysis stops at its next decoder
 * buffer, and nothing for Ref arrives once this has returned. Unknown or
 * finished Refs are ignored. */
static ERL_NIF_TERM nif_cancel_analysis(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
    (void)argc;
    if (!enif_is_ref(env, argv[0])) return enif_make_badarg(env);
    pthread_mutex_lock(&FJ.lock);
    for (file_job *j = FJ.jobs; j; j = j->next)
        if (enif_compare(j->ref, argv[0]) == 0) cancel_job_locked(j);
    pthread_mutex_unlock(&FJ.lock);
    return atom(env, "ok");
}

static bool get_notice(ErlNifEnv *env, const ERL_NIF_TERM argv[], ErlNifBinary *title, ErlNifBinary *text,
                       int *state) {
    char s[16];
    if (!enif_inspect_binary(env, argv[0], title) || !enif_inspect_binary(env, argv[1], text) ||
        !enif_get_atom(env, argv[2], s, sizeof(s), ERL_NIF_UTF8))
        return false;
    if (strcmp(s, "listening") == 0) *state = BG_LISTENING;
    else if (strcmp(s, "paused") == 0) *state = BG_PAUSED;
    else if (strcmp(s, "recording") == 0) *state = BG_RECORDING;
    else return false;
    return true;
}

/* background_start(Owner, Title, Text, State) -> ok | {error, Reason}.
 * Starts (or retargets and updates) the foreground service. Dirty IO. */
static ERL_NIF_TERM nif_background_start(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
    (void)argc;
    ErlNifPid owner;
    ErlNifBinary title, text;
    int state;
    if (!enif_get_local_pid(env, argv[0], &owner) || !get_notice(env, argv + 1, &title, &text, &state))
        return enif_make_badarg(env);

    bool attached;
    JNIEnv *j = jni_env(&attached);
    if (!j) return error_tuple(env, "unavailable");
    ERL_NIF_TERM result = error_tuple(env, "unavailable");
    pthread_mutex_lock(&BG.lock);
    if (bg_bind(j) && (*j)->PushLocalFrame(j, 8) == JNI_OK) {
        jstring jt = java_string(j, &title), jx = java_string(j, &text);
        jstring err = jt && jx ? (jstring)(*j)->CallStaticObjectMethod(j, BG.cls, BG.start, g_activity, jt, jx, state)
                               : NULL;
        if (jni_failed(j) || !jt || !jx) {
            result = error_tuple(env, "refused");
        } else if (err) {
            const char *e = (*j)->GetStringUTFChars(j, err, NULL);
            result = error_tuple(env, e && strcmp(e, "permission") == 0 ? "permission" : "refused");
            if (e) (*j)->ReleaseStringUTFChars(j, err, e);
        } else {
            BG.running = true;
            BG.owner = owner;
            bg_remember(&title, &text, state);
            result = atom(env, "ok");
            if (!bg_watch_locked(env, &owner)) {
                /* The owner died meanwhile: nobody to take the buttons. */
                bg_stop_locked(j);
                result = error_tuple(env, "owner_dead");
            }
        }
        (*j)->PopLocalFrame(j, NULL);
    }
    pthread_mutex_unlock(&BG.lock);
    jni_done(attached);
    return result;
}

/* background_update(Title, Text, State) -> ok | {error, not_running}. An
 * unchanged notice costs no Java call; the service limits posts to 4/s. */
static ERL_NIF_TERM nif_background_update(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
    (void)argc;
    ErlNifBinary title, text;
    int state;
    if (!get_notice(env, argv, &title, &text, &state)) return enif_make_badarg(env);
    pthread_mutex_lock(&BG.lock);
    if (!BG.running) {
        pthread_mutex_unlock(&BG.lock);
        return error_tuple(env, "not_running");
    }
    if (state == BG.state && same_binary(&title, &BG.title) && same_binary(&text, &BG.text)) {
        pthread_mutex_unlock(&BG.lock);
        return atom(env, "ok");
    }
    bool attached;
    JNIEnv *j = jni_env(&attached);
    if (j && (*j)->PushLocalFrame(j, 8) == JNI_OK) {
        jstring jt = java_string(j, &title), jx = java_string(j, &text);
        if (jt && jx) (*j)->CallStaticVoidMethod(j, BG.cls, BG.update, jt, jx, state);
        if (!jni_failed(j) && jt && jx) bg_remember(&title, &text, state);
        (*j)->PopLocalFrame(j, NULL);
    }
    pthread_mutex_unlock(&BG.lock);
    if (j) jni_done(attached);
    return atom(env, "ok");
}

/* background_stop() -> ok. Dirty IO. */
static ERL_NIF_TERM nif_background_stop(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
    (void)argc;
    (void)argv;
    bool attached = false;
    JNIEnv *j = jni_env(&attached);
    pthread_mutex_lock(&BG.lock);
    bg_stop_locked(j);
    pthread_mutex_unlock(&BG.lock);
    if (j) jni_done(attached);
    return atom(env, "ok");
}

/* background_running() -> boolean. */
static ERL_NIF_TERM nif_background_running(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
    (void)argc;
    (void)argv;
    pthread_mutex_lock(&BG.lock);
    bool running = BG.running;
    pthread_mutex_unlock(&BG.lock);
    return atom(env, running ? "true" : "false");
}

/* info() -> map of diagnostics: the stream, and how readings have been
 * delivered since listen. Dirty IO (takes the lock). */
static ERL_NIF_TERM nif_info(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
    (void)argc;
    (void)argv;
    enum { N = 17 };
    /* File analyses whose thread still runs (cancelled ones until they notice). */
    int analyses = 0;
    pthread_mutex_lock(&FJ.lock);
    for (file_job *j = FJ.jobs; j; j = j->next) analyses++;
    pthread_mutex_unlock(&FJ.lock);
    pthread_mutex_lock(&E.lock);
    AAudioStream *s = E.in;
    double input_latency_ms = -1;
    int64_t pos, time;
    if (s && libs_ok && aa.getTimestamp(s, CLOCK_MONOTONIC, &pos, &time) == AA_OK) {
        /* Frames captured but not yet read, as time. */
        double captured_now = (double)pos + (double)(now_ns() - time) * E.in_rate / 1e9;
        input_latency_ms = 1000.0 * (captured_now - (double)aa.getFramesRead(s)) / E.in_rate;
    }
    int64_t batches = atomic_load(&E.batches_sent);
    int64_t first = atomic_load(&E.first_ns);
    ERL_NIF_TERM keys[N] = {atom(env, "libraries"),     atom(env, "listening"),       atom(env, "rate"),
                            atom(env, "device"),        atom(env, "burst"),           atom(env, "buffer"),
                            atom(env, "low_latency"),   atom(env, "xruns"),           atom(env, "callbacks"),
                            atom(env, "last_callback_frames"), atom(env, "readings"), atom(env, "batches"),
                            atom(env, "spectra"),       atom(env, "lag_mean_ms"),     atom(env, "lag_max_ms"),
                            atom(env, "input_latency_ms"), atom(env, "analyses")};
    ERL_NIF_TERM vals[N] = {
        libs_ok ? atom(env, "ok") : atom(env, libs_error ? libs_error : "unknown"),
        atom(env, s && atomic_load(&E.run) ? "true" : "false"),
        enif_make_int(env, s ? E.in_rate : 0),
        enif_make_int(env, s ? aa.getDeviceId(s) : 0),
        enif_make_int(env, s ? aa.getFramesPerBurst(s) : 0),
        enif_make_int(env, s ? aa.getBufferSizeInFrames(s) : 0),
        atom(env, s && aa.getPerformanceMode(s) == AA_PERF_LOW_LATENCY ? "true" : "false"),
        enif_make_int(env, s ? aa.getXRunCount(s) : 0),
        enif_make_int64(env, atomic_load(&E.callbacks)),
        enif_make_int64(env, atomic_load(&E.last_burst)),
        enif_make_int64(env, atomic_load(&E.readings_sent)),
        enif_make_int64(env, batches),
        enif_make_int64(env, atomic_load(&E.spectra_sent)),
        enif_make_double(env, batches ? atomic_load(&E.lag_sum_ns) / 1e6 / batches : 0.0),
        enif_make_double(env, atomic_load(&E.lag_max_ns) / 1e6),
        enif_make_double(env, first >= 0 ? input_latency_ms : -1.0),
        enif_make_int(env, analyses),
    };
    pthread_mutex_unlock(&E.lock);
    ERL_NIF_TERM map;
    enif_make_map_from_arrays(env, keys, vals, N, &map);
    return map;
}

static int on_load(ErlNifEnv *env, void **priv, ERL_NIF_TERM info) {
    (void)priv;
    (void)info;
    pthread_mutex_init(&E.lock, NULL);
    pthread_mutex_init(&E.send_lock, NULL);
    pthread_mutex_init(&BG.lock, NULL);
    pthread_mutex_init(&FJ.lock, NULL);
    atomic_store(&E.first_ns, -1);
    ErlNifResourceTypeInit init = {.dtor = NULL, .stop = NULL, .down = listener_down, .members = 3};
    listener_type = enif_init_resource_type(env, "hum_audio_listener", &init, ERL_NIF_RT_CREATE, NULL);
    if (!listener_type) return 1;
    ErlNifResourceTypeInit bg_init = {.dtor = NULL, .stop = NULL, .down = bg_owner_down, .members = 3};
    bg_watch_type = enif_init_resource_type(env, "hum_audio_background", &bg_init, ERL_NIF_RT_CREATE, NULL);
    if (!bg_watch_type) return 1;
    ErlNifResourceTypeInit fj_init = {.dtor = NULL, .stop = NULL, .down = analysis_owner_down, .members = 3};
    analysis_watch_type = enif_init_resource_type(env, "hum_audio_analysis", &fj_init, ERL_NIF_RT_CREATE, NULL);
    if (!analysis_watch_type) return 1;
    libs_ok = bind_libraries();
    if (!libs_ok) LOGE("could not bind %s", libs_error);
    return 0;
}

static ErlNifFunc nif_funcs[] = {
    /* Dirty IO where the call may open, stop or close a stream, join a
     * thread, or call into Java. */
    {"listen", 4, nif_listen, ERL_NIF_DIRTY_JOB_IO_BOUND},
    {"stop", 1, nif_stop, ERL_NIF_DIRTY_JOB_IO_BOUND},
    {"set_spectrum", 2, nif_set_spectrum, 0},
    {"inputs", 0, nif_inputs, ERL_NIF_DIRTY_JOB_IO_BOUND},
    {"analyze_file", 3, nif_analyze_file, 0},
    {"cancel_analysis", 1, nif_cancel_analysis, 0},
    {"background_start", 4, nif_background_start, ERL_NIF_DIRTY_JOB_IO_BOUND},
    {"background_update", 3, nif_background_update, ERL_NIF_DIRTY_JOB_IO_BOUND},
    {"background_stop", 0, nif_background_stop, ERL_NIF_DIRTY_JOB_IO_BOUND},
    {"background_running", 0, nif_background_running, 0},
    {"info", 0, nif_info, ERL_NIF_DIRTY_JOB_IO_BOUND},
};

ERL_NIF_INIT(Elixir.Humdinger.Audio.Nif, nif_funcs, on_load, NULL, NULL, NULL)
