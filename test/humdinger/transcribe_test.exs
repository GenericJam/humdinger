defmodule Humdinger.TranscribeTest do
  use ExUnit.Case, async: true

  alias Humdinger.{Music, Scale, Take, Transcribe}

  # Renders events to readings every 10 ms, as Humdinger.Audio's analysis
  # would report them:
  #   {midi, ms}                a held note (fractional MIDI allowed)
  #   {:glide, from, to, ms}    a linear slide
  #   {:rest, ms}               silence
  #   {:noise, ms}              breath/noise: random pitch, low clarity
  # Options: seed, jitter (cents, uniform ±), vibrato {cents, hz},
  # clarity {lo, hi}, db.
  defp render(events, opts \\ []) do
    :rand.seed(:exsss, Keyword.get(opts, :seed, {1, 2, 3}))

    {readings, end_ms} =
      Enum.reduce(events, {[], 0}, fn event, {acc, t0} ->
        ms = event_ms(event)
        frames = for t <- t0..(t0 + ms - 10)//10, do: reading(event, t, t - t0, ms, opts)
        {Enum.reverse(frames, acc), t0 + ms}
      end)

    %{duration_ms: end_ms, waveform: <<>>, readings: Enum.reverse(readings)}
  end

  defp event_ms({:glide, _from, _to, ms}), do: ms
  defp event_ms({_kind, ms}), do: ms

  defp reading({:rest, _ms}, t, _dt, _ms2, _opts),
    do: %{t: t, hz: nil, clarity: 0.1, db: -90.0}

  defp reading({:noise, _ms}, t, _dt, _ms2, _opts) do
    hz = if :rand.uniform() < 0.6, do: 80 + :rand.uniform() * 800
    %{t: t, hz: hz, clarity: 0.1 + :rand.uniform() * 0.3, db: -35.0 + :rand.uniform() * 5}
  end

  defp reading({:glide, from, to, _ms}, t, dt, ms, opts),
    do: voiced(t, from + (to - from) * dt / ms, dt, opts)

  defp reading({midi, _ms}, t, dt, _ms2, opts), do: voiced(t, midi, dt, opts)

  defp voiced(t, pitch, dt, opts) do
    jitter = Keyword.get(opts, :jitter, 5) / 100 * (2 * :rand.uniform() - 1)

    vibrato =
      case Keyword.get(opts, :vibrato) do
        nil -> 0.0
        {cents, rate} -> cents / 100 * :math.sin(2 * :math.pi() * rate * dt / 1000)
      end

    {lo, hi} = Keyword.get(opts, :clarity, {0.85, 0.97})

    %{
      t: t,
      hz: Music.midi_to_hz(pitch + jitter + vibrato),
      clarity: lo + (hi - lo) * :rand.uniform(),
      db: Keyword.get(opts, :db, -20.0) + 2 * :rand.uniform()
    }
  end

  defp midis({%Take{notes: notes}, _stats}), do: Enum.map(notes, & &1.midi)

  # A legato line: each note followed by a short breath.
  defp line(notes, gap_ms \\ 40),
    do: Enum.flat_map(notes, fn {midi, ms} -> [{midi, ms - gap_ms}, {:rest, gap_ms}] end)

  @e_minor_tune [
    {64, 357},
    {66, 357},
    {67, 714},
    {71, 357},
    {69, 357},
    {67, 714},
    {66, 357},
    {64, 357},
    {62, 357},
    {64, 1071},
    {67, 357},
    {71, 714},
    {69, 714},
    {64, 1428}
  ]

  test "a clean melody comes out note for note, on time, clear and confident" do
    analysis =
      render([{:rest, 200} | line([{60, 400}, {62, 300}, {64, 300}, {67, 600}, {65, 400}])])

    {take, stats} = Transcribe.take(analysis, snap: :chromatic, quantize: :off, name: "memo.m4a")

    assert Enum.map(take.notes, & &1.midi) == [60, 62, 64, 67, 65]

    starts = [200, 600, 900, 1200, 1800]
    durs = [360, 260, 260, 560, 360]

    for {note, start, dur} <- Enum.zip([take.notes, starts, durs]) do
      assert_in_delta note.start_ms, start, 10
      assert_in_delta note.dur_ms, dur, 20
      refute note.unsure
      assert note.velocity in 80..127
    end

    assert take.source == {:file, "memo.m4a"}
    assert take.scale == Scale.chromatic()
    assert take.duration_ms == analysis.duration_ms
    assert %{note_count: 5, unsure_count: 0, voices: :one, clear: true} = stats
  end

  test "the trace follows the sung pitch, nil where nothing was voiced, at most every 10 ms" do
    {take, _stats} = Transcribe.take(render([{:rest, 100}, {69, 300}, {:rest, 100}]))

    assert {0, nil} = hd(take.trace)
    assert {100, p} = Enum.find(take.trace, fn {t, _p} -> t == 100 end)
    assert_in_delta p, 69.0, 0.1
    assert {490, nil} = List.last(take.trace)

    gaps =
      take.trace |> Enum.chunk_every(2, 1, :discard) |> Enum.map(fn [{a, _}, {b, _}] -> b - a end)

    assert Enum.all?(gaps, &(&1 >= 10))
  end

  test "vibrato of ±50 cents at 5–6 Hz stays one confident note" do
    for rate <- [5.0, 6.0] do
      {take, _} =
        Transcribe.take(render([{:rest, 100}, {67, 1200}, {:rest, 100}], vibrato: {50, rate}))

      assert [%{midi: 67, unsure: false, dur_ms: dur}] = take.notes
      assert_in_delta dur, 1200, 20
    end
  end

  test "a glide between two notes gives the two notes, not a staircase" do
    for glide_ms <- [120, 250, 400] do
      events = [{:rest, 100}, {62, 400}, {:glide, 62, 67, glide_ms}, {67, 400}, {:rest, 100}]
      {take, _} = Transcribe.take(render(events), snap: :chromatic, quantize: :off)

      assert [%{midi: 62} = a, %{midi: 67} = b] = take.notes
      assert a.start_ms + a.dur_ms <= b.start_ms
      assert_in_delta b.start_ms + b.dur_ms, 100 + 800 + glide_ms, 10
    end
  end

  test "a scoop into a note joins the note" do
    events = [{:rest, 100}, {:glide, 63, 65, 70}, {65, 500}, {:rest, 100}]
    {take, _} = Transcribe.take(render(events), snap: :chromatic, quantize: :off)

    assert [%{midi: 65, start_ms: start}] = take.notes
    assert_in_delta start, 100, 10
  end

  test "isolated octave slips are folded back; a real octave leap stays" do
    analysis = render([{:rest, 100}, {57, 600}, {69, 600}, {:rest, 100}])

    glitched =
      Map.update!(analysis, :readings, fn readings ->
        Enum.map(readings, fn
          %{t: t, hz: hz} = r when t in [250, 260, 400, 800, 810] -> %{r | hz: hz * 2}
          %{t: 1000, hz: hz} = r -> %{r | hz: hz / 2}
          r -> r
        end)
      end)

    {take, _} = Transcribe.take(glitched, snap: :chromatic, quantize: :off)
    assert midis({take, nil}) == [57, 69]
    refute Enum.any?(take.notes, & &1.unsure)

    trace = for {t, p} <- take.trace, p != nil, do: {t, p}
    assert Enum.all?(trace, fn {t, p} -> abs(p - if(t < 700, do: 57, else: 69)) < 1 end)
  end

  test "noise and silence give no notes" do
    analysis = render([{:rest, 300}, {:noise, 1500}, {:rest, 300}])
    {take, stats} = Transcribe.take(analysis)

    assert take.notes == []
    assert Enum.all?(take.trace, fn {_t, p} -> p == nil end)
    assert %{note_count: 0, unsure_count: 0, scale: nil, tempo_bpm: nil, clear: false} = stats
  end

  test "noise between notes doesn't add notes" do
    events = [{60, 400}, {:noise, 400}, {64, 400}, {:noise, 400}, {67, 400}]
    {take, _} = Transcribe.take(render(events), snap: :chromatic, quantize: :off)
    assert midis({take, nil}) == [60, 64, 67]
  end

  test "an empty or silent analysis gives an empty take with sensible stats" do
    empty = %{duration_ms: 0, waveform: <<>>, readings: []}

    for analysis <- [empty, render([{:rest, 2000}])] do
      {take, stats} = Transcribe.take(analysis)

      assert take.notes == []
      assert take.duration_ms == analysis.duration_ms
      assert take.tempo_bpm == nil

      assert stats == %{
               note_count: 0,
               unsure_count: 0,
               scale: nil,
               tempo_bpm: nil,
               voices: :one,
               clear: false
             }
    end
  end

  test "notes shorter than min_ms are dropped" do
    events = [{60, 300}, {:rest, 60}, {72, 40}, {:rest, 60}, {64, 300}]
    analysis = render(events)

    assert midis(Transcribe.take(analysis, snap: :chromatic, quantize: :off)) == [60, 64]

    assert midis(Transcribe.take(analysis, snap: :chromatic, quantize: :off, min_ms: 30)) ==
             [60, 72, 64]

    assert midis(Transcribe.take(analysis, snap: :chromatic, quantize: :off, min_ms: 400)) == []
  end

  test "same-pitch fragments across a tiny dropout merge into one note" do
    events = [{:rest, 100}, {62, 250}, {:rest, 20}, {62, 250}, {:rest, 100}]
    {take, _} = Transcribe.take(render(events), snap: :chromatic, quantize: :off)

    assert [%{midi: 62, start_ms: 100, dur_ms: 520}] = take.notes
  end

  test "a range re-times notes from its start and cuts notes at its edges" do
    analysis = render([{60, 500}, {:rest, 100}, {64, 500}, {:rest, 100}, {67, 500}])

    {take, _} = Transcribe.take(analysis, range: {300, 1400}, snap: :chromatic, quantize: :off)

    assert take.duration_ms == 1100
    assert [%{midi: 60} = a, %{midi: 64} = b, %{midi: 67} = c] = take.notes
    assert {a.start_ms, a.dur_ms} == {0, 200}
    assert {b.start_ms, b.dur_ms} == {300, 500}
    assert {c.start_ms, c.dur_ms} == {900, 200}
    assert {0, _} = hd(take.trace)
    assert {t_last, _} = List.last(take.trace)
    assert t_last < 1100

    {take, _} = Transcribe.take(analysis, range: {1250, 1300}, quantize: :off)
    assert take.notes == []
    assert take.duration_ms == 50
  end

  test "pitches snap to the snap scale, or to the nearest semitone for chromatic" do
    # E, F# and a G sung 30 cents flat... then an F a bit sharp: not in E minor.
    events = line([{64, 500}, {66, 500}, {66.7, 500}, {65.3, 500}, {64, 500}])
    analysis = render(events)

    e_minor = Scale.new("E", :minor)
    {take, stats} = Transcribe.take(analysis, snap: e_minor, quantize: :off)
    assert midis({take, stats}) == [64, 66, 67, 66, 64]
    assert take.scale == e_minor
    assert Enum.map(take.notes, & &1.unsure) == [false, false, false, true, false]

    {take, _} = Transcribe.take(analysis, snap: :chromatic, quantize: :off)
    assert midis({take, nil}) == [64, 66, 67, 65, 64]
    assert Enum.map(take.notes, & &1.unsure) == [false, false, false, false, false]
  end

  test "the default snap is the detected scale, E minor for an E-minor tune" do
    {take, stats} = Transcribe.take(render(line(@e_minor_tune)), quantize: :off)

    assert Scale.name(stats.scale) == "E minor"
    assert take.scale == stats.scale
    assert midis({take, stats}) == Enum.map(@e_minor_tune, &elem(&1, 0))
  end

  test "low clarity or an unsteady pitch makes a note unsure, and the take not clear" do
    analysis = render([{:rest, 100}, {60, 500}, {:rest, 100}])
    murky = render([{:rest, 100}, {60, 500}, {:rest, 100}], clarity: {0.5, 0.65})
    shaky = render([{:rest, 100}, {60, 500}, {:rest, 100}], jitter: 110)

    assert {%{notes: [%{midi: 60, unsure: false}]}, %{clear: true}} =
             Transcribe.take(analysis, snap: :chromatic)

    assert {%{notes: [%{midi: 60, unsure: true}]}, %{clear: false, unsure_count: 1}} =
             Transcribe.take(murky, snap: :chromatic)

    {take, stats} = Transcribe.take(shaky, snap: :chromatic)
    assert take.notes != []
    assert Enum.all?(take.notes, & &1.unsure)
    assert stats.unsure_count == length(take.notes)
    refute stats.clear
  end

  test "velocity follows the level relative to the loudest notes" do
    events = [{60, 300}, {:rest, 100}, {62, 300}]
    loud = render(events, db: -12.0)

    quieter =
      Map.update!(loud, :readings, fn readings ->
        Enum.map(readings, fn r -> if r.t >= 400, do: %{r | db: r.db - 15}, else: r end)
      end)

    {take, _} = Transcribe.take(quieter, snap: :chromatic, quantize: :off)
    assert [%{velocity: v1}, %{velocity: v2}] = take.notes
    assert v1 in 90..127
    assert v2 in 1..127
    assert (v1 - v2) in 35..55
  end

  test "the tempo is found from the onsets and notes are quantized to its grid" do
    analysis = render([{:rest, 300} | line(@e_minor_tune)], seed: {7, 8, 9})

    {take, stats} = Transcribe.take(analysis)
    assert stats.tempo_bpm in 82..86
    assert take.tempo_bpm == stats.tempo_bpm

    sixteenth = 15_000 / stats.tempo_bpm

    for n <- take.notes do
      steps = n.start_ms / sixteenth
      assert_in_delta steps, round(steps), 0.02
    end

    {as_sung, _} = Transcribe.take(analysis, quantize: :off)
    assert Enum.map(as_sung.notes, & &1.start_ms) |> hd() |> Kernel.-(300) |> abs() <= 10
  end

  test "without a tempo, notes stay as sung" do
    {take, stats} = Transcribe.take(render([{:rest, 130}, {60, 470}, {:rest, 100}, {64, 300}]))

    assert stats.tempo_bpm == nil
    assert [%{start_ms: 130}, %{start_ms: 700}] = take.notes
  end

  test "one voice for a sung line, several for a chord-like stream" do
    {_take, stats} = Transcribe.take(render(line(@e_minor_tune)))
    assert stats.voices == :one

    :rand.seed(:exsss, {4, 5, 6})
    chord = [60, 64, 67, 72]

    readings =
      for t <- 0..2990//10 do
        midi = Enum.random(chord)
        %{t: t, hz: Music.midi_to_hz(midi), clarity: 0.3 + 0.2 * :rand.uniform(), db: -18.0}
      end

    {_take, stats} = Transcribe.take(%{duration_ms: 3000, waveform: <<>>, readings: readings})
    assert stats.voices == :several
    refute stats.clear
  end

  test "rapid flips between clear pitches also read as several voices" do
    :rand.seed(:exsss, {9, 9, 9})

    readings =
      for t <- 0..2990//10 do
        midi = if rem(div(t, 30), 2) == 0, do: 60, else: 67
        %{t: t, hz: Music.midi_to_hz(midi), clarity: 0.8 + 0.1 * :rand.uniform(), db: -18.0}
      end

    {_take, stats} = Transcribe.take(%{duration_ms: 3000, waveform: <<>>, readings: readings})
    assert stats.voices == :several
  end
end
