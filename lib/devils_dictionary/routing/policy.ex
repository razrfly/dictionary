defmodule DevilsDictionary.Routing.Policy do
  @moduledoc """
  Offline reference evaluator for ADR 0002. It proposes classifications, never
  writes assignments, allocates addresses, or grants publication permission.
  Inputs are explicit snapshot records, so provider changes cannot affect a read.
  """

  @root Path.expand("../../../priv/routing", __DIR__)

  def load(root \\ @root) do
    rules = root |> Path.join("classification-rules.json") |> File.read!() |> Jason.decode!()
    registry = root |> Path.join("namespaces.json") |> File.read!() |> Jason.decode!()
    terms = root |> Path.join("vocabulary-terms.json") |> File.read!() |> Jason.decode!()
    families = MapSet.new(registry["public_families"], & &1["key"])
    ids = Enum.map(rules["instance_rules"], & &1["id"])
    anchors = Enum.flat_map(rules["instance_rules"], & &1["instance_anchors"])
    term_ids = MapSet.new(terms, & &1["qid"])

    referenced =
      anchors ++
        rules["source_page_anchors"] ++
        Map.keys(rules["self_rules"]) ++ Map.keys(rules["class_anchors"])

    mapped_families =
      Enum.map(rules["instance_rules"], & &1["family"]) ++
        Map.values(rules["self_rules"]) ++ Map.values(rules["class_anchors"])

    precedence_ids = Enum.flat_map(rules["precedence"], &[&1["winner"] | &1["over"]])

    unless rules["version"] == registry["version"] and length(ids) == length(Enum.uniq(ids)) and
             length(anchors) == length(Enum.uniq(anchors)) and
             MapSet.size(families) == length(registry["public_families"]) and
             Enum.all?(registry["public_families"], &(&1["key"] == &1["prefix"])) and
             Enum.all?(referenced, &MapSet.member?(term_ids, &1)) and
             Enum.all?(terms, &(is_integer(&1["revision"]) and is_binary(&1["label"]))) and
             Enum.all?(precedence_ids, &(&1 in ids)) and
             Enum.all?(mapped_families, &MapSet.member?(families, &1)) do
      raise ArgumentError, "inconsistent routing policy"
    end

    %{rules: rules, registry: registry, terms: terms}
  end

  @doc "Rank-aware P31/P279 values; no arbitrary relation or second P31 hop."
  def values(record, property) when property in ["P31", "P279"] do
    record
    |> selected_claims(property)
    |> Enum.reject(&(map_size(&1["qualifiers"] || %{}) > 0))
    |> Enum.map(&get_in(&1, ["mainsnak", "datavalue", "value", "id"]))
    |> Enum.filter(&(is_binary(&1) and Regex.match?(~r/^Q\d+$/, &1)))
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp selected_claims(record, property) do
    claims = get_in(record, ["claims", property]) || []
    usable = Enum.reject(claims, &(&1["rank"] == "deprecated"))
    preferred = Enum.filter(usable, &(&1["rank"] == "preferred"))
    if preferred == [], do: usable, else: preferred
  end

  @doc "Classify a snapshot entity with a QID-keyed archive of class evidence."
  def classify(entity, graph, policy) do
    qids = entity["qids"] || []
    source = if length(qids) == 1, do: Map.get(graph, hd(qids))
    p31 = if source, do: values(source, "P31"), else: entity["instance_of"] || []
    p279 = if source, do: values(source, "P279"), else: entity["subclass_of"] || []
    anchors = instance_anchors(policy)
    walk = walk(p31, graph, anchors, policy.rules)
    class_walk = walk(p279, graph, class_anchors(policy), policy.rules)
    self_family = if length(qids) == 1, do: policy.rules["self_rules"][hd(qids)]

    matches =
      cond do
        self_family -> [%{id: "class_subject", family: self_family, path: qids}]
        true -> walk.matches ++ class_walk.matches ++ local_matches(entity, policy)
      end
      |> precedence(policy.rules["precedence"])
      |> Enum.uniq()
      |> Enum.sort_by(&{&1.id, &1.path})

    warnings = evidence_warnings(entity, source, p31, p279, qids)

    warnings =
      if self_family, do: warnings, else: warnings ++ walk.warnings ++ class_walk.warnings

    families = matches |> Enum.map(& &1.family) |> Enum.uniq() |> Enum.sort()
    source_page = Enum.any?(p31, &(&1 in policy.rules["source_page_anchors"]))

    {status, reasons} =
      cond do
        entity["lifecycle"] != "active" ->
          {"identity_review", ["identity_#{entity["lifecycle"]}"]}

        source_page ->
          {"excluded_source_page", ["source_page_is_not_named_subject"]}

        entity["disambiguation"] == true ->
          {"needs_review", ["disambiguation_flag_conflicts_with_types"]}

        length(families) > 1 ->
          {"needs_review", ["incompatible_families"]}

        families == [] ->
          {"needs_review", ["unmapped_subject"]}

        warnings != [] ->
          {"needs_review", ["incomplete_or_conflicting_evidence"]}

        true ->
          {"mapped", ["versioned_rule_match"]}
      end

    %{
      object_id: entity["object_id"],
      label: entity["label"],
      stored_kind: entity["entity_kind"],
      policy_version: policy.rules["version"],
      status: status,
      reasons: reasons,
      candidate_families: families,
      family: if(length(families) == 1, do: hd(families)),
      page_role: if(entity["entity_kind"] == "edition", do: "edition", else: "subject"),
      matches: matches,
      warnings: Enum.sort(Enum.uniq(warnings)),
      source_revision: source && Map.take(source, ["qid", "revision_id", "checksum"]),
      evidence: evidence_for(matches, graph),
      publishable: false,
      allocated: false
    }
  end

  @doc "Propose an NFC, case-normalized segment; never an identity or allocation."
  def slug(label) when is_binary(label) do
    candidate =
      label
      |> String.normalize(:nfc)
      |> String.downcase()
      |> String.replace("+", "-plus-")
      |> String.replace("#", "-sharp-")
      |> String.replace("&", "-and-")
      |> String.replace(".", "-dot-")
      |> String.replace(~r/['’]/u, "")
      |> String.replace(~r/[^\p{L}\p{M}\p{N}]+/u, "-")
      |> String.trim("-")
      |> String.normalize(:nfc)

    if candidate != "" and byte_size(candidate) <= 120, do: candidate
  end

  def slug(_), do: nil

  defp instance_anchors(policy) do
    Enum.reduce(policy.rules["instance_rules"], %{}, fn rule, acc ->
      Enum.reduce(rule["instance_anchors"], acc, fn qid, index ->
        Map.put(index, qid, %{id: rule["id"], family: rule["family"]})
      end)
    end)
  end

  defp class_anchors(policy) do
    Map.new(policy.rules["class_anchors"], fn {qid, family} ->
      {qid, %{id: "subclass_subject", family: family}}
    end)
  end

  defp walk(starts, graph, anchors, rules) do
    queue = starts |> Enum.sort() |> Enum.map(&{&1, [&1], 0})
    walk_queue(queue, graph, anchors, rules, %{matches: [], warnings: []}, 0)
  end

  defp walk_queue([], _graph, _anchors, _rules, result, _count), do: result

  defp walk_queue([{qid, path, depth} | rest], graph, anchors, rules, result, count) do
    cond do
      count >= rules["max_nodes"] ->
        %{result | warnings: ["graph_node_limit" | result.warnings]}

      rule = Map.get(anchors, qid) ->
        next = %{result | matches: [Map.put(rule, :path, path) | result.matches]}
        walk_queue(rest, graph, anchors, rules, next, count + 1)

      depth >= rules["max_depth"] ->
        next = %{result | warnings: ["graph_depth_limit:#{qid}" | result.warnings]}
        walk_queue(rest, graph, anchors, rules, next, count + 1)

      record = Map.get(graph, qid) ->
        parents = values(record, "P279")
        {cycles, parents} = Enum.split_with(parents, &(&1 in path))
        warnings = Enum.map(cycles, &"graph_cycle:#{&1}")

        warnings =
          warnings
          |> warn(qualified?(record, "P279"), "qualified_ancestry:#{qid}")
          |> warn(missing_pin?(record), "missing_ancestry_revision_pin:#{qid}")

        warnings =
          if parents == [] and cycles == [],
            do: ["unmapped_class:#{qid}" | warnings],
            else: warnings

        next = %{result | warnings: warnings ++ result.warnings}
        more = Enum.map(parents, &{&1, path ++ [&1], depth + 1})
        walk_queue(rest ++ more, graph, anchors, rules, next, count + 1)

      true ->
        next = %{result | warnings: ["missing_class:#{qid}" | result.warnings]}
        walk_queue(rest, graph, anchors, rules, next, count + 1)
    end
  end

  defp local_matches(entity, policy) do
    cond do
      entity["entity_kind"] == "edition" and is_integer(entity["edition_work_id"]) ->
        [%{id: "edition_details", family: "works", path: []}]

      entity["entity_kind"] == "work" and entity["work_kind"] in policy.rules["local_work_kinds"] ->
        [%{id: "work_details", family: "works", path: []}]

      true ->
        []
    end
  end

  defp precedence(matches, rules) do
    Enum.reduce(rules, matches, fn rule, current ->
      if Enum.any?(current, &(&1.id == rule["winner"])) do
        Enum.reject(current, &(&1.id in rule["over"]))
      else
        current
      end
    end)
  end

  defp evidence_warnings(entity, source, p31, p279, qids) do
    projection_p31 = entity["instance_of"] || []
    projection_p279 = entity["subclass_of"] || []

    []
    |> warn(length(qids) > 1, "multiple_verified_qids")
    |> warn(
      source == nil and (projection_p31 != [] or projection_p279 != []),
      "unversioned_type_projection"
    )
    |> warn(
      source != nil and (Enum.sort(projection_p31) != p31 or Enum.sort(projection_p279) != p279),
      "projection_differs_from_source"
    )
    |> warn(
      source != nil and missing_pin?(source),
      "missing_revision_pin"
    )
    |> warn(
      source != nil and (qualified?(source, "P31") or qualified?(source, "P279")),
      "qualified_type_statement"
    )
  end

  defp qualified?(record, property),
    do: Enum.any?(selected_claims(record, property), &(map_size(&1["qualifiers"] || %{}) > 0))

  defp missing_pin?(record), do: record["checksum"] == nil or record["revision_id"] == nil

  defp warn(warnings, true, reason), do: [reason | warnings]
  defp warn(warnings, false, _reason), do: warnings

  defp evidence_for(matches, graph) do
    matches
    |> Enum.flat_map(& &1.path)
    |> Enum.uniq()
    |> Enum.sort()
    |> Enum.flat_map(fn qid ->
      case Map.get(graph, qid) do
        nil -> []
        record -> [Map.take(record, ["qid", "revision_id", "checksum"])]
      end
    end)
  end
end
