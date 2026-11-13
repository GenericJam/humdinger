defmodule Humdinger.TrackerTest do
  use ExUnit.Case, async: true

  alias Humdinger.{Music, Scale, Settings, Tracker}

  @hop 5
  @chromatic Scale.chromatic()

  # Readings every 5 ms from `from` for `ms`: `pitch` is a fractional MIDI
  # number, nil (silence) or a function of the time since `from`.
  defp sing(from, ms, pitch, opts \\ []) do
    db = Keyword.get(opts, :db, -30.0)
    clarity = Keyword.get(opts, :clarity, 0.95)

    for t <- from..(from + ms - 1)//@hop do
      p = if is_function(pitch), do: pitch.(t - from), else: pitch

      case p do
        nil -> %{t: t, hz: nil, clarity: 0.1, db: -75.0}
        p -> %{t: t, hz: Music.midi_to_hz(p), clarity: clarity, db: db}
      end
    end
  end

  defp settings(changes) do
    {:ok, settings} = Settings.merge(Settings.defaults(), changes)
    settings
  end

  defp run(tracker, readings) do
    Enum.reduce(readings, {tracker, []}, fn r, {tr, acc} ->
      {tr, events} = Tracker.push(tr, r)
      {tr, acc ++ Enum.map(events, &{r.t, &1})}
    end)
  end

  defp events(timed), do: Enum.map(timed, &elem(&1, 1))
  defp notes(timed), do: timed |> events() |> Enum.filter(&(elem(&1, 0) in [:note_on, :note_off]))
  defp ons(timed), do: for({_t, {:note_on, n, _v}} <- timed, do: n)

  defp chromatic(changes \\ []), do: settings([scale: @chromatic] ++ changes)

  describe "the voicing gate" do
    test "a steady note starts once, after the response time, with expression first" do
      for response <- [:fast, :balanced, :steady] do
        {tr, timed} = run(Tracker.new(chromatic(response: response)), sing(1000, 600, 69.0))

        assert [{t_on, {:note_on, 69, vel}}] =
                 Enum.filter(timed, &match?({_, {:note_on, _, _}}, &1))

        assert t_on - 1000 >= Tracker.response_ms(response)
        assert t_on - 1000 <= Tracker.response_ms(response) + @hop
        assert vel in 1..127
        assert [{:cc, 11, _}, {:note_on, 69, _} | _] = events(timed)
        assert %{note: 69, voiced: true, velocity: ^vel} = Tracker.display(tr)
        assert_in_delta Tracker.display(tr).cents, 0.0, 0.5
      end
    end

    test "noise, breath, quiet hums and short blips make no notes" do
      tr = Tracker.new(chromatic())
      unpitched = for t <- 0..500//5, do: %{t: t, hz: nil, clarity: 0.2, db: -20.0}
      unclear = sing(600, 500, 64.0, clarity: 0.5)
      quiet = sing(1200, 500, 64.0, db: -60.0)
      blip = sing(1800, 40, 64.0) ++ sing(1840, 200, nil)

      {tr, timed} = run(tr, unpitched ++ unclear ++ quiet ++ blip)
      assert timed == []
      refute Tracker.display(tr).voiced
    end

    test "louder onsets get higher velocities; fixed 100 when off" do
      vel = fn db, on? ->
        {_tr, timed} =
          run(Tracker.new(chromatic(velocity_from_loudness: on?)), sing(0, 200, 60.0, db: db))

        [v] = for {_, {:note_on, _, v}} <- timed, do: v
        v
      end

      assert vel.(-50.0, true) < vel.(-35.0, true)
      assert vel.(-35.0, true) < vel.(-15.0, true)
      assert vel.(-5.0, true) == 127
      assert vel.(-50.0, false) == 100
      assert vel.(-15.0, false) == 100
    end

    test "a dip in clarity or level inside a note doesn't chop it" do
      dip = sing(400, 20, 64.0, clarity: 0.3)
      soft = sing(420, 100, 64.0, db: -58.0)

      {_tr, timed} =
        run(Tracker.new(chromatic(on_stop: :note_off)), sing(0, 400, 64.0) ++ dip ++ soft)

      assert notes(timed) == [{:note_on, 64, hd(ons_vel(timed))}]
    end
  end

  defp ons_vel(timed), do: for({_, {:note_on, _, v}} <- timed, do: v)

  describe "when you stop" do
    test "note off ends the note within 30 ms of the last voiced reading" do
      {_tr, timed} =
        run(Tracker.new(chromatic(on_stop: :note_off)), sing(0, 300, 62.0) ++ sing(300, 200, nil))

      assert [{t_off, {:note_off, 62}}] = Enum.filter(timed, &match?({_, {:note_off, _}}, &1))
      assert t_off - 295 >= 30 and t_off - 295 <= 30 + @hop
    end

    test "hold bridges a breath on the same note without a new note on" do
      readings = sing(0, 300, 62.0) ++ sing(300, 150, nil) ++ sing(450, 300, 62.1)
      {tr, timed} = run(Tracker.new(chromatic(on_stop: :hold)), readings)

      assert ons(timed) == [62]
      assert Tracker.display(tr).note == 62
      refute Tracker.display(tr).holding
    end

    test "hold ends 250 ms after the last voiced reading, on a reading or on tick" do
      tr = Tracker.new(chromatic(on_stop: :hold))
      {tr, _} = run(tr, sing(0, 300, 62.0) ++ sing(300, 100, nil))
      assert Tracker.display(tr).holding
      assert Tracker.display(tr).note == 62
      assert Tracker.deadline(tr) == 295 + Tracker.hold_ms()

      assert {^tr, []} = Tracker.tick(tr, 500)
      {ticked, events} = Tracker.tick(tr, 545)
      assert events == [{:note_off, 62}]
      assert Tracker.deadline(ticked) == nil
      assert Tracker.tick(ticked, 2000) == {ticked, []}

      {_tr, timed} = run(tr, sing(400, 200, nil))
      assert [{545, {:note_off, 62}}] = timed
    end

    test "re-voicing a different note during a hold changes note as in a phrase" do
      for {change, expected} <- [
            legato: [{:note_on, 62, :v}, {:note_on, 65, :v}, {:note_off, 62}],
            new_note: [{:note_on, 62, :v}, {:note_off, 62}, {:note_on, 65, :v}]
          ] do
        readings = sing(0, 300, 62.0) ++ sing(300, 100, nil) ++ sing(400, 300, 65.0)
        {_tr, timed} = run(Tracker.new(chromatic(on_stop: :hold, pitch_change: change)), readings)
        assert strip_velocity(notes(timed)) == expected
      end
    end
  end

  defp strip_velocity(events),
    do:
      Enum.map(events, fn
        {:note_on, n, _} -> {:note_on, n, :v}
        e -> e
      end)

  describe "scale mode" do
    test "snaps to the scale and only moves past the boundary with hysteresis" do
      # D Dorian: A4 (69) and B4 (71) neighbour, the boundary is at 70.
      d_dorian = settings(scale: Scale.new("D", :dorian))
      hover = fn t -> 70.0 + 0.2 * :math.sin(t / 30) end
      {tr, timed} = run(Tracker.new(d_dorian), sing(0, 300, 69.0) ++ sing(300, 800, hover))
      assert ons(timed) == [69]
      assert Tracker.display(tr).note == 69

      {_tr, timed} = run(tr, sing(1100, 300, 70.4))
      assert ons(timed) == [71]
    end

    test "an off-scale pitch goes to the nearest scale note" do
      {_tr, timed} = run(Tracker.new(settings(scale: Scale.new("C", :major))), sing(0, 300, 61.3))
      assert ons(timed) == [62]
    end

    test "a semitone hover at the midpoint doesn't flip" do
      wobble = fn t -> 69.5 + 0.2 * :math.sin(t / 7) end
      {_tr, timed} = run(Tracker.new(chromatic()), sing(0, 300, 69.0) ++ sing(300, 1000, wobble))
      assert ons(timed) == [69]
    end

    test "legato and new note order the change differently" do
      readings = sing(0, 300, 69.0) ++ sing(300, 300, 71.0)

      {_tr, legato} = run(Tracker.new(chromatic(pitch_change: :legato)), readings)
      assert [{:note_on, 69, _}, {:note_on, 71, _}, {:note_off, 69}] = notes(legato)

      {_tr, new_note} = run(Tracker.new(chromatic(pitch_change: :new_note)), readings)
      assert [{:note_on, 69, _}, {:note_off, 69}, {:note_on, 71, _}] = notes(new_note)
    end

    test "a new note waits for the response time" do
      for response <- [:fast, :balanced, :steady] do
        readings = sing(0, 300, 69.0) ++ sing(300, 400, 72.0)
        {_tr, timed} = run(Tracker.new(chromatic(response: response)), readings)
        [{t, _}] = Enum.filter(timed, &match?({_, {:note_on, 72, _}}, &1))
        assert t - 300 >= Tracker.response_ms(response)
        assert t - 300 <= Tracker.response_ms(response) + 3 * @hop
      end
    end

    test "a quick passing note shorter than the response time is skipped" do
      readings = sing(0, 300, 60.0) ++ sing(300, 30, 62.0) ++ sing(330, 300, 64.0)
      {_tr, timed} = run(Tracker.new(chromatic(response: :steady)), readings)
      assert ons(timed) == [60, 64]
    end

    test "octave errors on single readings are ignored, a real leap is followed" do
      glitchy = fn t -> if rem(div(t, 5), 9) == 4, do: 69.0 + 12, else: 69.0 end
      {tr, timed} = run(Tracker.new(chromatic()), sing(0, 800, glitchy))
      assert ons(timed) == [69]

      {_tr, timed} = run(tr, sing(800, 300, 57.0))
      assert ons(timed) == [57]
    end

    test "vibrato around a note keeps the note (balanced)" do
      vibrato = fn t -> 67.0 + 0.5 * :math.sin(2 * :math.pi() * 5.5 * t / 1000) end
      {_tr, timed} = run(Tracker.new(chromatic()), sing(0, 2000, vibrato))
      assert ons(timed) == [67]
    end

    test "a glide steps through the scale and ends on the target" do
      glide = fn t -> 60.0 + 7.0 * min(t / 1000, 1.0) end

      {tr, timed} =
        run(Tracker.new(settings(scale: Scale.new("C", :major))), sing(0, 1400, glide))

      assert List.last(ons(timed)) == 67
      assert Enum.all?(ons(timed), &Scale.contains?(Scale.new("C", :major), &1))
      assert ons(timed) == Enum.sort(ons(timed))
      assert Tracker.display(tr).note == 67
    end
  end

  describe "octave and transpose" do
    test "shift the sent note, and the display shows the sent note" do
      s = chromatic(octave: -1, transpose: 2)
      {tr, timed} = run(Tracker.new(s), sing(0, 300, 69.0))
      assert ons(timed) == [59]
      assert Tracker.display(tr).note == 59
      assert_in_delta Tracker.display(tr).pitch, 59.0, 0.01
    end

    test "transpose happens before the scale snap, so notes stay in the scale" do
      scale = Scale.new("D", :dorian)
      {_tr, timed} = run(Tracker.new(settings(scale: scale, transpose: 1)), sing(0, 300, 69.0))
      assert [n] = ons(timed)
      assert Scale.contains?(scale, n)
    end

    test "notes are clamped to MIDI 0..127" do
      {_tr, high} = run(Tracker.new(chromatic(octave: 3, transpose: 12)), sing(0, 300, 100.0))
      assert ons(high) == [127]

      {_tr, low} = run(Tracker.new(chromatic(octave: -3, transpose: -12)), sing(0, 300, 30.0))
      assert ons(low) == [0]
    end
  end

  describe "open + bend mode" do
    defp open(changes \\ []), do: settings([mode: :open] ++ changes)

    test "strikes the nearest semitone and bends to the exact pitch" do
      {tr, timed} = run(Tracker.new(open()), sing(0, 300, 69.3))
      assert ons(timed) == [69]
      bends = for {_, {:pitch_bend, b}} <- timed, do: b
      assert_in_delta List.last(bends), 0.3 / 2 * 8192, 60
      assert_in_delta Tracker.display(tr).cents, 30, 1
    end

    test "bend is centred before each new note and set after it" do
      readings = sing(0, 300, 69.3) ++ sing(300, 400, 72.2)
      {_tr, timed} = run(Tracker.new(open(pitch_change: :new_note)), readings)
      evs = events(timed)
      i = Enum.find_index(evs, &match?({:note_on, 72, _}, &1))
      assert Enum.at(evs, i - 1) == {:pitch_bend, 0}
      assert Enum.at(evs, i - 2) == {:note_off, 69}
      assert {:pitch_bend, b} = Enum.at(evs, i + 1)
      assert_in_delta b, 0.2 / 2 * 8192, 60
    end

    test "a glide bends without new notes while it stays in the bend range" do
      # 69 → 72 at 5 semitones a second, then stop: it never settles on
      # 70 or 71 and never drifts past ±7.
      glide = fn t -> 69.0 + t / 200 end
      readings = sing(0, 300, 69.0) ++ sing(300, 600, glide) ++ sing(900, 300, nil)
      {_tr, timed} = run(Tracker.new(open(bend_range: 7, on_stop: :note_off)), readings)

      assert notes(timed) |> strip_velocity() == [{:note_on, 69, :v}, {:note_off, 69}]
      bends = for {_, {:pitch_bend, b}} <- timed, do: b
      assert Enum.max(bends) > 2.5 / 7 * 8192
      assert bends == Enum.sort(bends)
    end

    test "a slow glide that lingers on a semitone strikes it" do
      # Rises to 70.4 and dwells there: that is settling on 70.
      glide = fn t -> 69.0 + 1.4 * :math.sin(:math.pi() * t / 1200) end
      {_tr, timed} = run(Tracker.new(open()), sing(0, 300, 69.0) ++ sing(300, 600, glide))
      assert ons(timed) == [69, 70]
    end

    test "drifting past the bend range strikes a new note at once" do
      drift = fn t -> 69.0 + t / 100 end

      {_tr, timed} =
        run(Tracker.new(open(bend_range: 1)), sing(0, 300, 69.0) ++ sing(300, 150, drift))

      [_first, second | _] = ons(timed)
      [{t, _}] = Enum.filter(timed, &match?({_, {:note_on, ^second, _}}, &1))
      # Smoothed pitch passes 70 (one semitone) shortly after the raw pitch does.
      assert t < 300 + 100 + 40
    end

    test "settling on a new semitone re-strikes after the response time" do
      {_tr, timed} = run(Tracker.new(open()), sing(0, 300, 69.0) ++ sing(300, 400, 70.05))
      assert ons(timed) == [69, 70]
    end

    test "vibrato bends but never re-strikes" do
      vibrato = fn t -> 64.0 + 0.6 * :math.sin(2 * :math.pi() * 6 * t / 1000) end
      {_tr, timed} = run(Tracker.new(open(response: :steady)), sing(0, 2000, vibrato))
      assert ons(timed) == [64]
    end

    test "bends stay in range" do
      {_tr, timed} =
        run(
          Tracker.new(open(bend_range: 12)),
          sing(0, 300, 40.0) ++ sing(300, 500, fn t -> 40 + t / 20 end)
        )

      for {_, {:pitch_bend, b}} <- timed, do: assert(b in -8192..8191)
    end
  end

  describe "expression" do
    test "CC 11 follows loudness while a note sounds, rate-limited, only on change" do
      readings =
        for {t, i} <- Enum.with_index(0..1995//5) do
          %{t: t, hz: Music.midi_to_hz(64.0), clarity: 0.95, db: -50.0 + i * 0.1}
        end

      {_tr, timed} = run(Tracker.new(chromatic()), readings)
      cc11 = for {t, {:cc, 11, v}} <- timed, do: {t, v}
      values = Enum.map(cc11, &elem(&1, 1))
      assert Enum.count(cc11) > 10
      assert values == Enum.sort(values)
      assert values == Enum.dedup(values)

      cc11
      |> Enum.map(&elem(&1, 0))
      |> Enum.chunk_every(2, 1, :discard)
      |> Enum.each(fn [a, b] -> assert b - a >= 20 end)

      {_tr, steady} = run(Tracker.new(chromatic()), sing(0, 2000, 64.0, db: -30.0))
      assert [_one] = for({_, {:cc, 11, _}} <- steady, do: 1)

      {_tr, off} = run(Tracker.new(chromatic(cc11_from_loudness: false)), readings)
      assert for({_, {:cc, 11, _}} <- off, do: 1) == []
    end

    test "CC 1 follows vibrato depth when on, and returns to 0 when the voice stops" do
      vibrato = fn t -> 64.0 + 0.5 * :math.sin(2 * :math.pi() * 5.5 * t / 1000) end
      s = chromatic(cc1_from_vibrato: true, on_stop: :note_off)
      {_tr, timed} = run(Tracker.new(s), sing(0, 2000, vibrato) ++ sing(2000, 200, nil))
      cc1 = for {_, {:cc, 1, v}} <- timed, do: v
      assert Enum.max(cc1) in 40..70
      assert List.last(cc1) == 0

      {_tr, plain} = run(Tracker.new(s), sing(0, 2000, 64.0))
      assert for({_, {:cc, 1, _}} <- plain, do: 1) == []

      {_tr, off} = run(Tracker.new(chromatic()), sing(0, 2000, vibrato))
      assert for({_, {:cc, 1, _}} <- off, do: 1) == []
    end

    test "vibrato depth: periodic swings count, drift and jitter don't" do
      at = fn f -> for t <- 0..500//5, do: {t, f.(t)} end

      assert_in_delta Tracker.vibrato_cents(
                        at.(&(60 + 0.4 * :math.sin(2 * :math.pi() * 6 * &1 / 1000)))
                      ),
                      40,
                      4

      assert Tracker.vibrato_cents(at.(&(60 + &1 / 250))) == 0.0

      assert Tracker.vibrato_cents(at.(&(60 + 0.4 * :math.sin(2 * :math.pi() * 1.5 * &1 / 1000)))) ==
               0.0

      :rand.seed(:exsss, 7)
      assert Tracker.vibrato_cents(at.(fn _ -> 60 + (:rand.uniform() - 0.5) * 0.1 end)) == 0.0
      assert Tracker.vibrato_cents([]) == 0.0
      assert Tracker.vibrato_cents(Enum.take(at.(fn _ -> 60 end), 10)) == 0.0
    end
  end

  describe "release and configure" do
    test "release turns the note off and centres the bend" do
      tr = Tracker.new(open(cc1_from_vibrato: true))
      {tr, _} = run(tr, sing(0, 300, 69.3))
      {tr, events} = Tracker.release(tr)
      assert events == [{:note_off, 69}, {:pitch_bend, 0}]
      assert %{note: nil, voiced: false} = Tracker.display(tr)
      assert Tracker.release(tr) == {tr, []}

      # The voice still sounding must open the gate again from scratch.
      {_tr, timed} = run(tr, sing(300, 200, 69.3))
      assert ons(timed) == [69]
    end

    test "changing mode, scale, octave, transpose, bend range or channel releases" do
      {tr, _} = run(Tracker.new(chromatic()), sing(0, 300, 69.0))

      for change <- [
            [mode: :open],
            [scale: Scale.new("C", :major)],
            [octave: 1],
            [transpose: -2],
            [bend_range: 7],
            [channel: 3]
          ] do
        {_tr, events} = Tracker.configure(tr, chromatic(change))
        assert events == [{:note_off, 69}], inspect(change)
      end
    end

    test "other changes apply to the note in progress" do
      {tr, _} = run(Tracker.new(chromatic(cc1_from_vibrato: true)), sing(0, 300, 69.0))
      {tr, events} = Tracker.configure(tr, chromatic(response: :steady, pitch_change: :new_note))
      assert events == []
      assert Tracker.display(tr).note == 69

      {tr, events} = Tracker.configure(tr, chromatic(cc11_from_loudness: false))
      assert events == [{:cc, 11, 127}]
      {_tr, timed} = run(tr, sing(300, 300, 69.0))
      assert timed == []
    end
  end

  test "tuning labels" do
    assert Tracker.tuning_label(0) == "in tune"
    assert Tracker.tuning_label(9.9) == "in tune"
    assert Tracker.tuning_label(-10) == "a little flat"
    assert Tracker.tuning_label(30) == "a little sharp"
    assert Tracker.tuning_label(-30.5) == "flat"
    assert Tracker.tuning_label(48) == "sharp"
    assert Tracker.cents_label(-12.4) == "−12¢ · a little flat"
    assert Tracker.cents_label(3) == "+3¢ · in tune"
    assert Tracker.cents_label(0.2) == "0¢ · in tune"
  end

  test "response times" do
    assert Tracker.response_ms(:fast) < Tracker.response_ms(:balanced)
    assert Tracker.response_ms(:balanced) < Tracker.response_ms(:steady)
  end

  describe "over many random streams" do
    # Segments a singer (and a room) produce, stitched at random.
    defp segment(:silence, t), do: sing(t, 50 + :rand.uniform(400), nil)

    defp segment(:steady, t),
      do: sing(t, 40 + :rand.uniform(600), 40 + :rand.uniform() * 50, db: db())

    defp segment(:blip, t), do: sing(t, 5 + :rand.uniform(60), 40 + :rand.uniform() * 50)
    defp segment(:breath, t), do: sing(t, 10 + :rand.uniform(300), nil)

    defp segment(:glide, t) do
      {a, b} = {40 + :rand.uniform() * 50, 40 + :rand.uniform() * 50}
      ms = 50 + :rand.uniform(800)
      sing(t, ms, fn dt -> a + (b - a) * dt / ms end, db: db())
    end

    defp segment(:vibrato, t) do
      {c, depth, rate} =
        {40 + :rand.uniform() * 50, :rand.uniform() * 1.2, 3 + :rand.uniform() * 6}

      sing(
        t,
        100 + :rand.uniform(1000),
        fn dt -> c + depth * :math.sin(2 * :math.pi() * rate * dt / 1000) end,
        db: db()
      )
    end

    defp segment(:octave_errors, t) do
      c = 40 + :rand.uniform() * 50

      sing(t, 100 + :rand.uniform(500), fn _ ->
        if :rand.uniform() < 0.15, do: c + Enum.random([-12, 12]), else: c
      end)
    end

    defp segment(:noise, t) do
      for dt <- 0..:rand.uniform(400)//5 do
        %{
          t: t + dt,
          hz: if(:rand.uniform() < 0.5, do: 80 + :rand.uniform() * 900),
          clarity: :rand.uniform(),
          db: -80 + :rand.uniform() * 70
        }
      end
    end

    defp segment(:extreme, t),
      do: sing(t, 50 + :rand.uniform(300), Enum.random([5.0, 125.0, 140.0]))

    defp db, do: -55 + :rand.uniform() * 50

    defp random_settings do
      settings(
        response: Enum.random([:fast, :balanced, :steady]),
        pitch_change: Enum.random([:legato, :new_note]),
        on_stop: Enum.random([:note_off, :hold]),
        bend_range: Enum.random([1, 2, 7, 12]),
        velocity_from_loudness: Enum.random([true, false]),
        cc11_from_loudness: Enum.random([true, false]),
        cc1_from_vibrato: Enum.random([true, false]),
        mode: Enum.random([:scale, :open]),
        scale: Scale.new(Enum.random(0..11), Enum.random(Scale.modes())),
        octave: Enum.random(-3..3),
        transpose: Enum.random(-12..12),
        sensitivity_db: Enum.random(-70..-20) / 1
      )
    end

    defp stream do
      kinds = [
        :silence,
        :steady,
        :blip,
        :breath,
        :glide,
        :vibrato,
        :octave_errors,
        :noise,
        :extreme
      ]

      Enum.reduce(1..(3 + :rand.uniform(12)), {0, []}, fn _, {t, acc} ->
        seg = segment(Enum.random(kinds), t)
        {List.last(seg).t + @hop, [seg | acc]}
      end)
      |> elem(1)
      |> Enum.reverse()
      |> List.flatten()
    end

    # Plays the events against a model synth; fails on anything a synth
    # would choke on.
    defp check(sounding, events) do
      Enum.reduce(events, sounding, fn
        {:note_on, n, v}, s ->
          assert n in 0..127 and v in 1..127
          refute MapSet.member?(s, n), "note on #{n} while it sounds"
          MapSet.put(s, n)

        {:note_off, n}, s ->
          assert MapSet.member?(s, n), "note off #{n} that isn't sounding"
          MapSet.delete(s, n)

        {:pitch_bend, b}, s ->
          assert b in -8192..8191
          s

        {:cc, c, v}, s ->
          assert c in [1, 11] and v in 0..127
          s
      end)
    end

    test "every note on is balanced, at most one note sounds between readings, release ends all" do
      strikes =
        for seed <- 1..300 do
          :rand.seed(:exsss, seed)
          s = random_settings()
          readings = stream()

          {tr, sounding, strikes} =
            Enum.reduce(readings, {Tracker.new(s), MapSet.new(), 0}, fn r, {tr, sounding, n} ->
              {tr, events} = Tracker.push(tr, r)
              {tr, ticked} = Tracker.tick(tr, r.t)
              sounding = check(sounding, events ++ ticked)
              assert MapSet.size(sounding) <= 1, "seed #{seed}: #{inspect(sounding)}"
              assert Tracker.display(tr).note == sounding |> MapSet.to_list() |> List.first()
              {tr, sounding, n + Enum.count(events, &match?({:note_on, _, _}, &1))}
            end)

          {tr, settled} = Tracker.tick(tr, List.last(readings).t + 1000)
          sounding = check(sounding, settled)
          {tr, released} = Tracker.release(tr)
          assert MapSet.size(check(sounding, released)) == 0, "seed #{seed}"
          assert Tracker.display(tr).note == nil
          assert Tracker.release(tr) == {tr, []}
          strikes
        end

      # The streams do make notes (the checks above aren't vacuous).
      assert Enum.sum(strikes) > 600
      assert Enum.count(strikes, &(&1 == 0)) < 60
    end

    test "after a configure that re-maps notes nothing is left sounding" do
      for seed <- 1..100 do
        :rand.seed(:exsss, seed)
        readings = stream()
        {first, second} = Enum.split(readings, div(length(readings), 2))
        tr = Tracker.new(random_settings())
        {tr, a} = run(tr, first)
        {tr, b} = Tracker.configure(tr, random_settings())
        {tr, c} = run(tr, second)
        {_tr, d} = Tracker.release(tr)
        sounding = check(MapSet.new(), events(a) ++ b ++ events(c) ++ d)
        assert MapSet.size(sounding) == 0, "seed #{seed}"
      end
    end
  end
end
