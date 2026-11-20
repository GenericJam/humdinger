defmodule Humdinger.Engine.Notice do
  @moduledoc """
  What the background notification shows (`MobBackground`, the
  "Singing into FMutate" board), from the engine's state. Pure.

  | engine | title | text | buttons (`state`) |
  |---|---|---|---|
  | singing | Humdinger · listening | `A4 −12¢ → FMutate A · ch 1` | `:listening` |
  | nothing voiced | Humdinger · listening | `listening… → FMutate A · ch 1` | `:listening` |
  | recording | Humdinger · recording | as above | `:recording` |
  | paused | Humdinger · paused | `paused → FMutate A · ch 1` | `:paused` |
  | microphone error | Humdinger · no microphone | `microphone disconnected · Resume to try again` | `:paused` |

  The destination is the first one enabled and available
  (`Humdinger.Output.destinations/0`); with none the arrow part is left out
  (`A4 · ch 1`). A note held over a breath shows without cents.
  `notification/1` turns a notice into the `MobBackground` notification map
  with its three action buttons.
  """

  alias Humdinger.{Music, Tracker}

  @type t :: %{title: String.t(), text: String.t(), state: :listening | :paused | :recording}
  @type action :: %{id: atom(), label: String.t()}
  @type notification :: %{title: String.t(), text: String.t(), actions: [action()]}

  @doc """
  The notice for `status` (`Humdinger.Engine.status/0`), whether a take is
  being recorded, the tracker's display (`note`, `cents`), the destination
  name (or nil) and the MIDI channel.
  """
  @spec build(
          Humdinger.Engine.status(),
          boolean(),
          %{note: 0..127 | nil, cents: number() | nil},
          String.t() | nil,
          1..16
        ) :: t()
  def build({:error, reason}, _recording?, _display, _destination, _channel),
    do: %{
      title: "Humdinger · no microphone",
      text: "#{problem(reason)} · Resume to try again",
      state: :paused
    }

  def build(:paused, _recording?, _display, destination, channel),
    do: %{title: "Humdinger · paused", text: text("paused", destination, channel), state: :paused}

  def build(_listening, recording?, display, destination, channel) do
    {title, state} =
      if recording?,
        do: {"Humdinger · recording", :recording},
        else: {"Humdinger · listening", :listening}

    %{title: title, text: text(lead(display), destination, channel), state: state}
  end

  @doc """
  Turns a notice into the `MobBackground` notification map (`title`, `text`,
  and the three action buttons for `state`).
  """
  @spec notification(t()) :: notification()
  def notification(%{title: title, text: text, state: state}) do
    %{title: title, text: text, actions: actions(state)}
  end

  @doc """
  Destination name for the notice: the first destination that is enabled and
  available, or nil.
  """
  @spec destination([%{name: String.t(), enabled: boolean(), available: boolean()}]) ::
          String.t() | nil
  def destination(destinations),
    do: Enum.find_value(destinations, fn d -> d.enabled and d.available and d.name end)

  defp actions(state) do
    [
      if(state == :paused,
        do: %{id: :resume, label: "Resume"},
        else: %{id: :pause, label: "Pause"}
      ),
      if(state == :recording,
        do: %{id: :record_stop, label: "Stop rec"},
        else: %{id: :record, label: "Record"}
      ),
      %{id: :stop, label: "Stop"}
    ]
  end

  defp lead(%{note: nil}), do: "listening…"
  defp lead(%{note: note, cents: nil}), do: Music.note_name(note)

  defp lead(%{note: note, cents: cents}),
    do: "#{Music.note_name(note)} #{Tracker.cents_text(cents)}"

  defp text(lead, nil, channel), do: "#{lead} · ch #{channel}"
  defp text(lead, destination, channel), do: "#{lead} → #{destination} · ch #{channel}"

  defp problem(:permission), do: "microphone not allowed"
  defp problem(:device_lost), do: "microphone disconnected"
  defp problem(:microphone_unavailable), do: "microphone in use"
  defp problem(_other), do: "microphone stopped"
end
