defmodule Humdinger.Take do
  @moduledoc """
  What a recording captured, before it becomes a `Humdinger.Phrase`: the
  notes Humdinger sent while recording and the pitch the singer actually
  sang ("the faint line" on the Review screen). `Humdinger.Engine` returns
  one from `record_stop/0`, `Humdinger.Transcribe` builds one from an audio
  file; `Humdinger.Phrase.from_take/2` turns either into a phrase.

  Times are milliseconds from the start of the take.

  - `notes` — `%{start_ms, dur_ms, midi, velocity, unsure}`, in start order.
    `unsure` marks a note the detector wasn't confident about (Import shows
    them faded).
  - `trace` — `{t_ms, pitch}` samples of the sung pitch as a fractional MIDI
    number, `nil` where nothing was voiced; at most one every 10 ms.
  - `scale` — the `Humdinger.Scale` the notes were snapped to, or `nil` when
    they weren't (Live's "Open + bend" mode).
  - `tempo_bpm` — the tempo the take was performed at, when known (a
    metronome); `nil` asks the phrase to detect it.
  - `source` — `:hum`, or `{:file, filename}` for an imported recording.
  """

  @enforce_keys [:notes, :trace, :duration_ms, :source]
  defstruct notes: [],
            trace: [],
            duration_ms: 0,
            scale: nil,
            tempo_bpm: nil,
            source: :hum,
            recorded_at: nil

  @type note :: %{
          start_ms: non_neg_integer(),
          dur_ms: pos_integer(),
          midi: 0..127,
          velocity: 1..127,
          unsure: boolean()
        }
  @type t :: %__MODULE__{
          notes: [note()],
          trace: [{non_neg_integer(), float() | nil}],
          duration_ms: non_neg_integer(),
          scale: Humdinger.Scale.t() | nil,
          tempo_bpm: number() | nil,
          source: :hum | {:file, String.t()},
          recorded_at: DateTime.t() | nil
        }
end
