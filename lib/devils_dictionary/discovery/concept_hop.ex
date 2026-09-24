defmodule DevilsDictionary.Discovery.ConceptHop do
  @moduledoc """
  The concept hop (#172 build A): from a Wikidata item a sense refers to, a
  fixed, short list of properties followed at most two steps to an item with
  a page on another wiki — *coward* (Q104605901, "cowardly or fearful person",
  no Wikiquote page) *has characteristic* (`P1552`) *cowardice* (Q1401607),
  whose page is *Cowardice*.

  It extends the README's *one rule* the way the Met's walk does ("equal, or
  reached in ≤ 2 `P31`/`P279` steps"): the match is still a QID, reached by a
  relation Wikidata states and this module names, never a search by lemma.

  ## The rule is data (C3)

  `@properties` is the whole of it, in the order they are tried, each with the
  one phrase every reason renders it as (`wording/1`). Adding a property is
  one line here and a fixture. `rule/0` is what a recipe freezes, and
  `fingerprint/1` is how a changed rule becomes a changed recipe.

  ## Where it never lands

    * **From** — a hop starts only from an item the registry holds as a
      concept or an event (`origin?/1`): an individual — a person, a place, a
      work, an organisation — is not an instance of anything a theme page is
      about, and a taxon's broader item is `P171`, which is not on the list.
    * **Through or onto** — an item whose `P31` is a human, a fictional
      character or a creative-work class (`@refused`) is refused, as an end
      and as a step: the hop never lands on a person or a work.
    * **By `P31`** — only *from* an instance, an item with no `P279` of its
      own, only *onto* a class, an item that has one, and only as the last
      step. *Instance of* is a hop to a concept only when what it reaches is
      one: read off a class it names a metaclass, and walked on from the
      class it reached it leaves the word behind. The first live sample
      (2026-09-24, `docs/integrations/wikiquote.md`, *Concept hop*) walked
      *luthier* → *profession* → *Wage* and *witch doctor* → *occupation* →
      *Labor* before these two guards.
    * **Beyond two steps** — `@max_steps`. A third step is never fetched.

  ## Cost

  The walk reads nothing but the four properties' item ids and the site's
  sitelink (`WikidataClient.hop_nodes/3`). The first step's nodes come from
  the request the caller already made for the sitelinks, so a direct sitelink
  costs nothing extra; each step taken costs one `wbgetentities` for the items
  it reaches (`fetch`), and a step whose items all have pages ends the walk.
  """

  # The properties, tried in this order, and the phrase each reads as in a
  # reason: "the concept a sense of “coward” has as its characteristic".
  @properties [
    {"P1552", "has as its characteristic"},
    {"P279", "is a kind of"},
    {"P1269", "is a facet of"},
    {"P31", "is an instance of"}
  ]

  @max_steps 2

  # What the registry may hold a hop's first item as.
  @origin_kinds ~w(concept event)

  # `P31` values that make an item a person or a work, refused as a step and
  # as an end. Checked against the item's own `P31`, not walked: a subclass of
  # one of these that is not listed here is not caught, and the list grows by
  # a line when a fixture shows one.
  @refused MapSet.new(~w(
             Q5 Q15632617 Q95074
             Q17537576 Q838948 Q47461344 Q7725634 Q571 Q11424 Q5398426
             Q482994 Q7366 Q2188189 Q3305213 Q860861 Q25379 Q1004
           ))

  @typedoc "One step of a path: the property followed and the item it reached."
  @type step :: %{String.t() => String.t()}

  @typedoc """
  What `WikidataClient.hop_nodes/3` makes of an item: its sitelink title on
  the site, or nil, and its item ids under the hop's properties.
  """
  @type hop_node :: %{String.t() => String.t() | nil | %{String.t() => [String.t()]}}

  @typedoc "A reached page: the item, its title, and the path from the origin."
  @type hit :: %{String.t() => String.t() | [step()]}

  @doc "The properties the hop follows, in the order it tries them."
  def properties, do: Enum.map(@properties, &elem(&1, 0))

  @doc "The most steps a hop takes."
  def max_steps, do: @max_steps

  @doc """
  The properties a node must carry for the walk to judge it: the hop's own,
  and `P31` and `P279` for the guards, whatever a recipe's rule says.
  """
  def claim_properties, do: Enum.uniq(properties() ++ ~w(P31 P279))

  @doc "The rule a recipe freezes: `%{\"properties\" => [...], \"max_steps\" => 2}`."
  def rule, do: %{"properties" => properties(), "max_steps" => @max_steps}

  @doc """
  True for a rule this module can walk: known properties, in any subset and
  order, and at most `#{@max_steps}` steps.
  """
  def valid_rule?(%{"properties" => props, "max_steps" => steps})
      when is_list(props) and props != [] and is_integer(steps) and steps in 1..@max_steps//1,
      do: Enum.all?(props, &(&1 in properties())) and props == Enum.uniq(props)

  def valid_rule?(_rule), do: false

  @doc """
  A short digest of a rule, for a recipe's identity: another property, another
  order or another step count is another recipe. Nil for no rule.
  """
  def fingerprint(nil), do: nil

  def fingerprint(%{"properties" => props, "max_steps" => steps}) do
    "hop:#{Enum.join(props, ",")}:#{steps}"
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
    |> binary_part(0, 8)
  end

  @doc "The phrase a property reads as in a reason, or nil for one not on the list."
  def wording(property) do
    case List.keyfind(@properties, property, 0) do
      {^property, phrase} -> phrase
      nil -> nil
    end
  end

  @doc "Whether the registry's kind for an item lets a hop start from it."
  def origin?(kind) when is_atom(kind) and not is_nil(kind), do: origin?(Atom.to_string(kind))
  def origin?(kind), do: kind in @origin_kinds

  @doc "True when a node's `P31` names a person or a work."
  def refused?(%{"claims" => claims}),
    do: claims |> Map.get("P31", []) |> Enum.any?(&MapSet.member?(@refused, &1))

  def refused?(_node), do: false

  @doc "The properties along a path, in order: `[\"P1552\"]`."
  def reached(path), do: Enum.map(path, & &1["property"])

  @doc """
  Walks from `origins` — QIDs in preference order, each already judged a
  hoppable kind by the caller — to the nearest items with a page.

  `nodes` holds at least the origins' nodes (the caller's sitelinks answer).
  `fetch.(qids)` answers `{:ok, nodes}` for more of them, or anything else,
  which the walk returns unchanged: a deferral stays a deferral.

  Options:

    * `:rule` — the recipe's rule (default `rule/0`)
    * `:first` — stop at the first step that reaches any page (a provider's
      read); otherwise every origin walks to its own nearest page (a build's)
    * `:max_per_step` — the most items one step fetches (default: no limit;
      the caller's fetch batches)

  Returns `{:ok, %{origin => hit}}`, with no entry for an origin that reached
  nothing. A hit is `%{"qid", "title", "via"}`, `"via"` being the path:
  `[%{"property" => "P1552", "qid" => "Q1401607"}]`.
  """
  @spec reach([String.t()], %{String.t() => hop_node()}, function(), keyword()) ::
          {:ok, %{String.t() => hit()}} | term()
  def reach(origins, nodes, fetch, opts \\ []) do
    rule = opts[:rule] || rule()
    first? = Keyword.get(opts, :first, false)
    max_per_step = opts[:max_per_step]

    frontier =
      for origin <- Enum.uniq(origins),
          node = Map.get(nodes, origin),
          node != nil and not refused?(node),
          do: {origin, [], origin}

    walk(frontier, nodes, fetch, %{
      properties: rule["properties"],
      steps: rule["max_steps"],
      first?: first?,
      max_per_step: max_per_step,
      hits: %{}
    })
  end

  defp walk([], _nodes, _fetch, state), do: {:ok, state.hits}
  defp walk(_frontier, _nodes, _fetch, %{steps: 0} = state), do: {:ok, state.hits}

  defp walk(frontier, nodes, fetch, state) do
    candidates = candidates(frontier, nodes, state.properties)

    wanted =
      candidates
      |> Enum.map(&elem(&1, 2))
      |> Enum.uniq()
      |> Enum.reject(&Map.has_key?(nodes, &1))
      |> cap(state.max_per_step)

    with {:ok, nodes} <- fetch_nodes(wanted, nodes, fetch) do
      admitted =
        Enum.filter(candidates, fn {_origin, path, qid} ->
          admissible?(Map.get(nodes, qid), List.last(path)["property"])
        end)

      hits =
        Enum.reduce(admitted, state.hits, fn {origin, path, qid}, hits ->
          case nodes[qid]["title"] do
            title when is_binary(title) and not is_map_key(hits, origin) ->
              Map.put(hits, origin, %{"qid" => qid, "title" => title, "via" => path})

            _ ->
              hits
          end
        end)

      if state.first? and map_size(hits) > 0 do
        {:ok, hits}
      else
        # Instance-of ends a path: nothing is walked on from the class it
        # reached.
        next =
          Enum.reject(admitted, fn {origin, path, _qid} ->
            Map.has_key?(hits, origin) or List.last(path)["property"] == "P31"
          end)

        walk(next, nodes, fetch, %{state | hits: hits, steps: state.steps - 1})
      end
    end
  end

  # Every item one step from the frontier, origin by origin in order, property
  # by property in the rule's order, statement by statement. An item already
  # on an origin's own path is not a step back onto it.
  defp candidates(frontier, nodes, properties) do
    frontier
    |> Enum.flat_map(fn {origin, path, qid} ->
      claims = get_in(nodes, [qid, "claims"]) || %{}
      seen = MapSet.new([origin | Enum.map(path, & &1["qid"])])

      for property <- properties,
          property != "P31" or Map.get(claims, "P279", []) == [],
          next <- Map.get(claims, property, []),
          not MapSet.member?(seen, next),
          do: {origin, path ++ [%{"property" => property, "qid" => next}], next}
    end)
    |> Enum.uniq_by(fn {origin, _path, qid} -> {origin, qid} end)
  end

  defp cap(qids, nil), do: qids
  defp cap(qids, max) when is_integer(max), do: Enum.take(qids, max)

  defp fetch_nodes([], nodes, _fetch), do: {:ok, nodes}

  defp fetch_nodes(qids, nodes, fetch) do
    case fetch.(qids) do
      {:ok, fetched} when is_map(fetched) -> {:ok, Map.merge(nodes, fetched)}
      other -> other
    end
  end

  # An item the answer did not include (missing, deleted, or cut by the cap)
  # is no step. Nor is a person or a work. An instance-of step lands only on
  # a class.
  defp admissible?(nil, _property), do: false

  defp admissible?(node, property) do
    not refused?(node) and
      (property != "P31" or get_in(node, ["claims", "P279"]) not in [nil, []])
  end
end
