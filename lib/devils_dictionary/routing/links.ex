defmodule DevilsDictionary.Routing.Links do
  @moduledoc """
  The one way the reader links a subject (#219 B2).

  A subject — an entity with a subject or edition page — is linked at its
  page's allocated address when the resolver serves that address in the
  reading mode, and otherwise at `/entities/:id/:slug`, the exact-identity
  route that needs no address. Nothing here derives a namespace from a stored
  kind or a label, and nothing rebuilds a routing slug: the address is the one
  the ledger holds, read through `Routing.Resolver`'s own decision.

  `path/3` answers one subject; `paths/2` answers many in one query, for a
  list that would otherwise ask once per link.
  """

  import Ecto.Query

  alias DevilsDictionary.Claims.Connection
  alias DevilsDictionary.Repo
  alias DevilsDictionary.Routing.{Address, Page, PublicPath, Resolution, Resolver}

  @doc """
  The encoded path to link `object_id` in `mode`: its page's canonical when
  the resolver serves it in that mode, else the exact-identity route.
  `label` only makes that route's readable tail.
  """
  def path(object_id, label, mode \\ :public) do
    object_id |> List.wrap() |> addresses(mode) |> Map.get(object_id) ||
      entity_path(object_id, label)
  end

  @doc """
  `%{object_id => path}` for `{object_id, label}` pairs, in one query.
  """
  def paths(objects, mode \\ :public) do
    addressed = objects |> Enum.map(&elem(&1, 0)) |> addresses(mode)

    Map.new(objects, fn {object_id, label} ->
      {object_id, Map.get(addressed, object_id) || entity_path(object_id, label)}
    end)
  end

  @doc """
  The exact-identity route for an entity, which every subject has whether or
  not it has an address.
  """
  def entity_path(object_id, label), do: "/entities/#{object_id}/#{Connection.slugify(label)}"

  @doc """
  The address a page with its canonical row is served at in `mode`, or nil.
  Pure for an active page, so a caller that read the rows already — the
  Subjects section's one query — asks nothing more; a merged or split page is
  resolved by id, following the ledger.
  """
  def served(%Page{lifecycle_state: :active} = page, %PublicPath{} = canonical, mode) do
    case Resolver.decide(canonical, page, canonical, true, mode) do
      %Resolution{outcome: :canonical, location: location} -> Address.encode(location)
      _other -> nil
    end
  end

  def served(%Page{lifecycle_state: state} = page, _canonical, mode)
      when state in [:merged, :split] do
    case Resolver.link(page.id, mode: mode) do
      {:ok, path} -> path
      :error -> nil
    end
  end

  def served(_page, _canonical, _mode), do: nil

  # Each object's subject or edition page (one per object and locale) with
  # its canonical, read together.
  defp addresses([], _mode), do: %{}

  defp addresses(object_ids, mode) do
    ids = Enum.filter(object_ids, &(is_integer(&1) and &1 > 0))

    from(p in Page,
      left_join: c in PublicPath,
      on: c.id == p.canonical_path_id,
      where: p.target_object_id in ^ids,
      where: p.role in [:subject, :edition] and p.locale == "en",
      select: {p, c}
    )
    |> Repo.all()
    |> Enum.flat_map(fn {page, canonical} ->
      case served(page, canonical, mode) do
        nil -> []
        path -> [{page.target_object_id, path}]
      end
    end)
    |> Map.new()
  end
end
