/*
 * Host harness for c_src/pitch_yin.c, with the engine's settings (60–1600 Hz,
 * ~5.3 ms hop).
 *
 *   cc -O2 -o /tmp/pitch_host c_src/test/pitch_host.c -lm
 *   /tmp/pitch_host synth          # tone coverage/accuracy, noise and silence rejection
 *   ffmpeg -v error -i voice.m4a -ac 1 -ar 48000 -f f32le - | /tmp/pitch_host 48000 > pitch.csv
 *
 * File mode reads mono 32-bit float PCM on stdin and prints one reading per
 * hop: `t_ms,hz,clarity,db` (hz 0 when unpitched), t_ms the window centre,
 * then a summary on stderr: voiced share and octave jumps (a pitched reading
 * about an octave away from both neighbours, which a sung line never does in
 * 5 ms).
 */

#include <stdio.h>
#include <stdlib.h>

#include "../pitch_yin.c"

#define MIN_HZ 60.0f
#define MAX_HZ 1600.0f
#define RATE 48000

static int hop_for(const pitch_detector *p, int rate) {
    int h = (int)(rate * 0.0053 / p->factor + 0.5) * p->factor;
    return h > 0 ? h : p->factor;
}

static double cents(double hz, double ref) { return 1200.0 * log2(hz / ref); }

static int cmp_double(const void *a, const void *b) {
    double x = *(const double *)a, y = *(const double *)b;
    return x < y ? -1 : x > y;
}

static unsigned rng = 12345;
static float noise(void) {
    rng = rng * 1664525u + 1013904223u;
    return (float)((rng >> 8) & 0xFFFF) / 32768.0f - 1.0f;
}

enum { SINE, SAW, VOICE, WEAK_FUNDAMENTAL, WHISTLE };
static const char *kind_name[] = {"sine", "saw (1/k harmonics)", "voice (formants, vibrato, breath)",
                                  "weak fundamental (h1 -20 dB)", "whistle (sine + breath)"};

/* One second of a tone at `f0` (Hz) of the given kind, amplitude ~0.1. */
static void synth(float *x, int n, double f0, int kind) {
    double phase = 0;
    for (int i = 0; i < n; i++) {
        double t = (double)i / RATE;
        double f = f0;
        if (kind == VOICE) f = f0 * pow(2.0, (30.0 / 1200.0) * sin(2 * M_PI * 5.5 * t)); /* ±30 ¢ vibrato */
        phase += 2 * M_PI * f / RATE;
        double v = 0;
        switch (kind) {
        case SINE: v = sin(phase); break;
        case WHISTLE: v = sin(phase) + 0.05 * noise(); break;
        case SAW:
            for (int k = 1; k * f < RATE / 2.2 && k <= 40; k++) v += sin(k * phase) / k;
            break;
        case WEAK_FUNDAMENTAL:
            for (int k = 1; k * f < RATE / 2.2 && k <= 20; k++) v += sin(k * phase) * (k == 1 ? 0.1 : 1.0 / k);
            break;
        case VOICE:
            /* Harmonics shaped by two formants (~700 Hz, ~1200 Hz: an "ah"),
             * so the 2nd–4th harmonics of a low voice outweigh the 1st. */
            for (int k = 1; k * f < RATE / 2.2 && k <= 60; k++) {
                double h = k * f;
                double g = 0.3 / k + exp(-pow((h - 700) / 150, 2)) + 0.6 * exp(-pow((h - 1200) / 200, 2));
                v += g * sin(k * phase);
            }
            v += 0.03 * noise();
            break;
        }
        x[i] = (float)v;
    }
    /* Normalise to an RMS of −25 dBFS. */
    double e = 0;
    for (int i = 0; i < n; i++) e += (double)x[i] * x[i];
    double g = pow(10, -25.0 / 20) / sqrt(e / n);
    for (int i = 0; i < n; i++) x[i] = (float)(x[i] * g);
}

static int run_synth(void) {
    int n = RATE;
    float *x = malloc(sizeof(float) * n);
    double *errs = malloc(sizeof(double) * 200000);
    int all_bad = 0;
    for (int kind = SINE; kind <= WHISTLE; kind++) {
        double lo = kind == WHISTLE ? 500 : 60, hi = kind == WHISTLE ? 1600 : (kind == SINE ? 1600 : 1000);
        int count = 0, octave = 0, unvoiced = 0, total = 0;
        for (double f0 = lo; f0 <= hi * 1.0001; f0 *= pow(2, 1.0 / 12)) {
            synth(x, n, f0, kind);
            pitch_detector *p = pitch_new(RATE, MIN_HZ, MAX_HZ);
            int hop = hop_for(p, RATE), win = pitch_window_input_samples(p);
            for (int at = 0; at + hop <= n; at += hop) {
                pitch_push(p, x + at, hop);
                if (at + hop < win + RATE / 10) continue; /* window full, past the onset */
                pitch_reading r = pitch_detect(p);
                total++;
                if (!(r.hz > 0) || !isfinite(r.hz)) {
                    unvoiced++;
                    continue;
                }
                /* Vibrato: compare with the true pitch at the window centre. */
                double t = (at + hop - win / 2.0) / RATE;
                double truth = kind == VOICE ? f0 * pow(2.0, (30.0 / 1200.0) * sin(2 * M_PI * 5.5 * t)) : f0;
                double c = cents(r.hz, truth);
                if (fabs(c) > 600) octave++;
                else errs[count++] = fabs(c);
            }
            pitch_free(p);
        }
        qsort(errs, count, sizeof(double), cmp_double);
        double med = count ? errs[count / 2] : 0, p95 = count ? errs[(int)(count * 0.95)] : 0,
               worst = count ? errs[count - 1] : 0;
        printf("%-34s %4.0f–%4.0f Hz  readings %6d  |err| median %5.2f ¢  p95 %5.2f ¢  max %6.2f ¢  "
               "octave errors %.3f%%  unvoiced %.3f%%\n",
               kind_name[kind], lo, hi, total, med, p95, worst, 100.0 * octave / total, 100.0 * unvoiced / total);
        /* At least 99% voiced per tone family; the lowest voice's vibrato crosses MIN_HZ. */
        if (total == 0 || unvoiced * 100 > total || octave > 0 || p95 > 10) all_bad = 1;
    }

    /* Noise and silence must stay unpitched. */
    pitch_detector *p = pitch_new(RATE, MIN_HZ, MAX_HZ);
    int hop = hop_for(p, RATE), pitched = 0, readings = 0;
    for (int i = 0; i < n; i++) x[i] = 0.05f * noise();
    for (int at = 0; at + hop <= n; at += hop) {
        pitch_push(p, x + at, hop);
        if (at < pitch_window_input_samples(p)) continue;
        readings++;
        if (pitch_detect(p).hz != 0) pitched++;
    }
    printf("%-34s pitched %d of %d readings\n", "white noise (−29 dBFS)", pitched, readings);
    if (readings == 0 || pitched != 0) all_bad = 1;
    for (int i = 0; i < n; i++) x[i] = 0;
    pitch_free(p);
    p = pitch_new(RATE, MIN_HZ, MAX_HZ);
    pitch_push(p, x, n);
    pitch_reading r = pitch_detect(p);
    printf("%-34s hz %.1f clarity %.2f db %.1f\n", "digital silence", r.hz, r.clarity, r.rms_db);
    if (r.hz != 0) all_bad = 1;
    printf("hop %d samples (%.2f ms), window %d samples (%.1f ms), analysis rate %d Hz\n", hop,
           1000.0 * hop / RATE, pitch_window_input_samples(p), 1000.0 * pitch_window_input_samples(p) / RATE,
           p->rate);
    pitch_free(p);
    free(x);
    free(errs);
    return all_bad;
}

static int run_file(int rate) {
    pitch_detector *p = pitch_new(rate, MIN_HZ, MAX_HZ);
    if (!p) return 1;
    int hop = hop_for(p, rate), win = pitch_window_input_samples(p);
    float *chunk = malloc(sizeof(float) * hop);
    long consumed = 0, cap = 1 << 16, n = 0;
    float *hz = malloc(sizeof(float) * cap);
    printf("t_ms,hz,clarity,db\n");
    while (fread(chunk, sizeof(float), hop, stdin) == (size_t)hop) {
        pitch_push(p, chunk, hop);
        consumed += hop;
        if (consumed < win) continue;
        pitch_reading r = pitch_detect(p);
        printf("%.1f,%.3f,%.3f,%.1f\n", 1000.0 * (consumed - win / 2.0) / rate, r.hz, r.clarity, r.rms_db);
        if (n == cap) hz = realloc(hz, sizeof(float) * (cap *= 2));
        hz[n++] = r.hz;
    }
    long voiced = 0, jumps = 0;
    for (long i = 0; i < n; i++) {
        if (hz[i] <= 0) continue;
        voiced++;
        if (i == 0 || i + 1 >= n || hz[i - 1] <= 0 || hz[i + 1] <= 0) continue;
        double a = cents(hz[i], hz[i - 1]), b = cents(hz[i], hz[i + 1]);
        if (fabs(a) > 900 && fabs(b) > 900 && a * b > 0) jumps++;
    }
    fprintf(stderr, "readings %ld, voiced %ld (%.1f%%), octave jumps %ld (%.3f%% of voiced)\n", n, voiced,
            n ? 100.0 * voiced / n : 0, jumps, voiced ? 100.0 * jumps / voiced : 0);
    free(hz);
    free(chunk);
    pitch_free(p);
    return 0;
}

int main(int argc, char **argv) {
    if (argc > 1 && strcmp(argv[1], "synth") == 0) return run_synth();
    return run_file(argc > 1 ? atoi(argv[1]) : RATE);
}
