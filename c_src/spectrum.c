/*
 * spectrum.c — one spectrum column for the Spectrum view.
 *
 * The latest ~85 ms (4096 samples at 48 kHz) under a Hann window, read out
 * at SPEC_BINS log-spaced frequencies, bin i centred at 50 · 2^(i / 20) Hz
 * (Humdinger.Audio.bin_hz/1). Each column byte is the level of the
 * strongest component in its band, as the amplitude of a sine in dBFS (a
 * full-scale sine reads 0 dB), mapped −90 dB → 0 … −10 dB → 255.
 *
 * Bands at least two FFT bins wide (above ~680 Hz at 48 kHz) take the
 * largest bin of a radix-2 FFT inside them, so a harmonic shows at its own
 * amplitude however wide its band. Narrower bands get the window's DFT
 * evaluated at their exact centre (Goertzel): reading the FFT there would
 * snap every low harmonic to the nearest FFT bin, a band or two off. The
 * Hann main lobe (±2 FFT bins, ±23 Hz) spreads a low harmonic over a few
 * neighbouring bands, still well apart from the next harmonic.
 *
 * Pure C, no platform dependencies: c_src/test/spectrum_host.c checks it on
 * the Mac.
 */

#include <math.h>
#include <stdint.h>
#include <stdlib.h>

#ifndef M_PI
#define M_PI 3.14159265358979323846
#endif

#define SPEC_BINS 128
#define SPEC_BASE_HZ 50.0
#define SPEC_BINS_PER_OCTAVE 20.0
#define SPEC_FLOOR_DB -90.0f
#define SPEC_CEIL_DB -10.0f

typedef struct {
    int n, rate;
    float *window;
    float *re, *im;
    float *cos_t, *sin_t; /* twiddles, n/2 each */
    float *mag;           /* amplitude per FFT bin, 0..n/2 */
    int narrow;           /* bands [0, narrow) use Goertzel at their centre */
    double coeff[SPEC_BINS];                    /* 2 cos(ω) of each narrow band's centre */
    int band_lo[SPEC_BINS], band_hi[SPEC_BINS]; /* FFT bins inside a wide band */
} spectrum;

/* FFT points for a capture rate: about 85 ms. */
static int spectrum_size(int rate) {
    int n = 256;
    while (n < 8192 && n < rate * 85 / 1000) n *= 2;
    return n;
}

static void spectrum_free(spectrum *s) {
    if (!s) return;
    free(s->window);
    free(s->re);
    free(s->im);
    free(s->cos_t);
    free(s->sin_t);
    free(s->mag);
    free(s);
}

static spectrum *spectrum_new(int rate) {
    spectrum *s = calloc(1, sizeof(*s));
    if (!s) return NULL;
    s->rate = rate;
    s->n = spectrum_size(rate);
    int n = s->n;
    s->window = malloc(sizeof(float) * n);
    s->re = malloc(sizeof(float) * n);
    s->im = malloc(sizeof(float) * n);
    s->cos_t = malloc(sizeof(float) * (n / 2));
    s->sin_t = malloc(sizeof(float) * (n / 2));
    s->mag = malloc(sizeof(float) * (n / 2 + 1));
    if (!s->window || !s->re || !s->im || !s->cos_t || !s->sin_t || !s->mag) {
        spectrum_free(s);
        return NULL;
    }
    for (int i = 0; i < n; i++) s->window[i] = (float)(0.5 - 0.5 * cos(2.0 * M_PI * i / n));
    for (int i = 0; i < n / 2; i++) {
        s->cos_t[i] = (float)cos(2.0 * M_PI * i / n);
        s->sin_t[i] = (float)-sin(2.0 * M_PI * i / n);
    }
    double df = (double)rate / n;
    double half = pow(2.0, 0.5 / SPEC_BINS_PER_OCTAVE);
    for (int b = 0; b < SPEC_BINS; b++) {
        double f = SPEC_BASE_HZ * pow(2.0, b / SPEC_BINS_PER_OCTAVE);
        if (f * half - f / half < 2.0 * df) {
            s->narrow = b + 1;
            s->coeff[b] = 2.0 * cos(2.0 * M_PI * f / rate);
        }
        s->band_lo[b] = (int)ceil(f / half / df);
        s->band_hi[b] = (int)floor(f * half / df);
        if (s->band_hi[b] > n / 2) s->band_hi[b] = n / 2;
    }
    return s;
}

/* In-place iterative radix-2 FFT of re/im. */
static void spectrum_fft(spectrum *s) {
    int n = s->n;
    float *re = s->re, *im = s->im;
    for (int i = 1, j = 0; i < n; i++) {
        int bit = n >> 1;
        for (; j & bit; bit >>= 1) j ^= bit;
        j ^= bit;
        if (i < j) {
            float t = re[i];
            re[i] = re[j];
            re[j] = t;
            t = im[i];
            im[i] = im[j];
            im[j] = t;
        }
    }
    for (int len = 2; len <= n; len <<= 1) {
        int half = len >> 1, step = n / len;
        for (int i = 0; i < n; i += len) {
            for (int k = 0; k < half; k++) {
                float wr = s->cos_t[k * step], wi = s->sin_t[k * step];
                int a = i + k, b = a + half;
                float xr = re[b] * wr - im[b] * wi;
                float xi = re[b] * wi + im[b] * wr;
                re[b] = re[a] - xr;
                im[b] = im[a] - xi;
                re[a] += xr;
                im[a] += xi;
            }
        }
    }
}

static uint8_t spectrum_byte(float amplitude) {
    float db = amplitude > 1e-9f ? 20.0f * log10f(amplitude) : SPEC_FLOOR_DB;
    float v = (db - SPEC_FLOOR_DB) / (SPEC_CEIL_DB - SPEC_FLOOR_DB) * 255.0f;
    return v <= 0.0f ? 0 : v >= 255.0f ? 255 : (uint8_t)(v + 0.5f);
}

/* One column from the latest s->n samples `x` (oldest first). */
static void spectrum_column(spectrum *s, const float *x, uint8_t out[SPEC_BINS]) {
    int n = s->n;
    for (int i = 0; i < n; i++) {
        s->re[i] = x[i] * s->window[i];
        s->im[i] = 0.0f;
    }
    /* A sine of amplitude A peaks at A · n / 4 under the Hann window. */
    double scale = 4.0 / n;

    for (int b = 0; b < s->narrow; b++) {
        double c = s->coeff[b], s1 = 0.0, s2 = 0.0;
        for (int i = 0; i < n; i++) {
            double s0 = s->re[i] + c * s1 - s2;
            s2 = s1;
            s1 = s0;
        }
        double power = s1 * s1 + s2 * s2 - c * s1 * s2;
        out[b] = spectrum_byte((float)(sqrt(power > 0.0 ? power : 0.0) * scale));
    }

    spectrum_fft(s);
    for (int k = 0; k <= n / 2; k++)
        s->mag[k] = sqrtf(s->re[k] * s->re[k] + s->im[k] * s->im[k]) * (float)scale;
    for (int b = s->narrow; b < SPEC_BINS; b++) {
        float level = 0.0f;
        for (int j = s->band_lo[b]; j <= s->band_hi[b]; j++)
            if (s->mag[j] > level) level = s->mag[j];
        out[b] = spectrum_byte(level);
    }
}
