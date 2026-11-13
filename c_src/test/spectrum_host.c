/*
 * Host harness for c_src/spectrum.c.
 *
 *   cc -O2 -o /tmp/spectrum_host c_src/test/spectrum_host.c -lm && /tmp/spectrum_host
 *
 * Feeds harmonic tones (1/k harmonics, −25 dBFS) through one column and
 * checks that harmonics 1–4 are local peaks in their own bins (bin of f is
 * round(20 · log2(f / 50))) with valleys between them, and that a
 * full-scale sine reads its amplitude. Exit status 1 on a failure.
 */

#include <stdbool.h>
#include <stdio.h>
#include <string.h>

#include "../spectrum.c"

#define RATE 48000

static int bin_of(double f) { return (int)lround(20.0 * log2(f / SPEC_BASE_HZ)); }

static void tone(float *x, int n, double f0, double amplitude, int harmonics) {
    for (int i = 0; i < n; i++) {
        double v = 0;
        for (int k = 1; k <= harmonics && k * f0 < RATE / 2.2; k++) v += sin(2 * M_PI * k * f0 * i / RATE) / k;
        x[i] = (float)(amplitude * v);
    }
}

static int check_harmonics(spectrum *s, float *x, double f0) {
    uint8_t col[SPEC_BINS];
    tone(x, s->n, f0, 0.056, 30); /* ≈ −25 dBFS RMS */
    spectrum_column(s, x, col);
    int failed = 0;
    printf("%6.1f Hz:", f0);
    for (int k = 1; k <= 4; k++) {
        int b = bin_of(k * f0);
        if (b >= SPEC_BINS) break;
        /* The column peaks within one bin of the harmonic's exact (fractional)
         * bin, and the level halfway to the next harmonic is well below it. */
        double exact = 20.0 * log2(k * f0 / SPEC_BASE_HZ);
        int peak = b;
        for (int j = b - 3; j <= b + 3; j++)
            if (j >= 0 && j < SPEC_BINS && col[j] > col[peak]) peak = j;
        int valley = bin_of((k + 0.5) * f0);
        bool ok = fabs(peak - exact) <= 1.0 && valley < SPEC_BINS && col[valley] + 60 < col[peak];
        printf("  h%d bin %3d (%.0f Hz) level %3d, peak at %3d, valley %3d%s", k, b, k * f0, col[b], peak,
               valley < SPEC_BINS ? col[valley] : -1, ok ? "" : " FAIL");
        if (!ok) failed = 1;
    }
    printf("\n");
    return failed;
}

int main(void) {
    spectrum *s = spectrum_new(RATE);
    if (!s) return 1;
    float *x = malloc(sizeof(float) * s->n);
    printf("FFT %d points (%.1f ms) at %d Hz, %.2f Hz per FFT bin\n", s->n, 1000.0 * s->n / RATE, RATE,
           (double)RATE / s->n);
    int failed = 0;
    double f0s[] = {98.0, 110.0, 146.8, 220.0, 261.6, 440.0, 659.3};
    for (unsigned i = 0; i < sizeof(f0s) / sizeof(f0s[0]); i++) failed |= check_harmonics(s, x, f0s[i]);

    /* A full-scale 1 kHz sine: 0 dB, above the ceiling → 255; at −50 dB →
     * (−50 + 90) / 80 · 255 ≈ 128. */
    uint8_t col[SPEC_BINS];
    for (int i = 0; i < s->n; i++) x[i] = (float)(pow(10, -50.0 / 20) * sin(2 * M_PI * 1000.0 * i / RATE));
    spectrum_column(s, x, col);
    int b = bin_of(1000.0);
    printf("1 kHz sine at −50 dB: bin %d level %d (expect ≈128)\n", b, col[b]);
    if (abs(col[b] - 128) > 4) failed = 1;

    /* Silence: all zero. */
    memset(x, 0, sizeof(float) * s->n);
    spectrum_column(s, x, col);
    int max = 0;
    for (int i = 0; i < SPEC_BINS; i++)
        if (col[i] > max) max = col[i];
    printf("silence: max level %d (expect 0)\n", max);
    if (max != 0) failed = 1;

    /* One 220 Hz harmonic tone drawn as a column, low to high. */
    tone(x, s->n, 220.0, 0.056, 30);
    spectrum_column(s, x, col);
    const char *ramp = " .:-=+*#%@";
    printf("220 Hz column, bin 0 (50 Hz) → 127 (%.0f Hz):\n", SPEC_BASE_HZ * pow(2, 127 / 20.0));
    for (int i = 0; i < SPEC_BINS; i++) putchar(ramp[col[i] * 9 / 255]);
    printf("\n");

    free(x);
    spectrum_free(s);
    printf(failed ? "FAILED\n" : "ok\n");
    return failed;
}
