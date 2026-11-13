defmodule Humdinger.Pdf do
  @moduledoc """
  A small PDF 1.4 writer: enough for printable sheet music, nothing more.

  A page is a size in points (1/72 in, y up from the bottom-left corner) and
  a content stream built from the operator functions below, each returning
  iodata to be concatenated in drawing order:

      content = [
        Pdf.fill_color(0xFF17141F),
        Pdf.rect(50, 700, 100, 2),
        Pdf.fill(),
        Pdf.text(50, 720, :helvetica_bold, 18, "New phrase")
      ]

      Pdf.document([%{size: Pdf.page_size(:a4), content: content}], title: "New phrase")

  Text uses three of the standard 14 fonts every reader has (Helvetica,
  Helvetica-Bold, Times-Bold), so nothing is embedded. They are WinAnsi
  encoded: Latin-1 and the usual typographic punctuation print as is,
  musical sharps and flats become `#` and `b`, accented letters outside the
  encoding lose their accents, anything else becomes `?`. Content streams
  are deflated.
  """

  import Bitwise

  @type font :: :helvetica | :helvetica_bold | :times_bold
  @type page :: %{size: {number, number}, content: iodata}

  @fonts [helvetica: "Helvetica", helvetica_bold: "Helvetica-Bold", times_bold: "Times-Bold"]
  @font_ids @fonts |> Keyword.keys() |> Enum.with_index(1) |> Map.new()

  # Advance widths (1/1000 em) of WinAnsi codes 32..255, from Adobe's AFM
  # metrics for the core fonts; 0 for codes the encoding leaves undefined.
  @helvetica ~w(
    278 278 355 556 556 889 667 191 333 333 389 584 278 333 278 278
    556 556 556 556 556 556 556 556 556 556 278 278 584 584 584 556
    1015 667 667 722 722 667 611 778 722 278 500 667 556 833 722 778
    667 778 722 667 611 722 667 944 667 667 611 278 278 278 469 556
    333 556 556 500 556 556 278 556 556 222 222 500 222 833 556 556
    556 556 333 500 278 556 500 722 500 500 500 334 260 334 584 0
    556 0 222 556 333 1000 556 556 333 1000 667 333 1000 0 611 0
    0 222 222 333 333 350 556 1000 333 1000 500 333 944 0 500 667
    278 333 556 556 556 556 260 556 333 737 370 556 584 333 737 333
    400 584 333 333 333 556 537 278 333 333 365 556 834 834 834 611
    667 667 667 667 667 667 1000 722 667 667 667 667 278 278 278 278
    722 722 778 778 778 778 778 584 778 722 722 722 722 667 667 611
    556 556 556 556 556 556 889 500 556 556 556 556 278 278 278 278
    556 556 556 556 556 556 556 584 611 556 556 556 556 500 556 500
  )
  @helvetica_bold ~w(
    278 333 474 556 556 889 722 238 333 333 389 584 278 333 278 278
    556 556 556 556 556 556 556 556 556 556 333 333 584 584 584 611
    975 722 722 722 722 667 611 778 722 278 556 722 611 833 722 778
    667 778 722 667 611 722 667 944 667 667 611 333 278 333 584 556
    333 556 611 556 611 556 333 611 611 278 278 556 278 889 611 611
    611 611 389 556 333 611 556 778 556 556 500 389 280 389 584 0
    556 0 278 556 500 1000 556 556 333 1000 667 333 1000 0 611 0
    0 278 278 500 500 350 556 1000 333 1000 556 333 944 0 500 667
    278 333 556 556 556 556 280 556 333 737 370 556 584 333 737 333
    400 584 333 333 333 611 556 278 333 333 365 556 834 834 834 611
    722 722 722 722 722 722 1000 722 667 667 667 667 278 278 278 278
    722 722 778 778 778 778 778 584 778 722 722 722 722 667 667 611
    556 556 556 556 556 556 889 556 556 556 556 556 278 278 278 278
    611 611 611 611 611 611 611 584 611 611 611 611 611 556 611 556
  )
  @times_bold ~w(
    250 333 555 500 500 1000 833 278 333 333 500 570 250 333 250 278
    500 500 500 500 500 500 500 500 500 500 333 333 570 570 570 500
    930 722 667 722 722 667 611 778 778 389 500 778 667 944 722 778
    611 778 722 556 667 722 722 1000 722 722 667 333 278 333 581 500
    333 500 556 444 556 444 333 500 556 278 333 556 278 833 556 500
    556 556 444 389 333 556 500 722 500 500 444 394 220 394 520 0
    500 0 333 500 500 1000 500 500 333 1000 556 333 1000 0 667 0
    0 333 333 500 500 350 500 1000 333 1000 389 333 722 0 444 722
    250 333 500 500 500 500 220 500 333 747 300 500 570 333 747 333
    400 570 300 300 333 556 540 250 333 300 330 500 750 750 750 500
    722 722 722 722 722 722 1000 722 667 667 667 667 389 389 389 389
    722 722 778 778 778 778 778 570 778 722 722 722 722 722 611 556
    500 500 500 500 500 500 722 444 444 444 444 444 278 278 278 278
    500 556 500 500 500 500 500 570 500 556 556 556 556 500 556 500
  )
  @widths %{
    helvetica: @helvetica |> Enum.map(&String.to_integer/1) |> List.to_tuple(),
    helvetica_bold: @helvetica_bold |> Enum.map(&String.to_integer/1) |> List.to_tuple(),
    times_bold: @times_bold |> Enum.map(&String.to_integer/1) |> List.to_tuple()
  }

  # WinAnsi codes 0x80..0x9F that differ from Latin-1.
  @win_ansi_extra %{
    0x20AC => 0x80,
    0x201A => 0x82,
    0x0192 => 0x83,
    0x201E => 0x84,
    0x2026 => 0x85,
    0x2020 => 0x86,
    0x2021 => 0x87,
    0x02C6 => 0x88,
    0x2030 => 0x89,
    0x0160 => 0x8A,
    0x2039 => 0x8B,
    0x0152 => 0x8C,
    0x017D => 0x8E,
    0x2018 => 0x91,
    0x2019 => 0x92,
    0x201C => 0x93,
    0x201D => 0x94,
    0x2022 => 0x95,
    0x2013 => 0x96,
    0x2014 => 0x97,
    0x02DC => 0x98,
    0x2122 => 0x99,
    0x0161 => 0x9A,
    0x203A => 0x9B,
    0x0153 => 0x9C,
    0x017E => 0x9E,
    0x0178 => 0x9F
  }
  @substitutes %{0x266F => "#", 0x266D => "b", 0x2212 => "-", 0x2032 => "'", 0x2033 => "\""}

  @doc "Paper sizes in points: A4 is 595 × 842, US Letter 612 × 792."
  @spec page_size(:a4 | :letter) :: {pos_integer, pos_integer}
  def page_size(:a4), do: {595, 842}
  def page_size(:letter), do: {612, 792}

  @doc """
  The PDF file for `pages`, in order. Options: `title:` (the document's
  title in its info dictionary).
  """
  @spec document([page, ...], keyword) :: binary
  def document([_ | _] = pages, opts \\ []) do
    font_count = map_size(@font_ids)
    first_page = 4 + font_count
    page_refs = for i <- 0..(length(pages) - 1), do: [ref(first_page + 2 * i), " "]

    title =
      case opts[:title] do
        nil -> []
        title -> [" /Title ", text_string(title)]
      end

    info = ["<< /Producer (Humdinger)", title, " >>"]

    fonts =
      for {_font, base} <- @fonts,
          do: [
            "<< /Type /Font /Subtype /Type1 /BaseFont /",
            base,
            " /Encoding /WinAnsiEncoding >>"
          ]

    font_resources =
      for id <- 1..font_count, do: ["/F", Integer.to_string(id), " ", ref(3 + id), " "]

    page_objects =
      pages
      |> Enum.with_index()
      |> Enum.flat_map(fn {%{size: {w, h}, content: content}, i} ->
        [
          [
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 ",
            num(w),
            " ",
            num(h),
            "] /Resources << /Font << ",
            font_resources,
            ">> >> /Contents ",
            ref(first_page + 2 * i + 1),
            " >>"
          ],
          stream(content)
        ]
      end)

    objects =
      [
        "<< /Type /Catalog /Pages 2 0 R >>",
        [
          "<< /Type /Pages /Kids [",
          page_refs,
          "] /Count ",
          Integer.to_string(length(pages)),
          " >>"
        ],
        info
        | fonts
      ] ++ page_objects

    serialize(objects)
  end

  defp serialize(objects) do
    header = "%PDF-1.4\n%\xE2\xE3\xCF\xD3\n"

    {body, offsets, size} =
      objects
      |> Enum.with_index(1)
      |> Enum.reduce({[], [], byte_size(header)}, fn {object, n}, {acc, offsets, pos} ->
        chunk = [Integer.to_string(n), " 0 obj\n", object, "\nendobj\n"]
        {[acc | chunk], [pos | offsets], pos + IO.iodata_length(chunk)}
      end)

    count = length(objects) + 1

    xref = [
      "xref\n0 ",
      Integer.to_string(count),
      "\n0000000000 65535 f \n",
      offsets |> Enum.reverse() |> Enum.map(&[pad10(&1), " 00000 n \n"])
    ]

    trailer = [
      "trailer\n<< /Size ",
      Integer.to_string(count),
      " /Root 1 0 R /Info 3 0 R >>\nstartxref\n",
      Integer.to_string(size),
      "\n%%EOF\n"
    ]

    IO.iodata_to_binary([header, body, xref, trailer])
  end

  defp stream(content) do
    data = :zlib.compress(content)

    [
      "<< /Length ",
      Integer.to_string(byte_size(data)),
      " /Filter /FlateDecode >>\nstream\n",
      data,
      "\nendstream"
    ]
  end

  defp ref(n), do: [Integer.to_string(n), " 0 R"]
  defp pad10(n), do: n |> Integer.to_string() |> String.pad_leading(10, "0")

  # Info strings as UTF-16BE with a byte-order mark, so any title survives.
  defp text_string(s) do
    utf16 = :unicode.characters_to_binary(s, :utf8, :utf16)
    ["<FEFF", Base.encode16(utf16), ">"]
  end

  # ── Path construction and painting ────────────────────────────────────

  @doc "Starts a subpath at (x, y)."
  def move_to(x, y), do: [num(x), " ", num(y), " m\n"]

  @doc "A straight segment to (x, y)."
  def line_to(x, y), do: [num(x), " ", num(y), " l\n"]

  @doc "A cubic Bézier segment through control points (x1, y1), (x2, y2) to (x, y)."
  def curve_to(x1, y1, x2, y2, x, y) do
    [Enum.map_intersperse([x1, y1, x2, y2, x, y], " ", &num/1), " c\n"]
  end

  @doc "Closes the current subpath."
  def close_path, do: "h\n"

  @doc "A rectangle subpath from its bottom-left corner."
  def rect(x, y, w, h), do: [Enum.map_intersperse([x, y, w, h], " ", &num/1), " re\n"]

  @doc "Fills the path (nonzero winding)."
  def fill, do: "f\n"

  @doc "Fills the path with the even-odd rule: inner contours become holes."
  def fill_even_odd, do: "f*\n"

  @doc "Strokes the path."
  def stroke, do: "S\n"

  @doc "Stroke width in points."
  def line_width(w), do: [num(w), " w\n"]

  @doc "Fill colour (also text colour) from an ARGB integer; alpha is ignored."
  def fill_color(argb), do: [rgb(argb), " rg\n"]

  @doc "Stroke colour from an ARGB integer; alpha is ignored."
  def stroke_color(argb), do: [rgb(argb), " RG\n"]

  @doc "Saves the graphics state (colours, line width, transform)."
  def save, do: "q\n"

  @doc "Restores the graphics state saved by the matching `save/0`."
  def restore, do: "Q\n"

  @doc "Concatenates the matrix `[a b c d e f]` to the current transform."
  def transform(a, b, c, d, e, f) do
    [Enum.map_intersperse([a, b, c, d, e, f], " ", &num/1), " cm\n"]
  end

  defp rgb(argb) do
    [argb >>> 16 &&& 0xFF, argb >>> 8 &&& 0xFF, argb &&& 0xFF]
    |> Enum.map_intersperse(" ", &num(&1 / 255))
  end

  # ── Text ──────────────────────────────────────────────────────────────

  @doc "Draws `string` with its baseline starting at (x, y), in the fill colour."
  @spec text(number, number, font, number, String.t()) :: iodata
  def text(x, y, font, size, string) do
    [
      "BT /F",
      Integer.to_string(Map.fetch!(@font_ids, font)),
      " ",
      num(size),
      " Tf ",
      num(x),
      " ",
      num(y),
      " Td (",
      escape(encode(string)),
      ") Tj ET\n"
    ]
  end

  @doc "The advance width of `string` set in `font` at `size`, in points."
  @spec text_width(String.t(), font, number) :: float
  def text_width(string, font, size) do
    widths = Map.fetch!(@widths, font)

    units =
      for <<byte <- encode(string)>>, reduce: 0 do
        acc -> acc + elem(widths, byte - 32)
      end

    units * size / 1000
  end

  @doc """
  `string` in WinAnsi bytes. Characters outside the encoding are replaced:
  ♯ ♭ − by `#` `b` `-`, accented letters by their base letter, control
  characters by a space, the rest by `?`.
  """
  @spec encode(String.t()) :: binary
  def encode(string) do
    for <<cp::utf8 <- string>>, into: "", do: encode_char(cp)
  end

  defp encode_char(cp) when cp in 0x20..0x7E or cp in 0xA0..0xFF, do: <<cp>>
  defp encode_char(cp) when cp < 0x20 or cp in 0x7F..0x9F, do: " "
  defp encode_char(cp) when is_map_key(@win_ansi_extra, cp), do: <<@win_ansi_extra[cp]>>
  defp encode_char(cp) when is_map_key(@substitutes, cp), do: @substitutes[cp]

  defp encode_char(cp) do
    case :unicode.characters_to_nfd_binary(<<cp::utf8>>) do
      <<base::utf8, _marks::binary>> when base != cp -> encode_char(base)
      _ -> "?"
    end
  end

  defp escape(bytes) do
    for <<byte <- bytes>>, into: "" do
      case byte do
        ?( -> "\\("
        ?) -> "\\)"
        ?\\ -> "\\\\"
        b when b > 126 -> "\\" <> String.pad_leading(Integer.to_string(b, 8), 3, "0")
        b -> <<b>>
      end
    end
  end

  # Numbers: integers as is, floats to 3 decimals without trailing zeros.
  defp num(n) when is_integer(n), do: Integer.to_string(n)
  defp num(n) when is_float(n), do: :erlang.float_to_binary(n, [:compact, decimals: 3])
end
