defmodule Humdinger.Engine.Recording do
  @moduledoc """
  A take in progress, for `Humdinger.Engine`: the notes sent and the sung
  pitch since `start/3`, in ms from the start (engine time minus `t0`).
  Pure; `finish/2` turns it into a `Humdinger.Take`.

  Notes come from note on/off pairs: a note sounding at the start begins at
  0, one still sounding at the finish ends there. The trace keeps a pitch at
  most every 10 ms and a single nil where the voice stops.
  """

  alias Humdinger.{Scale, Take}

  @trace_every_ms 10

  @enforce_keys [:t0, :recorded_at]
  defstruct [:t0, :scale, :recorded_at, open: %{}, notes: [], trace: [], trace_t: nil]

  @type t :: %__MODULE__{}

  @doc """
  Start at engine time `t0`. `sounding` is the note already sounding as
  `{midi, velocity}`, or nil; `scale` the take's scale (nil in Open mode).
  """
  @spec start(number(), {0..127, 1..127} | nil, Scale.t() | nil) :: t()
  def start(t0, sounding, scale) do
    open =
      case sounding do
        {midi, velocity} -> %{midi => {0, velocity}}
        nil -> %{}
      end

    %__MODULE__{t0: t0, open: open, scale: scale, recorded_at: DateTime.utc_now()}
  end

  @doc "Add the Tracker events sent at engine time `t`."
  @spec events(t(), [Humdinger.Tracker.event()], number()) :: t()
  def events(%__MODULE__{} = rec, events, t) do
    at = at(rec, t)

    Enum.reduce(events, rec, fn
      {:note_on, midi, velocity}, rec ->
        put_in(rec.open[midi], {at, velocity})

      {:note_off, midi}, rec ->
        case Map.pop(rec.open, midi) do
          {{start, velocity}, open} ->
            %{rec | open: open, notes: [note(midi, start, at, velocity) | rec.notes]}

          {nil, _open} ->
            rec
        end

      _other, rec ->
        rec
    end)
  end

  @doc "Add the sung pitch (fractional MIDI, or nil when not voiced) at engine time `t`."
  @spec trace(t(), number(), float() | nil) :: t()
  def trace(%__MODULE__{} = rec, t, pitch) do
    at = at(rec, t)

    cond do
      pitch == nil and match?([{_, nil} | _], rec.trace) -> rec
      pitch == nil and rec.trace == [] -> rec
      pitch != nil and rec.trace_t != nil and at - rec.trace_t < @trace_every_ms -> rec
      true -> %{rec | trace: [{at, pitch} | rec.trace], trace_t: at}
    end
  end

  @doc "The take, ending at engine time `t`; `{:error, :empty}` without notes."
  @spec finish(t(), number()) :: {:ok, Take.t()} | {:error, :empty}
  def finish(%__MODULE__{} = rec, t) do
    end_ms = at(rec, t)

    notes =
      rec.open
      |> Enum.reduce(rec.notes, fn {midi, {start, velocity}}, notes ->
        [note(midi, start, end_ms, velocity) | notes]
      end)
      |> Enum.sort_by(&{&1.start_ms, &1.midi})

    if notes == [] do
      {:error, :empty}
    else
      {:ok,
       %Take{
         notes: notes,
         trace: Enum.reverse(rec.trace),
         duration_ms: end_ms,
         scale: rec.scale,
         source: :hum,
         recorded_at: rec.recorded_at
       }}
    end
  end

  defp at(rec, t), do: max(round(t - rec.t0), 0)

  defp note(midi, start, stop, velocity),
    do: %{
      start_ms: start,
      dur_ms: max(stop - start, 1),
      midi: midi,
      velocity: velocity,
      unsure: false
    }
end
