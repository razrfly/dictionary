defmodule DevilsDictionary.Discovery.Shelf do
  @moduledoc """
  How several sources become one shelf: the order across them and the
  duplicates between them (M2 and M3 of #116).

  K2 of #109 made a shelf a content type rather than a provider, and the
  *Artworks* shelf got two of the three rules a many-source shelf needs for
  free from identity — every item carried a QID or a Met object id, so the
  catalog could dedup on it and the order barely mattered. A shelf of
  photographs will not: a stock photo has no QID, the same Flickr image reaches
  a page through two aggregators under two ids, and two live providers with
  eight items each would paint as eight of one and then eight of the other.
  These are the two rules, written once, content-type-neutral, and computed at
  read time so no provider's persisted results are ever rewritten.

  ## Order — `interleave/3`

  Within each **group** (the reader's is the archetype: live before corpus,
  as K2 says), the shelf takes item 1 from every contributing source, then
  item 2, and so on. Sources are ordered by **tier** (aristocracy → middle →
  plebs) and then by slug; within a source, the order the source gave. That is
  the whole of the rule: no relevance ranking across sources (#101's), no
  trust weighting beyond `tier`.

  ## Duplicates — `dedup/2`

  One item per **identity** when the items carry one, and one item per
  **canonical media URL** otherwise, first wins. `keys/1` is what makes two
  shelf items the same thing:

    * the registry object they resolved to (`object_id`)
    * every `{namespace, external_id}` in `identifiers`, and the item's own
      `external_namespace`/`external_id`, so a provider that names another
      provider's namespace joins it
    * the canonical form of the full-size media URL (`image_url`, then
      `media_url`): host and path, lower-cased host, no scheme, no query, no
      trailing slash. Never the thumbnail, which is each provider's own
      derivative and never agrees across two of them.

  Perceptual-hash dedup is out of scope until a ledger shows it is needed.
  """

  @tiers %{aristocracy: 0, middle: 1, plebs: 2}

  @media_keys ~w(image_url media_url)

  @typedoc "Where a source sorts: aristocracy first, then middle, then plebs, then anything unnamed."
  @type tier_rank :: 0 | 1 | 2 | 3

  @doc "The sort rank of a source tier; an unnamed tier sorts after every named one."
  @spec tier_rank(atom() | nil) :: tier_rank()
  def tier_rank(tier), do: Map.get(@tiers, tier, 3)

  @doc """
  Sorts by group, drops duplicates in that order, then round-robins the
  sources within each group.

  This is the composition the reader uses: the sort puts the better-tiered
  source's copy of a duplicate first, so it is the copy that survives, and the
  interleave then takes turns among what is left.
  """
  def compose(items, group_fun, source_fun, keys_fun)
      when is_function(group_fun, 1) and is_function(source_fun, 1) and
             is_function(keys_fun, 1) do
    items
    |> Enum.sort_by(&{group_fun.(&1), source_fun.(&1)})
    |> dedup(keys_fun)
    |> interleave(group_fun, source_fun)
  end

  @doc """
  Round-robin across sources within each group.

  `group_fun` returns something groups sort by (the reader's is the archetype
  rank); `source_fun` returns something sources sort by (the reader's is
  `{tier_rank, slug}`). Groups are emitted in ascending order, sources within
  a group take turns in ascending order, and items within a source keep the
  order they arrived in. `Enum.sort_by/2` is stable, so nothing here reorders
  a source's own ranking.
  """
  def interleave(items, group_fun, source_fun)
      when is_function(group_fun, 1) and is_function(source_fun, 1) do
    items
    |> Enum.group_by(group_fun)
    |> Enum.sort_by(fn {group, _members} -> group end)
    |> Enum.flat_map(fn {_group, members} -> round_robin(members, source_fun) end)
  end

  defp round_robin(items, source_fun) do
    items
    |> Enum.group_by(source_fun)
    |> Enum.sort_by(fn {source, _run} -> source end)
    |> Enum.map(fn {_source, run} -> run end)
    |> take_turns([])
  end

  defp take_turns([], acc), do: Enum.reverse(acc)

  defp take_turns(runs, acc) do
    {heads, tails} = runs |> Enum.map(fn [head | tail] -> {head, tail} end) |> Enum.unzip()
    take_turns(Enum.reject(tails, &(&1 == [])), Enum.reverse(heads, acc))
  end

  @doc """
  One item per identity, first wins.

  `keys_fun` returns the list of keys under which an item is the same as
  another; an item sharing any key with one already kept is dropped, and its
  keys join the kept item's, so a third item that shares only the dropped one's
  other key collapses too. An item with no keys at all is always kept.
  """
  def dedup(items, keys_fun \\ &keys/1) when is_function(keys_fun, 1) do
    {kept, _seen} =
      Enum.reduce(items, {[], MapSet.new()}, fn item, {kept, seen} ->
        keys = keys_fun.(item)
        duplicate? = Enum.any?(keys, &MapSet.member?(seen, &1))
        seen = Enum.into(keys, seen)

        if duplicate?, do: {kept, seen}, else: {[item | kept], seen}
      end)

    Enum.reverse(kept)
  end

  @doc """
  The keys under which a shelf item is the same thing as another.

  Read from a live `DevilsDictionary.Discovery.Result`, a transient provider
  item or a catalog item alike: all three carry `preview_metadata` and an
  `external_namespace`/`external_id`, a resolved one carries `object_id`, and
  a persisted one carries the `identifiers` its provider proposed.
  """
  def keys(item) when is_map(item) do
    object_key(Map.get(item, :object_id)) ++
      identifier_keys(item) ++
      media_key(Map.get(item, :preview_metadata))
  end

  defp object_key(object_id) when is_integer(object_id), do: [{:object, object_id}]
  defp object_key(_object_id), do: []

  defp identifier_keys(item) do
    own =
      case {Map.get(item, :external_namespace), Map.get(item, :external_id)} do
        {namespace, id} when is_binary(namespace) and is_binary(id) -> [{namespace, id}]
        _ -> []
      end

    proposed =
      item
      |> Map.get(:identifiers)
      |> List.wrap()
      |> Enum.flat_map(fn
        %{namespace: namespace, external_id: id} when is_binary(namespace) and is_binary(id) ->
          [{namespace, id}]

        %{"namespace" => namespace, "external_id" => id}
        when is_binary(namespace) and is_binary(id) ->
          [{namespace, id}]

        _identifier ->
          []
      end)

    Enum.map(own ++ proposed, fn {namespace, id} -> {:identifier, namespace, id} end)
  end

  defp media_key(metadata) when is_map(metadata) do
    case Enum.find_value(@media_keys, &canonical_media_url(metadata[&1])) do
      nil -> []
      url -> [{:media, url}]
    end
  end

  defp media_key(_metadata), do: []

  @doc """
  The canonical form of a media URL: lower-cased host and path, no scheme,
  no port, no query string, no fragment, no trailing slash. `nil` for anything
  that is not an absolute URL with a host.

  Two sizes of one Unsplash photo differ only in their query string, and
  `http` and `https` name the same file; neither difference is a second
  picture.
  """
  def canonical_media_url(url) when is_binary(url) do
    case URI.parse(String.trim(url)) do
      %URI{host: host, path: path} when is_binary(host) and host != "" ->
        String.downcase(host) <> String.trim_trailing(path || "", "/")

      _uri ->
        nil
    end
  end

  def canonical_media_url(_url), do: nil
end
