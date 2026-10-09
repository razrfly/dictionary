# Extracts, byte for byte, the lines of a policy export that the population's
# evaluation reads: the attestation, the lexical count, every population
# entity, and every class-evidence record its classification depends on
# (Policy.classify/3's dependencies and source lookups). Verifies that every
# population entity classifies identically on the subset and on the whole.
#
#   mix run --no-start extract_subset.exs EXPORT POPULATION OUT
alias DevilsDictionary.Routing.{AuditSnapshot, Classifications, Policy}

[input, population_path, out] = System.argv()
{:ok, snap} = AuditSnapshot.read(input)
population = population_path |> File.read!() |> Jason.decode!()
ids = MapSet.new(population["records"], & &1["object_id"])
policy = Policy.load()
entities = Enum.filter(snap.entities, &MapSet.member?(ids, &1["object_id"]))
true = length(entities) == MapSet.size(ids)

qids =
  Enum.reduce(entities, MapSet.new(), fn e, acc ->
    r = Policy.classify(e, snap.graph, policy)

    acc
    |> MapSet.union(MapSet.new(r.dependencies, & &1["qid"]))
    |> MapSet.union(MapSet.new(e["qids"] || []))
  end)

sub_graph = Map.take(snap.graph, MapSet.to_list(qids))

mismatch =
  for e <- entities,
      a = Policy.classify(e, snap.graph, policy),
      b = Policy.classify(e, sub_graph, policy),
      a != b or Classifications.fingerprint(a) != Classifications.fingerprint(b),
      do: e["object_id"]

IO.puts(
  "entities #{length(entities)}, graph records #{map_size(sub_graph)} of #{map_size(snap.graph)}, mismatches #{inspect(mismatch)}"
)

[] = mismatch

keep = fn line ->
  case Jason.decode!(line) do
    %{"record_type" => t} when t in ["snapshot", "lexical_population"] -> true
    %{"record_type" => "entity", "object_id" => id} -> MapSet.member?(ids, id)
    %{"record_type" => "class_evidence", "qid" => q} -> Map.has_key?(sub_graph, q)
  end
end

lines =
  input
  |> File.read!()
  |> String.split("\n", trim: true)
  |> Enum.filter(keep)

File.write!(out, Enum.map(lines, &[&1, "\n"]))
{:ok, check} = AuditSnapshot.read(out)

IO.puts(
  "subset lines #{length(lines)}, entities #{length(check.entities)}, graph #{map_size(check.graph)}, sha256 #{check.sha256}, input sha256 #{snap.sha256}"
)
