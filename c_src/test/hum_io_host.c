/*
 * Host checks for c_src/hum_io.c, Humdinger's mob_audio_io processors: the
 * callbacks are driven the way the plugin drives them (stream_event, then
 * capture/render blocks with their mai_time), with a scripted clock.
 *
 *   cc -std=c11 -O1 -g -Wall -Wextra -Werror -fsanitize=address,undefined \
 *      -I deps/mob_audio_io/priv/include -o /tmp/hum_io_host c_src/test/hum_io_host.c -lm -lpthread
 *   /tmp/hum_io_host priv/piano
 *
 * Exit 0 when every check holds, 1 otherwise (each failure is printed).
 */

#include <math.h>
#include <stdio.h>

#include "../hum_io.c"

/* The plugin's clock, scripted: the processors only call it from hum_audio.c,
 * but the header declares it and the progress checks pass `now` explicitly. */
static int64_t fake_now;
int64_t mai_now_ns(void) { return fake_now; }

static int failures;

#define CHECK(cond, ...)                                              \
    do {                                                              \
        if (!(cond)) {                                                \
            failures++;                                               \
            fprintf(stderr, "%s:%d: %s: ", __FILE__, __LINE__, #cond); \
            fprintf(stderr, __VA_ARGS__);                             \
            fprintf(stderr, "\n");                                    \
        }                                                             \
    } while (0)

#define MS 1000000LL
#define S 1000000000LL

static mai_time at(int64_t frame, int64_t host_ns, int64_t present_ns, int32_t rate, int32_t channels) {
    return (mai_time){.frame = frame, .host_ns = host_ns, .present_ns = present_ns, .rate = rate, .channels = channels};
}

/* ── hum_mic ───────────────────────────────────────────────────────────── */

static hum_mic mic;

static void check_mic(void) {
    float block[2 * 192];
    for (int i = 0; i < 192; i++) block[i] = (float)i / 192.0f;

    hum_mic_reset(&mic);
    mai_time t = at(0, 0, 0, 48000, 1);
    hum_mic_event(&mic, 1, MAI_EVENT_STARTED, &t);
    CHECK(atomic_load(&mic.open) == 1, "open %d", atomic_load(&mic.open));
    CHECK(atomic_load(&mic.rate) == 48000, "rate %d", atomic_load(&mic.rate));

    /* Not capturing yet: nothing lands in the ring. */
    t = at(0, 1 * S, 0, 48000, 1);
    hum_mic_capture(&mic, block, 192, &t);
    CHECK(atomic_load(&mic.written) == 0, "written %lld before capturing", (long long)atomic_load(&mic.written));

    atomic_store(&mic.capturing, true);
    t = at(192, 2 * S, 0, 48000, 1);
    hum_mic_capture(&mic, block, 192, &t);
    int64_t bi, bn;
    CHECK(atomic_load(&mic.written) == 192, "written %lld", (long long)atomic_load(&mic.written));
    CHECK(hum_pair_read(&mic.base, &bi, &bn), "no stretch after the first block");
    /* The block's first sample: a block (4 ms at 48 kHz) before the callback. */
    CHECK(bi == 0 && bn == 2 * S - 4 * MS, "stretch (%lld, %lld)", (long long)bi, (long long)bn);
    CHECK(mic.ring[100] == block[100], "ring[100] %f", mic.ring[100]);
    CHECK(atomic_load(&mic.arrivals_n) == 1 && atomic_load(&mic.arrivals[0].end) == 192 &&
              atomic_load(&mic.arrivals[0].ns) == 2 * S,
          "arrival (%lld, %lld)", (long long)atomic_load(&mic.arrivals[0].end),
          (long long)atomic_load(&mic.arrivals[0].ns));

    /* The next block continues the stretch. */
    t = at(384, 2 * S + 4 * MS, 0, 48000, 1);
    hum_mic_capture(&mic, block, 192, &t);
    CHECK(hum_pair_read(&mic.base, &bi, &bn) && bi == 0, "stretch moved to %lld", (long long)bi);
    CHECK(atomic_load(&mic.callbacks) == 2 && atomic_load(&mic.last_frames) == 192, "callbacks %lld",
          (long long)atomic_load(&mic.callbacks));

    /* A reopen (STOPPED, STARTED at 44.1 kHz, stereo): a new stretch at the
     * ring's end, the input folded to mono. */
    hum_mic_event(&mic, 1, MAI_EVENT_STOPPED, &t);
    t = at(576, 0, 0, 44100, 2);
    hum_mic_event(&mic, 1, MAI_EVENT_STARTED, &t);
    CHECK(atomic_load(&mic.open) == 1 && atomic_load(&mic.rate) == 44100, "after reopen: open %d rate %d",
          atomic_load(&mic.open), atomic_load(&mic.rate));
    for (int i = 0; i < 147; i++) {
        block[2 * i] = 0.5f;
        block[2 * i + 1] = -0.25f;
    }
    t = at(576, 5 * S, 0, 44100, 2);
    hum_mic_capture(&mic, block, 147, &t);
    CHECK(hum_pair_read(&mic.base, &bi, &bn) && bi == 384 && bn == 5 * S - 147 * S / 44100,
          "new stretch (%lld, %lld)", (long long)bi, (long long)bn);
    CHECK(fabsf(mic.ring[384] - 0.125f) < 1e-6f, "stereo fold %f", mic.ring[384]);
    CHECK(atomic_load(&mic.written) == 384 + 147, "written %lld", (long long)atomic_load(&mic.written));

    /* A new listening empties it; the next block starts the first stretch. */
    hum_mic_event(&mic, 1, MAI_EVENT_STOPPED, &t);
    hum_mic_reset(&mic);
    CHECK(!hum_pair_read(&mic.base, &bi, &bn) && atomic_load(&mic.written) == 0, "reset left a stretch");
    atomic_store(&mic.capturing, true);
    t = at(0, 9 * S, 0, 48000, 1);
    hum_mic_capture(&mic, block, 96, &t);
    CHECK(hum_pair_read(&mic.base, &bi, &bn) && bi == 0 && bn == 9 * S - 2 * MS, "first stretch (%lld, %lld)",
          (long long)bi, (long long)bn);
}

/* ── hum_piano ─────────────────────────────────────────────────────────── */

static hum_piano piano = {.lock = PTHREAD_MUTEX_INITIALIZER};

static piano_raw_note *notes(int n, double start_ms, double dur_ms, int midi) {
    piano_raw_note *raw = calloc((size_t)n, sizeof(piano_raw_note));
    for (int i = 0; i < n; i++)
        raw[i] = (piano_raw_note){.start_ms = start_ms + i * dur_ms, .dur_ms = dur_ms, .midi = midi, .gain = 0.8f};
    return raw;
}

static hum_piano_state progress(int64_t now, int64_t *ms, int64_t *finish_in) {
    const char *why;
    return hum_piano_progress(&piano, now, ms, finish_in, &why);
}

static void check_piano(const char *dir) {
    int64_t ms, finish_in;
    const char *why;

    CHECK(strcmp(hum_piano_prepare(&piano, "/nonexistent", notes(1, 0, 100, 60), 1, 100), "samples_unavailable") == 0,
          "a missing bank");
    const char *err = hum_piano_prepare(&piano, dir, notes(1, 0, 100, 200), 1, 100);
    CHECK(err && strcmp(err, "invalid_notes") == 0, "a note past MIDI 127: %s", err ? err : "accepted");

    /* Two 250 ms A4s: the phrase ends at 500 ms, the release tail later. */
    CHECK(hum_piano_prepare(&piano, dir, notes(2, 0, 250, 69), 2, 500) == NULL, "prepare");
    CHECK(progress(0, &ms, &finish_in) == HUM_PIANO_IDLE, "playing before any stream started");

    mai_time t = at(0, 0, 0, 48000, 1);
    hum_piano_event(&piano, 1, MAI_EVENT_STARTED, &t);
    CHECK(atomic_load(&piano.armed), "STARTED didn't arm");
    CHECK(piano.phrase_end_frames == 24000, "phrase end %lld", (long long)piano.phrase_end_frames);
    CHECK(piano.total_frames > 24000, "total %lld", (long long)piano.total_frames);
    CHECK(strcmp(hum_piano_prepare(&piano, dir, notes(1, 0, 100, 60), 1, 100), "busy") == 0,
          "prepared under a running stream");
    CHECK(progress(0, &ms, &finish_in) == HUM_PIANO_PLAYING && ms == 0, "before the first block: %lld", (long long)ms);

    /* 192-frame blocks every 4 ms, each heard 10 ms after its callback. */
    float out[192];
    double energy = 0.0;
    int64_t host = 1 * S, last_ms = -1, end_at = -1;
    bool monotonic = true, finished = false;
    for (int b = 0; b < 2000 && !atomic_load(&piano.done); b++) {
        t = at((int64_t)b * 192, host, host + 10 * MS, 48000, 1);
        memset(out, 0, sizeof(out));
        hum_piano_render(&piano, out, 192, &t);
        for (int i = 0; i < 192; i++) energy += (double)out[i] * out[i];
        if (atomic_load(&piano.done) && end_at < 0) {
            int64_t f, a;
            hum_pair_read(&piano.anchor, &f, &a);
            end_at = a + (piano.total_frames - f) * S / 48000;
        }
        /* The playhead at the middle of the block's period. */
        hum_piano_state st = progress(host + 2 * MS, &ms, &finish_in);
        if (ms < last_ms) monotonic = false;
        last_ms = ms;
        if (b == 50) {
            /* Block 50's callback at 1.2 s: what has been heard by 1.202 s
             * is the audio of blocks whose sound began 10 ms before. */
            int64_t want = llround(((double)(host + 2 * MS - (1 * S + 10 * MS)) / S) * 1000.0);
            CHECK(llabs(ms - want) <= 1, "playhead %lld ms, want %lld", (long long)ms, (long long)want);
        }
        if (st == HUM_PIANO_FINISHED) finished = true;
        host += 4 * MS;
    }
    CHECK(energy > 1.0, "the phrase was silent (energy %f)", energy);
    CHECK(monotonic, "the playhead went back");
    CHECK(atomic_load(&piano.rendered) == piano.total_frames, "rendered %lld of %lld",
          (long long)atomic_load(&piano.rendered), (long long)piano.total_frames);
    CHECK(!finished, "finished while its end was still in the buffer (last block at %lld ns)", (long long)host);
    /* Done, not yet heard: the end in a little, then finished on the dot. */
    hum_piano_state st = progress(end_at - 3 * MS, &ms, &finish_in);
    CHECK(st == HUM_PIANO_PLAYING && finish_in == 3 * MS && ms == 500, "before the end: state %d, in %lld, ms %lld",
          st, (long long)finish_in, (long long)ms);
    CHECK(progress(end_at, &ms, &finish_in) == HUM_PIANO_FINISHED && ms == 500, "at the end: ms %lld",
          (long long)ms);
    /* Further callbacks play silence. */
    memset(out, 0, sizeof(out));
    t = at(0, host, host + 10 * MS, 48000, 1);
    out[0] = 0.0f;
    hum_piano_render(&piano, out, 192, &t);
    float peak = 0.0f;
    for (int i = 0; i < 192; i++) peak = fmaxf(peak, fabsf(out[i]));
    CHECK(peak == 0.0f, "sound after the end: %f", peak);
    hum_piano_event(&piano, 1, MAI_EVENT_STOPPED, &t);

    /* Stereo, at 44.1 kHz, with no presentation time yet (Android 12+'s
     * first callbacks): both channels alike, heard about two blocks on. */
    CHECK(hum_piano_prepare(&piano, dir, notes(1, 0, 200, 60), 1, 200) == NULL, "prepare stereo");
    t = at(0, 0, 0, 44100, 2);
    hum_piano_event(&piano, 2, MAI_EVENT_STARTED, &t);
    float st_out[2 * 441];
    memset(st_out, 0, sizeof(st_out));
    t = at(0, 1 * S, 0, 44100, 2);
    hum_piano_render(&piano, st_out, 441, &t);
    bool alike = true;
    double st_energy = 0.0;
    for (int i = 0; i < 441; i++) {
        if (st_out[2 * i] != st_out[2 * i + 1]) alike = false;
        st_energy += (double)st_out[2 * i] * st_out[2 * i];
    }
    CHECK(alike && st_energy > 0.0, "stereo: alike %d, energy %f", alike, st_energy);
    int64_t f, a;
    CHECK(hum_pair_read(&piano.anchor, &f, &a) && f == 0 && a == 1 * S + 20 * MS, "estimated anchor (%lld, %lld)",
          (long long)f, (long long)a);
    CHECK(progress(1 * S, &ms, &finish_in) == HUM_PIANO_PLAYING && ms == 0, "heard early: %lld", (long long)ms);
    CHECK(progress(1 * S + 30 * MS, &ms, &finish_in) == HUM_PIANO_PLAYING && ms == 10, "playhead %lld",
          (long long)ms);

    /* A reopen at the same rate goes on; at another rate it can't. */
    hum_piano_event(&piano, 2, MAI_EVENT_STOPPED, &t);
    t = at(441, 0, 0, 44100, 2);
    hum_piano_event(&piano, 2, MAI_EVENT_STARTED, &t);
    CHECK(atomic_load(&piano.armed) && atomic_load(&piano.rendered) == 441, "reopen lost the place");
    hum_piano_event(&piano, 2, MAI_EVENT_STOPPED, &t);
    t = at(882, 0, 0, 48000, 2);
    hum_piano_event(&piano, 2, MAI_EVENT_STARTED, &t);
    CHECK(hum_piano_progress(&piano, 2 * S, &ms, &finish_in, &why) == HUM_PIANO_FAILED && strcmp(why, "output_error") == 0,
          "a reopen at a new rate went on");
    memset(st_out, 0, sizeof(st_out));
    hum_piano_render(&piano, st_out, 441, &t);
    CHECK(st_out[0] == 0.0f && st_out[100] == 0.0f, "sound after failing");
    hum_piano_event(&piano, 2, MAI_EVENT_STOPPED, &t);
    CHECK(atomic_load(&piano.open) == 0, "open %d", atomic_load(&piano.open));

    /* The next prepare clears the failure. */
    CHECK(hum_piano_prepare(&piano, dir, notes(1, 0, 100, 60), 1, 100) == NULL, "prepare after a failure");
    CHECK(progress(0, &ms, &finish_in) == HUM_PIANO_IDLE, "still failed");

    free(piano.raw);
    piano_synth_free(&piano.synth);
    hum_free_samples(piano.bank.samples, piano.bank.count);
}

int main(int argc, char **argv) {
    if (argc != 2) {
        fprintf(stderr, "usage: %s <piano samples dir (priv/piano)>\n", argv[0]);
        return 2;
    }
    check_mic();
    check_piano(argv[1]);
    if (failures) {
        fprintf(stderr, "%d check(s) failed\n", failures);
        return 1;
    }
    printf("hum_io: all checks passed\n");
    return 0;
}
