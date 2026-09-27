defmodule DevilsDictionary.Curation.Excerpt do
  @moduledoc """
  The words a lead quotes: the opening sentences of an exact revision, cut only
  where a sentence ends (#156: *clip only at a valid textual boundary*).

  The excerpt is a **prefix of the stored body**, byte for byte, so joining it
  to the rest of the entry gives back the entry. Nothing is rewritten, nothing
  is reordered, and there is no ellipsis to guess at; the component says the
  entry continues and links to all of it.

  Only the first block is ever quoted, and only when it is prose. Bierce's
  verse and Johnson's citations are `> ` blockquotes (`DevilsDictionary.Markdown`),
  and an entry that opens on one has no sentence to lead with, so it is
  refused rather than cut mid-verse.

  A full stop after an initial (*J.*) or a common abbreviation (*Mr.*, *e.g.*)
  is not a sentence end. The rule is deliberately small: a selection names how
  many sentences it wants, and a test pins what that gives.
  """

  alias DevilsDictionary.Markdown

  @sentence_end ~r/[.!?][”’"')\]]*(?=\s+[“"‘'(\[]?\p{Lu}|\s*\z)/u
  @abbreviations ~w(mr mrs ms dr st jr sr mt vs viz cf etc e.g i.e no)

  @doc """
  The first `count` sentences of `body` (stored in `format`), as
  `{:ok, %{markdown, text, html, clipped?, chars}}`.

  `markdown` is the exact prefix of the stored body; `html` is that prefix
  through `Markdown.to_html/2` with its paragraph wrapper removed; `text` is
  its words; `clipped?` says whether the entry goes on; `chars` is the whole
  entry's length in characters. A body with no prose opening, or no sentence
  end in its first block, is `{:error, reason}`.
  """
  def sentences(body, format, count)
      when is_binary(body) and is_integer(count) and count >= 1 do
    body = String.trim(body)
    [first | _rest] = String.split(body, ~r/\n[ \t]*\n/, parts: 2)
    first = String.trim_trailing(first)

    cond do
      first == "" ->
        {:error, :empty}

      String.starts_with?(first, ">") ->
        {:error, :no_prose_opening}

      true ->
        case sentence_ends(first) do
          [] ->
            {:error, :no_sentence_boundary}

          ends ->
            cut = Enum.at(ends, min(count, length(ends)) - 1)
            excerpt(body, binary_part(first, 0, cut), format)
        end
    end
  end

  def sentences(_body, _format, _count), do: {:error, :empty}

  defp excerpt(body, prefix, format) do
    html = Markdown.to_html(prefix, format)

    {:ok,
     %{
       markdown: prefix,
       html: unwrap(html),
       text: text_of(html),
       clipped?: byte_size(prefix) < byte_size(body),
       chars: body |> Markdown.to_html(format) |> text_of() |> String.length()
     }}
  end

  # Byte offsets just past each sentence end in `text`, in order.
  defp sentence_ends(text) do
    @sentence_end
    |> Regex.scan(text, return: :index)
    |> Enum.map(fn [{start, length}] -> {start, start + length} end)
    |> Enum.reject(fn {start, _end} -> abbreviation?(binary_part(text, 0, start)) end)
    |> Enum.map(&elem(&1, 1))
  end

  # The token the full stop closes: an initial or a listed abbreviation is not
  # the end of a sentence.
  defp abbreviation?(before) do
    token =
      case Regex.run(~r/(\S+)\z/u, before) do
        [_, token] -> token |> String.trim_leading("(") |> String.trim_leading("*")
        nil -> ""
      end

    Regex.match?(~r/\A\p{Lu}\z/u, token) or String.downcase(token) in @abbreviations
  end

  defp unwrap(html) do
    case Regex.run(~r{\A<p>(.*)</p>\z}s, String.trim(html)) do
      [_, inner] -> inner
      nil -> html
    end
  end

  defp text_of(html) do
    html
    |> String.replace(~r{<br\s*/?>|</p>}, "\\0 ")
    |> Floki.parse_fragment!()
    |> Floki.text()
    |> String.replace(~r/\s+/u, " ")
    |> String.trim()
  end
end
