defmodule Mix.Tasks.Dd.Routing.Audit do
  @moduledoc """
  Evaluate ADR 0002 against an offline, read-only database export.

      mix dd.routing.audit --input /tmp/routing-input.jsonl --output /tmp/routing-audit

  Writes a complete JSONL manifest and a summary. Starts no application,
  database connection, background job, or provider request. Every address is
  a proposal; no output grants publication or reserves a path.

  Generate the input using docs/audits/2026-09-26-issue194/policy-export.sql.
  """
  use Mix.Task

  alias DevilsDictionary.Routing.Policy

  @shortdoc "Read-only offline classification and proposed-path audit"
  @requirements ["compile"]

  @impl true
  def run(args) do
    {opts, extra, invalid} = OptionParser.parse(args, strict: [input: :string, output: :string])

    unless (extra == [] and invalid == [] and opts[:input]) && opts[:output] do
      Mix.raise("usage: mix dd.routing.audit --input snapshot.jsonl --output directory")
    end

    policy = Policy.load()
    snapshot = read_snapshot(opts[:input])
    entities = Enum.sort_by(snapshot.entities, & &1["object_id"])
    results = Enum.map(entities, &Policy.classify(&1, snapshot.graph, policy))
    results = Enum.map(results, &Map.put(&1, :candidate_path, candidate_path(&1)))

    collisions =
      results
      |> Enum.reject(&is_nil(&1.candidate_path))
      |> Enum.group_by(& &1.candidate_path)
      |> Enum.filter(fn {_path, rows} -> length(rows) > 1 end)
      |> Map.new()

    results =
      Enum.map(results, fn result ->
        address_status =
          cond do
            result.candidate_path == nil -> "not_proposed"
            Map.has_key?(collisions, result.candidate_path) -> "collision_review"
            result.status != "mapped" -> "classification_review"
            true -> "candidate"
          end

        Map.put(result, :address_status, address_status)
      end)

    ids = Enum.map(results, & &1.object_id)

    if length(ids) != MapSet.size(MapSet.new(ids)),
      do: Mix.raise("duplicate entity identity in input")

    summary = %{
      policy_version: policy.rules["version"],
      policy_sha256: policy_digest(),
      input_sha256: digest(File.read!(opts[:input])),
      snapshot: snapshot.info,
      entities: length(results),
      lexical_population: snapshot.lexical,
      class_evidence_records: map_size(snapshot.graph),
      classification_status: Enum.frequencies_by(results, & &1.status),
      address_status: Enum.frequencies_by(results, & &1.address_status),
      candidate_families:
        results |> Enum.reject(&is_nil(&1.family)) |> Enum.frequencies_by(& &1.family),
      collision_groups: map_size(collisions),
      colliding_entities: collisions |> Map.values() |> Enum.map(&length/1) |> Enum.sum(),
      warning_counts:
        results
        |> Enum.flat_map(& &1.warnings)
        |> Enum.map(&(String.split(&1, ":") |> hd()))
        |> Enum.frequencies(),
      publication_approved: 0,
      allocated_paths: 0,
      limits: [
        "Mapped is a policy result, not verified publication readiness.",
        "Unknown or incomplete graph branches require review.",
        "Current subject metadata and archived evidence can disagree.",
        "Lexical routes are retained; lexical population is counted, not reallocated.",
        "Candidate paths are not persisted addresses; collisions remain explicit."
      ]
    }

    File.mkdir_p!(opts[:output])

    File.write!(
      Path.join(opts[:output], "assignments.jsonl"),
      Enum.map(results, &[Jason.encode!(ordered_json(&1)), "\n"])
    )

    File.write!(
      Path.join(opts[:output], "summary.json"),
      Jason.encode!(ordered_json(summary), pretty: true) <> "\n"
    )

    Mix.shell().info(Jason.encode!(summary, pretty: true))
  end

  defp read_snapshot(path) do
    snapshot =
      File.stream!(path)
      |> Stream.map(&Jason.decode!/1)
      |> Enum.reduce(%{graph: %{}, entities: [], info: nil, lexical: nil}, fn row, state ->
        case row["record_type"] do
          "snapshot" ->
            if state.info, do: Mix.raise("duplicate snapshot attestation")
            %{state | info: row}

          "lexical_population" ->
            if state.lexical, do: Mix.raise("duplicate lexical population")
            %{state | lexical: row}

          "class_evidence" ->
            if Map.has_key?(state.graph, row["qid"]),
              do: Mix.raise("duplicate class evidence identity")

            %{state | graph: Map.put(state.graph, row["qid"], row)}

          "entity" ->
            %{state | entities: [row | state.entities]}

          other ->
            Mix.raise("unknown snapshot record type: #{inspect(other)}")
        end
      end)

    unless snapshot.info && snapshot.info["read_only"] == "on" && snapshot.lexical &&
             is_integer(snapshot.lexical["count"]) && snapshot.entities != [] do
      Mix.raise("incomplete or non-read-only snapshot")
    end

    snapshot
  end

  defp candidate_path(%{status: status, family: family, label: label})
       when status in ["mapped", "needs_review"] and is_binary(family) do
    case Policy.slug(label) do
      nil -> nil
      slug -> "/#{family}/#{slug}"
    end
  end

  defp candidate_path(_), do: nil

  # Map iteration order can differ between BEAM runs. Preserve byte-identical
  # audit manifests by sorting every JSON object's keys, including evidence.
  defp ordered_json(value) when is_map(value) do
    value
    |> Enum.map(fn {key, item} -> {to_string(key), ordered_json(item)} end)
    |> Enum.sort_by(&elem(&1, 0))
    |> Jason.OrderedObject.new()
  end

  defp ordered_json(value) when is_list(value), do: Enum.map(value, &ordered_json/1)
  defp ordered_json(value), do: value

  defp policy_digest do
    ~w(namespaces.json classification-rules.json vocabulary-terms.json)
    |> Enum.map(&File.read!(Path.join("priv/routing", &1)))
    |> IO.iodata_to_binary()
    |> digest()
  end

  defp digest(bytes), do: :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)
end
