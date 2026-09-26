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

  Nothing in the router calls this yet; reader integration is Stage 3.
  """

  import Ecto.Query
  import DevilsDictionary.Routing.Id, only: [is_id: 1]

  require Logger

  alias DevilsDictionary.Repo
  alias DevilsDictionary.Routing.{Address, Page, Pages, PublicPath, Resolution}

  @max_merge_hops 64

  @doc """
  Resolves a raw request path, as received (percent-encoded).

  An equivalent spelling of a reserved path — case, Unicode form, a trailing
  slash — resolves to the same page and is answered with a redirect to the
  canonical, never a second 200.
  """
  def resolve(raw) do
    case Address.normalize_request(raw) do
      {:ok, normalized, exact?} ->
        case load(normalized) do
          nil ->
            %Resolution{outcome: :missing, request: raw}

          {path, page, canonical} ->
            path
            |> decide(page, canonical, exact?)
            |> Map.put(:request, raw)
            |> with_successors(true)
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
  The decision, given the loaded rows. Pure, so every state — including ones
  the database refuses to store — can be examined.
  """
  def decide(%PublicPath{} = path, %Page{} = page, canonical, exact?) do
    base = %Resolution{outcome: :missing, path: path, page: page}

    cond do
      page.lifecycle_state == :merged ->
        corrupt(base, :path_on_merged_page, %{})

      # Gone is only news for a page the public has seen.
      path.kind == :tombstone and page.publication_state in [:published, :withdrawn] ->
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

      page.publication_state != :published ->
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
  Resolves an exact page id — the basis of every internal link.

  A missing id — or anything that is not an id — is `:missing`: no record
  found by a name or slug stands in for it. A merged page redirects to its survivor's canonical; a retired page is
  `:gone`.
  """
  def resolve_page(page_id), do: resolve_page(page_id, true)

  defp resolve_page(page_id, expand?) do
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
          canonical -> decide(canonical, page, canonical, true)
        end
        |> via_merge(hops)
        |> with_successors(expand?)
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
  a page that is missing, retired, unpublished or inconsistent.
  """
  def link(page_id) do
    case resolve_page(page_id) do
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
  defp with_successors(%Resolution{outcome: :choice, page: page} = resolution, true) do
    successors =
      case Pages.current_revision(page) do
        nil ->
          []

        revision ->
          revision.memberships
          |> Enum.filter(&(&1.relationship == :split_successor))
          |> Enum.map(
            &%{page_id: &1.target_page_id, resolution: resolve_page(&1.target_page_id, false)}
          )
      end

    %{resolution | successors: successors}
  end

  defp with_successors(resolution, _expand?), do: resolution

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
