defmodule DevilsDictionary.Routing.Links do
  @moduledoc """
  The one way the reader links a subject (#219 B2).

  A subject — an entity with a subject or edition page — is linked at its
  page's allocated address when the resolver serves that address in the
  reading mode, and otherwise at `/entities/:id/:slug`, the exact-identity
  route that needs no address. Nothing here derives a namespace from a stored
  kind or a label, and nothing rebuilds a routing slug: the address is the one
  the ledger holds, read through `Routing.Resolver`'s own decision.

  **On the published host, read publicly** (#237 D2, `Routing.PublicRouting`),
  there is no fallback: a subject with no served address is not linked at
  all, and the reader shows its label as text (`fallback/3`). The
  exact-identity route reads any entity, a draft subject's included, so a
  public visitor is never sent there, and there it answers 404 for an entity
  whose page is not served publicly, as that page's own address does
  (`withheld?/2`). Internal reading and every other server are unchanged.

  `path/3` answers one subject; `paths/2` answers many in one query, for a
  list that would otherwise ask once per link.
  """

  import Ecto.Query

  alias DevilsDictionary.Claims.Connection
  alias DevilsDictionary.Repo

  alias DevilsDictionary.Routing.{
    Address,
    Page,
    PublicPath,
    PublicRouting,
    Resolution,
    Resolver
  }

  @type mode :: :public | :internal

  @doc """
  The encoded path to link `object_id` in `mode`: its page's canonical when
  the resolver serves it in that mode, else `fallback/3` — the exact-identity
  route, or nil on the published host read publicly. `label` only makes that
  route's readable tail.
  """
  @spec path(integer(), String.t() | nil, mode()) :: String.t() | nil
  def path(object_id, label, mode \\ :public) do
    object_id |> List.wrap() |> addresses(mode) |> Map.get(object_id) ||
      fallback(object_id, label, mode)
  end

  @doc """
  `%{object_id => path}` for `{object_id, label}` pairs, in one query. A path
  is nil where `path/3`'s would be.
  """
  @spec paths([{integer(), String.t() | nil}], mode()) :: %{integer() => String.t() | nil}
  def paths(objects, mode \\ :public) do
    addressed = objects |> Enum.map(&elem(&1, 0)) |> addresses(mode)

    Map.new(objects, fn {object_id, label} ->
      {object_id, Map.get(addressed, object_id) || fallback(object_id, label, mode)}
    end)
  end

  @doc """
  Where a subject with no address served in `mode` is linked: the
  exact-identity route, or nil on the published host read publicly (#237
  D2), where that route would show a visitor what the subject's own address
  does not. Every reader link that falls back goes through here, never
  through `entity_path/2`, so a nil is rendered as the label in plain text.
  """
  @spec fallback(integer(), String.t() | nil, mode()) :: String.t() | nil
  def fallback(object_id, label, mode) do
    if published_public?(mode), do: nil, else: entity_path(object_id, label)
  end

  @doc """
  The exact-identity route for an entity, which every subject has whether or
  not it has an address. Only a builder: whether a reader links it is
  `fallback/3`'s question.
  """
  def entity_path(object_id, label), do: "/entities/#{object_id}/#{Connection.slugify(label)}"

  @doc """
  Whether the exact-identity route withholds `object_id` in `mode` (#237 D2):
  on the published host read publicly, an entity whose subject or edition
  page is not served there — a draft, a withdrawn page, any page while the
  launch switch is off — answers 404, as that page's own address does. The
  answer is `served/3`'s, the resolver's own. An entity with no such page, or
  whose page is served, is not withheld, and nothing is withheld in internal
  reading or on any other server.
  """
  @spec withheld?(integer(), mode()) :: boolean()
  def withheld?(object_id, mode) do
    published_public?(mode) and
      case pages([object_id]) do
        [] -> false
        rows -> Enum.all?(rows, fn {page, canonical} -> is_nil(served(page, canonical, mode)) end)
      end
  end

  defp published_public?(mode), do: mode == :public and PublicRouting.published_host?()

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

  defp addresses([], _mode), do: %{}

  defp addresses(object_ids, mode) do
    object_ids
    |> pages()
    |> Enum.flat_map(fn {page, canonical} ->
      case served(page, canonical, mode) do
        nil -> []
        path -> [{page.target_object_id, path}]
      end
    end)
    |> Map.new()
  end

  # Each object's subject or edition page (one per object and locale) with
  # its canonical, read together.
  defp pages(object_ids) do
    ids = Enum.filter(object_ids, &(is_integer(&1) and &1 > 0))

    from(p in Page,
      left_join: c in PublicPath,
      on: c.id == p.canonical_path_id,
      where: p.target_object_id in ^ids,
      where: p.role in [:subject, :edition] and p.locale == "en",
      select: {p, c}
    )
    |> Repo.all()
  end
end
