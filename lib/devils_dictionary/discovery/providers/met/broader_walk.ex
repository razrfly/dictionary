defmodule DevilsDictionary.Discovery.Providers.Met.BroaderWalk do
  @moduledoc """
  Whether a Met tag reaches a target's entity in at most two `P31`/`P279` steps.

  The Met's tag vocabulary is depictive, not conceptual: it says what a work
  *shows*. There is no *war* tag — there is *World War I*, *World War II*,
  *American Civil War*. The #99 P0 probe found zero exact tag matches for all
  ten of #86's meanings, so without this walk the Met serves concrete nouns and
  nothing else.

  Wikidata closes the gap in the direction it can be walked. Measured:

      Q361  World War I        → Q103495 world war → Q198 war   (2 steps)
      Q362  World War II       → Q198 war                       (1 step)
      Q8676 American Civil War → Q8465 civil war  → Q198 war     (2 steps)
      Q42937 Trojan War        → no path within two steps

  ## Why up and not down

  #102's D11 describes this as the mapping carrying "QIDs of entities that are
  P31/P279-**narrower**" than the sense's entity. That is the same relation read
  from the other end, and it is the end the bounded adapter cannot reach:
  `wbgetentities` answers "what is this an instance or subclass of", never "what
  are the instances of this". Enumerating everything narrower than *war* is a
  SPARQL query over an open set — 17 rows locally, tens of thousands on
  Wikidata — while walking up from the handful of tags a page actually returned
  is two batched requests with a fixed ceiling. Same edges, same two steps, same
  answer, bounded instead of open.

  The walk is cached in the run's request parameters, so paging through a
  target's results re-reads it rather than re-fetching it.
  """

  alias DevilsDictionary.Absorb.Clients.Wikidata

  @properties ~w(P31 P279)
  @max_steps 2
  @max_per_step 50

  @typedoc "QID → the QIDs it is an instance or subclass of."
  @type index :: %{optional(String.t()) => [String.t()]}

  @doc """
  Builds a matcher for the tag QIDs on `objects` against `targets`.

  Returns `{matcher, index}`. The matcher answers `{:ok, target_qid, via}` —
  `via` being the intermediate QIDs, empty for a one-step hop — or `:none`. The
  index is the edge cache to hand back on the next page.

  Nothing is fetched when every tag already matches a target exactly, which is
  the common case for a concrete noun.
  """
  @spec build([map()], [String.t()], index() | nil) :: {(String.t() -> term()), index()}
  def build(objects, targets, cached_index) do
    targets = MapSet.new(targets)
    index = normalize_index(cached_index)

    unresolved =
      objects
      |> Enum.flat_map(&tag_qids/1)
      |> Enum.uniq()
      |> Enum.reject(&MapSet.member?(targets, &1))

    index = expand(unresolved, index, targets, @max_steps)

    {fn qid -> path(qid, index, targets) end, index}
  end

  defp tag_qids(object) do
    DevilsDictionary.Discovery.Providers.Met.tags(object) |> Enum.map(&elem(&1, 1))
  end

  # One batched request per step, and only for QIDs whose parents are not
  # already cached. A step that resolves nothing new stops the walk early.
  defp expand(_qids, index, _targets, 0), do: index

  defp expand(qids, index, targets, steps) do
    missing = qids |> Enum.reject(&is_map_key(index, &1)) |> Enum.take(@max_per_step)

    index = if missing == [], do: index, else: Map.merge(index, fetch(missing))

    next =
      qids
      |> Enum.flat_map(&Map.get(index, &1, []))
      |> Enum.uniq()
      |> Enum.reject(&MapSet.member?(targets, &1))

    if next == [], do: index, else: expand(next, index, targets, steps - 1)
  end

  defp fetch(qids) do
    case Wikidata.fetch(qids) do
      {:ok, entities} ->
        # A QID the API does not know is absent from the answer; caching it as
        # a dead end is what stops the next page asking again.
        Map.new(qids, fn qid ->
          {qid, parents(Map.get(entities, qid))}
        end)

      {:error, _reason} ->
        %{}
    end
  end

  defp parents(nil), do: []

  defp parents(entity) do
    @properties
    |> Enum.flat_map(&Wikidata.entity_ids(entity, &1))
    |> Enum.uniq()
  end

  defp path(qid, index, targets) do
    parents = Map.get(index, qid, [])

    case Enum.find(parents, &MapSet.member?(targets, &1)) do
      nil -> two_step(parents, index, targets)
      target -> {:ok, target, []}
    end
  end

  defp two_step(parents, index, targets) do
    parents
    |> Enum.find_value(:none, fn parent ->
      case index |> Map.get(parent, []) |> Enum.find(&MapSet.member?(targets, &1)) do
        nil -> nil
        target -> {:ok, target, [parent]}
      end
    end)
  end

  defp normalize_index(index) when is_map(index) do
    Map.new(index, fn {qid, parents} -> {qid, List.wrap(parents)} end)
  end

  defp normalize_index(_index), do: %{}
end
