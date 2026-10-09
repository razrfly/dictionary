defmodule DevilsDictionary.Routing.Sitemaps do
  @moduledoc """
  The sitemaps (#237 C5, ADR 0004 §7): exactly the published canonical
  pages, an active subject or edition page in the `published` state at its
  canonical address, and nothing else, while public routing is on
  (`Routing.PublicRouting`); none while it is off (D5).

  `/sitemap.xml` is a sitemap index naming `/sitemaps/subjects-N.xml`, each
  holding at most #{50_000} URLs and 50 MB uncompressed (Google's limits),
  split by whichever comes first (`chunk/2`). A URL's `lastmod` is when its
  content last changed: the newest of the page's own current revision and
  the current revisions of the articles about its subject, or, where nothing
  dates its content, when it was published. Never an audit run's time.

  The lists are cached per publication receipt, per route change and per
  content change: the cache is keyed by the newest receipt
  (`Routing.Publications.generation/0`), the newest ledger row, the newest
  page, content and assertion revisions (what `lastmod` reads), the switch
  and the origin, so a publish, a withdrawal, a move, a retirement or a
  changed article changes the sitemaps at the next request.
  """

  import Ecto.Query

  alias DevilsDictionary.Repo
  alias DevilsDictionary.Routing.{Address, Publications, PublicRouting, RouteChange}

  @max_urls 50_000
  @max_bytes 50 * 1024 * 1024
  @name "subjects"

  @xml_head ~s(<?xml version="1.0" encoding="UTF-8"?>\n)
  @urlset_open ~s(<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">\n)
  @urlset_close "</urlset>\n"

  @doc "The limits a sitemap is split at: `%{urls:, bytes:}`."
  def limits, do: %{urls: @max_urls, bytes: @max_bytes}

  @doc "The bytes a sitemap's envelope takes before its first URL."
  def envelope, do: byte_size(@xml_head) + byte_size(@urlset_open) + byte_size(@urlset_close)

  @doc "The sitemaps' file names, in order (`subjects-1.xml`, ...); none while off."
  def names, do: Enum.map(chunks(), & &1.name)

  @doc "The sitemap index's XML."
  def index do
    origin = PublicRouting.origin()

    IO.iodata_to_binary([
      @xml_head,
      ~s(<sitemapindex xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">\n),
      for chunk <- chunks() do
        [
          "  <sitemap><loc>",
          escape(origin <> "/sitemaps/" <> chunk.name),
          "</loc>",
          if(chunk.lastmod, do: ["<lastmod>", chunk.lastmod, "</lastmod>"], else: []),
          "</sitemap>\n"
        ]
      end,
      "</sitemapindex>\n"
    ])
  end

  @doc "One sitemap's XML by file name, or `:error` for a name that is not one."
  def sitemap(name) when is_binary(name) do
    case Enum.find(chunks(), &(&1.name == name)) do
      nil -> :error
      chunk -> {:ok, chunk.xml}
    end
  end

  @doc """
  Every URL the sitemaps list, `%{path:, lastmod:}` (the stored path and a
  W3C date or nil), in byte order of the path: the published canonical pages,
  or none while public routing is off.
  """
  def entries do
    if PublicRouting.enabled?(), do: published(), else: []
  end

  @doc """
  What the sitemaps are built from, and so what the cache is keyed by: the
  newest receipt, the newest ledger row, the newest revisions `lastmod`
  reads, the switch and the origin.
  """
  def generation do
    {Publications.generation(), ledger_generation(), content_generation(),
     PublicRouting.enabled?(), PublicRouting.origin()}
  end

  defp ledger_generation, do: Repo.one(from c in RouteChange, select: coalesce(max(c.id), 0))

  # Each a primary key's maximum, an index lookup: a new page revision, a new
  # revision of an article, or a new or changed `about` assertion moves it.
  defp content_generation do
    %{rows: [row]} =
      Repo.query!("""
      SELECT (SELECT coalesce(max(id), 0) FROM page_revisions),
             (SELECT coalesce(max(id), 0) FROM content_revisions),
             (SELECT coalesce(max(id), 0) FROM assertion_revisions)
      """)

    List.to_tuple(row)
  end

  # ── the cache ────────────────────────────────────────────────────────────

  defp chunks do
    key = generation()

    case :persistent_term.get(__MODULE__, nil) do
      {^key, chunks} ->
        chunks

      _stale ->
        chunks = build(entries(), elem(key, 4))
        :persistent_term.put(__MODULE__, {key, chunks})
        chunks
    end
  end

  @doc "Forgets the cached sitemaps, so the next request builds them again."
  def forget, do: :persistent_term.erase(__MODULE__)

  defp build(entries, origin) do
    entries
    |> Enum.map(fn entry -> {entry, url(entry, origin)} end)
    |> chunk()
    |> Enum.with_index(1)
    |> Enum.map(fn {urls, n} ->
      %{
        name: "#{@name}-#{n}.xml",
        xml: urlset(urls),
        lastmod:
          urls |> Enum.map(fn {entry, _xml} -> entry.lastmod end) |> Enum.max(fn -> nil end)
      }
    end)
  end

  @doc """
  Splits `{entry, url_xml}` pairs into sitemaps at `limits` (`urls:` and
  `bytes:`, Google's by default): a sitemap holds at most that many URLs
  and, with its envelope, at most that many bytes, whichever comes first.
  Pure, so the split is unit-tested at small limits.
  """
  def chunk(urls, limits \\ []) do
    max_urls = Keyword.get(limits, :urls, @max_urls)
    max_bytes = Keyword.get(limits, :bytes, @max_bytes)
    envelope = envelope()
    split(urls, {[], 0, envelope}, [], {max_urls, max_bytes, envelope})
  end

  # `current` is `{urls, count, bytes}`, the count carried beside the list.
  defp split([], {[], _count, _bytes}, done, _limits), do: Enum.reverse(done)

  defp split([], {current, _count, _bytes}, done, _limits),
    do: Enum.reverse([Enum.reverse(current) | done])

  defp split(
         [{_entry, xml} = url | rest],
         {current, count, bytes},
         done,
         {max_urls, max_bytes, envelope} = limits
       ) do
    size = byte_size(xml)

    if current != [] and (count >= max_urls or bytes + size > max_bytes) do
      split([url | rest], {[], 0, envelope}, [Enum.reverse(current) | done], limits)
    else
      split(rest, {[url | current], count + 1, bytes + size}, done, limits)
    end
  end

  defp url(entry, origin) do
    IO.iodata_to_binary([
      "  <url><loc>",
      escape(origin <> Address.encode(entry.path)),
      "</loc>",
      if(entry.lastmod, do: ["<lastmod>", entry.lastmod, "</lastmod>"], else: []),
      "</url>\n"
    ])
  end

  defp urlset(urls) do
    IO.iodata_to_binary([@xml_head, @urlset_open, Enum.map(urls, &elem(&1, 1)), @urlset_close])
  end

  @doc "A text as XML character data."
  def escape(text) do
    text
    |> String.replace("&", "&amp;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
    |> String.replace("\"", "&quot;")
    |> String.replace("'", "&apos;")
  end

  # ── what is published ────────────────────────────────────────────────────

  # When a page's content last changed: its own current revision, or the
  # newest current revision of an article about its subject; failing both,
  # when it was published. Never an audit run's time.
  @lastmod """
  coalesce(
    greatest(
      (SELECT r.inserted_at FROM page_revisions r WHERE r.id = p.current_revision_id),
      (SELECT max(cr.inserted_at)
         FROM assertion_revisions a
         JOIN predicates pr ON pr.id = a.predicate_id AND pr.key = 'about'
         JOIN content_revisions cr ON cr.content_id = a.subject_object_id AND cr.is_current
        WHERE a.object_object_id = p.target_object_id
          AND a.is_current AND a.lifecycle_state = 'active')),
    (SELECT max(pp.committed_at) FROM page_publications pp
      WHERE pp.page_id = p.id AND pp.action = 'publish'))
  """

  defp published do
    %{rows: rows} =
      Repo.query!("""
      SELECT c.path, #{@lastmod}
        FROM pages p
        JOIN public_paths c ON c.id = p.canonical_path_id AND c.kind = 'canonical'
       WHERE p.publication_state = 'published' AND p.lifecycle_state = 'active'
         AND p.role IN ('subject', 'edition') AND p.locale = 'en'
       ORDER BY c.path COLLATE "C"
      """)

    Enum.map(rows, fn [path, lastmod] -> %{path: path, lastmod: lastmod && w3c(lastmod)} end)
  end

  @doc "When a page's content last changed, as its sitemap entry says (W3C), or nil."
  def lastmod(page_id) when is_integer(page_id) do
    case Repo.query!("SELECT #{@lastmod} FROM pages p WHERE p.id = $1", [page_id]).rows do
      [[at]] when not is_nil(at) -> w3c(at)
      _ -> nil
    end
  end

  def lastmod(_page_id), do: nil

  defp w3c(%NaiveDateTime{} = at),
    do: at |> NaiveDateTime.truncate(:second) |> NaiveDateTime.to_iso8601() |> Kernel.<>("Z")

  defp w3c(%DateTime{} = at), do: at |> DateTime.truncate(:second) |> DateTime.to_iso8601()
end
