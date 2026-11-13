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
 * amplitude however wide its band. Narrower bands need the window's DFT
 * at their own centre: reading the FFT there would snap every low harmonic
 * to the nearest FFT bin, a band or two off. They read a second, zoomed FFT
 * of the same windowed audio low-passed and decimated by `dec` (4 at
 * 48 kHz) and zero-padded back to n points, so its bins are `dec` times
 * closer (2.9 Hz at 48 kHz), interpolated at the band centre; the narrow
 * bands all sit far below the decimated Nyquist. (Evaluating each centre
 * directly with Goertzel cost ~16× more and was 94% of a column.) At rates
 * too low to decimate, Goertzel it is. The Hann main lobe (±2 FFT bins,
 * ±23 Hz) spreads a low harmonic over a few neighbouring bands, still well
 * apart from the next harmonic.
 *
 * Pure C, no platform dependencies: c_src/test/spectrum_host.c checks it on
 * the Mac.
 */

#include <math.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

#ifndef M_PI
#define M_PI 3.14159265358979323846
#endif

#define SPEC_BINS 128
#define SPEC_BASE_HZ 50.0
#define SPEC_BINS_PER_OCTAVE 20.0
#define SPEC_FLOOR_DB -90.0f
#define SPEC_CEIL_DB -10.0f
/* The zoomed FFT's decimated rate is at least this. */
#define SPEC_ZOOM_RATE 12000
/* Low-pass taps per unit of decimation (+1). */
#define SPEC_LP_TAPS_PER_DEC 8

typedef struct {
    int n, rate;
    float *window;
    float *xw;            /* the windowed audio */
    float *re, *im;
    float *cos_t, *sin_t; /* twiddles, n/2 each */
    float *mag;           /* amplitude per FFT bin, 0..n/2 */
    int narrow;           /* bands [0, narrow) are narrower than two FFT bins */
    int dec;              /* zoom decimation; < 2: Goertzel for narrow bands */
    int lp_taps;
    float *lp;            /* the zoom's low-pass, DC gain 1 */
    float zbin[SPEC_BINS];  /* a narrow band's centre in zoomed-FFT bins */
    double coeff[SPEC_BINS]; /* Goertzel: 2 cos(ω) of each narrow band's centre */
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
    free(s->xw);
    free(s->re);
    free(s->im);
    free(s->cos_t);
    free(s->sin_t);
    free(s->mag);
    free(s->lp);
    free(s);
}

static spectrum *spectrum_new(int rate) {
    spectrum *s = calloc(1, sizeof(*s));
    if (!s) return NULL;
    s->rate = rate;
    s->n = spectrum_size(rate);
    int n = s->n;
    s->dec = rate / SPEC_ZOOM_RATE;
    s->lp_taps = s->dec >= 2 ? SPEC_LP_TAPS_PER_DEC * s->dec + 1 : 0;
    s->window = malloc(sizeof(float) * n);
    s->xw = malloc(sizeof(float) * n);
    s->re = malloc(sizeof(float) * n);
    s->im = malloc(sizeof(float) * n);
    s->cos_t = malloc(sizeof(float) * (n / 2));
    s->sin_t = malloc(sizeof(float) * (n / 2));
    s->mag = malloc(sizeof(float) * (n / 2 + 1));
    s->lp = malloc(sizeof(float) * (size_t)(s->lp_taps > 0 ? s->lp_taps : 1));
    if (!s->window || !s->xw || !s->re || !s->im || !s->cos_t || !s->sin_t || !s->mag || !s->lp) {
        spectrum_free(s);
        return NULL;
    }
    for (int i = 0; i < n; i++) s->window[i] = (float)(0.5 - 0.5 * cos(2.0 * M_PI * i / n));
    for (int i = 0; i < n / 2; i++) {
        s->cos_t[i] = (float)cos(2.0 * M_PI * i / n);
        s->sin_t[i] = (float)-sin(2.0 * M_PI * i / n);
    }
    if (s->dec >= 2) {
        /* Windowed sinc, cutoff at 0.4 × the decimated rate. */
        double fc = 0.4 / s->dec, sum = 0.0;
        int mid = s->lp_taps / 2;
        for (int i = 0; i < s->lp_taps; i++) {
            int k = i - mid;
            double sinc = k == 0 ? 2.0 * fc : sin(2.0 * M_PI * fc * k) / (M_PI * k);
            double w = 0.5 - 0.5 * cos(2.0 * M_PI * i / (s->lp_taps - 1));
            s->lp[i] = (float)(sinc * w);
            sum += sinc * w;
        }
        for (int i = 0; i < s->lp_taps; i++) s->lp[i] = (float)(s->lp[i] / sum);
    }
    double df = (double)rate / n;
    double half = pow(2.0, 0.5 / SPEC_BINS_PER_OCTAVE);
    for (int b = 0; b < SPEC_BINS; b++) {
        double f = SPEC_BASE_HZ * pow(2.0, b / SPEC_BINS_PER_OCTAVE);
        if (f * half - f / half < 2.0 * df) {
            s->narrow = b + 1;
            s->coeff[b] = 2.0 * cos(2.0 * M_PI * f / rate);
            s->zbin[b] = (float)(f * s->dec / df);
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

/* The FFT of re/im (im zero) as amplitudes in mag, times `scale`. */
static void spectrum_magnitudes(spectrum *s, float scale) {
    memset(s->im, 0, sizeof(float) * (size_t)s->n);
    spectrum_fft(s);
    for (int k = 0; k <= s->n / 2; k++)
        s->mag[k] = sqrtf(s->re[k] * s->re[k] + s->im[k] * s->im[k]) * scale;
}

static uint8_t spectrum_byte(float amplitude) {
    float db = amplitude > 1e-9f ? 20.0f * log10f(amplitude) : SPEC_FLOOR_DB;
    float v = (db - SPEC_FLOOR_DB) / (SPEC_CEIL_DB - SPEC_FLOOR_DB) * 255.0f;
    return v <= 0.0f ? 0 : v >= 255.0f ? 255 : (uint8_t)(v + 0.5f);
}

/* Narrow bands from the zoomed FFT: xw low-passed and decimated by `dec`,
 * zero-padded to n. Decimating keeps 1/dec of the DFT's sum, hence × dec. */
static void spectrum_narrow_zoomed(spectrum *s, uint8_t out[SPEC_BINS], float scale) {
    int n = s->n, dec = s->dec, taps = s->lp_taps, mid = taps / 2, m_n = n / dec;
    memset(s->re, 0, sizeof(float) * (size_t)n);
    for (int m = 0; m < m_n; m++) {
        int c = m * dec - mid; /* the tap at lp[0] */
        float acc = 0.0f;
        if (c >= 0 && c + taps <= n) {
            const float *x = s->xw + c;
            for (int k = 0; k < taps; k++) acc += s->lp[k] * x[k];
        } else {
            for (int k = 0; k < taps; k++)
                if (c + k >= 0 && c + k < n) acc += s->lp[k] * s->xw[c + k];
        }
        s->re[m] = acc;
    }
    spectrum_magnitudes(s, scale * (float)dec);
    for (int b = 0; b < s->narrow; b++) {
        float c = s->zbin[b];
        int k = (int)c;
        float frac = c - (float)k;
        out[b] = spectrum_byte(s->mag[k] * (1.0f - frac) + s->mag[k + 1] * frac);
    }
}

/* Narrow bands by Goertzel at each centre, for rates too low to decimate. */
static void spectrum_narrow_goertzel(spectrum *s, uint8_t out[SPEC_BINS], double scale) {
    for (int b = 0; b < s->narrow; b++) {
        double c = s->coeff[b], s1 = 0.0, s2 = 0.0;
        for (int i = 0; i < s->n; i++) {
            double s0 = s->xw[i] + c * s1 - s2;
            s2 = s1;
            s1 = s0;
        }
        double power = s1 * s1 + s2 * s2 - c * s1 * s2;
        out[b] = spectrum_byte((float)(sqrt(power > 0.0 ? power : 0.0) * scale));
    }
}

/* One column from the latest s->n samples `x` (oldest first). */
static void spectrum_column(spectrum *s, const float *x, uint8_t out[SPEC_BINS]) {
    int n = s->n;
    for (int i = 0; i < n; i++) s->xw[i] = x[i] * s->window[i];
    /* A sine of amplitude A peaks at A · n / 4 under the Hann window. */
    float scale = 4.0f / (float)n;

    if (s->dec >= 2) spectrum_narrow_zoomed(s, out, scale);
    else spectrum_narrow_goertzel(s, out, scale);

    memcpy(s->re, s->xw, sizeof(float) * (size_t)n);
    spectrum_magnitudes(s, scale);
    for (int b = s->narrow; b < SPEC_BINS; b++) {
        float level = 0.0f;
        for (int j = s->band_lo[b]; j <= s->band_hi[b]; j++)
            if (s->mag[j] > level) level = s->mag[j];
        out[b] = spectrum_byte(level);
    }
}
