defmodule Humdinger.Test.FakeAudio do
  @moduledoc """
  A scripted microphone for host tests, with the `Humdinger.Audio.Fake`
  test API: `sing/2` delivers readings, `spectrum/2` a spectrum column,
  `fail/2` ends listening with an error, `listening?/1` and `spectrum?/1`
  report what the listener asked for, `current/0` is the live reference.
  `refuse_next/1` makes the next `listen/2` fail (e.g. `:permission`).

  One listener at a time, as on the phone: a new `listen/2` makes the old
  reference stale. State lives in an unlinked, named Agent, so tests using
  it run `async: false`.
  """

  @behaviour Humdinger.Audio

  @impl Humdinger.Audio
  def listen(owner, opts) do
    case update(fn s -> {s.refuse, %{s | refuse: nil}} end) do
      nil ->
        ref = make_ref()
        spectrum = Keyword.get(opts, :spectrum, false)

        update(fn s ->
          {:ok, %{s | current: ref, owners: Map.put(s.owners, ref, owner), spectrum: spectrum}}
        end)

        {:ok, ref}

      reason ->
        {:error, reason}
    end
  end

  @impl Humdinger.Audio
  def set_spectrum(ref, on?) do
    update(fn s -> {:ok, if(s.current == ref, do: %{s | spectrum: on?}, else: s)} end)
  end

  @impl Humdinger.Audio
  def stop(ref) do
    update(fn s ->
      {:ok, if(s.current == ref, do: %{s | current: nil, spectrum: false}, else: s)}
    end)
  end

  @impl Humdinger.Audio
  def inputs, do: [%{id: :builtin, name: "Phone", kind: :builtin_mic}]

  @impl Humdinger.Audio
  def analyze_file(_owner, _path, _opts), do: {:error, :not_supported}

  @doc "Deliver readings to the listener that got `ref` (stale or not)."
  def sing(ref, readings), do: deliver(ref, {:readings, readings})

  @doc "Deliver a spectrum column."
  def spectrum(ref, spectrum), do: deliver(ref, {:spectrum, spectrum})

  @doc "End listening with an error, as a lost device does."
  def fail(ref, reason) do
    deliver(ref, {:error, reason})
    stop(ref)
  end

  @doc "Make the next `listen/2` return `{:error, reason}`."
  def refuse_next(reason), do: update(fn s -> {:ok, %{s | refuse: reason}} end)

  @doc "The live reference, or nil."
  def current, do: update(fn s -> {s.current, s} end)

  def listening?(ref), do: current() == ref

  def spectrum?(ref), do: update(fn s -> {s.current == ref and s.spectrum, s} end)

  @doc "Forget everything (call from a test's setup)."
  def reset, do: update(fn _ -> {:ok, initial()} end)

  defp deliver(ref, message) do
    owner = update(fn s -> {Map.fetch!(s.owners, ref), s} end)
    send(owner, {:hum_audio, ref, message})
    :ok
  end

  defp update(fun) do
    ensure_started()
    Agent.get_and_update(__MODULE__, fun)
  end

  defp ensure_started do
    case Agent.start(&initial/0, name: __MODULE__) do
      {:ok, _} -> :ok
      {:error, {:already_started, _}} -> :ok
    end
  end

  defp initial, do: %{current: nil, owners: %{}, spectrum: false, refuse: nil}
end
