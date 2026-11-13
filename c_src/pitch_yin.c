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
    float fir_hist[2 * YIN_FIR_TAPS]; /* last input samples for the low-pass, twice */
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
        /* Each sample goes in twice, TAPS apart, so the last TAPS samples
         * are always contiguous: fir_hist[fir_pos .. fir_pos + TAPS). */
        p->fir_hist[p->fir_pos] = p->fir_hist[p->fir_pos + YIN_FIR_TAPS] = in[i];
        if (++p->fir_pos == YIN_FIR_TAPS) p->fir_pos = 0;
        if (++p->phase < p->factor) continue;
        p->phase = 0;

        const float *h = p->fir_hist + p->fir_pos; /* oldest first */
        float acc = 0.0f;
        for (int t = 0; t < YIN_FIR_TAPS; t++) acc += p->fir[t] * h[t];
        p->buf[p->buf_pos] = acc;
        if (++p->buf_pos == p->buf_len) p->buf_pos = 0;
    }
}

/* Σ (x[j] − y[j])², the hot loop (~400 × 270 per reading), in eight
 * independent partial sums: one running sum is a chain of dependent
 * multiply-adds, latency-bound (most of a reading on a moto e 2020). The
 * partial sums change the result only by rounding. On arm64 they are two
 * NEON registers; on 32-bit ARM, scalar VFP (zig builds armeabi-v7a with the
 * soft-float calling convention, where NEON vectors don't compile). */
#if defined(__aarch64__)
#include <arm_neon.h>

static float pitch_sq_diff(const float *x, const float *y, int n) {
    float32x4_t a0 = vdupq_n_f32(0.0f), a1 = vdupq_n_f32(0.0f);
    int j = 0;
    for (; j + 8 <= n; j += 8) {
        float32x4_t d0 = vsubq_f32(vld1q_f32(x + j), vld1q_f32(y + j));
        float32x4_t d1 = vsubq_f32(vld1q_f32(x + j + 4), vld1q_f32(y + j + 4));
        a0 = vfmaq_f32(a0, d0, d0);
        a1 = vfmaq_f32(a1, d1, d1);
    }
    float d = vaddvq_f32(vaddq_f32(a0, a1));
    for (; j < n; j++) {
        float delta = x[j] - y[j];
        d += delta * delta;
    }
    return d;
}
#else
static float pitch_sq_diff(const float *x, const float *y, int n) {
    /* Separate locals, not an array: at -Os an array stays in memory. */
    float a0 = 0.0f, a1 = 0.0f, a2 = 0.0f, a3 = 0.0f, a4 = 0.0f, a5 = 0.0f, a6 = 0.0f, a7 = 0.0f;
    int j = 0;
    for (; j + 8 <= n; j += 8) {
        float d0 = x[j] - y[j], d1 = x[j + 1] - y[j + 1], d2 = x[j + 2] - y[j + 2], d3 = x[j + 3] - y[j + 3];
        float d4 = x[j + 4] - y[j + 4], d5 = x[j + 5] - y[j + 5], d6 = x[j + 6] - y[j + 6], d7 = x[j + 7] - y[j + 7];
        a0 += d0 * d0;
        a1 += d1 * d1;
        a2 += d2 * d2;
        a3 += d3 * d3;
        a4 += d4 * d4;
        a5 += d5 * d5;
        a6 += d6 * d6;
        a7 += d7 * d7;
    }
    float d = ((a0 + a1) + (a2 + a3)) + ((a4 + a5) + (a6 + a7));
    for (; j < n; j++) {
        float delta = x[j] - y[j];
        d += delta * delta;
    }
    return d;
}
#endif

/* Analyse the most recent window. */
static pitch_reading pitch_detect(pitch_detector *p) {
    pitch_reading r = {0.0f, 0.0f, YIN_FLOOR_DB};
    int w = p->window;

    /* The ring, oldest first. */
    int head = p->buf_len - p->buf_pos;
    memcpy(p->frame, p->buf + p->buf_pos, sizeof(float) * (size_t)head);
    memcpy(p->frame + head, p->buf, sizeof(float) * (size_t)p->buf_pos);

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
        float d = pitch_sq_diff(x, x + tau, n);
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
