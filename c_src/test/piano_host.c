/*
 * Host harness for c_src/piano.c: renders a scripted bank and voices or notes
 * and writes the 16-bit little-endian mono result to stdout.
 * test/humdinger/piano_render_test.exs compiles this harness with
 * `cc -O2 -o <exe> c_src/test/piano_host.c -lm` and drives it through `stream`
 * (held note outlasting its sample, negative onset rejection with exit 4,
 * 48 kHz resampling leading silence and pitch, and the 32-voice polyphony cap).
 *
 *   cc -O2 -o /tmp/piano_host c_src/test/piano_host.c -lm
 *   printf 'bank 22050\nsample dc 1000 0.5\nvoice 0 100 600 1.0 1.0\nrender 2000\n' | /tmp/piano_host > out.s16
 *
 * Script commands (`render`, `time`, or `stream` terminates the script):
 *
 *   bank RATE                           bank sample rate (default: 22050)
 *   out_rate RATE                       output rate for subsequent `note`s and `stream` (default: bank rate)
 *   sample dc FRAMES VALUE              constant VALUE (-1..1)
 *   sample sine FRAMES PERIOD AMP       sine wave PERIOD source frames per cycle
 *   sample file PATH                    raw s16le mono from PATH
 *   root MIDI                           set root_midi of last added sample
 *   voice SAMPLE START RELEASE STEP GAIN
 *   note START_MS DUR_MS MIDI VEL       add a note for `stream`
 *   render FRAMES                       one-shot render of `voice`s to stdout
 *   time FRAMES REPEAT                  print mean ms over REPEAT renders (stdout, text)
 *   stream BLOCK_FRAMES                 stream `note`s via piano_synth_render_block
 *
 * Exit codes: 0 ok, 2 parse/argument error, 3 allocation/file failure,
 * 4 piano_synth_init rejected the notes in `stream`.
 */

#include <stdbool.h>
#include <stdio.h>
#include <time.h>

#include "../piano.c"

#define MAX_SAMPLES 64
#define MAX_VOICES 4096
#define MAX_STREAM_BLOCK 4096

static int16_t *read_file(const char *path, int64_t *frames) {
    FILE *f = fopen(path, "rb");
    if (!f) return NULL;
    fseek(f, 0, SEEK_END);
    long size = ftell(f);
    fseek(f, 0, SEEK_SET);
    int16_t *pcm = malloc((size_t)size + 2);
    *frames = (int64_t)(size / 2);
    if (pcm && fread(pcm, 2, (size_t)*frames, f) != (size_t)*frames) *frames = 0;
    fclose(f);
    return pcm;
}

static int16_t *synth(const char *kind, int64_t frames, double a, double b) {
    int16_t *pcm = malloc(sizeof(int16_t) * (size_t)frames);
    if (!pcm) return NULL;
    for (int64_t i = 0; i < frames; i++) {
        double x = strcmp(kind, "dc") == 0 ? a : b * sin(2.0 * M_PI * (double)i / a);
        pcm[i] = (int16_t)lrint(x * 32767.0);
    }
    return pcm;
}

static double now_ms(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (double)ts.tv_sec * 1000.0 + (double)ts.tv_nsec / 1e6;
}

int main(void) {
    piano_sample samples[MAX_SAMPLES];
    static piano_voice voices[MAX_VOICES];
    static piano_note notes[PIANO_MAX_NOTES];
    piano_bank bank = {.rate = 22050, .count = 0, .samples = samples};
    int n = 0;
    int note_n = 0;
    int out_rate = 0;
    char cmd[32];

    while (scanf("%31s", cmd) == 1) {
        if (strcmp(cmd, "bank") == 0) {
            if (scanf("%d", &bank.rate) != 1) return 2;
        } else if (strcmp(cmd, "out_rate") == 0) {
            if (scanf("%d", &out_rate) != 1 || out_rate <= 0) return 2;
        } else if (strcmp(cmd, "sample") == 0) {
            char kind[16], path[1024];
            int64_t frames = 0;
            int16_t *pcm = NULL;
            if (scanf("%15s", kind) != 1 || bank.count == MAX_SAMPLES) return 2;
            if (strcmp(kind, "file") == 0) {
                if (scanf("%1023s", path) != 1) return 2;
                pcm = read_file(path, &frames);
            } else {
                double a = 0, b = 0;
                long long fr = 0;
                if (scanf("%lld %lf", &fr, &a) != 2) return 2;
                if (strcmp(kind, "sine") == 0 && scanf("%lf", &b) != 1) return 2;
                frames = fr;
                pcm = synth(kind, frames, a, b);
            }
            if (!pcm) return 3;
            samples[bank.count++] = (piano_sample){.pcm = pcm, .frames = frames, .root_midi = -1};
        } else if (strcmp(cmd, "root") == 0) {
            int root_midi = 0;
            if (bank.count == 0 || scanf("%d", &root_midi) != 1) return 2;
            samples[bank.count - 1].root_midi = root_midi;
        } else if (strcmp(cmd, "voice") == 0) {
            long long start, release;
            piano_voice *v = &voices[n];
            if (n == MAX_VOICES || scanf("%d %lld %lld %lf %f", &v->sample, &start, &release, &v->step, &v->gain) != 5)
                return 2;
            v->start = start;
            v->release = release;
            n++;
        } else if (strcmp(cmd, "note") == 0) {
            double start_ms, dur_ms;
            int midi, vel;
            if (note_n >= PIANO_MAX_NOTES || scanf("%lf %lf %d %d", &start_ms, &dur_ms, &midi, &vel) != 4)
                return 2;
            int rate = out_rate > 0 ? out_rate : bank.rate;
            int64_t sf = piano_ms_to_frames(start_ms, rate);
            int64_t rf = piano_ms_to_frames(start_ms + dur_ms, rate);
            notes[note_n++] = (piano_note){
                .start_frame = sf,
                .release_frame = rf,
                .midi = midi,
                .gain = (float)vel / 127.0f,
            };
        } else if (strcmp(cmd, "stream") == 0) {
            int block_frames = 0;
            if (scanf("%d", &block_frames) != 1 || block_frames <= 0 || block_frames > MAX_STREAM_BLOCK) return 2;
            int rate = out_rate > 0 ? out_rate : bank.rate;
            piano_synth ps;
            if (piano_synth_init(&ps, &bank, notes, note_n, rate) != 0) return 4;
            float block[MAX_STREAM_BLOCK];
            int16_t s16[MAX_STREAM_BLOCK];
            for (;;) {
                int32_t got = piano_synth_render_block(&ps, &bank, block, block_frames);
                if (got <= 0) break;
                for (int32_t i = 0; i < got; i++) {
                    float s = block[i] * 32767.0f;
                    if (s > 32767.0f) s = 32767.0f;
                    if (s < -32767.0f) s = -32767.0f;
                    s16[i] = (int16_t)lrintf(s);
                }
                fwrite(s16, sizeof(int16_t), (size_t)got, stdout);
            }
            piano_synth_free(&ps);
            return 0;
        } else if (strcmp(cmd, "render") == 0 || strcmp(cmd, "time") == 0) {
            long long frames;
            int repeat = 1;
            if (scanf("%lld", &frames) != 1 || frames < 0) return 2;
            bool timing = strcmp(cmd, "time") == 0;
            if (timing && scanf("%d", &repeat) != 1) return 2;
            float *mix = malloc(sizeof(float) * (size_t)(frames + 1));
            int16_t *out = malloc(sizeof(int16_t) * (size_t)(frames + 1));
            if (!mix || !out) return 3;
            double t0 = now_ms();
            for (int r = 0; r < repeat; r++) piano_render(&bank, voices, n, mix, out, frames);
            if (timing) printf("%.3f\n", (now_ms() - t0) / repeat);
            else fwrite(out, sizeof(int16_t), (size_t)frames, stdout);
            return 0;
        } else {
            fprintf(stderr, "unknown command %s\n", cmd);
            return 2;
        }
    }
    return 2;
}
