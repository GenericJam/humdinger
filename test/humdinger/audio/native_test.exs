defmodule Humdinger.Audio.NativeTest do
  # MobAudioIo.Fake and the NIF double are global: not async.
  use ExUnit.Case, async: false

  # The plugin and the relays log every stream; the assertions are on messages.
  @moduletag :capture_log

  alias Humdinger.Audio.Native
  alias Humdinger.Audio.Native.Analyses
  alias Humdinger.Test.FakeAudioNif, as: Nif
  alias MobAudioIo.Fake, as: Plugin

  @notes [%{start_ms: 0, dur_ms: 250, midi: 60}]

  setup do
    Plugin.reset()
    Plugin.register_processor("hum_mic")
    Plugin.register_processor("hum_piano")
    Nif.reset()
    start_supervised!(Analyses)

    on_exit(fn ->
      Native.Mic.close()
      Native.Piano.close()
      Application.delete_env(:humdinger, :input_preset)
    end)
  end

  defp streams(direction), do: for(%{direction: ^direction} = s <- Plugin.status().streams, do: s)

  defp spawn_owner do
    test = self()

    spawn(fn ->
      receive do
        :exit -> :ok
      end

      send(test, :owner_gone)
    end)
  end

  describe "listen" do
    test "arms the NIF, then opens a mono input on hum_mic with the performance preset" do
      assert {:ok, ref} = Native.listen(self(), spectrum: true)
      me = self()
      assert [{:listen, ^me, ^ref, true}] = Nif.calls()
      assert [%{processor: "hum_mic", preset: :performance, input_channels: 1}] = streams(:input)
    end

    test "stop closes the stream and stops the NIF; a stale ref changes nothing" do
      {:ok, ref} = Native.listen(self(), [])
      assert :ok = Native.stop(make_ref())
      assert [_] = streams(:input)
      assert Nif.listener() == ref

      assert :ok = Native.stop(ref)
      assert streams(:input) == []
      assert Nif.listener() == nil
      assert :ok = Native.stop(ref)
    end

    test "a new listen replaces the old: its stream closes and its ref goes stale" do
      {:ok, old} = Native.listen(self(), [])
      {:ok, new} = Native.listen(self(), [])
      assert [_] = streams(:input)
      assert {:stop, old} in Nif.calls()
      assert Nif.listener() == new
    end

    test "without the microphone permission: {:error, :permission}, and the NIF is disarmed" do
      Plugin.deny_permission()
      assert {:error, :permission} = Native.listen(self(), [])
      assert Nif.listener() == nil
      assert streams(:input) == []
    end

    test "a chosen input the system won't open falls back to the default" do
      Plugin.fail_next_open({:invalid_device, "no input device 7 (AudioManager.getDevices)"})
      assert {:ok, ref} = Native.listen(self(), input: 7)
      assert [_] = streams(:input)
      assert Nif.listener() == ref
    end

    test "the platform refusing the default microphone is :microphone_unavailable" do
      Plugin.fail_next_open({:unavailable, "open: AAUDIO_ERROR_INTERNAL (-896)"})
      assert {:error, :microphone_unavailable} = Native.listen(self(), [])
      assert Nif.listener() == nil
    end

    test "a dead owner: {:error, :owner_dead}, nothing opened" do
      owner = spawn(fn -> :ok end)
      ref = Process.monitor(owner)
      assert_receive {:DOWN, ^ref, _, _, _}
      assert {:error, :owner_dead} = Native.listen(owner, [])
      assert streams(:input) == []
      assert Nif.listener() == nil
    end

    test "the owner's exit closes the stream and stops the NIF" do
      owner = spawn_owner()
      {:ok, ref} = Native.listen(owner, [])
      send(owner, :exit)
      assert_receive :owner_gone, 1000
      wait_until(fn -> streams(:input) == [] end)
      assert {:stop, ref} in Nif.calls()
    end

    test "a lost device ends the listening with {:error, :device_lost} after the NIF stopped" do
      {:ok, ref} = Native.listen(self(), [])
      [%{id: stream}] = streams(:input)
      :ok = Plugin.inject(stream, :device_lost, %{})
      assert_receive {:hum_audio, ^ref, {:error, :device_lost}}, 1000
      assert Nif.listener() == nil
      assert streams(:input) == []
    end

    test "a failed reopen ends it with {:error, :input_error}" do
      {:ok, ref} = Native.listen(self(), [])
      [%{id: stream}] = streams(:input)
      :ok = Plugin.inject(stream, :error, %{reason: :unavailable, detail: "", while: :retry})
      assert_receive {:hum_audio, ^ref, {:error, :input_error}}, 1000
      assert streams(:input) == []
    end

    test "set_input_preset changes the next listen's preset" do
      Native.set_input_preset(:unprocessed)
      {:ok, _} = Native.listen(self(), [])
      assert [%{preset: :unprocessed}] = streams(:input)
    end
  end

  test "info adds the stream's figures while listening" do
    assert %{stream: nil, burst: 0, analyses: 0} = Native.info()
    {:ok, _} = Native.listen(self(), [])

    assert %{listening: true, burst: 192, preset: 0, stream: %{processor: "hum_mic"}} =
             Native.info()
  end

  test "inputs are the plugin's input devices in the contract's kinds" do
    Plugin.set_devices(:input, [
      %{id: 15, name: "Built-in mic", kind: :builtin_mic},
      %{id: 22, name: "Buds", kind: :bluetooth_a2dp},
      %{id: 30, name: "Dock", kind: :car}
    ])

    assert [
             %{id: 15, kind: :builtin_mic},
             %{id: 22, name: "Buds", kind: :bluetooth},
             %{id: 30, kind: :other}
           ] = Native.inputs()
  end

  describe "analyze_file" do
    setup do
      dir = Path.join(System.tmp_dir!(), "hum_native_#{System.unique_integer([:positive])}")
      File.mkdir_p!(dir)
      on_exit(fn -> File.rm_rf(dir) end)
      path = Path.join(dir, "tone.wav")
      File.write!(path, wav(48_000, 24_000))
      %{path: path, dir: dir}
    end

    test "decodes and analyses the file", %{path: path} do
      assert {:ok, ref} = Native.analyze_file(self(), path, [])
      assert_receive {:hum_audio, ^ref, {:analysis, %{duration_ms: 500}}}, 2000
      wait_until(fn -> Analyses.running() == 0 end)
    end

    test "decoding errors arrive in the contract's words", %{dir: dir} do
      {:ok, ref} = Native.analyze_file(self(), Path.join(dir, "missing.m4a"), [])
      assert_receive {:hum_audio, ^ref, {:analysis_error, :not_found}}, 2000

      garbage = Path.join(dir, "garbage.wav")
      File.write!(garbage, "not a wav file at all")
      {:ok, ref} = Native.analyze_file(self(), garbage, [])
      assert_receive {:hum_audio, ^ref, {:analysis_error, reason}}, 2000
      assert reason in [:unsupported, :decode_error]
    end

    test "a newer analysis by the same owner cancels the older, which sends nothing", %{
      path: path
    } do
      Nif.set(:push_delay, 100)
      {:ok, old} = Native.analyze_file(self(), path, [])
      {:ok, new} = Native.analyze_file(self(), path, [])
      assert_receive {:hum_audio, ^new, {:analysis, _}}, 2000
      refute_received {:hum_audio, ^old, _}
      wait_until(fn -> Analyses.running() == 0 end)
    end

    test "two owners at once; a third is busy", %{path: path} do
      Nif.set(:push_delay, 200)
      a = spawn_owner()
      b = spawn_owner()
      {:ok, _} = Native.analyze_file(a, path, [])
      {:ok, _} = Native.analyze_file(b, path, [])
      assert Analyses.running() == 2
      assert {:error, :busy} = Native.analyze_file(self(), path, [])
      # An owner with a running job may still replace it.
      assert {:ok, _} = Native.analyze_file(a, path, [])
      send(a, :exit)
      send(b, :exit)
      wait_until(fn -> Analyses.running() == 0 end)
    end

    test "a cancelled analysis stops within a chunk, not at the end of the file", %{dir: dir} do
      # Ten one-second chunks at 100 ms each: a full run takes a second.
      path = Path.join(dir, "long.wav")
      File.write!(path, wav(48_000, 480_000))
      Nif.set(:push_delay, 100)
      {:ok, ref} = Native.analyze_file(self(), path, [])
      wait_until(fn -> Analyses.running() == 1 end)
      Process.sleep(150)
      t0 = System.monotonic_time(:millisecond)
      assert :ok = Native.cancel_analysis(ref)
      wait_until(fn -> Analyses.running() == 0 end)
      assert System.monotonic_time(:millisecond) - t0 < 400
      refute_received {:hum_audio, ^ref, _}
    end

    test "cancel_analysis: nothing arrives for the ref", %{path: path} do
      Nif.set(:push_delay, 100)
      {:ok, ref} = Native.analyze_file(self(), path, [])
      assert :ok = Native.cancel_analysis(ref)
      wait_until(fn -> Analyses.running() == 0 end)
      refute_received {:hum_audio, ^ref, _}
    end

    test "the owner's exit cancels its analysis", %{path: path} do
      Nif.set(:push_delay, 100)
      owner = spawn_owner()
      {:ok, _} = Native.analyze_file(owner, path, [])
      send(owner, :exit)
      wait_until(fn -> Analyses.running() == 0 end)
      assert {:error, :owner_dead} = Native.analyze_file(owner, path, [])
    end
  end

  describe "play_piano" do
    test "prepares the phrase, opens a mono output on hum_piano, reports positions, then finishes" do
      Nif.positions([
        {:playing, 0, nil},
        {:playing, 120, nil},
        {:playing, 240, 3.0},
        {:finished, 250}
      ])

      assert {:ok, ref} = Native.play_piano(self(), @notes)
      assert [{:piano_prepare, @notes, dir}] = Nif.calls()
      assert dir =~ "priv/piano"
      assert [%{processor: "hum_piano", channels: 1}] = streams(:output)

      assert_receive {:hum_audio, ^ref, {:piano_position, 0}}, 1000
      assert_receive {:hum_audio, ^ref, {:piano_position, 120}}, 1000
      assert_receive {:hum_audio, ^ref, {:piano_position, 240}}, 1000
      assert_receive {:hum_audio, ^ref, {:piano_position, 250}}, 1000
      assert_receive {:hum_audio, ^ref, :piano_finished}, 1000
      wait_until(fn -> streams(:output) == [] end)
    end

    test "positions never go back" do
      Nif.positions([{:playing, 100, nil}, {:playing, 90, nil}, {:finished, 100}])
      {:ok, ref} = Native.play_piano(self(), @notes)
      assert_receive {:hum_audio, ^ref, :piano_finished}, 1000
      assert_received {:hum_audio, ^ref, {:piano_position, 100}}
      refute_received {:hum_audio, ^ref, {:piano_position, 90}}
    end

    test "cancel_piano closes the stream; nothing more arrives" do
      {:ok, ref} = Native.play_piano(self(), @notes)
      assert :ok = Native.cancel_piano(ref)
      assert streams(:output) == []
      flush(ref)
      Process.sleep(80)
      refute_received {:hum_audio, ^ref, _}
      assert :ok = Native.cancel_piano(ref)
    end

    test "a newer preview preempts the older" do
      {:ok, old} = Native.play_piano(self(), @notes)
      {:ok, new} = Native.play_piano(self(), @notes)
      assert [_] = streams(:output)
      flush(old)
      Process.sleep(80)
      refute_received {:hum_audio, ^old, _}
      assert :ok = Native.cancel_piano(old)
      assert [_] = streams(:output)
      assert :ok = Native.cancel_piano(new)
    end

    test "a lost output device ends it with {:piano_error, :device_lost}" do
      {:ok, ref} = Native.play_piano(self(), @notes)
      [%{id: stream}] = streams(:output)
      :ok = Plugin.inject(stream, :device_lost, %{})
      assert_receive {:hum_audio, ^ref, {:piano_error, :device_lost}}, 1000
      wait_until(fn -> streams(:output) == [] end)
    end

    test "a phrase the stream couldn't play ends it with the NIF's reason" do
      Nif.positions([{:failed, :output_error}])
      {:ok, ref} = Native.play_piano(self(), @notes)
      assert_receive {:hum_audio, ^ref, {:piano_error, :output_error}}, 1000
      wait_until(fn -> streams(:output) == [] end)
    end

    test "notes the NIF refuses: the error, and no stream" do
      Nif.set(:prepare, {:error, :invalid_notes})
      assert {:error, :invalid_notes} = Native.play_piano(self(), @notes)
      assert streams(:output) == []
    end

    test "the player's exit closes the stream" do
      owner = spawn_owner()
      {:ok, _} = Native.play_piano(owner, @notes)
      send(owner, :exit)
      wait_until(fn -> streams(:output) == [] end)
    end

    test "off the phone (no NIF): {:error, :unsupported}" do
      Application.put_env(:humdinger, :audio_nif, Humdinger.Audio.Nif)
      on_exit(fn -> Application.put_env(:humdinger, :audio_nif, Nif) end)
      assert {:error, :unsupported} = Native.play_piano(self(), @notes)
      assert {:error, :unsupported} = Native.listen(self(), [])
    end
  end

  defp flush(ref) do
    receive do
      {:hum_audio, ^ref, _} -> flush(ref)
    after
      0 -> :ok
    end
  end

  defp wait_until(fun, tries \\ 200) do
    cond do
      fun.() -> :ok
      tries == 0 -> flunk("condition never held")
      true -> Process.sleep(10) && wait_until(fun, tries - 1)
    end
  end

  # A mono 16-bit WAV: `frames` of a 440 Hz sine at `rate`.
  defp wav(rate, frames) do
    data =
      for i <- 0..(frames - 1), into: <<>> do
        <<round(8000 * :math.sin(2 * :math.pi() * 440 * i / rate))::little-signed-16>>
      end

    fmt =
      <<1::little-16, 1::little-16, rate::little-32, rate * 2::little-32, 2::little-16,
        16::little-16>>

    body =
      "WAVE" <>
        "fmt " <>
        <<byte_size(fmt)::little-32>> <> fmt <> "data" <> <<byte_size(data)::little-32>> <> data

    "RIFF" <> <<byte_size(body)::little-32>> <> body
  end
end
