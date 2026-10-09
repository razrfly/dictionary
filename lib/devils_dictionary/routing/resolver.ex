defmodule DevilsDictionary.Routing.Resolver do
  @moduledoc """
  Resolves a request path or an exact page id to a `Routing.Resolution`.

  Read-only and deterministic: it consults the ledger's current state and
  nothing else — no label, slug similarity, classification or provider. An
  alias names a destination *page*, whose current canonical is read directly,
  so a redirect is always a single hop. State the invariants should have made
  impossible is reported as `:corrupt` with diagnostics and logged, never
  papered over with a guess.

  Every decision is made from rows read in **one statement** — the path, its
  page and that page's canonical together — so a move or merge committing
  between two reads cannot make consistent state look corrupt.

  ## Reading modes (#219)

  Every entry point takes `mode:`, `:public` (the default) or `:internal`,
  and link generation and direct requests use the same one:

    * `:public` serves only `published` pages. A draft is `:unavailable`,
      indistinguishable from missing.
    * `:internal` also serves `draft` pages, for a reader who may see work in
      progress (`DevilsDictionaryWeb.ReadingMode` decides who). It changes no
      publication state, approval or ledger row.

  Public mode also obeys the launch switch (`Routing.PublicRouting`, #237):
  while it is off, nothing is served publicly at a ledger address — every
  page is withheld and a tombstone is `:unavailable` too, so the family routes
  answer 404 — and nothing in the ledger changes. Internal mode ignores it.

  `withdrawn` pages are withheld in both modes, and every lifecycle rule —
  merged, split, retired, tombstones — is the same in both. An alias or an
  equivalent spelling answers with its **destination's** outcome in the same
  mode, so a public request never redirects to a draft.

  The reader serves the eight family routes and the `/on` overviews through
  this module (`DevilsDictionaryWeb.ReadingStatus`, `EntityLive`, `WordLive`)
  and links subjects through `Routing.Links`.
  """

  import Ecto.Query
  import DevilsDictionary.Routing.Input, only: [is_id: 1]

  require Logger

  alias DevilsDictionary.Repo
  alias DevilsDictionary.Routing.{Address, Page, Pages, PublicPath, PublicRouting, Resolution}

  @max_merge_hops 64
  @modes [:public, :internal]

  @doc """
  Resolves a raw request path, as received (percent-encoded).

  An equivalent spelling of a reserved path — case, Unicode form, a trailing
  slash — resolves to the same page and is answered with a redirect to the
  canonical, never a second 200.
  """
  def resolve(raw, opts \\ []) do
    mode = mode!(opts)

    case Address.normalize_request(raw) do
      {:ok, normalized, exact?} ->
        case load(normalized) do
          nil ->
            %Resolution{outcome: :missing, request: raw}

          {path, page, canonical} ->
            path
            |> decide(page, canonical, exact?, mode)
            |> Map.put(:request, raw)
            |> with_successors(true, mode)
            |> report()
        end

      {:error, reason}
      when reason in [:malformed_encoding, :encoded_separator, :nul, :invalid_utf8] or
             reason in [:not_a_path, :dot_segment, :empty_segment, :not_absolute] ->
        %Resolution{outcome: :invalid, request: raw, reason: reason}

      {:error, reason} ->
        %Resolution{outcome: :missing, request: raw, reason: reason}
    end
  end

  # One statement, one snapshot.
  defp load(normalized) do
    Repo.one(
      from path in PublicPath,
        join: page in Page,
        on: page.id == path.destination_page_id,
        left_join: canonical in PublicPath,
        on: canonical.id == page.canonical_path_id,
        where: path.path == ^normalized,
        select: {path, page, canonical}
    )
  end

  # A page and its canonical, in one statement.
  # Not an id — nil, a string, out of range — is missing, like an absent row.
  defp load_page(page_id) when not is_id(page_id), do: nil

  defp load_page(page_id) do
    Repo.one(
      from page in Page,
        left_join: canonical in PublicPath,
        on: canonical.id == page.canonical_path_id,
        where: page.id == ^page_id,
        select: {page, canonical}
    )
  end

  @doc """
  The decision, given the loaded rows, in `mode` (`:public` by default). Pure
  but for public mode's launch switch, which is configuration
  (`Routing.PublicRouting`), so every state — including ones the database
  refuses to store — can be examined.
  """
  def decide(%PublicPath{} = path, %Page{} = page, canonical, exact?, mode \\ :public)
      when mode in @modes do
    base = %Resolution{outcome: :missing, path: path, page: page}

    cond do
      page.lifecycle_state == :merged ->
        corrupt(base, :path_on_merged_page, %{})

      # Gone is only news for a page the public has seen, and only while the
      # public is served at all.
      path.kind == :tombstone and page.publication_state in [:published, :withdrawn] and
          (mode == :internal or PublicRouting.enabled?()) ->
        %{base | outcome: :gone}

      path.kind == :tombstone ->
        %{base | outcome: :unavailable}

      page.lifecycle_state == :retired ->
        corrupt(base, :live_path_on_retired_page, %{})

      is_nil(canonical) and page.publication_state == :published ->
        corrupt(base, :published_page_without_canonical, %{})

      is_nil(canonical) ->
        %{base | outcome: :unavailable}

      canonical.kind != :canonical or canonical.destination_page_id != page.id or
          page.canonical_path_id != canonical.id ->
        corrupt(base, :canonical_pointer_mismatch, %{
          canonical_path_id: canonical.id,
          canonical_kind: canonical.kind,
          canonical_destination_page_id: canonical.destination_page_id
        })

      not visible?(page, mode) ->
        %{base | outcome: :unavailable}

      path.id != canonical.id or not exact? ->
        %{base | outcome: :redirect, location: canonical.path}

      page.lifecycle_state == :split ->
        %{base | outcome: :choice, location: canonical.path}

      true ->
        %{base | outcome: :canonical, location: canonical.path}
    end
  end

  defp corrupt(resolution, reason, details) do
    %{
      resolution
      | outcome: :corrupt,
        reason: reason,
        diagnostics:
          Map.merge(details, %{
            path_id: resolution.path && resolution.path.id,
            page_id: resolution.page && resolution.page.id
          })
    }
  end

  @doc """
  Whether a page may be served in `mode`: a published page internally, and
  publicly while public routing is on; a draft only internally; a withdrawn
  page never.
  """
  def visible?(%Page{publication_state: :published}, :public), do: PublicRouting.enabled?()
  def visible?(%Page{publication_state: :published}, _mode), do: true
  def visible?(%Page{publication_state: :draft}, :internal), do: true
  def visible?(%Page{}, _mode), do: false

  @doc """
  Resolves an exact page id — the basis of every internal link — in the
  reading mode `opts[:mode]` (`:public` by default).

  A missing id — or anything that is not an id — is `:missing`: no record
  found by a name or slug stands in for it. A merged page redirects to its survivor's canonical; a retired page is
  `:gone`.
  """
  def resolve_page(page_id, opts \\ []), do: resolve_page(page_id, true, mode!(opts))

  defp resolve_page(page_id, expand?, mode) do
    case follow(load_page(page_id), 0, MapSet.new()) do
      {:error, :missing} ->
        %Resolution{outcome: :missing}

      {:error, reason, page} ->
        %Resolution{outcome: :missing, page: page} |> corrupt(reason, %{}) |> report()

      {:ok, %Page{lifecycle_state: :retired, publication_state: state} = page, _, _hops}
      when state in [:published, :withdrawn] ->
        %Resolution{outcome: :gone, page: page}

      {:ok, %Page{lifecycle_state: :retired} = page, _, _hops} ->
        %Resolution{outcome: :unavailable, page: page}

      {:ok, page, canonical, hops} ->
        case canonical do
          nil -> unrouted(page)
          canonical -> decide(canonical, page, canonical, true, mode)
        end
        |> via_merge(hops)
        |> with_successors(expand?, mode)
        |> report()
    end
  end

  defp unrouted(%Page{publication_state: :published} = page),
    do:
      corrupt(%Resolution{outcome: :missing, page: page}, :published_page_without_canonical, %{})

  defp unrouted(%Page{} = page), do: %Resolution{outcome: :unavailable, page: page}

  # Reached through a merge: the reader asked for another page's id.
  defp via_merge(%Resolution{outcome: outcome} = resolution, hops)
       when hops > 0 and outcome in [:canonical, :choice],
       do: %{resolution | outcome: :redirect}

  defp via_merge(resolution, _hops), do: resolution

  # Each hop is one consistent read of a page and its canonical.
  defp follow(nil, _hops, _seen), do: {:error, :missing}

  defp follow({%Page{lifecycle_state: :merged} = page, _canonical}, hops, seen) do
    cond do
      MapSet.member?(seen, page.id) -> {:error, :merge_cycle, page}
      hops >= @max_merge_hops -> {:error, :merge_chain_too_long, page}
      true -> follow(load_page(page.merged_into_page_id), hops + 1, MapSet.put(seen, page.id))
    end
  end

  defp follow({%Page{} = page, canonical}, hops, _seen), do: {:ok, page, canonical, hops}

  @doc """
  The encoded canonical link for a page id, following merges, or `:error` for
  a page that is missing, retired, not visible in the reading mode
  (`opts[:mode]`, `:public` by default) or inconsistent.
  """
  def link(page_id, opts \\ []) do
    case resolve_page(page_id, opts) do
      %Resolution{outcome: outcome, location: location}
      when outcome in [:canonical, :redirect, :choice] ->
        {:ok, Address.encode(location)}

      _other ->
        :error
    end
  end

  # A choice names every successor the split recorded, in its order, each
  # resolved by id. None is chosen for the reader. Only one level is expanded:
  # a successor that is itself split is a choice the reader opens next, so
  # successors that name each other cannot loop.
  defp with_successors(%Resolution{outcome: :choice, page: page} = resolution, true, mode) do
    successors =
      case Pages.current_revision(page) do
        nil ->
          []

        revision ->
          revision.memberships
          |> Enum.filter(&(&1.relationship == :split_successor))
          |> Enum.map(
            &%{
              page_id: &1.target_page_id,
              resolution: resolve_page(&1.target_page_id, false, mode)
            }
          )
      end

    %{resolution | successors: successors}
  end

  defp with_successors(resolution, _expand?, _mode), do: resolution

  defp mode!(opts) do
    case Keyword.get(opts, :mode, :public) do
      mode when mode in @modes -> mode
      other -> raise ArgumentError, "unknown reading mode: #{inspect(other)}"
    end
  end

  defp report(%Resolution{outcome: :corrupt} = resolution) do
    Logger.error("routing: corrupt resolver state",
      reason: resolution.reason,
      diagnostics: inspect(resolution.diagnostics)
    )

    resolution
  end

  defp report(resolution), do: resolution

  @doc "Every stored path serving a page, for history views and diagnostics."
  def paths(page_id) when not is_id(page_id), do: []

  def paths(page_id) do
    Repo.all(from p in PublicPath, where: p.destination_page_id == ^page_id, order_by: p.id)
  end
end
