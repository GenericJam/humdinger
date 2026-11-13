defmodule Humdinger.LiveFeed do
  @moduledoc """
  The last few seconds of Engine frames, kept for the Live and Spectrum
  screens: the sung pitch as `{t, pitch}` samples (one nil per gap) and
  the notes sent, as `%{start_ms, end_ms, midi}` (`end_ms: nil` while
  sounding). A note starts when a frame's `note` (the sent note) changes
  to it and ends when it changes again. Times are the frames' `t` (the
  engine clock). Anything that ended more than `keep_ms` before the
  newest frame is dropped.

  Pure: `push/2` a frame, read `trace/1` and `notes/1` (oldest first).
  """

  @default_keep_ms 4_500

  defstruct trace: [], notes: [], now: nil, keep_ms: @default_keep_ms

  @type note :: %{start_ms: integer(), end_ms: integer() | nil, midi: integer()}
  @type t :: %__MODULE__{
          trace: [{integer(), float() | nil}],
          notes: [note()],
          now: integer() | nil,
          keep_ms: pos_integer()
        }

  @doc "An empty feed keeping `keep_ms` of history (default #{@default_keep_ms})."
  @spec new(pos_integer()) :: t()
  def new(keep_ms \\ @default_keep_ms), do: %__MODULE__{keep_ms: keep_ms}

  @doc """
  Add a frame (`%{t, pitch, note}`). Frames without a time (the engine is
  off) are ignored; a frame older than the newest one starts the feed over
  (a new engine).
  """
  @spec push(t(), map()) :: t()
  def push(feed, %{t: nil}), do: feed

  def push(%{now: now} = feed, %{t: t} = frame) when is_integer(now) and t < now,
    do: push(new(feed.keep_ms), frame)

  def push(feed, %{t: t} = frame) do
    %{feed | now: t}
    |> add_sample(t, Map.get(frame, :pitch))
    |> add_note(t, Map.get(frame, :note))
    |> prune()
  end

  @doc "Pitch samples, oldest first."
  @spec trace(t()) :: [{integer(), float() | nil}]
  def trace(feed), do: Enum.reverse(feed.trace)

  @doc "Sent notes, oldest first."
  @spec notes(t()) :: [note()]
  def notes(feed), do: Enum.reverse(feed.notes)

  @doc "The latest sung pitch, nil when the voice is silent."
  @spec pitch(t()) :: float() | nil
  def pitch(%{trace: [{_t, pitch} | _]}), do: pitch
  def pitch(_feed), do: nil

  @doc """
  Whether anything is drawn in the `window_ms` before the newest frame: a
  voiced sample or a note. A feed that shows nothing doesn't need redrawing
  as time passes.
  """
  @spec visible?(t(), pos_integer()) :: boolean()
  def visible?(%{now: nil}, _window_ms), do: false

  def visible?(feed, window_ms) do
    from = feed.now - window_ms

    Enum.any?(feed.notes, &(&1.end_ms == nil or &1.end_ms >= from)) or
      Enum.any?(feed.trace, fn {t, pitch} -> pitch != nil and t >= from end)
  end

  defp add_sample(%{trace: [{_last, nil} | _]} = feed, _t, nil), do: feed
  defp add_sample(%{trace: []} = feed, _t, nil), do: feed
  defp add_sample(feed, t, pitch), do: %{feed | trace: [{t, pitch} | feed.trace]}

  defp add_note(%{notes: [%{end_ms: nil, midi: midi} | _]} = feed, _t, midi), do: feed

  defp add_note(feed, t, midi) do
    notes =
      case feed.notes do
        [%{end_ms: nil} = open | rest] -> [%{open | end_ms: t} | rest]
        notes -> notes
      end

    notes = if midi, do: [%{start_ms: t, end_ms: nil, midi: midi} | notes], else: notes
    %{feed | notes: notes}
  end

  # Keeps one sample before the cut so the line still enters from the edge.
  defp prune(feed) do
    cut = feed.now - feed.keep_ms
    {recent, older} = Enum.split_while(feed.trace, fn {t, _} -> t >= cut end)
    trace = recent ++ Enum.take(older, 1)
    notes = Enum.filter(feed.notes, &(&1.end_ms == nil or &1.end_ms >= cut))
    %{feed | trace: trace, notes: notes}
  end
end
