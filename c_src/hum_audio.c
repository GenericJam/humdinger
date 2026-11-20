/*
 * c_src/hum_audio.c — the microphone's pitch, level and spectrum, and offline
 * analysis of audio files (Android).
 *
 *   input callback   AAudio microphone, low-latency mode, mono float
 *                    (VOICE_PERFORMANCE preset, VOICE_RECOGNITION before
 *                    Android 10: neither applies AGC or noise suppression)
 *                    into a lock-free ring.
 *   listen thread    YIN (pitch_yin.c) every hop (~5.3 ms) over a 42 ms
 *                    window, and a spectrum column (spectrum.c) every 1/30 s
 *                    while asked for. Readings go to the owner in batches as
 *                    soon as two are ready (or one has waited 6 ms), so each
 *                    message leaves within ~12 ms of the newest sample's
 *                    arrival. A thread that falls behind restarts on the
 *                    newest audio rather than deliver late readings.
 *   file threads     analyze_file/3: AMediaExtractor + AMediaCodec decode a
 *                    file, mixed down to mono and analysed as it decodes
 *                    (nothing but the readings is kept), one thread per owner.
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
 *
 * One listener at a time: listen/4 stops the previous one first, and its
 * reference goes stale. The owner is monitored; when it dies the microphone
 * stops.
 *
 * AAudio and libmediandk are opened with dlopen: the app links against
 * android-24 headers, where AAudio (API 26) doesn't exist, while the app's
 * minSdk is 28, so both libraries are always present at run time. Java
 * (AudioManager, permissions) is reached through the JVM and activity Mob's
 * JNI glue exports.
 *
 * Locks, always taken in this order: lock → send_lock. `lock` serialises the
 * control path (open, start, stop and close the stream, join the listen
 * thread) and is never taken by callbacks; `send_lock` guards the listener's
 * owner and reference, so no message of a stopped listener starts once stop
 * has returned. The stream is closed only once it is quiet (stopped, no
 * callback running).
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

/* Android's armeabi-v7a has VFPv3 and NEON. Built for a generic ARMv7 (zig's
 * default), every float operation becomes a library call and the detector
 * runs far slower than real time on a moto e 2020: refuse to build that way. */
#if defined(__arm__) && defined(__SOFTFP__)
#error "hum_audio needs hardware floating point on 32-bit ARM: compile armeabi-v7a with -mfloat-abi=softfp (android/app/src/main/jni/build.zig)"
#endif

#include "pitch_yin.c"
#include "spectrum.c"
#include "piano.c"

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
/* Unread audio beyond this (or two bursts and a hop, or a window and a hop,
 * whichever is more) means the listen thread is behind: it skips to the
 * newest audio rather than deliver stale readings. */
#define MAX_BACKLOG_MS 30

/* ── AAudio, declared by hand (see header comment) ───────────────────────── */

typedef struct AAudioStreamBuilderStruct AAudioStreamBuilder;
typedef struct AAudioStreamStruct AAudioStream;
typedef int32_t aaudio_result_t;
typedef int32_t (*aa_data_cb)(AAudioStream *, void *, void *, int32_t);
typedef void (*aa_error_cb)(AAudioStream *, void *, aaudio_result_t);

enum {
    AA_OK = 0,
    AA_UNSPECIFIED = 0,
    AA_DIRECTION_OUTPUT = 0,
    AA_DIRECTION_INPUT = 1,
    AA_FORMAT_PCM_FLOAT = 2,
    AA_SHARING_SHARED = 1,
    AA_PERF_NONE = 10,
    AA_PERF_LOW_LATENCY = 12,
    AA_USAGE_MEDIA = 1,
    AA_CONTENT_TYPE_MUSIC = 2,
    AA_PRESET_GENERIC = 1,
    AA_PRESET_VOICE_RECOGNITION = 6,
    AA_PRESET_UNPROCESSED = 9,
    AA_PRESET_VOICE_PERFORMANCE = 10,
    AA_CALLBACK_CONTINUE = 0,
    AA_CALLBACK_STOP = 1,
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
    void (*setUsage)(AAudioStreamBuilder *, int32_t);
    void (*setContentType)(AAudioStreamBuilder *, int32_t);
    void (*setDataCallback)(AAudioStreamBuilder *, aa_data_cb, void *);
    void (*setErrorCallback)(AAudioStreamBuilder *, aa_error_cb, void *);
    aaudio_result_t (*openStream)(AAudioStreamBuilder *, AAudioStream **);
    aaudio_result_t (*builderDelete)(AAudioStreamBuilder *);
    aaudio_result_t (*close)(AAudioStream *);
    aaudio_result_t (*requestStart)(AAudioStream *);
    aaudio_result_t (*requestStop)(AAudioStream *);
    int32_t (*getDeviceId)(AAudioStream *);
    int32_t (*getSampleRate)(AAudioStream *);
    int32_t (*getChannelCount)(AAudioStream *);
    int32_t (*getFramesPerBurst)(AAudioStream *);
    int32_t (*getBufferSizeInFrames)(AAudioStream *);
    int32_t (*getXRunCount)(AAudioStream *);
    int32_t (*getPerformanceMode)(AAudioStream *);
    int32_t (*getSharingMode)(AAudioStream *);
    int32_t (*getInputPreset)(AAudioStream *);
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
    *(void **)&aa.setUsage = dlsym(a, "AAudioStreamBuilder_setUsage");
    *(void **)&aa.setContentType = dlsym(a, "AAudioStreamBuilder_setContentType");
    BIND(aa, a, setDataCallback, "AAudioStreamBuilder_setDataCallback");
    BIND(aa, a, setErrorCallback, "AAudioStreamBuilder_setErrorCallback");
    BIND(aa, a, openStream, "AAudioStreamBuilder_openStream");
    BIND(aa, a, builderDelete, "AAudioStreamBuilder_delete");
    BIND(aa, a, close, "AAudioStream_close");
    BIND(aa, a, requestStart, "AAudioStream_requestStart");
    BIND(aa, a, requestStop, "AAudioStream_requestStop");
    BIND(aa, a, getDeviceId, "AAudioStream_getDeviceId");
    BIND(aa, a, getSampleRate, "AAudioStream_getSampleRate");
    BIND(aa, a, getChannelCount, "AAudioStream_getChannelCount");
    BIND(aa, a, getFramesPerBurst, "AAudioStream_getFramesPerBurst");
    BIND(aa, a, getBufferSizeInFrames, "AAudioStream_getBufferSizeInFrames");
    BIND(aa, a, getXRunCount, "AAudioStream_getXRunCount");
    BIND(aa, a, getPerformanceMode, "AAudioStream_getPerformanceMode");
    BIND(aa, a, getSharingMode, "AAudioStream_getSharingMode");
    BIND(aa, a, getInputPreset, "AAudioStream_getInputPreset");
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

typedef struct {
    _Atomic int64_t sum_ns, max_ns, count;
} cost;

/* Batch lag histogram: LAG_BUCKET_US wide, the last bucket is "more". */
#define LAG_BUCKETS 200
#define LAG_BUCKET_US 500
/* Recent input callbacks: the ring index they delivered up to, and when. */
#define ARRIVALS 64

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
    _Atomic int64_t lag_hist[LAG_BUCKETS];
    struct {
        _Atomic int64_t end, ns;
    } arrivals[ARRIVALS];
    _Atomic int64_t arrivals_n;
    cost detect_cost, column_cost;  /* one pitch reading, one spectrum column */
    _Atomic int64_t skipped, skips; /* audio dropped to catch up */

    int in_burst;          /* the stream's frames per burst */
    _Atomic int32_t preset; /* AAudio input preset for the next listen (VOICE_PERFORMANCE) */
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
    int64_t k = atomic_fetch_add_explicit(&E.arrivals_n, 1, memory_order_relaxed) & (ARRIVALS - 1);
    atomic_store_explicit(&E.arrivals[k].end, w + frames, memory_order_relaxed);
    atomic_store_explicit(&E.arrivals[k].ns, now_ns(), memory_order_relaxed);
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

static aaudio_result_t open_input_on(int32_t device, int32_t preset, uint64_t generation) {
    AAudioStreamBuilder *b;
    aaudio_result_t r = aa.createStreamBuilder(&b);
    if (r != AA_OK) return r;
    aa.setDirection(b, AA_DIRECTION_INPUT);
    if (device > 0) aa.setDeviceId(b, device);
    aa.setChannelCount(b, 1);
    aa.setFormat(b, AA_FORMAT_PCM_FLOAT);
    aa.setSharingMode(b, AA_SHARING_SHARED);
    aa.setPerformanceMode(b, AA_PERF_LOW_LATENCY);
    aa.setInputPreset(b, preset);
    aa.setDataCallback(b, input_cb, NULL);
    aa.setErrorCallback(b, input_error_cb, (void *)(uintptr_t)generation);
    AAudioStream *s = NULL;
    r = aa.openStream(b, &s);
    aa.builderDelete(b);
    if (r == AA_OK) {
        E.in = s;
        E.in_rate = aa.getSampleRate(s);
        E.in_burst = aa.getFramesPerBurst(s);
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

    /* Lag: from the input callback that delivered the newest sample analysed
     * to the send (what this engine adds; the stream's own buffering, a burst
     * at most, comes before). Diagnostics: a callback overwriting an entry
     * mid-read only skews one batch. */
    int64_t now = now_ns(), arrived = -1, n = atomic_load_explicit(&E.arrivals_n, memory_order_relaxed);
    for (int64_t k = n - 1; k >= 0 && k >= n - ARRIVALS; k--) {
        if (atomic_load_explicit(&E.arrivals[k & (ARRIVALS - 1)].end, memory_order_relaxed) < newest_sample) break;
        arrived = atomic_load_explicit(&E.arrivals[k & (ARRIVALS - 1)].ns, memory_order_relaxed);
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
    /* More unread audio than this and the thread is behind, not just
     * handed a burst: it drops to the newest audio (see below). */
    int64_t max_backlog = (int64_t)rate * MAX_BACKLOG_MS / 1000;
    if (max_backlog < 2 * (int64_t)E.in_burst + hop) max_backlog = 2 * (int64_t)E.in_burst + hop;
    if (max_backlog < (int64_t)window + hop) max_backlog = (int64_t)window + hop;
    /* Readings need a window of audio pushed since `valid_from`. */
    int64_t read = 0, next_column = 0, valid_from = 0;
    batch b = {.count = 0};

    while (atomic_load(&E.run)) {
        int64_t written = atomic_load_explicit(&E.written, memory_order_acquire);
        if (written - read > max_backlog) {
            /* Behind (a slow phone, the thread starved): never queue stale
             * audio. Restart the detector on the newest window; the
             * readings in between are lost, not late. */
            int64_t to = written - window;
            atomic_fetch_add(&E.skipped, to - read);
            atomic_fetch_add(&E.skips, 1);
            read = valid_from = to;
        }
        while (written - read >= hop) {
            for (int i = 0; i < hop; i++) chunk[i] = E.ring[(read + i) & (RING_SIZE - 1)];
            read += hop;
            pitch_push(p, chunk, hop);
            if (read - valid_from >= window) {
                int64_t t0 = now_ns();
                pitch_reading pr = pitch_detect(p);
                count_cost(&E.detect_cost, now_ns() - t0);
                if (b.count == 0) b.first_at_ns = now_ns();
                b.items[b.count++] = (reading){sample_ms(read - window / 2.0), pr.hz, pr.clarity, pr.rms_db};
                if (b.count >= 2) send_batch(generation, &b, read);
            }
            /* A column only once the readings have caught up: the spectrum
             * is for looking at, the readings drive the MIDI. */
            if (atomic_load(&E.spectrum_on) && read >= sp->n && read >= next_column && written - read < hop) {
                int64_t t0 = now_ns();
                for (int i = 0; i < sp->n; i++) column_in[i] = E.ring[(read - sp->n + i) & (RING_SIZE - 1)];
                uint8_t bins[SPEC_BINS];
                spectrum_column(sp, column_in, bins);
                count_cost(&E.column_cost, now_ns() - t0);
                send_spectrum(generation, sample_ms(read - sp->n / 2.0), bins);
                next_column = next_column + spectrum_every > read ? next_column + spectrum_every
                                                                    : read + spectrum_every;
            }
        }
        if (b.count == 1 && now_ns() - b.first_at_ns >= BATCH_WAIT_NS) send_batch(generation, &b, read);
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

/* ── File analysis ───────────────────────────────────────────────────────── */

/* One analyze_file/3 job, in FJ.jobs until it is done or dropped.
 * `started`: a thread runs it. Each owner has at most one thread: a newer
 * analysis while the owner's thread still runs (perhaps cancelled, until
 * its decoder notices) waits, unstarted, for that thread to pick it up, and
 * an even newer one replaces the waiting one. `cancelled` is set (under
 * FJ.lock) on a started job by cancel_analysis/1, by a newer analysis from
 * the same owner, or by the owner's death; the decoder then stops at its
 * next buffer and nothing is sent. Unstarted jobs are simply dropped. */
typedef struct file_job {
    char *path;
    ErlNifPid owner;
    ErlNifEnv *env; /* holds ref */
    ERL_NIF_TERM ref;
    uint64_t id;
    bool started; /* under FJ.lock */
    _Atomic bool cancelled;
    struct analysis_watch *watch; /* monitors owner */
    struct file_job *next;
} file_job;

/* Monitors a job's owner; `id` names the job. */
typedef struct analysis_watch {
    uint64_t id;
} analysis_watch;

static ErlNifResourceType *analysis_watch_type;

/* Owners with an analysis thread at once (each decodes a whole file on a
 * core of its own; the import screen needs one). With one thread per owner,
 * this caps the threads. */
#define MAX_ANALYSES 2

/* FJ.lock is taken alone, never with the other locks. */
static struct {
    pthread_mutex_t lock;
    file_job *jobs;
    uint64_t next_id;
} FJ;

/* Free a job out of FJ.jobs (not under FJ.lock: it releases the monitor). */
static void free_job(file_job *job) {
    if (!job) return;
    if (job->watch) enif_release_resource(job->watch); /* drops the owner's monitor */
    enif_free_env(job->env);
    free(job->path);
    free(job);
}

/* Take `job` out of FJ.jobs. Caller holds FJ.lock. */
static void unlink_job_locked(file_job *job) {
    for (file_job **p = &FJ.jobs; *p; p = &(*p)->next) {
        if (*p == job) {
            *p = job->next;
            return;
        }
    }
}

/* Stop `job`: a started one is cancelled (its thread ends it); an unstarted
 * one is taken out and returned, for the caller to free once unlocked.
 * Caller holds FJ.lock. */
static file_job *cancel_job_locked(file_job *job) {
    if (!job->started) {
        unlink_job_locked(job);
        return job;
    }
    if (!atomic_exchange(&job->cancelled, true)) LOGI("analyze_file %s: cancelling", job->path);
    return NULL;
}

/* A job's owner died: cancel the job if it is still there. */
static void analysis_owner_down(ErlNifEnv *env, void *obj, ErlNifPid *pid, ErlNifMonitor *mon) {
    (void)env;
    (void)pid;
    (void)mon;
    analysis_watch *w = obj;
    file_job *dropped = NULL;
    pthread_mutex_lock(&FJ.lock);
    for (file_job *j = FJ.jobs; j; j = j->next) {
        if (j->id == w->id) {
            dropped = cancel_job_locked(j);
            break;
        }
    }
    pthread_mutex_unlock(&FJ.lock);
    free_job(dropped);
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

/* Runs `arg`, then whatever analysis its owner asked for meanwhile (one
 * thread per owner, see file_job). */
static void *file_main(void *arg) {
    for (file_job *job = arg; job;) {
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
            for (size_t i = a.n_readings; i-- > 0;)
                list = enif_make_list_cell(env, reading_term(env, &a.readings[i], keys), list);
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
         * returned, nothing more arrives for the job's reference. Then take
         * the owner's waiting analysis, if any. */
        file_job *next = NULL;
        pthread_mutex_lock(&FJ.lock);
        unlink_job_locked(job);
        if (!cancelled && !atomic_load(&job->cancelled)) {
            ERL_NIF_TERM msg = enif_make_tuple3(env, atom(env, "hum_audio"), enif_make_copy(env, job->ref), payload);
            enif_send(NULL, &job->owner, env, msg);
        }
        for (file_job *j = FJ.jobs; j && !next; j = j->next) {
            if (!j->started && enif_compare_pids(&j->owner, &job->owner) == 0) {
                j->started = true;
                next = j;
            }
        }
        pthread_mutex_unlock(&FJ.lock);
        enif_free_env(env);
        free_job(job);
        job = next;
    }
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
    int32_t preset = atomic_load(&E.preset);
    aaudio_result_t r = open_input_on(device, preset, generation);
    if (r != AA_OK && preset == AA_PRESET_VOICE_PERFORMANCE) {
        /* VOICE_PERFORMANCE is Android 10+. */
        LOGE("input preset %d refused (%d): using VOICE_RECOGNITION", preset, r);
        preset = AA_PRESET_VOICE_RECOGNITION;
        r = open_input_on(device, preset, generation);
    }
    if (r != AA_OK && device > 0) {
        LOGE("input device %d unavailable (%d): using the default", device, r);
        r = open_input_on(AA_UNSPECIFIED, preset, generation);
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
    memset((void *)E.lag_hist, 0, sizeof(E.lag_hist));
    atomic_store(&E.arrivals_n, 0);
    memset((void *)E.arrivals, 0, sizeof(E.arrivals));
    memset((void *)&E.detect_cost, 0, sizeof(E.detect_cost));
    memset((void *)&E.column_cost, 0, sizeof(E.column_cost));
    atomic_store(&E.skipped, 0);
    atomic_store(&E.skips, 0);
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
 * owner's earlier analysis (one per owner, one thread per owner: see
 * file_job); `busy` while MAX_ANALYSES other owners have a thread running,
 * cancelled or not. */
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
    file_job *dropped = NULL;
    pthread_mutex_lock(&FJ.lock);
    int others = 0;
    for (file_job *j = FJ.jobs; j; j = j->next)
        if (j->started && enif_compare_pids(&j->owner, &owner) != 0) others++;
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
        /* The owner's thread, if it has one, stops its job and then takes
         * this one; a job still waiting for it is replaced. */
        bool owner_thread = false;
        for (file_job *j = FJ.jobs, *following; j; j = following) {
            following = j->next;
            if (enif_compare_pids(&j->owner, &owner) != 0) continue;
            if (j->started) owner_thread = true;
            file_job *gone = cancel_job_locked(j);
            if (gone) {
                gone->next = dropped;
                dropped = gone;
            }
        }
        job->watch = w;
        job->started = !owner_thread;
        job->next = FJ.jobs;
        FJ.jobs = job;
        if (job->started) {
            pthread_t t;
            pthread_attr_t attr;
            pthread_attr_init(&attr);
            pthread_attr_setdetachstate(&attr, PTHREAD_CREATE_DETACHED);
            if (pthread_create(&t, &attr, file_main, job) != 0) {
                unlink_job_locked(job);
                failure = "thread";
            }
            pthread_attr_destroy(&attr);
        }
    }
    pthread_mutex_unlock(&FJ.lock);
    while (dropped) {
        file_job *following = dropped->next;
        free_job(dropped);
        dropped = following;
    }
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
    file_job *dropped = NULL;
    pthread_mutex_lock(&FJ.lock);
    for (file_job *j = FJ.jobs; j; j = j->next) {
        if (enif_compare(j->ref, argv[0]) == 0) {
            dropped = cancel_job_locked(j);
            break;
        }
    }
    pthread_mutex_unlock(&FJ.lock);
    free_job(dropped);
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

/* info() -> map of diagnostics: the stream, and how readings have been
 * delivered since listen. Dirty IO (takes the lock). */
static ERL_NIF_TERM nif_info(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
    (void)argc;
    (void)argv;
    enum { N = 26 };
    /* File analysis threads running (cancelled ones until they notice). */
    int analyses = 0;
    pthread_mutex_lock(&FJ.lock);
    for (file_job *j = FJ.jobs; j; j = j->next) analyses += j->started;
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
    int64_t detect_n = atomic_load(&E.detect_cost.count), column_n = atomic_load(&E.column_cost.count);
    int64_t lag_n = 0;
    for (int i = 0; i < LAG_BUCKETS; i++) lag_n += atomic_load_explicit(&E.lag_hist[i], memory_order_relaxed);
    ERL_NIF_TERM keys[N] = {atom(env, "libraries"),     atom(env, "listening"),       atom(env, "rate"),
                            atom(env, "device"),        atom(env, "burst"),           atom(env, "buffer"),
                            atom(env, "low_latency"),   atom(env, "xruns"),           atom(env, "callbacks"),
                            atom(env, "last_callback_frames"), atom(env, "readings"), atom(env, "batches"),
                            atom(env, "spectra"),       atom(env, "lag_mean_ms"),     atom(env, "lag_max_ms"),
                            atom(env, "input_latency_ms"), atom(env, "analyses"), atom(env, "preset"),
                            atom(env, "detect_us_mean"), atom(env, "detect_us_max"),
                            atom(env, "column_us_mean"), atom(env, "column_us_max"),
                            atom(env, "skipped_ms"), atom(env, "skips"), atom(env, "lag_p50_ms"),
                            atom(env, "lag_p95_ms")};
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
        enif_make_double(env, lag_n ? atomic_load(&E.lag_sum_ns) / 1e6 / lag_n : 0.0),
        enif_make_double(env, atomic_load(&E.lag_max_ns) / 1e6),
        enif_make_double(env, first >= 0 ? input_latency_ms : -1.0),
        enif_make_int(env, analyses),
        enif_make_int(env, s ? aa.getInputPreset(s) : 0),
        enif_make_double(env, detect_n ? atomic_load(&E.detect_cost.sum_ns) / 1e3 / detect_n : 0.0),
        enif_make_double(env, atomic_load(&E.detect_cost.max_ns) / 1e3),
        enif_make_double(env, column_n ? atomic_load(&E.column_cost.sum_ns) / 1e3 / column_n : 0.0),
        enif_make_double(env, atomic_load(&E.column_cost.max_ns) / 1e3),
        enif_make_double(env, s ? 1000.0 * atomic_load(&E.skipped) / E.in_rate : 0.0),
        enif_make_int64(env, atomic_load(&E.skips)),
        enif_make_double(env, lag_percentile(0.50)),
        enif_make_double(env, lag_percentile(0.95)),
    };
    pthread_mutex_unlock(&E.lock);
    ERL_NIF_TERM map;
    enif_make_map_from_arrays(env, keys, vals, N, &map);
    return map;
}

/* set_input_preset(voice_performance | voice_recognition | unprocessed |
 * generic) -> ok: the AAudio input preset the next listen opens with. For
 * measuring a phone (scripts/realtime_check.exs); the app keeps the default,
 * voice_performance (see AGENTS.md, "The audio engine"). */
static ERL_NIF_TERM nif_set_input_preset(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
    (void)argc;
    char name[24];
    if (!enif_get_atom(env, argv[0], name, sizeof(name), ERL_NIF_UTF8)) return enif_make_badarg(env);
    int32_t preset = strcmp(name, "voice_recognition") == 0   ? AA_PRESET_VOICE_RECOGNITION
                     : strcmp(name, "unprocessed") == 0       ? AA_PRESET_UNPROCESSED
                     : strcmp(name, "voice_performance") == 0 ? AA_PRESET_VOICE_PERFORMANCE
                     : strcmp(name, "generic") == 0           ? AA_PRESET_GENERIC
                                                              : -1;
    if (preset < 0) return enif_make_badarg(env);
    atomic_store(&E.preset, preset);
    return atom(env, "ok");
}

/* ── Piano output ──────────────────────────────────────────────────────── */

#define PIANO_RING_SIZE (1 << 14)          /* mono output samples, power of two */
#define PIANO_UNDERRUN_RING_SIZE (1 << 10) /* stream-frame underrun ranges, power of two */
#define PIANO_MIN_ROOT 22
#define PIANO_MAX_ROOT 106
#define PIANO_ROOT_STEP 3
#define PIANO_ROOT_COUNT 29
#define PIANO_SAMPLE_RATE 22050
#define PIANO_MAX_WAV_BYTES (2 * 1024 * 1024)
#define PIANO_POS_INTERVAL_NS 34000000LL       /* <= 30 Hz */
#define PIANO_MAX_TS_EXTRAPOLATE_NS 50000000LL /* cap wall-clock projection past ts_ns */
#define PIANO_NO_TS_GRACE_NS 300000000LL       /* grace before getFramesRead fallback */

typedef struct {
    uint64_t generation;
} piano_res;

typedef struct {
    double start_ms;
    double dur_ms;
    int32_t midi;
    float gain;
} piano_raw_note;

typedef struct {
    int64_t start;
    int64_t len;
} piano_underrun_range;

static ErlNifResourceType *piano_watch_type;

static struct {
    pthread_mutex_t lock;
    pthread_mutex_t send_lock;

    _Atomic uint64_t generation;
    AAudioStream *out;
    int out_rate;
    int out_channels;
    int out_burst;
    int out_buffer_frames;

    float ring[PIANO_RING_SIZE];
    _Atomic int64_t ring_write;
    _Atomic int64_t ring_read;
    _Atomic int64_t cb_total_frames;        /* total frames output callback handed to AAudio */
    /* Underrun stream-frame ranges: SPSC ring written by piano_out_cb and
     * consumed by piano_main as stream_pos reaches them. If the ring fills up,
     * extra underrun frames spill into underrun_overflow (subtracted at once). */
    piano_underrun_range underrun_ring[PIANO_UNDERRUN_RING_SIZE];
    _Atomic int64_t underrun_write;
    _Atomic int64_t underrun_read;
    _Atomic int64_t underrun_overflow;
    _Atomic int64_t last_real_stream_frame; /* stream frame index where total_frames ends */
    _Atomic bool playing;                   /* output callback consumes from ring */
    _Atomic bool out_failed;                /* output error callback fired */
    _Atomic bool synth_done;                /* render thread wrote all frames */
    _Atomic bool all_real_queued;           /* output callback queued total_frames to AAudio */
    int64_t total_frames;
    int64_t phrase_end_frames;
    double phrase_end_ms;
    int64_t last_sent_pos_ms;

    pthread_t thread;
    _Atomic bool run;

    /* Protected by P.lock. */
    piano_bank bank;
    bool bank_loaded;
    piano_synth synth;

    /* Protected by P.send_lock. */
    bool active;
    ErlNifPid owner;
    ErlNifEnv *ref_env;
    ERL_NIF_TERM ref;
    piano_res *monitor;
} P;

/* Persistent detached worker for asynchronous piano cleanup (owner down,
 * AAudio error callback, render thread completion). Lock order: P.lock ->
 * PC.lock; never hold PC.lock while taking P.lock. */
static struct {
    pthread_mutex_t lock;
    pthread_cond_t cond;
    bool started;
    bool has_request;
    uint64_t pending_generation;
} PC;

static uint16_t read_le16(const uint8_t *p) { return (uint16_t)p[0] | ((uint16_t)p[1] << 8); }

static uint32_t read_le32(const uint8_t *p) {
    return (uint32_t)p[0] | ((uint32_t)p[1] << 8) | ((uint32_t)p[2] << 16) | ((uint32_t)p[3] << 24);
}

static void free_piano_samples(piano_sample *samples, int count) {
    if (!samples) return;
    for (int i = 0; i < count; i++) free((void *)samples[i].pcm);
    free(samples);
}

static bool load_wav_mono_s16(const char *path, int16_t **pcm_out, int64_t *frames_out) {
    FILE *f = fopen(path, "rb");
    if (!f) return false;
    if (fseek(f, 0, SEEK_END) != 0) {
        fclose(f);
        return false;
    }
    long len = ftell(f);
    if (len < 44 || len > PIANO_MAX_WAV_BYTES || fseek(f, 0, SEEK_SET) != 0) {
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
        uint32_t chunk_sz = read_le32(hdr + 4);
        size_t payload = pos + 8;
        if ((uint64_t)chunk_sz > (uint64_t)(sz - payload)) break;

        if (memcmp(hdr, "fmt ", 4) == 0) {
            if (chunk_sz < 16) break;
            uint16_t audio_fmt = read_le16(buf + payload);
            uint16_t channels = read_le16(buf + payload + 2);
            uint32_t rate = read_le32(buf + payload + 4);
            uint16_t bits = read_le16(buf + payload + 14);
            if (audio_fmt != 1 || channels != 1 || rate != PIANO_SAMPLE_RATE || bits != 16) break;
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
    for (int64_t i = 0; i < frames; i++) {
        pcm[i] = (int16_t)read_le16(data_ptr + (size_t)i * 2);
    }
    free(buf);
    *pcm_out = pcm;
    *frames_out = frames;
    return true;
}

static bool load_piano_bank_locked(const char *dir) {
    if (P.bank_loaded) return true;
    piano_sample *samples = calloc(PIANO_ROOT_COUNT, sizeof(piano_sample));
    if (!samples) return false;

    int count = 0;
    for (int midi = PIANO_MIN_ROOT; midi <= PIANO_MAX_ROOT && count < PIANO_ROOT_COUNT;
         midi += PIANO_ROOT_STEP) {
        char path[1024];
        int n = snprintf(path, sizeof(path), "%s/mf_%03d.wav", dir, midi);
        if (n < 0 || (size_t)n >= sizeof(path)) {
            free_piano_samples(samples, count);
            return false;
        }
        int16_t *pcm = NULL;
        int64_t frames = 0;
        if (!load_wav_mono_s16(path, &pcm, &frames)) {
            LOGE("piano sample missing or invalid: %s", path);
            free_piano_samples(samples, count);
            return false;
        }
        samples[count++] = (piano_sample){.pcm = pcm, .frames = frames, .root_midi = midi};
    }

    if (count != PIANO_ROOT_COUNT) {
        free_piano_samples(samples, count);
        return false;
    }
    P.bank = (piano_bank){.rate = PIANO_SAMPLE_RATE, .count = count, .samples = samples};
    P.bank_loaded = true;
    return true;
}

static void send_piano_position(uint64_t generation, int64_t ms) {
    ErlNifEnv *env = enif_alloc_env();
    ERL_NIF_TERM payload = enif_make_tuple2(env, atom(env, "piano_position"), enif_make_int64(env, ms));
    pthread_mutex_lock(&P.send_lock);
    if (P.active && generation == atomic_load(&P.generation)) {
        ERL_NIF_TERM msg = enif_make_tuple3(env, atom(env, "hum_audio"), enif_make_copy(env, P.ref), payload);
        enif_send(NULL, &P.owner, env, msg);
    }
    pthread_mutex_unlock(&P.send_lock);
    enif_free_env(env);
}

static void send_piano_terminal(uint64_t generation, const char *kind, const char *reason) {
    ErlNifEnv *env = enif_alloc_env();
    ERL_NIF_TERM payload =
        reason ? enif_make_tuple2(env, atom(env, kind), atom(env, reason)) : atom(env, kind);
    pthread_mutex_lock(&P.send_lock);
    if (P.active && generation == atomic_load(&P.generation)) {
        P.active = false;
        ERL_NIF_TERM msg = enif_make_tuple3(env, atom(env, "hum_audio"), enif_make_copy(env, P.ref), payload);
        enif_send(NULL, &P.owner, env, msg);
    }
    pthread_mutex_unlock(&P.send_lock);
    enif_free_env(env);
}

/* Stops the render thread, silences messages for the current ref, and stops
 * and closes P.out. If P.out refuses to stop within the 1 s timeout, keeps
 * P.out (the orphan), P.ref_env/P.ref, and P.synth so a retry cancel or
 * subsequent play can try stop_and_close(&P.out) again, and returns false. */
static bool stop_piano_locked(void) {
    atomic_fetch_add(&P.generation, 1);
    atomic_store(&P.playing, false);
    if (atomic_exchange(&P.run, false)) pthread_join(P.thread, NULL);
    pthread_mutex_lock(&P.send_lock);
    piano_res *monitor = P.monitor;
    P.monitor = NULL;
    P.active = false;
    pthread_mutex_unlock(&P.send_lock);
    if (monitor) enif_release_resource(monitor);
    if (!stop_and_close(&P.out)) {
        LOGE("piano output stream failed to stop: left open");
        return false;
    }
    pthread_mutex_lock(&P.send_lock);
    if (P.ref_env) {
        enif_free_env(P.ref_env);
        P.ref_env = NULL;
    }
    pthread_mutex_unlock(&P.send_lock);
    piano_synth_free(&P.synth);
    return true;
}

static void *piano_cleanup_main(void *arg) {
    (void)arg;
    for (;;) {
        pthread_mutex_lock(&PC.lock);
        while (!PC.has_request) pthread_cond_wait(&PC.cond, &PC.lock);
        uint64_t generation = PC.pending_generation;
        PC.has_request = false;
        pthread_mutex_unlock(&PC.lock);

        pthread_mutex_lock(&P.lock);
        if (generation == atomic_load(&P.generation)) {
            if (!stop_piano_locked()) LOGE("piano cleanup: output stream stuck");
        }
        pthread_mutex_unlock(&P.lock);
    }
    return NULL;
}

static bool ensure_piano_cleanup_worker_locked(void) {
    pthread_mutex_lock(&PC.lock);
    if (PC.started) {
        pthread_mutex_unlock(&PC.lock);
        return true;
    }
    pthread_t t;
    pthread_attr_t attr;
    pthread_attr_init(&attr);
    pthread_attr_setdetachstate(&attr, PTHREAD_CREATE_DETACHED);
    int err = pthread_create(&t, &attr, piano_cleanup_main, NULL);
    pthread_attr_destroy(&attr);
    if (err == 0) PC.started = true;
    pthread_mutex_unlock(&PC.lock);
    if (err != 0) LOGE("piano: failed to spawn cleanup worker");
    return err == 0;
}

static void schedule_piano_cleanup(uint64_t generation) {
    pthread_mutex_lock(&PC.lock);
    if (generation > PC.pending_generation) PC.pending_generation = generation;
    PC.has_request = true;
    pthread_cond_signal(&PC.cond);
    pthread_mutex_unlock(&PC.lock);
}

static void piano_owner_down(ErlNifEnv *env, void *obj, ErlNifPid *pid, ErlNifMonitor *mon) {
    (void)env;
    (void)pid;
    (void)mon;
    piano_res *res = obj;
    schedule_piano_cleanup(res->generation);
}

/* Real-time AAudio output callback: zero locks, zero allocations.
 * Continues zero-filling after all real frames are queued so the AAudio
 * stream stays STARTED and AAudioStream_getTimestamp keeps advancing through
 * the final hardware drain. */
static int32_t piano_out_cb(AAudioStream *s, void *user, void *data, int32_t frames) {
    (void)s;
    float *out = (float *)data;
    int ch = P.out_channels > 0 ? P.out_channels : 1;
    memset(out, 0, sizeof(float) * (size_t)frames * (size_t)ch);

    if ((uintptr_t)user != (uintptr_t)atomic_load_explicit(&P.generation, memory_order_acquire) ||
        !atomic_load_explicit(&P.playing, memory_order_acquire) ||
        atomic_load_explicit(&P.out_failed, memory_order_relaxed))
        return AA_CALLBACK_STOP;

    int64_t cb_before = atomic_load_explicit(&P.cb_total_frames, memory_order_relaxed);
    if (!atomic_load_explicit(&P.all_real_queued, memory_order_relaxed)) {
        int64_t r = atomic_load_explicit(&P.ring_read, memory_order_relaxed);
        int64_t w = atomic_load_explicit(&P.ring_write, memory_order_acquire);
        int64_t avail = w - r;
        if (avail < 0) avail = 0;
        int32_t take = avail < (int64_t)frames ? (int32_t)avail : frames;

        for (int32_t i = 0; i < take; i++) {
            float v = P.ring[(r + i) & (PIANO_RING_SIZE - 1)];
            if (ch == 1) {
                out[i] = v;
            } else {
                for (int c = 0; c < ch; c++) out[i * ch + c] = v;
            }
        }

        int64_t next_r = r + take;
        atomic_store_explicit(&P.ring_read, next_r, memory_order_release);

        /* synth_done is published after the final ring_write: re-read the write
         * position once it is seen, or frames written in between would be lost. */
        bool done = atomic_load_explicit(&P.synth_done, memory_order_acquire);
        if (done && next_r >= atomic_load_explicit(&P.ring_write, memory_order_acquire)) {
            atomic_store_explicit(&P.last_real_stream_frame, cb_before + take, memory_order_release);
            atomic_store_explicit(&P.all_real_queued, true, memory_order_release);
        } else if (take < frames) {
            int64_t u_len = (int64_t)(frames - take);
            int64_t u_r = atomic_load_explicit(&P.underrun_read, memory_order_acquire);
            int64_t u_w = atomic_load_explicit(&P.underrun_write, memory_order_relaxed);
            if (u_w - u_r < PIANO_UNDERRUN_RING_SIZE) {
                P.underrun_ring[u_w & (PIANO_UNDERRUN_RING_SIZE - 1)] = (piano_underrun_range){
                    .start = cb_before + take,
                    .len = u_len,
                };
                atomic_store_explicit(&P.underrun_write, u_w + 1, memory_order_release);
            } else {
                /* Ring full: approximate by subtracting immediately rather than blocking. */
                atomic_fetch_add_explicit(&P.underrun_overflow, u_len, memory_order_release);
            }
        }
    }

    atomic_store_explicit(&P.cb_total_frames, cb_before + frames, memory_order_release);
    return AA_CALLBACK_CONTINUE;
}

static void piano_error_cb(AAudioStream *s, void *user, aaudio_result_t err) {
    (void)s;
    LOGE("piano output stream error %d", err);
    uint64_t generation = atomic_load(&P.generation);
    if ((uintptr_t)user != (uintptr_t)generation) return;
    atomic_store(&P.out_failed, true);
    const char *reason = err == AA_ERROR_DISCONNECTED ? "device_lost" : "output_error";
    send_piano_terminal(generation, "piano_error", reason);
    schedule_piano_cleanup(generation);
}

static aaudio_result_t open_piano_output(uint64_t generation, AAudioStream **out_stream) {
    AAudioStreamBuilder *b = NULL;
    aaudio_result_t r = aa.createStreamBuilder(&b);
    if (r != AA_OK) return r;
    aa.setDirection(b, AA_DIRECTION_OUTPUT);
    aa.setChannelCount(b, 1);
    aa.setFormat(b, AA_FORMAT_PCM_FLOAT);
    aa.setSharingMode(b, AA_SHARING_SHARED);
    aa.setPerformanceMode(b, AA_PERF_NONE);
    if (aa.setUsage) aa.setUsage(b, AA_USAGE_MEDIA);
    if (aa.setContentType) aa.setContentType(b, AA_CONTENT_TYPE_MUSIC);
    aa.setDataCallback(b, piano_out_cb, (void *)(uintptr_t)generation);
    aa.setErrorCallback(b, piano_error_cb, (void *)(uintptr_t)generation);
    AAudioStream *s = NULL;
    r = aa.openStream(b, &s);
    aa.builderDelete(b);
    if (r == AA_OK) *out_stream = s;
    return r;
}

static int64_t piano_played_ms(int64_t played_frames) {
    if (played_frames <= 0 || P.out_rate <= 0) return 0;
    int64_t cap = (int64_t)llround(P.phrase_end_ms);
    if (cap < 0) cap = 0;
    if (played_frames >= P.phrase_end_frames) return cap;
    int64_t ms = (int64_t)llround((double)played_frames * 1000.0 / (double)P.out_rate);
    if (ms < 0) ms = 0;
    if (ms > cap) ms = cap;
    return ms;
}

static void *piano_main(void *arg) {
    uint64_t generation = (uint64_t)(uintptr_t)arg;
    const int32_t block_cap = 512;
    float block[512];
    int64_t start_ns = now_ns();
    int64_t last_pos_ns = 0;
    int64_t last_presented_synth = 0;
    int64_t last_stream_pos = 0;
    int64_t settled_underrun = 0;
    bool ts_seen = false;
    int64_t prev_ts_pos = -1;
    int64_t prev_ts_ns = 0;
    int64_t last_ts_change_ns = 0;
    int64_t measured_hal_lag_frames = 0;
    int64_t ep_drained_at_ns = 0;
    int64_t ep_drained_extra = 0;

    while (atomic_load(&P.run)) {
        if (atomic_load(&P.out_failed)) break;

        if (!atomic_load_explicit(&P.synth_done, memory_order_relaxed)) {
            int64_t r = atomic_load_explicit(&P.ring_read, memory_order_acquire);
            int64_t w = atomic_load_explicit(&P.ring_write, memory_order_relaxed);
            while ((w - r) + block_cap <= PIANO_RING_SIZE) {
                int32_t got = piano_synth_render_block(&P.synth, &P.bank, block, block_cap);
                if (got <= 0) {
                    atomic_store_explicit(&P.synth_done, true, memory_order_release);
                    break;
                }
                for (int32_t i = 0; i < got; i++) P.ring[(w + i) & (PIANO_RING_SIZE - 1)] = block[i];
                w += got;
                atomic_store_explicit(&P.ring_write, w, memory_order_release);
                if (P.synth.cursor_frame >= P.total_frames) {
                    atomic_store_explicit(&P.synth_done, true, memory_order_release);
                    break;
                }
            }
        }

        int64_t now = now_ns();
        int64_t cb_total = atomic_load_explicit(&P.cb_total_frames, memory_order_acquire);
        int64_t queued_real = atomic_load_explicit(&P.ring_read, memory_order_acquire);

        int64_t ts_pos = -1, ts_ns = 0;
        aaudio_result_t ts_res = aa.getTimestamp(P.out, CLOCK_MONOTONIC, &ts_pos, &ts_ns);
        int64_t ep_read = aa.getFramesRead(P.out);

        bool ts_fresh = false;
        int64_t stream_pos = last_stream_pos;
        if (ts_res == AA_OK && ts_pos >= 0 && ts_ns > 0) {
            if (ts_pos != prev_ts_pos || ts_ns != prev_ts_ns) {
                prev_ts_pos = ts_pos;
                prev_ts_ns = ts_ns;
                last_ts_change_ns = now;
            }
            ts_fresh = (now - last_ts_change_ns) < PIANO_NO_TS_GRACE_NS;
            int64_t dt_ns = now - ts_ns;
            if (dt_ns > PIANO_MAX_TS_EXTRAPOLATE_NS) dt_ns = PIANO_MAX_TS_EXTRAPOLATE_NS;
            if (dt_ns < -PIANO_MAX_TS_EXTRAPOLATE_NS) dt_ns = -PIANO_MAX_TS_EXTRAPOLATE_NS;
            int64_t cand = ts_pos + (int64_t)llround((double)dt_ns * (double)P.out_rate / 1e9);
            if (cand < 0) cand = 0;
            if (cand > cb_total) cand = cb_total;
            if (cand > stream_pos) stream_pos = cand;
            last_stream_pos = stream_pos;
            ts_seen = true;
            if (ep_read > ts_pos) {
                int64_t lag = ep_read - ts_pos;
                if (lag > measured_hal_lag_frames && lag < (int64_t)P.out_rate * 2)
                    measured_hal_lag_frames = lag;
            }
        } else if (!ts_seen && (now - start_ns) >= PIANO_NO_TS_GRACE_NS && ep_read > 0) {
            /* Device/route never yielded getTimestamp: stay conservative behind
             * endpoint framesRead without fabricating wall-clock time. */
            int64_t margin = P.out_burst > 0 ? (int64_t)P.out_burst * 2 : (int64_t)P.out_rate / 25;
            int64_t cand = ep_read > margin ? ep_read - margin : 0;
            if (cand > cb_total) cand = cb_total;
            if (cand > stream_pos) stream_pos = cand;
            last_stream_pos = stream_pos;
        }

        /* Subtract only the underrun frames that have actually reached the
         * presented stream_pos so a buffered underrun never stalls the playhead
         * early. */
        int64_t u_r = atomic_load_explicit(&P.underrun_read, memory_order_relaxed);
        int64_t u_w = atomic_load_explicit(&P.underrun_write, memory_order_acquire);
        int64_t partial_underrun = 0;
        while (u_r < u_w) {
            piano_underrun_range ur = P.underrun_ring[u_r & (PIANO_UNDERRUN_RING_SIZE - 1)];
            if (ur.start + ur.len <= stream_pos) {
                settled_underrun += ur.len;
                u_r++;
                atomic_store_explicit(&P.underrun_read, u_r, memory_order_release);
            } else {
                if (ur.start < stream_pos) partial_underrun = stream_pos - ur.start;
                break;
            }
        }
        int64_t overflow_underrun = atomic_load_explicit(&P.underrun_overflow, memory_order_acquire);
        int64_t synth_cand = stream_pos - settled_underrun - partial_underrun - overflow_underrun;
        if (synth_cand < 0) synth_cand = 0;
        if (synth_cand > queued_real) synth_cand = queued_real;
        if (synth_cand > last_presented_synth) last_presented_synth = synth_cand;

        if (last_pos_ns == 0 || now - last_pos_ns >= PIANO_POS_INTERVAL_NS) {
            int64_t pos_ms = piano_played_ms(last_presented_synth);
            if (pos_ms < P.last_sent_pos_ms) pos_ms = P.last_sent_pos_ms;
            if (pos_ms > P.last_sent_pos_ms || last_pos_ns == 0) {
                P.last_sent_pos_ms = pos_ms;
                last_pos_ns = now;
                send_piano_position(generation, pos_ms);
            }
        }

        if (atomic_load_explicit(&P.all_real_queued, memory_order_acquire)) {
            int64_t last_real = atomic_load_explicit(&P.last_real_stream_frame, memory_order_acquire);
            bool finished = ts_fresh && stream_pos >= last_real;

            if (ts_fresh) ep_drained_at_ns = 0;

            if (!finished && ep_read >= last_real && !ts_fresh) {
                /* Wait for hardware endpoint + measured HAL/buffer tail to finish
                 * presenting when getTimestamp is unavailable or stops advancing. */
                if (ep_drained_at_ns == 0) {
                    ep_drained_at_ns = now;
                    ep_drained_extra = ep_read - last_real;
                }
                int64_t tail_frames = measured_hal_lag_frames > 0
                                          ? measured_hal_lag_frames
                                          : (P.out_buffer_frames > 0 ? P.out_buffer_frames : P.out_burst * 2);
                int64_t rem_tail = tail_frames > ep_drained_extra ? tail_frames - ep_drained_extra : 0;
                int64_t tail_ns = P.out_rate > 0 ? (int64_t)llround((double)rem_tail * 1e9 / (double)P.out_rate)
                                                 : 100000000LL;
                if (now - ep_drained_at_ns >= tail_ns) finished = true;
            }

            if (finished && atomic_load(&P.run) && !atomic_load(&P.out_failed)) {
                int64_t end_ms = piano_played_ms(P.total_frames);
                if (end_ms > P.last_sent_pos_ms && now_ns() - last_pos_ns >= PIANO_POS_INTERVAL_NS) {
                    P.last_sent_pos_ms = end_ms;
                    send_piano_position(generation, end_ms);
                }
                send_piano_terminal(generation, "piano_finished", NULL);
                schedule_piano_cleanup(generation);
                break;
            }
        }

        usleep(2000);
    }

    return NULL;
}

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

        if (!enif_get_map_value(env, head, k_start, &v_start) ||
            !enif_get_map_value(env, head, k_dur, &v_dur) ||
            !enif_get_map_value(env, head, k_midi, &v_midi) ||
            !get_erlang_number(env, v_start, &start_ms) ||
            !get_erlang_number(env, v_dur, &dur_ms) ||
            !enif_get_int(env, v_midi, &midi) ||
            start_ms < 0.0 || dur_ms <= 0.0 || midi < 0 || midi > 127) {
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

/* play_piano(Owner, Ref, Notes, SamplesDir) -> ok | {error, Reason}. Dirty IO. */
static ERL_NIF_TERM nif_play_piano(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
    (void)argc;
    ErlNifPid owner;
    ErlNifBinary dir_bin;
    if (!enif_get_local_pid(env, argv[0], &owner) || !enif_is_ref(env, argv[1]) ||
        !enif_is_list(env, argv[2]) || !enif_inspect_binary(env, argv[3], &dir_bin) ||
        dir_bin.size == 0 || dir_bin.size >= 900 || memchr(dir_bin.data, 0, dir_bin.size))
        return enif_make_badarg(env);

    piano_raw_note *raw = NULL;
    int32_t note_count = 0;
    double max_end_ms = 0.0;
    const char *err_reason = NULL;
    bool badarg = false;
    if (!parse_piano_notes(env, argv[2], &raw, &note_count, &max_end_ms, &err_reason, &badarg)) {
        if (badarg) return enif_make_badarg(env);
        return error_tuple(env, err_reason ? err_reason : "invalid_notes");
    }

    if (!libs_ok) {
        free(raw);
        return error_tuple(env, "unsupported");
    }

    char dir[901];
    memcpy(dir, dir_bin.data, dir_bin.size);
    dir[dir_bin.size] = '\0';

    pthread_mutex_lock(&P.lock);
    if (!stop_piano_locked()) {
        pthread_mutex_unlock(&P.lock);
        free(raw);
        return error_tuple(env, "stream_stuck");
    }

    if (!load_piano_bank_locked(dir)) {
        pthread_mutex_unlock(&P.lock);
        free(raw);
        return error_tuple(env, "samples_unavailable");
    }

    if (!ensure_piano_cleanup_worker_locked()) {
        pthread_mutex_unlock(&P.lock);
        free(raw);
        return error_tuple(env, "thread");
    }

    piano_res *res = enif_alloc_resource(piano_watch_type, sizeof(piano_res));
    if (!res) {
        pthread_mutex_unlock(&P.lock);
        free(raw);
        return error_tuple(env, "alloc");
    }

    uint64_t generation = atomic_fetch_add(&P.generation, 1) + 1;
    res->generation = generation;

    AAudioStream *out_stream = NULL;
    if (open_piano_output(generation, &out_stream) != AA_OK || !out_stream) {
        enif_release_resource(res);
        pthread_mutex_unlock(&P.lock);
        free(raw);
        return error_tuple(env, "output_unavailable");
    }

    int out_rate = aa.getSampleRate(out_stream);
    int out_channels = aa.getChannelCount(out_stream);
    int out_burst = aa.getFramesPerBurst(out_stream);
    if (out_rate <= 0 || out_channels < 1) {
        stop_and_close(&out_stream);
        enif_release_resource(res);
        pthread_mutex_unlock(&P.lock);
        free(raw);
        return error_tuple(env, "output_unavailable");
    }

    piano_note *notes = calloc((size_t)note_count, sizeof(piano_note));
    if (!notes) {
        stop_and_close(&out_stream);
        enif_release_resource(res);
        pthread_mutex_unlock(&P.lock);
        free(raw);
        return error_tuple(env, "alloc");
    }

    int64_t max_frames = piano_ms_to_frames((double)PIANO_MAX_DURATION_MS, out_rate);
    for (int32_t i = 0; i < note_count; i++) {
        int64_t sf = piano_ms_to_frames(raw[i].start_ms, out_rate);
        int64_t rf = piano_ms_to_frames(raw[i].start_ms + raw[i].dur_ms, out_rate);
        if (rf <= sf) rf = sf + 1;
        if (rf > max_frames) rf = max_frames;
        notes[i] = (piano_note){
            .start_frame = sf,
            .release_frame = rf,
            .midi = raw[i].midi,
            .gain = raw[i].gain,
        };
    }
    free(raw);

    if (piano_synth_init(&P.synth, &P.bank, notes, note_count, out_rate) != 0) {
        free(notes);
        stop_and_close(&out_stream);
        enif_release_resource(res);
        pthread_mutex_unlock(&P.lock);
        return error_tuple(env, "invalid_notes");
    }
    free(notes);

    P.out = out_stream;
    P.out_rate = out_rate;
    P.out_channels = out_channels;
    P.out_burst = out_burst;
    P.out_buffer_frames = aa.getBufferSizeInFrames(out_stream);
    atomic_store(&P.ring_write, 0);
    atomic_store(&P.ring_read, 0);
    atomic_store(&P.cb_total_frames, 0);
    atomic_store(&P.underrun_write, 0);
    atomic_store(&P.underrun_read, 0);
    atomic_store(&P.underrun_overflow, 0);
    atomic_store(&P.last_real_stream_frame, 0);
    atomic_store(&P.out_failed, false);
    atomic_store(&P.synth_done, false);
    atomic_store(&P.all_real_queued, false);
    P.total_frames = P.synth.total_frames;
    P.phrase_end_frames = P.synth.phrase_end_frame;
    P.phrase_end_ms = max_end_ms;
    P.last_sent_pos_ms = -1;

    /* Pre-fill up to half the ring before starting AAudio so the first
     * callback never underruns. */
    int64_t target_prefill = PIANO_RING_SIZE / 2;
    if (P.total_frames < target_prefill) target_prefill = P.total_frames;
    float prefill[512];
    int64_t w = 0;
    while (w < target_prefill) {
        int32_t chunk = target_prefill - w < 512 ? (int32_t)(target_prefill - w) : 512;
        int32_t got = piano_synth_render_block(&P.synth, &P.bank, prefill, chunk);
        if (got <= 0) {
            atomic_store(&P.synth_done, true);
            break;
        }
        for (int32_t i = 0; i < got; i++) P.ring[(w + i) & (PIANO_RING_SIZE - 1)] = prefill[i];
        w += got;
    }
    if (P.synth.cursor_frame >= P.total_frames) atomic_store(&P.synth_done, true);
    atomic_store(&P.ring_write, w);

    if (enif_monitor_process(env, res, &owner, NULL) != 0) {
        enif_release_resource(res);
        stop_and_close(&P.out);
        piano_synth_free(&P.synth);
        pthread_mutex_unlock(&P.lock);
        return error_tuple(env, "owner_dead");
    }

    pthread_mutex_lock(&P.send_lock);
    P.owner = owner;
    P.ref_env = enif_alloc_env();
    P.ref = enif_make_copy(P.ref_env, argv[1]);
    P.monitor = res;
    P.active = true;
    pthread_mutex_unlock(&P.send_lock);

    const char *failure = NULL;
    atomic_store(&P.playing, true);
    atomic_store(&P.run, true);
    if (pthread_create(&P.thread, NULL, piano_main, (void *)(uintptr_t)generation) != 0) {
        atomic_store(&P.run, false);
        failure = "thread";
    } else if (aa.requestStart(P.out) != AA_OK) {
        LOGE("piano output start failed");
        failure = "output_unavailable";
    }
    if (failure) (void)stop_piano_locked();
    pthread_mutex_unlock(&P.lock);
    return failure ? error_tuple(env, failure) : atom(env, "ok");
}

/* cancel_piano(Ref) -> ok | {error, stream_stuck}. Idempotent; stops the
 * render thread, prevents any further messages for Ref, and stops and closes
 * the AAudio output stream. Returns {error, stream_stuck} if the stream could
 * not be stopped within the timeout (keeping the orphan for retry). Unknown
 * Ref returns ok. Dirty IO. */
static ERL_NIF_TERM nif_cancel_piano(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
    (void)argc;
    if (!enif_is_ref(env, argv[0])) return enif_make_badarg(env);
    bool ok = true;
    pthread_mutex_lock(&P.lock);
    pthread_mutex_lock(&P.send_lock);
    bool mine = P.ref_env != NULL && enif_compare(P.ref, argv[0]) == 0;
    pthread_mutex_unlock(&P.send_lock);
    if (mine) ok = stop_piano_locked();
    pthread_mutex_unlock(&P.lock);
    return ok ? atom(env, "ok") : error_tuple(env, "stream_stuck");
}

static int on_load(ErlNifEnv *env, void **priv, ERL_NIF_TERM info) {
    (void)priv;
    (void)info;
    pthread_mutex_init(&E.lock, NULL);
    pthread_mutex_init(&E.send_lock, NULL);
    pthread_mutex_init(&FJ.lock, NULL);
    pthread_mutex_init(&P.lock, NULL);
    pthread_mutex_init(&P.send_lock, NULL);
    pthread_mutex_init(&PC.lock, NULL);
    pthread_cond_init(&PC.cond, NULL);
    atomic_store(&E.first_ns, -1);
    atomic_store(&E.preset, AA_PRESET_VOICE_PERFORMANCE);
    ErlNifResourceTypeInit init = {.dtor = NULL, .stop = NULL, .down = listener_down, .members = 3};
    listener_type = enif_init_resource_type(env, "hum_audio_listener", &init, ERL_NIF_RT_CREATE, NULL);
    if (!listener_type) return 1;
    ErlNifResourceTypeInit fj_init = {.dtor = NULL, .stop = NULL, .down = analysis_owner_down, .members = 3};
    analysis_watch_type = enif_init_resource_type(env, "hum_audio_analysis", &fj_init, ERL_NIF_RT_CREATE, NULL);
    if (!analysis_watch_type) return 1;
    ErlNifResourceTypeInit p_init = {.dtor = NULL, .stop = NULL, .down = piano_owner_down, .members = 3};
    piano_watch_type = enif_init_resource_type(env, "hum_audio_piano", &p_init, ERL_NIF_RT_CREATE, NULL);
    if (!piano_watch_type) return 1;
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
    {"info", 0, nif_info, ERL_NIF_DIRTY_JOB_IO_BOUND},
    {"set_input_preset", 1, nif_set_input_preset, 0},
    {"play_piano", 4, nif_play_piano, ERL_NIF_DIRTY_JOB_IO_BOUND},
    {"cancel_piano", 1, nif_cancel_piano, ERL_NIF_DIRTY_JOB_IO_BOUND},
};

ERL_NIF_INIT(Elixir.Humdinger.Audio.Nif, nif_funcs, on_load, NULL, NULL, NULL)
