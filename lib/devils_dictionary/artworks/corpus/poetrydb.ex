defmodule DevilsDictionary.Artworks.Corpus.Poetrydb do
  @moduledoc """
  Builds the `poetrydb` corpus manifest: the poems, once, with their poets.

  A corpus is a **selection**, built once and committed, never re-run at seed
  time. PoetryDB gives that rule a second reason beyond the Met's: its
  `/author/<poet>` endpoint answers `503` for the two poets whose collected
  works are largest — Byron, whose *Don Juan* alone is 16,092 lines, and
  Shelley — after about sixteen seconds, every time. A corpus that rebuilt
  itself on seed would hold 127 poets on a good day and 125 on a bad one, and
  nobody could say which. It holds what it holds, and
  `docs/integrations/poetrydb.md` says what is missing and why.

  ## What a row is

  PoetryDB publishes no identifier, so `poem_id` is derived: the poet, the
  title and the text, digested. Poet and title are not enough on their own —
  18 pairs in the 2,526 poems fetched are used twice — and the text is in the
  key anyway, since `lines_sha256` is what tells a corrected poem from the one
  it replaced. `DevilsDictionary.Discovery.Providers.Poetrydb.poem_id/3` is the
  single definition, so a poem found live and the same poem held here are one
  identity rather than two.

  `line_count` is `length(lines)`, and it is not PoetryDB's `linecount`. Those
  two numbers disagree for 1,694 of the 2,526 poems, because the API's field
  counts non-blank lines while the array it returns includes the blank ones
  that separate stanzas. A line number the reader can count to is an index into
  the array, so the array's length is the count this records; the source's own
  figure is kept beside it as `source_line_count` rather than reconciled away.

  ## The author crosswalk

  `author_qid` is the one identity claim in the file, and it is about the poet,
  never about the poem. It is present only where a rule named a winner: the
  most-linked Wikidata human with a poet-or-writer occupation whose label or
  alias is exactly the poet's name, with at least five sitelinks and at least
  three times the runner-up's. 115 of 127 poets clear that; the other twelve
  are namesakes nothing separates, or names PoetryDB spells its own way
  ("Lord Alfred Tennyson", "Samuel Coleridge"), and they carry no QID at all.
  A guess here would be worse than a gap — it is the only place in this corpus
  where a wrong identifier could reach a page.
  """

  alias DevilsDictionary.Artworks.Corpus.Manifest
  alias DevilsDictionary.Discovery.Providers.Poetrydb

  @kind "poetrydb"

  @doc "The manifest kind this builder produces."
  def kind, do: @kind

  @doc """
  Builds the manifest from `rows` and writes it to `path`.

  Rows arrive from a **bounded** probe with a request ceiling and a ledger
  written as it goes — never a total recorded at the end, because a run that
  is killed then leaves a range instead of a number.
  """
  def build!(rows, path \\ default_path(), metadata \\ %{}) when is_list(rows) do
    @kind
    |> Manifest.new(rows, metadata)
    |> Manifest.save!(path)
  end

  @doc """
  One manifest row from one poem as PoetryDB returns it, plus the crosswalk.

  `poem` is `%{"author" => _, "title" => _, "lines" => [_], "linecount" => _}`
  and `crosswalk` maps a poet's name to a QID where the rule named one.

  `:source_url` overrides the locator the row records. It defaults to the
  `/author/<poet>` route every row came from until Phase 1c, and it is passed
  when a row came from somewhere else: Byron's and Shelley's poems arrive one
  `linecount` bucket at a time, because the author route answers `503` for
  them, and a row that claimed the author route would be naming a locator that
  does not resolve for it.
  """
  def row(poem, crosswalk \\ %{}, opts \\ [])

  def row(%{"author" => author, "title" => title, "lines" => lines} = poem, crosswalk, opts) do
    author = String.trim(author)
    title = String.trim(title)

    %{
      "poem_id" => Poetrydb.poem_id(author, title, lines),
      "title" => title,
      "author" => author,
      "line_count" => length(lines),
      "source_line_count" => poem["linecount"],
      "lines_sha256" => Poetrydb.lines_hash(lines),
      "source_url" => Keyword.get(opts, :source_url) || source_url(author)
    }
    |> put_author_qid(Map.get(crosswalk, author))
  end

  @doc """
  The locator one `linecount` bucket of one poet's poems came back from.

  `/author,linecount/<poet>;<n>` is the only route that returns the `lines`
  field for a poet whose collected works are too large for `/author/<poet>` to
  serialize. `linecount` matches exactly — measured: `Shelley;4` answers with
  the eighteen four-line poems and nothing else — so a bucket is a partition of
  that poet's poems and not a filter over them.
  """
  def bucket_url(author, line_count) do
    encoded = URI.encode(String.trim(author), &URI.char_unreserved?/1)
    "https://poetrydb.org/author,linecount/#{encoded};#{line_count}/title,author,linecount,lines"
  end

  defp put_author_qid(row, qid) when is_binary(qid) do
    if Regex.match?(~r/\AQ[1-9]\d*\z/, qid), do: Map.put(row, "author_qid", qid), else: row
  end

  defp put_author_qid(row, _qid), do: row

  defp source_url(author) do
    encoded = URI.encode(author, &URI.char_unreserved?/1)
    "https://poetrydb.org/author/#{encoded}/title,author,linecount,lines"
  end

  @doc "Where the committed manifest lives."
  def default_path, do: "priv/artworks/manifests/#{@kind}-v1.json"
end
