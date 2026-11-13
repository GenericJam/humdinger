defmodule Humdinger.PdfTest do
  use ExUnit.Case, async: true

  alias Humdinger.Pdf

  defp page(content), do: %{size: Pdf.page_size(:a4), content: content}

  # Every `N 0 obj ... endobj` with its byte offset.
  defp objects(pdf) do
    ~r/(\d+) 0 obj\n/
    |> Regex.scan(pdf, return: :index)
    |> Enum.map(fn [{at, _}, {n_at, n_len}] ->
      {String.to_integer(binary_part(pdf, n_at, n_len)), at}
    end)
  end

  defp streams(pdf) do
    ~r/<< \/Length (\d+) \/Filter \/FlateDecode >>\nstream\n/
    |> Regex.scan(pdf, return: :index)
    |> Enum.map(fn [{at, len}, {l_at, l_len}] ->
      length = String.to_integer(binary_part(pdf, l_at, l_len))
      data = binary_part(pdf, at + len, length)
      assert binary_part(pdf, at + len + length, 10) == "\nendstream"
      :zlib.uncompress(data)
    end)
  end

  describe "document/2" do
    test "has a header, a cross-reference table pointing at every object, and a trailer" do
      pdf = Pdf.document([page([Pdf.rect(10, 10, 100, 50), Pdf.fill()])], title: "Hum")

      assert "%PDF-1.4\n" <> _ = pdf
      assert String.ends_with?(pdf, "%%EOF\n")

      [_, startxref] = Regex.run(~r/startxref\n(\d+)\n%%EOF\n$/, pdf)
      xref_at = String.to_integer(startxref)
      assert binary_part(pdf, xref_at, 5) == "xref\n"

      [_, count] =
        Regex.run(~r/xref\n0 (\d+)\n/, binary_part(pdf, xref_at, byte_size(pdf) - xref_at))

      count = String.to_integer(count)
      [_, size] = Regex.run(~r/trailer\n<< \/Size (\d+) /, pdf)
      assert String.to_integer(size) == count

      entries =
        ~r/^(\d{10}) (\d{5}) ([fn]) \n/m
        |> Regex.scan(binary_part(pdf, xref_at, byte_size(pdf) - xref_at))
        |> Enum.map(fn [line, offset, _gen, kind] ->
          assert byte_size(line) == 20
          {String.to_integer(offset), kind}
        end)

      assert length(entries) == count
      assert hd(entries) == {0, "f"}

      in_use = tl(entries)
      assert length(in_use) == length(objects(pdf))

      for {{offset, "n"}, n} <- Enum.with_index(in_use, 1) do
        assert binary_part(pdf, offset, byte_size("#{n} 0 obj\n")) == "#{n} 0 obj\n"
      end
    end

    test "deflates content streams, which inflate back to the content" do
      content = [Pdf.fill_color(0xFF102030), Pdf.move_to(1, 2), Pdf.line_to(3.5, 4), Pdf.fill()]
      [stream] = streams(Pdf.document([page(content)]))
      assert stream == IO.iodata_to_binary(content)
    end

    test "counts its pages and gives each its size and own content" do
      pages = [
        page(Pdf.text(10, 10, :helvetica, 12, "one")),
        %{size: Pdf.page_size(:letter), content: Pdf.text(10, 10, :helvetica, 12, "two")},
        page(Pdf.text(10, 10, :helvetica, 12, "three"))
      ]

      pdf = Pdf.document(pages)

      assert pdf =~ "/Type /Pages /Kids ["
      assert [_, "3"] = Regex.run(~r/\/Count (\d+)/, pdf)
      assert Enum.count(Regex.scan(~r/\/Type \/Page /, pdf)) == 3
      assert pdf =~ "/MediaBox [0 0 612 792]"
      assert Enum.count(Regex.scan(~r/\/MediaBox \[0 0 595 842\]/, pdf)) == 2

      assert pdf |> streams() |> Enum.map(&(Regex.run(~r/\((\w+)\) Tj/, &1) |> List.last())) ==
               ~w(one two three)
    end

    test "carries the title as UTF-16 and names Humdinger as the producer" do
      pdf = Pdf.document([page([])], title: "Ré ♯")
      assert pdf =~ "/Producer (Humdinger)"
      assert pdf =~ "/Title <FEFF005200E90020266F>"
    end

    test "leaves the title out when there is none" do
      refute Pdf.document([page([])]) =~ "/Title"
    end
  end

  describe "text" do
    defp shown(string) do
      [_, shown] =
        Regex.run(~r/\((.*)\) Tj/s, IO.iodata_to_binary(Pdf.text(0, 0, :helvetica, 10, string)))

      shown
    end

    test "escapes parentheses and backslashes" do
      assert shown(~S"a(b)c\d") == ~S"a\(b\)c\\d"
    end

    test "writes Latin-1 and WinAnsi punctuation as octal codes" do
      assert shown("é · €") == ~S"\351 \267 \200"
      assert shown("“ok” – 1…") == ~S"\223ok\224 \226 1\205"
    end

    test "replaces characters outside WinAnsi sensibly" do
      assert shown("F♯ B♭") == "F# Bb"
      assert shown("Ł ő") == "? o"
      assert shown("漢") == "?"
      assert shown("a\tb\nc") == "a b c"
    end

    test "selects the font and size" do
      assert IO.iodata_to_binary(Pdf.text(1, 2.5, :times_bold, 12, "x")) ==
               "BT /F3 12 Tf 1 2.5 Td (x) Tj ET\n"
    end

    test "measures text with the font's metrics" do
      assert Pdf.text_width("Hello", :helvetica, 10) == 22.78
      assert Pdf.text_width("Hello", :helvetica, 20) == 45.56

      assert Pdf.text_width("Hello", :helvetica_bold, 10) >
               Pdf.text_width("Hello", :helvetica, 10)

      assert Pdf.text_width("", :times_bold, 10) == 0
    end
  end

  describe "graphics operators" do
    test "write numbers compactly and colours as 0..1 RGB" do
      ops =
        IO.iodata_to_binary([
          Pdf.curve_to(1, 2.0, 3.25, 4.125, 5.0001, -6),
          Pdf.fill_color(0xFFFF0000),
          Pdf.stroke_color(0x80000000),
          Pdf.transform(1, 0, 0, 1, 0, 10.5)
        ])

      assert ops ==
               "1 2.0 3.25 4.125 5.0 -6 c\n1.0 0.0 0.0 rg\n0.0 0.0 0.0 RG\n1 0 0 1 0 10.5 cm\n"
    end
  end
end
