/*
 * pitch_yin.c — monophonic pitch detection for a singing, humming or
 * whistling voice (YIN).
 *
 * de Cheveigné & Kawahara, "YIN, a fundamental frequency estimator for
 * speech and music" (JASA 2002): difference function, cumulative mean
 * normalisation, absolute threshold, parabolic interpolation.
 *
 * Input arrives at the capture rate (typically 48 kHz) and is decimated to
 * about 16 kHz through a windowed-sinc low-pass first: the difference
 * function costs O(window × max lag), so analysing at 16 kHz is ~9× cheaper
 * than at 48 kHz, and 16 kHz still resolves a 1.6 kHz whistle to a few
 * cents with the interpolation.
 *
 * Ported from Choir Coach (~/code/choir_coach/c_src/pitch_yin.c). Pure C
 * with no platform dependencies: the Android engine includes it, and
 * c_src/test/pitch_host.c builds it on the Mac.
 */

#include <math.h>
#include <stdlib.h>
#include <string.h>

#ifndef M_PI
#define M_PI 3.14159265358979323846
#endif

/* The first lag whose normalised difference dips under this is the period. */
#define YIN_THRESHOLD 0.15f
/* No dip under YIN_THRESHOLD: the deepest one still counts as pitched up to
 * here (a breathy or soft voice), beyond it the window is unpitched. */
#define YIN_VOICED_MAX 0.35f
#ifndef YIN_TARGET_RATE
#define YIN_TARGET_RATE 16000
#endif
#define YIN_FIR_TAPS 31
/* Below this level nothing is detected: no singer is that quiet, and the
 * Tracker's own gate (sensitivity) sits above it. */
#define YIN_SILENCE_DB -70.0f
/* The level reported for digital silence. */
#define YIN_FLOOR_DB -90.0f

typedef struct {
    float hz;      /* 0 when unpitched */
    float clarity; /* 0..1: 1 − normalised difference at the chosen lag */
    float rms_db;  /* window level, dBFS, ≥ YIN_FLOOR_DB */
} pitch_reading;

typedef struct {
    int in_rate; /* capture sample rate */
    int factor;  /* decimation factor */
    int rate;    /* analysis rate = in_rate / factor */
    int tau_min, tau_max;
    int integration; /* samples summed per lag */
    int window;      /* analysis window = integration + tau_max + 1 */

    float fir[YIN_FIR_TAPS];
    float fir_hist[YIN_FIR_TAPS]; /* last input samples for the low-pass */
    int fir_pos;
    int phase; /* input samples since the last kept output */

    float *buf; /* decimated ring, window samples */
    int buf_len, buf_pos;

    float *frame; /* linearised window */
    float *diff;  /* difference / CMND per lag */
} pitch_detector;

/* Windowed-sinc low-pass at 0.45 × the output Nyquist, Hann window. */
static void pitch_design_fir(float *h, int taps, int factor) {
    float fc = 0.45f / (float)factor; /* cycles per input sample */
    float sum = 0.0f;
    int mid = taps / 2;
    for (int i = 0; i < taps; i++) {
        int n = i - mid;
        float sinc = n == 0 ? 2.0f * fc : sinf(2.0f * (float)M_PI * fc * n) / ((float)M_PI * n);
        float w = 0.5f - 0.5f * cosf(2.0f * (float)M_PI * i / (taps - 1));
        h[i] = sinc * w;
        sum += h[i];
    }
    for (int i = 0; i < taps; i++) h[i] /= sum;
}

static pitch_detector *pitch_new(int in_rate, float min_hz, float max_hz) {
    pitch_detector *p = calloc(1, sizeof(*p));
    if (!p) return NULL;
    p->in_rate = in_rate;
    p->factor = in_rate / YIN_TARGET_RATE;
    if (p->factor < 1) p->factor = 1;
    p->rate = in_rate / p->factor;
    p->tau_min = (int)floorf(p->rate / max_hz);
    p->tau_max = (int)ceilf(p->rate / min_hz);
    if (p->tau_min < 2) p->tau_min = 2;
    p->integration = p->tau_max + p->tau_max / 2;
    p->window = p->integration + p->tau_max + 1;
    pitch_design_fir(p->fir, YIN_FIR_TAPS, p->factor);

    p->buf_len = p->window;
    p->buf = calloc(p->buf_len, sizeof(float));
    p->frame = calloc(p->window, sizeof(float));
    p->diff = calloc(p->tau_max + 2, sizeof(float));
    if (!p->buf || !p->frame || !p->diff) {
        free(p->buf);
        free(p->frame);
        free(p->diff);
        free(p);
        return NULL;
    }
    return p;
}

static void pitch_free(pitch_detector *p) {
    if (!p) return;
    free(p->buf);
    free(p->frame);
    free(p->diff);
    free(p);
}

/* Window length in input samples: how much history one reading spans. */
static int pitch_window_input_samples(const pitch_detector *p) { return p->window * p->factor; }

/* Feed input samples (mono float, ±1). */
static void pitch_push(pitch_detector *p, const float *in, int n) {
    for (int i = 0; i < n; i++) {
        p->fir_hist[p->fir_pos] = in[i];
        p->fir_pos = (p->fir_pos + 1) % YIN_FIR_TAPS;
        if (++p->phase < p->factor) continue;
        p->phase = 0;

        float acc = 0.0f;
        int k = p->fir_pos; /* oldest sample */
        for (int t = 0; t < YIN_FIR_TAPS; t++) {
            acc += p->fir[t] * p->fir_hist[k];
            k = (k + 1) % YIN_FIR_TAPS;
        }
        p->buf[p->buf_pos] = acc;
        p->buf_pos = (p->buf_pos + 1) % p->buf_len;
    }
}

/* Analyse the most recent window. */
static pitch_reading pitch_detect(pitch_detector *p) {
    pitch_reading r = {0.0f, 0.0f, YIN_FLOOR_DB};
    int w = p->window;

    for (int i = 0; i < w; i++) p->frame[i] = p->buf[(p->buf_pos + i) % p->buf_len];

    double energy = 0.0;
    for (int i = 0; i < w; i++) energy += (double)p->frame[i] * p->frame[i];
    double rms = sqrt(energy / w);
    float db = rms > 0.0 ? (float)(20.0 * log10(rms)) : YIN_FLOOR_DB;
    r.rms_db = db < YIN_FLOOR_DB ? YIN_FLOOR_DB : db;
    if (r.rms_db < YIN_SILENCE_DB) return r;

    /* Difference function d(τ) and cumulative mean normalised d'(τ). */
    const float *x = p->frame;
    int n = p->integration;
    float running = 0.0f;
    p->diff[0] = 1.0f;
    for (int tau = 1; tau <= p->tau_max; tau++) {
        float d = 0.0f;
        for (int j = 0; j < n; j++) {
            float delta = x[j] - x[j + tau];
            d += delta * delta;
        }
        running += d;
        p->diff[tau] = running > 0.0f ? d * tau / running : 1.0f;
    }

    /* First dip below the threshold, followed down to its local minimum;
     * failing that, the global minimum (pitched only if deep enough). */
    int best = -1;
    for (int tau = p->tau_min; tau < p->tau_max; tau++) {
        if (p->diff[tau] < YIN_THRESHOLD) {
            while (tau + 1 < p->tau_max && p->diff[tau + 1] < p->diff[tau]) tau++;
            best = tau;
            break;
        }
    }
    if (best < 0) {
        best = p->tau_min;
        for (int tau = p->tau_min + 1; tau < p->tau_max; tau++)
            if (p->diff[tau] < p->diff[best]) best = tau;
    }

    /* Parabolic interpolation around the minimum. */
    float shift = 0.0f;
    if (best > 1 && best < p->tau_max) {
        float a = p->diff[best - 1], b = p->diff[best], c = p->diff[best + 1];
        float denom = a - 2.0f * b + c;
        if (fabsf(denom) > 1e-9f) shift = 0.5f * (a - c) / denom;
        if (shift > 0.5f) shift = 0.5f;
        if (shift < -0.5f) shift = -0.5f;
    }

    float clarity = 1.0f - p->diff[best];
    r.clarity = clarity < 0.0f ? 0.0f : (clarity > 1.0f ? 1.0f : clarity);
    if (p->diff[best] <= YIN_VOICED_MAX) r.hz = (float)p->rate / ((float)best + shift);
    return r;
}
