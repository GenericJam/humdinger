defmodule Humdinger.Transcribe do
  @moduledoc """
  Turns an audio file's analysis (`Humdinger.Audio.analyze_file/3`) into a
  `Humdinger.Take`, plus what the Import screen says about it: "Heard 14
  notes · E minor · 84 bpm · one voice", the "clear" chip and "2 unsure ·
  faded".

  From readings to notes:

  1. **Gate.** A reading is voiced when it has a pitch, clarity ≥ 0.45 and a
     level at most 30 dB under the take's loud level (the 90th percentile of
     its pitched readings), and never under −70 dBFS. Consecutive voiced
     readings (no gap over 2.5 reading steps) form a run.
  2. **Octave repair.** A reading about an octave (±1.5 semitones) away from
     the median of its neighbours in the run (5 each side) is folded back:
     YIN's usual slip. A real leap survives, because past its first reading
     its neighbours are on its side.
  3. **Hysteresis.** A run follows one note until the pitch has left the
     note's median (over its last 100 readings inside the band) by more than
     0.6 semitone and settled elsewhere: its last 50 ms within one semitone,
     drifting under 5 semitones per second, their median more than 0.8
     semitone from the note's. Vibrato (±50 cents) never settles outside
     the band; a glide hasn't settled until it arrives, and is then shared
     between the two notes by nearest pitch. The new note's median starts
     from where it settled, not from the glide.
  4. **Glides.** A piece shorter than 100 ms whose second half sits 0.4
     semitone or more away from its first half (a scoop into a note, a fall
     off one, a step of a slow slide) joins the neighbour in its run whose
     pitch is nearest.
  5. **Pitch.** A note's pitch is the median of its readings, snapped to the
     snap scale (nearest semitone for chromatic). Neighbours of the same
     pitch less than 30 ms apart merge; notes shorter than `min_ms` go.
  6. **Velocity** follows the note's mean level: 100 at the take's loud
     level, 3 per dB, within 1..127.
  7. **Unsure** notes: mean clarity under 0.7; a wandering pitch (median
     distance from the note's median over 0.45 semitone, where ±50 cents of
     vibrato is about 0.35); a jittery one (mean step between consecutive
     readings over 0.3 semitone, where 6 Hz vibrato is about 0.12); or a
     median more than 0.4 semitone from the snapped note (sung between
     notes, or outside the snap scale).

  The scale is `Humdinger.Scale.detect/1` over the pieces at least `min_ms`
  long, weighted by duration. The tempo is `Humdinger.Tempo.detect/1` over
  the note onsets; with one, notes are quantized by
  `Humdinger.Phrase.quantize_notes/3` on a grid starting at the range start
  (where the phrase's first bar will start). Without one they stay as sung.

  `voices` is `:several` when, over the loud readings (within 12 dB of the
  loudest tenth, at least 20 of them), more than 40 % have no pitch or a
  clarity under 0.5 (a chord confuses YIN), or more than 20 % of consecutive
  pitched ones jump by over 1.5 semitones (other than an octave): the
  detector flipping between voices. `clear` is true for one voice with notes,
  at least 70 % of voiced readings at clarity ≥ 0.75 and at most a fifth of
  the notes unsure.
  """

  alias Humdinger.{Music, Phrase, Scale, Take, Tempo}

  @default_step_ms 10
  @trace_step_ms 10
  @gate_clarity 0.45
  @gate_range_db 30
  @gate_floor_db -70
  @run_gap_steps 2.5
  @octave_neighbours 5
  @octave_tolerance 1.5
  @split_semitones 0.6
  @median_frames 100
  @settle_ms 50
  @settle_spread 1.0
  @settle_slope 5.0
  @settle_away 0.8
  @glide_ms 100
  @glide_move 0.4
  @merge_gap_ms 30
  @loud_velocity 100
  @velocity_per_db 3
  @unsure_clarity 0.7
  @unsure_spread 0.45
  @unsure_jitter 0.3
  @unsure_offset 0.4
  @clear_clarity 0.75
  @clear_share 0.7
  @clear_unsure 0.2
  @loud_range_db 12
  @several_min_frames 20
  @several_clarity 0.5
  @several_murky_share 0.4
  @several_pitched_clarity 0.3
  @several_jump 1.5
  @several_jump_share 0.2

  @type stats :: %{
          note_count: non_neg_integer(),
          unsure_count: non_neg_integer(),
          scale: Scale.t() | nil,
          tempo_bpm: pos_integer() | nil,
          voices: :one | :several,
          clear: boolean()
        }

  # A reading in the working form: {t_ms, pitch (fractional MIDI) | nil, clarity, db}.
  @typep frame :: {integer(), float() | nil, number(), number()}

  @doc """
  Transcribes an analysis into a take and its stats.

  Options:

  - `range: {from_ms, to_ms}` — the part of the file to use (default all of
    it). Times in the take start at `from_ms`; notes are cut at the edges.
  - `snap: %Humdinger.Scale{} | :chromatic` — default the detected scale
    (chromatic when none). It becomes `Take.scale`.
  - `quantize: :q8 | :q16 | :triplet | :off` (default `:q16`).
  - `min_ms` — shorter notes are dropped (default 60).
  - `name` — the file name, for `Take.source` (default `"audio"`).
  """
  @spec take(Humdinger.Audio.analysis(), keyword()) :: {Take.t(), stats()}
  def take(%{duration_ms: duration_ms, readings: readings}, opts \\ []) do
    {from, to} = range(Keyword.get(opts, :range), duration_ms)
    length_ms = to - from
    min_ms = Keyword.get(opts, :min_ms, 60)
    readings = for %{t: t} = r <- readings, t >= from and t < to, do: %{r | t: t - from}
    step = frame_step(readings)
    ref_db = percentile(for(%{hz: hz, db: db} <- readings, is_number(hz), do: db), 0.9)
    frames = Enum.map(readings, &frame(&1, ref_db))
    runs = frames |> runs(step) |> Enum.map(&repair_octaves/1)

    pieces =
      for run <- runs, segment <- run |> split(step) |> absorb_glides() do
        piece(segment, step, length_ms)
      end

    detected =
      Scale.detect(
        for p <- pieces, p.stop - p.start >= min_ms, do: {round(p.pitch), p.stop - p.start}
      )

    snap = snap_scale(Keyword.get(opts, :snap), detected)

    notes =
      pieces
      |> Enum.map(&Map.put(&1, :midi, snap_pitch(snap, &1.pitch)))
      |> merge_same()
      |> Enum.reject(&(&1.stop - &1.start < min_ms))
      |> merge_same()
      |> Enum.map(&note(&1, ref_db))

    bpm =
      case Tempo.detect(Enum.map(notes, & &1.start_ms)) do
        %{bpm: bpm} -> bpm
        nil -> nil
      end

    notes = quantize(notes, bpm, Keyword.get(opts, :quantize, :q16))
    unsure_count = Enum.count(notes, & &1.unsure)
    voices = voices(readings, step)

    take = %Take{
      notes: notes,
      trace: trace(frames, runs),
      duration_ms: length_ms,
      scale: snap,
      tempo_bpm: bpm,
      source: {:file, Keyword.get(opts, :name, "audio")}
    }

    stats = %{
      note_count: length(notes),
      unsure_count: unsure_count,
      scale: if(notes == [], do: nil, else: detected),
      tempo_bpm: bpm,
      voices: voices,
      clear: clear?(notes, unsure_count, voices, runs)
    }

    {take, stats}
  end

  defp range(nil, duration_ms), do: {0, duration_ms}

  defp range({from, to}, duration_ms) do
    from = from |> round() |> max(0) |> min(duration_ms)
    {from, to |> round() |> max(from) |> min(duration_ms)}
  end

  defp frame_step(readings) do
    gaps = for [%{t: a}, %{t: b}] <- Enum.chunk_every(readings, 2, 1, :discard), b > a, do: b - a

    case median(gaps) do
      nil -> @default_step_ms
      gap -> max(round(gap), 1)
    end
  end

  defp frame(%{t: t, hz: hz, clarity: clarity, db: db}, ref_db) do
    voiced =
      is_number(hz) and hz > 0 and clarity >= @gate_clarity and
        db >= max(ref_db - @gate_range_db, @gate_floor_db)

    {t, if(voiced, do: Music.hz_to_midi(hz)), clarity, db}
  end

  @spec runs([frame()], pos_integer()) :: [[frame()]]
  defp runs(frames, step) do
    {runs, current} =
      Enum.reduce(frames, {[], []}, fn
        {_t, nil, _c, _db}, {runs, current} ->
          {close_run(current, runs), []}

        {t, _p, _c, _db} = f, {runs, [{prev, _, _, _} | _] = current}
        when t - prev > @run_gap_steps * step ->
          {close_run(current, runs), [f]}

        f, {runs, current} ->
          {runs, [f | current]}
      end)

    Enum.reverse(close_run(current, runs))
  end

  defp close_run([], runs), do: runs
  defp close_run(current, runs), do: [Enum.reverse(current) | runs]

  defp repair_octaves(run) do
    pitches = run |> Enum.map(&elem(&1, 1)) |> List.to_tuple()
    last = tuple_size(pitches) - 1

    run
    |> Enum.with_index()
    |> Enum.map(fn {{t, p, c, db}, i} ->
      lo = max(i - @octave_neighbours, 0)
      hi = min(i + @octave_neighbours, last)
      neighbours = for j <- lo..hi//1, j != i, do: elem(pitches, j)
      {t, fold_octave(p, neighbours), c, db}
    end)
  end

  defp fold_octave(p, [_, _, _, _ | _] = neighbours) do
    m = median(neighbours)

    cond do
      abs(p - m) < 12 - @octave_tolerance -> p
      abs(p - 12 - m) <= @octave_tolerance -> p - 12
      abs(p + 12 - m) <= @octave_tolerance -> p + 12
      true -> p
    end
  end

  defp fold_octave(p, _neighbours), do: p

  # Hysteresis over one run. `current` (the note's frames), `anchor` (the
  # pitches its median is taken from: not the glide that led into it) and
  # `candidate` are newest first; `done` holds finished segments
  # (chronological), newest first.
  defp split(run, step) do
    {done, current, _anchor, candidate} =
      Enum.reduce(run, {[], [], [], []}, &follow(&1, &2, step))

    Enum.reject(Enum.reverse([Enum.reverse(candidate ++ current) | done]), &(&1 == []))
  end

  defp follow({_t, p, _c, _db} = frame, {done, [], [], []}, _step), do: {done, [frame], [p], []}

  defp follow({_t, p, _c, _db} = frame, {done, current, anchor, candidate}, step) do
    old = median(anchor)

    if abs(p - old) <= @split_semitones do
      {done, [frame | candidate ++ current], Enum.take([p | anchor], @median_frames), []}
    else
      candidate = [frame | candidate]

      case settled(candidate, old, step) do
        nil -> {done, current, anchor, candidate}
        {tail, new} -> start_note(done, current, candidate, old, tail, new)
      end
    end
  end

  # Ends the current note where the candidate settled at `new`, sharing the
  # glide before it by nearest pitch.
  defp start_note(done, current, candidate, old, tail, new) do
    {to_old, to_new} =
      candidate
      |> Enum.reverse()
      |> Enum.split_while(fn {_t, q, _c, _db} -> abs(q - old) < abs(q - new) end)

    {[Enum.reverse(current, to_old) | done], Enum.reverse(to_new), tail, []}
  end

  # The candidate's last 50 ms and their median, when they hold still clearly
  # away from the current note.
  defp settled([{newest, _, _, _} | _] = candidate, old, step) do
    tail = Enum.take_while(candidate, fn {t, _p, _c, _db} -> newest - t < @settle_ms end)
    {oldest, _, _, _} = List.last(tail)
    pitches = pitches(tail)
    {low, high} = Enum.min_max(pitches)
    new = median(pitches)

    if newest - oldest + step >= @settle_ms and high - low <= @settle_spread and
         abs(new - old) > @settle_away and abs(slope(tail)) <= @settle_slope do
      {pitches, new}
    end
  end

  # Semitones per second, least squares.
  defp slope(frames) do
    n = length(frames)
    mt = Enum.sum_by(frames, &elem(&1, 0)) / n
    mp = Enum.sum_by(frames, &elem(&1, 1)) / n

    {num, den} =
      Enum.reduce(frames, {0.0, 0.0}, fn {t, p, _c, _db}, {num, den} ->
        {num + (t - mt) * (p - mp), den + (t - mt) * (t - mt)}
      end)

    if den == 0.0, do: 0.0, else: num / den * 1000
  end

  defp absorb_glides([_, _ | _] = segments) do
    case Enum.find_index(segments, &gliding?/1) do
      nil -> segments
      i -> segments |> merge_into_neighbour(i) |> absorb_glides()
    end
  end

  defp absorb_glides(segments), do: segments

  defp gliding?([{first, _, _, _} | _] = segment) do
    {last, _, _, _} = List.last(segment)
    {head, tail} = Enum.split(segment, div(length(segment), 2))

    last - first < @glide_ms and head != [] and
      abs(median(pitches(tail)) - median(pitches(head))) >= @glide_move
  end

  defp merge_into_neighbour(segments, i) do
    segment = Enum.at(segments, i)
    m = median(pitches(segment))
    prev = if i > 0, do: Enum.at(segments, i - 1)
    next = Enum.at(segments, i + 1)

    if next == nil or (prev != nil and distance(prev, m) <= distance(next, m)) do
      segments |> List.replace_at(i - 1, prev ++ segment) |> List.delete_at(i)
    else
      segments |> List.replace_at(i + 1, segment ++ next) |> List.delete_at(i)
    end
  end

  defp distance(segment, pitch), do: abs(median(pitches(segment)) - pitch)

  defp piece([{start, _, _, _} | _] = frames, step, length_ms) do
    {last, _, _, _} = List.last(frames)

    %{
      frames: frames,
      start: start,
      stop: min(last + step, length_ms),
      pitch: median(pitches(frames))
    }
  end

  defp snap_scale(%Scale{} = scale, _detected), do: scale
  defp snap_scale(:chromatic, _detected), do: Scale.chromatic()
  defp snap_scale(nil, %Scale{} = detected), do: detected
  defp snap_scale(nil, nil), do: Scale.chromatic()

  defp snap_pitch(scale, pitch), do: scale |> Scale.snap(pitch) |> max(0) |> min(127)

  defp merge_same(pieces) do
    pieces
    |> Enum.reduce([], fn
      %{midi: midi, start: start} = p, [%{midi: midi, stop: stop} = prev | rest]
      when start - stop <= @merge_gap_ms ->
        frames = prev.frames ++ p.frames
        [%{prev | frames: frames, stop: p.stop, pitch: median(pitches(frames))} | rest]

      p, acc ->
        [p | acc]
    end)
    |> Enum.reverse()
  end

  defp note(%{frames: frames, start: start, stop: stop, pitch: pitch, midi: midi}, ref_db) do
    n = length(frames)
    clarity = Enum.sum_by(frames, &elem(&1, 2)) / n
    db = Enum.sum_by(frames, &elem(&1, 3)) / n
    spread = median(for {_t, p, _c, _db} <- frames, do: abs(p - pitch))

    steps =
      for [{_, a, _, _}, {_, b, _, _}] <- Enum.chunk_every(frames, 2, 1, :discard), do: abs(b - a)

    jitter = if steps == [], do: 0.0, else: Enum.sum(steps) / length(steps)

    %{
      start_ms: start,
      dur_ms: stop - start,
      midi: midi,
      velocity:
        (@loud_velocity + @velocity_per_db * (db - ref_db)) |> round() |> max(1) |> min(127),
      unsure:
        clarity < @unsure_clarity or spread > @unsure_spread or jitter > @unsure_jitter or
          abs(pitch - midi) > @unsure_offset
    }
  end

  defp quantize(notes, nil, _quantize), do: notes
  defp quantize(notes, _bpm, :off), do: notes
  defp quantize(notes, bpm, quantize), do: Phrase.quantize_notes(notes, bpm, quantize)

  defp trace(frames, runs) do
    voiced = Map.new(for run <- runs, {t, p, _c, _db} <- run, do: {t, Float.round(p, 2)})

    frames
    |> Enum.reduce({[], nil}, fn {t, _p, _c, _db}, {acc, last} ->
      if last == nil or t - last >= @trace_step_ms,
        do: {[{t, Map.get(voiced, t)} | acc], t},
        else: {acc, last}
    end)
    |> elem(0)
    |> Enum.reverse()
  end

  defp voices(readings, step) do
    case percentile(Enum.map(readings, & &1.db), 0.9) do
      nil ->
        :one

      loud_db ->
        loud =
          for %{db: db} = r <- readings,
              db >= max(loud_db - @loud_range_db, @gate_floor_db),
              do: r

        if murky?(loud) or flipping?(loud, step), do: :several, else: :one
    end
  end

  defp murky?(loud) do
    n = length(loud)
    murky = Enum.count(loud, &(not is_number(&1.hz) or &1.clarity < @several_clarity))
    n >= @several_min_frames and murky / n > @several_murky_share
  end

  defp flipping?(loud, step) do
    pitched =
      for %{t: t, hz: hz, clarity: c} <- loud,
          is_number(hz) and hz > 0 and c >= @several_pitched_clarity,
          do: {t, Music.hz_to_midi(hz)}

    jumps =
      for [{t1, a}, {t2, b}] <- Enum.chunk_every(pitched, 2, 1, :discard),
          t2 - t1 <= @run_gap_steps * step,
          do: abs(b - a) > @several_jump and abs(abs(b - a) - 12) > @octave_tolerance

    n = length(jumps)
    n >= @several_min_frames and Enum.count(jumps, & &1) / n > @several_jump_share
  end

  defp clear?([], _unsure_count, _voices, _runs), do: false
  defp clear?(_notes, _unsure_count, :several, _runs), do: false

  defp clear?(notes, unsure_count, :one, runs) do
    clarities = for run <- runs, {_t, _p, c, _db} <- run, do: c
    high = Enum.count(clarities, &(&1 >= @clear_clarity))

    high / max(length(clarities), 1) >= @clear_share and
      unsure_count <= @clear_unsure * length(notes)
  end

  defp pitches(frames), do: Enum.map(frames, &elem(&1, 1))

  defp median([]), do: nil

  defp median(xs) do
    sorted = Enum.sort(xs)
    n = length(sorted)
    mid = div(n, 2)

    if rem(n, 2) == 1,
      do: Enum.at(sorted, mid),
      else: (Enum.at(sorted, mid - 1) + Enum.at(sorted, mid)) / 2
  end

  defp percentile([], _q), do: nil

  defp percentile(xs, q) do
    sorted = Enum.sort(xs)
    Enum.at(sorted, floor(q * (length(sorted) - 1)))
  end
end
