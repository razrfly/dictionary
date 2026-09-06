defmodule DevilsDictionary.Markdown do
  @moduledoc """
  The tiny slice of Markdown the 👑 corpus actually uses, rendered to HTML.

  Bierce (997 entries) and Johnson (42,726) are stored as `body_format:
  :markdown`, and between them they use exactly three constructs, which a scan
  of all 43,723 bodies confirms:

    * blank-line-separated paragraphs;
    * `> ` blockquotes — 2,278 bodies — for Bierce's verse and Johnson's
      quotations, which keep their line breaks because half of them are verse
      and the citation on the last line is the author's own;
    * `*emphasis*` — 277 bodies — Bierce's 171 `<i>` pairs (foreign phrases and
      book titles) plus Johnson's.

  There are **no** headings, code spans, links, lists or HTML tags in the
  corpus, so there is nothing here to parse them with. That is the point: this
  renders what we store, and anything else is escaped and shown literally
  rather than silently reinterpreted.

  #71 §8a.4 asked for Earmark ("pure Elixir, no NIF"). Earmark 1.4.49 is
  retired on Hex and carries a security advisory, and the replacement it names
  (MDEx) is a Rust NIF — the thing the issue ruled out. Forty lines that handle
  three constructs honour the intent better than either.

  Every `&`, `<` and `>` in the source text is escaped **before** any markup is
  emitted, so a body can never inject HTML. Callers render the result with
  `Phoenix.HTML.raw/1`, and it is built in `WordPage.build/2` — never in a
  template.
  """

  @doc """
  Renders a stored body to an HTML string.

  `:markdown` gets the three constructs above; `:text` (Wikipedia's 70,925
  extracts) gets paragraphs and nothing else; anything else is treated as text,
  because guessing is how markup gets executed.
  """
  def to_html(body, format \\ :markdown)

  def to_html(nil, _format), do: ""
  def to_html("", _format), do: ""

  def to_html(body, :markdown) do
    body
    |> String.split(~r/\n[ \t]*\n/)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.map_join("\n", &block/1)
  end

  def to_html(body, _text) do
    body
    |> String.split(~r/\n[ \t]*\n/)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.map_join("\n", &"<p>#{escape(&1) |> breaks()}</p>")
  end

  # A block is a blockquote when its first line opens with `> `. Johnson's
  # quotations are one block of `> ` lines each, so the whole block belongs to
  # one <blockquote>; the line breaks inside it are the verse and survive as
  # <br>.
  defp block("> " <> _ = quoted) do
    inner =
      quoted
      |> String.split("\n")
      |> Enum.map_join("\n", &strip_marker/1)
      |> render_inline()

    "<blockquote><p>#{inner}</p></blockquote>"
  end

  defp block(paragraph), do: "<p>#{render_inline(paragraph)}</p>"

  defp strip_marker("> " <> rest), do: rest
  defp strip_marker(">" <> rest), do: rest
  defp strip_marker(line), do: line

  defp render_inline(text), do: text |> escape() |> emphasis() |> breaks()

  # Escaping happens first and once. `'` and `"` are left alone: this string is
  # element content, never an attribute value.
  defp escape(text) do
    text
    |> String.replace("&", "&amp;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
  end

  # `*…*` only, non-greedy, never across a line break — the corpus has no `_`
  # emphasis and no `**strong**`, and a lone `*` stays a lone `*`.
  defp emphasis(text), do: String.replace(text, ~r/\*([^*\n]+)\*/, "<em>\\1</em>")

  defp breaks(text), do: String.replace(text, "\n", "<br>\n")
end
