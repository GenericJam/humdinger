/*
 * c_src/piano.c — the built-in piano's renderer: plain C, no Android, no
 * BEAM. hum_audio.c includes it (the NIF renders and plays a phrase with
 * it); c_src/test/piano_host.c builds it on the Mac for the host tests.
 *
 * A bank is a handful of recorded piano notes (mono, 16-bit, one rate). A
 * voice plays one bank sample from output frame `start`, reading it `step`
 * source frames per output frame (the pitch shift; the bank and the output
 * share a rate), scaled by `gain`. From frame `release` (the key coming up)
 * it fades out exponentially, as the damper does: −60 dB RELEASE_S later,
 * when the voice stops. A voice also stops where its sample ends (the
 * samples carry their own fade-out). Between source frames the sample is
 * read by linear interpolation.
 *
 * Voices are mixed in float, then scaled by PIANO_MASTER and soft-clipped
 * into 16-bit: unity up to PIANO_KNEE, then a tanh shoulder that never
 * reaches full scale, so chords and overlapping release tails can't wrap
 * around or clip hard.
 */

#include <math.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

#if defined(__GNUC__) || defined(__clang__)
#define PIANO_MAYBE_UNUSED __attribute__((unused))
#else
#define PIANO_MAYBE_UNUSED
#endif

/* The damper: −60 dB this long after the release. */
#define PIANO_RELEASE_S 0.25f
#define PIANO_MASTER 0.8f
#define PIANO_KNEE 0.75f

#define PIANO_MAX_VOICES 32
#define PIANO_MAX_NOTES 4096
#define PIANO_MAX_DURATION_MS 600000
#define PIANO_DEFAULT_VELOCITY 100

typedef struct {
    const int16_t *pcm;
    int64_t frames;
    int32_t root_midi; /* 0..127 when indexed by MIDI root */
} piano_sample;

typedef struct {
    int rate;
    int count;
    piano_sample *samples;
} piano_bank;

typedef struct {
    int32_t sample;  /* index into the bank */
    int64_t start;   /* output frame of the strike */
    int64_t release; /* output frame of the note-off, ≥ start */
    double step;     /* source frames per output frame */
    float gain;
} piano_voice;

typedef struct {
    int64_t start_frame;
    int64_t release_frame;
    int32_t midi;
    float gain;
} piano_note;

typedef struct {
    bool active;
    int32_t midi;
    int32_t sample;
    int64_t start_frame;
    int64_t release_frame;
    int64_t end_frame;
    double step;
    float gain;
    float env;
} piano_active_voice;

typedef struct {
    piano_note *notes;
    int32_t note_count;
    int32_t next_note;
    piano_active_voice voices[PIANO_MAX_VOICES];
    int out_rate;
    int64_t release_frames;
    float decay;
    int64_t cursor_frame;
    int64_t phrase_end_frame;
    int64_t total_frames;
} piano_synth;

/* Output frames the release takes to reach −60 dB, and the per-frame decay. */
static PIANO_MAYBE_UNUSED int64_t piano_release_frames(int rate) {
    return (int64_t)(PIANO_RELEASE_S * (float)rate + 0.5f);
}

static PIANO_MAYBE_UNUSED float piano_release_decay(int rate) {
    /* exp(ln(0.001) / frames): ×0.001 (−60 dB) over the release. */
    return expf(-6.9077553f / (float)piano_release_frames(rate));
}

static PIANO_MAYBE_UNUSED int64_t piano_ms_to_frames(double ms, int rate) {
    if (rate <= 0) return -1;
    return (int64_t)llround(ms * (double)rate / 1000.0);
}

static PIANO_MAYBE_UNUSED float piano_soft_clip(float x) {
    float y = x * PIANO_MASTER;
    float a = fabsf(y);
    if (a > PIANO_KNEE) {
        float over = (a - PIANO_KNEE) / (1.0f - PIANO_KNEE);
        a = PIANO_KNEE + (1.0f - PIANO_KNEE) * tanhf(over);
        y = y < 0.0f ? -a : a;
    }
    if (y > 1.0f) y = 1.0f;
    if (y < -1.0f) y = -1.0f;
    return y;
}

/* Pick the closest root sample in `bank` for `midi` and compute the source
 * frame increment for `out_rate`. Returns -1 if no usable root exists. */
static PIANO_MAYBE_UNUSED int32_t piano_pick_sample(const piano_bank *bank, int32_t midi, int out_rate,
                                                    double *step_out) {
    if (!bank || bank->count <= 0 || bank->rate <= 0 || out_rate <= 0) return -1;
    int32_t best = -1;
    int32_t best_dist = 1000;
    for (int32_t i = 0; i < bank->count; i++) {
        const piano_sample *s = &bank->samples[i];
        if (!s->pcm || s->frames < 2 || s->root_midi < 0 || s->root_midi > 127) continue;
        int32_t d = midi - s->root_midi;
        if (d < 0) d = -d;
        if (d < best_dist) {
            best_dist = d;
            best = i;
        }
    }
    if (best < 0) return -1;
    double ratio = pow(2.0, (double)(midi - bank->samples[best].root_midi) / 12.0);
    if (step_out) *step_out = ((double)bank->rate / (double)out_rate) * ratio;
    return best;
}

/* Add one voice into `mix` (`frames` long). Ignores a voice whose sample
 * isn't in the bank. */
static PIANO_MAYBE_UNUSED void piano_add_voice(const piano_bank *bank, const piano_voice *v, float *mix,
                                               int64_t frames) {
    if (v->sample < 0 || v->sample >= bank->count || v->step <= 0.0 || v->start >= frames) return;
    const piano_sample *s = &bank->samples[v->sample];
    if (s->frames < 2) return;

    int64_t release = v->release < v->start ? v->start : v->release;
    int64_t tail = piano_release_frames(bank->rate);
    int64_t end = release + tail;
    /* Where the sample runs out: the last frame that still has a neighbour. */
    int64_t sample_end = v->start + (int64_t)((double)(s->frames - 1) / v->step);
    if (sample_end < end) end = sample_end;
    if (end > frames) end = frames;

    float decay = piano_release_decay(bank->rate);
    float env = 1.0f;
    for (int64_t t = v->start < 0 ? 0 : v->start; t < end; t++) {
        double pos = (double)(t - v->start) * v->step;
        int64_t i = (int64_t)pos;
        if (i + 1 >= s->frames) break;
        float frac = (float)(pos - (double)i);
        float x = (float)s->pcm[i] + frac * (float)(s->pcm[i + 1] - s->pcm[i]);
        if (t >= release) env *= decay;
        mix[t] += x * (1.0f / 32768.0f) * v->gain * env;
    }
}

/* Float to 16-bit through the master gain and the soft clip. */
static PIANO_MAYBE_UNUSED int16_t piano_to_s16(float x) {
    float s = piano_soft_clip(x) * 32767.0f;
    if (s > 32767.0f) s = 32767.0f;
    if (s < -32767.0f) s = -32767.0f;
    return (int16_t)lrintf(s);
}

/* Render `n` voices into `out` (`frames` 16-bit samples). `mix` is scratch
 * space of `frames` floats. */
static PIANO_MAYBE_UNUSED void piano_render(const piano_bank *bank, const piano_voice *voices, int n, float *mix,
                                            int16_t *out, int64_t frames) {
    memset(mix, 0, sizeof(float) * (size_t)frames);
    for (int k = 0; k < n; k++) piano_add_voice(bank, &voices[k], mix, frames);
    for (int64_t t = 0; t < frames; t++) out[t] = piano_to_s16(mix[t]);
}

static int piano_note_cmp(const void *a, const void *b) {
    const piano_note *na = (const piano_note *)a;
    const piano_note *nb = (const piano_note *)b;
    if (na->start_frame < nb->start_frame) return -1;
    if (na->start_frame > nb->start_frame) return 1;
    if (na->midi < nb->midi) return -1;
    if (na->midi > nb->midi) return 1;
    return 0;
}

static PIANO_MAYBE_UNUSED void piano_synth_free(piano_synth *ps) {
    if (!ps) return;
    free(ps->notes);
    memset(ps, 0, sizeof(*ps));
}

/* Prepare streaming synthesis for sorted `notes` (`1..PIANO_MAX_NOTES`) at
 * `out_rate`. Allocates once up front; block rendering allocates nothing. */
static PIANO_MAYBE_UNUSED int piano_synth_init(piano_synth *ps, const piano_bank *bank, const piano_note *notes,
                                               int32_t note_count, int out_rate) {
    if (!ps || !bank || !notes || note_count <= 0 || note_count > PIANO_MAX_NOTES || out_rate <= 0) return -1;
    memset(ps, 0, sizeof(*ps));

    piano_note *copy = calloc((size_t)note_count, sizeof(piano_note));
    if (!copy) return -1;
    memcpy(copy, notes, (size_t)note_count * sizeof(piano_note));
    qsort(copy, (size_t)note_count, sizeof(piano_note), piano_note_cmp);

    int64_t max_frames = piano_ms_to_frames((double)PIANO_MAX_DURATION_MS, out_rate);
    int64_t release_frames = piano_release_frames(out_rate);
    int64_t phrase_end = 0;
    int64_t total_end = 0;

    for (int32_t i = 0; i < note_count; i++) {
        piano_note *n = &copy[i];
        if (n->midi < 0 || n->midi > 127 || n->start_frame < 0 || n->release_frame <= n->start_frame ||
            n->release_frame > max_frames || n->gain <= 0.0f || n->gain > 1.0f) {
            free(copy);
            return -1;
        }
        double step = 0.0;
        int32_t si = piano_pick_sample(bank, n->midi, out_rate, &step);
        if (si < 0 || step <= 0.0) {
            free(copy);
            return -1;
        }
        int64_t sample_end = n->start_frame + (int64_t)floor((double)(bank->samples[si].frames - 1) / step);
        int64_t voice_end = n->release_frame + release_frames;
        if (sample_end < voice_end) voice_end = sample_end;
        if (n->release_frame > phrase_end) phrase_end = n->release_frame;
        if (voice_end > total_end) total_end = voice_end;
    }

    ps->notes = copy;
    ps->note_count = note_count;
    ps->next_note = 0;
    ps->out_rate = out_rate;
    ps->release_frames = release_frames;
    ps->decay = piano_release_decay(out_rate);
    ps->cursor_frame = 0;
    ps->phrase_end_frame = phrase_end;
    ps->total_frames = phrase_end > total_end ? phrase_end : total_end;
    return 0;
}

static void piano_synth_trigger(piano_synth *ps, const piano_bank *bank, const piano_note *n, int64_t frame) {
    double step = 0.0;
    int32_t sample = piano_pick_sample(bank, n->midi, ps->out_rate, &step);
    if (sample < 0 || step <= 0.0) return;

    const piano_sample *s = &bank->samples[sample];
    if (s->frames < 2) return;

    int32_t slot = -1;
    int32_t steal_rel = -1;
    float steal_rel_amp = 1e9f;
    int32_t steal_old = -1;
    int64_t steal_old_start = INT64_MAX;
    float steal_old_amp = 1e9f;

    for (int32_t i = 0; i < PIANO_MAX_VOICES; i++) {
        piano_active_voice *v = &ps->voices[i];
        if (!v->active) {
            if (slot < 0) slot = i;
            continue;
        }
        if (v->midi == n->midi && v->release_frame > frame) {
            v->release_frame = frame;
            int64_t r_end = frame + ps->release_frames;
            if (r_end < v->end_frame) v->end_frame = r_end;
        }
        float amp = v->gain * v->env;
        if (frame >= v->release_frame) {
            if (amp < steal_rel_amp) {
                steal_rel_amp = amp;
                steal_rel = i;
            }
        } else if (v->start_frame < steal_old_start ||
                   (v->start_frame == steal_old_start && amp < steal_old_amp)) {
            steal_old_start = v->start_frame;
            steal_old_amp = amp;
            steal_old = i;
        }
    }

    if (slot < 0) slot = steal_rel >= 0 ? steal_rel : steal_old;
    if (slot < 0) return;

    int64_t sample_end = n->start_frame + (int64_t)floor((double)(s->frames - 1) / step);
    int64_t r_end = n->release_frame + ps->release_frames;
    int64_t end_frame = sample_end < r_end ? sample_end : r_end;
    if (end_frame <= frame) return;

    ps->voices[slot] = (piano_active_voice){
        .active = true,
        .midi = n->midi,
        .sample = sample,
        .start_frame = n->start_frame,
        .release_frame = n->release_frame,
        .end_frame = end_frame,
        .step = step,
        .gain = n->gain,
        .env = 1.0f,
    };
}

/* Render up to `frames` mono float samples into `out`, returning the number of
 * frames produced (0 once past `ps->total_frames`). Zero allocations. */
static PIANO_MAYBE_UNUSED int32_t piano_synth_render_block(piano_synth *ps, const piano_bank *bank, float *out,
                                                           int32_t frames) {
    if (!ps || !bank || !out || frames <= 0) return 0;
    int64_t rem = ps->total_frames - ps->cursor_frame;
    if (rem <= 0) return 0;
    int32_t todo = rem < (int64_t)frames ? (int32_t)rem : frames;

    int32_t pos = 0;
    while (pos < todo) {
        int64_t cur = ps->cursor_frame;
        while (ps->next_note < ps->note_count && ps->notes[ps->next_note].start_frame <= cur) {
            piano_synth_trigger(ps, bank, &ps->notes[ps->next_note], cur);
            ps->next_note++;
        }

        int32_t chunk = todo - pos;
        if (ps->next_note < ps->note_count) {
            int64_t until_next = ps->notes[ps->next_note].start_frame - cur;
            if (until_next > 0 && until_next < (int64_t)chunk) chunk = (int32_t)until_next;
        }

        memset(out + pos, 0, sizeof(float) * (size_t)chunk);

        for (int32_t vi = 0; vi < PIANO_MAX_VOICES; vi++) {
            piano_active_voice *v = &ps->voices[vi];
            if (!v->active) continue;
            const piano_sample *s = &bank->samples[v->sample];
            int64_t v_end = cur + chunk;
            if (v->end_frame < v_end) v_end = v->end_frame;

            for (int64_t f = cur; f < v_end; f++) {
                double spos = (double)(f - v->start_frame) * v->step;
                int64_t idx = (int64_t)spos;
                if (idx < 0 || idx + 1 >= s->frames) {
                    v->active = false;
                    break;
                }
                float frac = (float)(spos - (double)idx);
                float x = (float)s->pcm[idx] + frac * (float)(s->pcm[idx + 1] - s->pcm[idx]);
                if (f >= v->release_frame) v->env *= ps->decay;
                out[pos + (int32_t)(f - cur)] += x * (1.0f / 32768.0f) * v->gain * v->env;
            }
            if (cur + chunk >= v->end_frame) v->active = false;
        }

        ps->cursor_frame += chunk;
        pos += chunk;
    }

    for (int32_t i = 0; i < todo; i++) out[i] = piano_soft_clip(out[i]);
    return todo;
}
