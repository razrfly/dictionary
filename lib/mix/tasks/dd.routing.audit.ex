defmodule Mix.Tasks.Dd.Routing.Audit do
  @moduledoc """
  Evaluate ADR 0004 against an offline, read-only database export.

      mix dd.routing.audit --input /tmp/routing-input.jsonl --output /tmp/routing-audit

  Writes a complete JSONL manifest and a summary. Starts no application,
  database connection, background job, or provider request. Every address is
  a proposal; no output grants publication or reserves a path.

  Generate the input using docs/audits/2026-09-26-issue194/policy-export.sql.
  """
  use Mix.Task

  alias DevilsDictionary.Routing.{AuditSnapshot, Policy}

  @shortdoc "Read-only offline classification and proposed-path audit"
  @requirements ["compile"]

  @impl true
  def run(args) do
    {opts, extra, invalid} = OptionParser.parse(args, strict: [input: :string, output: :string])

    unless (extra == [] and invalid == [] and opts[:input]) && opts[:output] do
      Mix.raise("usage: mix dd.routing.audit --input snapshot.jsonl --output directory")
    end

    policy = Policy.load()

    snapshot =
      case AuditSnapshot.read(opts[:input]) do
        {:ok, snapshot} -> snapshot
        {:error, message} -> Mix.raise(message)
      end

    results = Enum.map(snapshot.entities, &Policy.classify(&1, snapshot.graph, policy))
    results = Enum.map(results, &Map.put(&1, :candidate_path, AuditSnapshot.candidate_path(&1)))

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

    summary = %{
      policy_version: policy.rules["version"],
      policy_sha256: AuditSnapshot.policy_digest(),
      input_sha256: snapshot.sha256,
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
end
