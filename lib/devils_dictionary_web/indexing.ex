defmodule DevilsDictionaryWeb.Indexing do
  @moduledoc """
  Which pages a search engine may index (#237 C4; ADR 0004 §6 and §7), and
  which it is kept from, in one place.

  **Indexable**, and nothing else:

    * a published subject or edition page, served publicly (public reading
      mode, the launch switch on, `Routing.PublicRouting`) at its canonical
      address spelled exactly, with no query string (`subject?/4`);
    * an On page the launch manifest lists as a lexical entry (D1), while
      one of the subject pages it was listed for is published, served
      publicly, at `/on/:slug` spelled exactly, with no query string
      (`lexical?/3`).

  **Every other surface is noindex** (`surfaces/0`), and still answers 200
  where it would anyway, so a crawler can read the instruction (ADR §7:
  let crawlers retrieve noindex responses). `surface/1` names the surface a
  router path belongs to, so a test can hold every route to this list.

  #{Enum.map_join([{"/", "the way in, and search: `?q=` is a lookup variant"}, {"/on/:slug", "every On page but the launch manifest's lexical entries (D1), and any with a query string"}, {"/words/:id/:slug", "every exact word (D1)"}, {"/entities/:id/:slug", "the exact-identity route; its canonical is the subject's address where one is served"}, {"/<family>/:slug", "a draft, a withdrawn page, an alias, a choice, an unresolved address, every page while the switch is off, and any with a query string"}, {"/evidence/…", "raw evidence"}, {"/connections/…, /connect", "claims, proposals and their review"}, {"/sources/:slug", "a source's provenance page"}, {"/artworks", "the artworks shelf"}, {"/ops/…, /reconciliation, /users/…, /kit, /dev/…", "operations, review, accounts and development"}, {"/s/…, /health, /admin/…", "retired paths that redirect"}, {"/robots.txt, /sitemap.xml, /sitemaps/…", "for crawling, not pages: the sitemaps say noindex in X-Robots-Tag"}, {"?demo, ?opening, a section cursor, a trail, a drawer: any query string", "a view variant of a page whose canonical is its base"}], "\n", fn {surface, why} -> "  * `#{surface}`: #{why}" end)}

  `robots.txt` keeps crawlers out of the surfaces that are not for reading
  at all (`kept_out/0`): the registry's reserved prefixes that are neither a
  reader's route nor a static asset, and `/search`, which #237 names. Reader
  surfaces that are noindex stay fetchable, so the instruction is seen.
  """

  import Ecto.Query

  alias DevilsDictionary.Repo
  alias DevilsDictionary.Routing.{Address, LaunchManifest, Page, Policy, PublicRouting}

  @surfaces [
    {"/", "the way in, and search: `?q=` is a lookup variant"},
    {"/on/:slug",
     "every On page but the launch manifest's lexical entries (D1), and any with a query string"},
    {"/words/:id/:slug", "every exact word (D1)"},
    {"/entities/:id/:slug",
     "the exact-identity route; its canonical is the subject's address where one is served"},
    {"/<family>/:slug",
     "a draft, a withdrawn page, an alias, a choice, an unresolved address, every page while the switch is off, and any with a query string"},
    {"/evidence/…", "raw evidence"},
    {"/connections/…, /connect", "claims, proposals and their review"},
    {"/sources/:slug", "a source's provenance page"},
    {"/artworks", "the artworks shelf"},
    {"/ops/…, /reconciliation, /users/…, /kit, /dev/…",
     "operations, review, accounts and development"},
    {"/s/…, /health, /admin/…", "retired paths that redirect"},
    {"/robots.txt, /sitemap.xml, /sitemaps/…",
     "for crawling, not pages: the sitemaps say noindex in X-Robots-Tag"},
    {"?demo, ?opening, a section cursor, a trail, a drawer: any query string",
     "a view variant of a page whose canonical is its base"}
  ]

  # A router path's first segment, to the surface above it belongs to.
  @by_segment %{
    "" => "/",
    "on" => "/on/:slug",
    "words" => "/words/:id/:slug",
    "entities" => "/entities/:id/:slug",
    "evidence" => "/evidence/…",
    "connections" => "/connections/…, /connect",
    "connect" => "/connections/…, /connect",
    "sources" => "/sources/:slug",
    "artworks" => "/artworks",
    "ops" => "/ops/…, /reconciliation, /users/…, /kit, /dev/…",
    "reconciliation" => "/ops/…, /reconciliation, /users/…, /kit, /dev/…",
    "users" => "/ops/…, /reconciliation, /users/…, /kit, /dev/…",
    "kit" => "/ops/…, /reconciliation, /users/…, /kit, /dev/…",
    "dev" => "/ops/…, /reconciliation, /users/…, /kit, /dev/…",
    "s" => "/s/…, /health, /admin/…",
    "health" => "/s/…, /health, /admin/…",
    "admin" => "/s/…, /health, /admin/…",
    "robots.txt" => "/robots.txt, /sitemap.xml, /sitemaps/…",
    "sitemap.xml" => "/robots.txt, /sitemap.xml, /sitemaps/…",
    "sitemaps" => "/robots.txt, /sitemap.xml, /sitemaps/…"
  }

  @reserved Policy.root()
            |> Path.join("namespaces.json")
            |> File.read!()
            |> Jason.decode!()
            |> Map.fetch!("reserved_prefixes")

  # Reserved prefixes a crawler may fetch: the reader's routes (their pages
  # say noindex themselves), the future locale prefix, and the static files a
  # page renders with, which a crawler needs to see the page as a reader does.
  @fetchable ~w(on words define entities l sources artworks assets fonts images)
  @static_files ~w(sitemap.xml robots.txt favicon.ico)

  @kept_out (@reserved -- (@fetchable ++ @static_files)) ++ ["search"]

  @doc "Every noindex surface, `{surface, why}`."
  def surfaces, do: @surfaces

  @doc """
  The noindex surface a router path (`/evidence/content/:id`) belongs to, as
  `{surface, why}`, or nil for a path no surface names. A family route and
  `/on/:slug` are listed too: they are noindex but for the two exceptions
  above.
  """
  def surface(path) when is_binary(path) do
    segment =
      case String.split(path, "/", parts: 3) do
        ["", first | _] -> first
        _ -> nil
      end

    name =
      cond do
        is_nil(segment) -> nil
        segment in Address.families() -> "/<family>/:slug"
        true -> Map.get(@by_segment, segment)
      end

    name && Enum.find(@surfaces, fn {surface, _why} -> surface == name end)
  end

  @doc "The robots instruction for an indexable page (none) or not (`noindex`)."
  def robots(true), do: nil
  def robots(false), do: "noindex"

  @doc """
  Whether a subject or edition page, as resolved for this request, may be
  indexed: published and active, served publicly (public mode, the switch
  on) at its canonical exactly (`outcome` `:canonical`), with no query
  string (`query` is the request's query string or nil).
  """
  def subject?(%Page{} = page, outcome, mode, query) do
    page.publication_state == :published and page.lifecycle_state == :active and
      page.role in [:subject, :edition] and outcome == :canonical and mode == :public and
      PublicRouting.enabled?() and no_query?(query)
  end

  def subject?(_page, _outcome, _mode, _query), do: false

  @doc """
  Whether `/on/:slug` may be indexed: the launch manifest lists it as a
  lexical entry (D1), one of the subject pages it was listed for is
  published and active, the request is public with the switch on, and there
  is no query string.
  """
  def lexical?(slug, mode, query) when is_binary(slug) do
    mode == :public and PublicRouting.enabled?() and no_query?(query) and
      case Map.get(lexical_entries(), "/on/" <> slug) do
        nil -> false
        page_ids -> published?(page_ids)
      end
  end

  def lexical?(_slug, _mode, _query), do: false

  @doc "Which of these page ids are published and active, as a set, in one query."
  def published_ids(page_ids) when is_list(page_ids) do
    case page_ids |> Enum.filter(&is_integer/1) |> Enum.uniq() do
      [] ->
        MapSet.new()

      ids ->
        from(p in Page,
          where:
            p.id in ^ids and p.publication_state == :published and
              p.lifecycle_state == :active,
          select: p.id
        )
        |> Repo.all()
        |> MapSet.new()
    end
  end

  @doc """
  Whether any of a lexical entry's subject pages is published and active.
  """
  def published?(page_ids) when is_list(page_ids) do
    ids = Enum.filter(page_ids, &is_integer/1)

    ids != [] and
      Repo.exists?(
        from p in Page,
          where:
            p.id in ^ids and p.publication_state == :published and
              p.lifecycle_state == :active
      )
  end

  def published?(_page_ids), do: false

  @doc "Whether a request's query string (or nil) leaves the page its base."
  def no_query?(nil), do: true
  def no_query?(""), do: true
  def no_query?(query) when is_binary(query), do: false

  @doc """
  The reserved prefixes `robots.txt` keeps crawlers out of, from the
  registry: every reserved prefix that is neither a reader's route nor a
  static file, and `search`.
  """
  def kept_out, do: @kept_out

  @doc """
  The launch manifest's lexical entries, `%{"/on/slug" => subject_page_ids}`,
  read from `config :devils_dictionary, :launch_manifest` (default
  `priv/routing/launch-manifest.json`), cached until the file changes. None
  when there is no manifest, or it does not read.
  """
  def lexical_entries do
    path = manifest_path()

    stamp =
      case File.stat(path) do
        {:ok, %{mtime: mtime, size: size}} -> {path, mtime, size}
        {:error, _} -> {path, :none}
      end

    case :persistent_term.get({__MODULE__, :lexical}, nil) do
      {^stamp, entries} ->
        entries

      _stale ->
        entries = read_lexical(stamp, path)
        :persistent_term.put({__MODULE__, :lexical}, {stamp, entries})
        entries
    end
  end

  defp read_lexical({_, :none}, _path), do: %{}

  defp read_lexical(_stamp, path) do
    case LaunchManifest.read(path) do
      {:ok, manifest} ->
        Map.new(
          manifest.lexical,
          &{String.normalize(&1["path"], :nfc), List.wrap(&1["subject_page_ids"])}
        )

      {:error, _} ->
        %{}
    end
  end

  @doc "The launch manifest's path."
  def manifest_path do
    Application.get_env(:devils_dictionary, :launch_manifest) ||
      Path.join(Policy.root(), "launch-manifest.json")
  end
end
