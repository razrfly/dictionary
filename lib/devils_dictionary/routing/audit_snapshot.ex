defmodule DevilsDictionary.Routing.AuditSnapshot do
  @moduledoc """
  The read-only policy export that `mix dd.routing.audit` evaluates and the
  Stage 2 backfill (`Routing.Backfill`) is bound to
  (`docs/audits/2026-09-26-issue194/policy-export.sql`).

  One JSONL file: a `snapshot` attestation taken in a read-only transaction,
  every Wikidata `class_evidence` record, every `entity` with its evaluator
  input, and the `lexical_population` count. `read/1` refuses a file with a
  duplicate identity, an unknown record type, or no read-only attestation, so
  the evaluator never sees an ambiguous input.
  """

  alias DevilsDictionary.Routing.Policy

  @policy_files ~w(namespaces.json classification-rules.json vocabulary-terms.json)

  @doc """
  `{:ok, %{info:, graph:, entities:, lexical:, sha256:}}` for the export at
  `path`, with entities in object-id order, or `{:error, message}`.
  """
  def read(path) do
    case File.read(path) do
      {:ok, bytes} ->
        bytes
        |> String.split("\n", trim: true)
        |> Enum.with_index(1)
        |> Enum.reduce_while({:ok, empty()}, fn {line, number}, {:ok, state} ->
          with {:ok, row} <- decode(line, number),
               {:ok, state} <- add(row, state) do
            {:cont, {:ok, state}}
          else
            {:error, _message} = error -> {:halt, error}
          end
        end)
        |> complete(bytes)

      {:error, reason} ->
        {:error, "cannot read #{path}: #{:file.format_error(reason)}"}
    end
  end

  defp empty, do: %{graph: %{}, entities: [], info: nil, lexical: nil}

  # A truncated export (an interrupted psql) or a line that is not a JSON
  # object is a refusal, never a crash.
  defp decode(line, number) do
    case Jason.decode(line) do
      {:ok, %{} = row} -> {:ok, row}
      {:ok, _other} -> {:error, "snapshot line #{number} is not a JSON object"}
      {:error, _} -> {:error, "snapshot line #{number} is not valid JSON"}
    end
  end

  defp add(%{"record_type" => "snapshot"} = row, %{info: nil} = state),
    do: {:ok, %{state | info: row}}

  defp add(%{"record_type" => "snapshot"}, _state), do: {:error, "duplicate snapshot attestation"}

  defp add(%{"record_type" => "lexical_population"} = row, %{lexical: nil} = state),
    do: {:ok, %{state | lexical: row}}

  defp add(%{"record_type" => "lexical_population"}, _state),
    do: {:error, "duplicate lexical population"}

  defp add(%{"record_type" => "class_evidence", "qid" => qid} = row, state) do
    if Map.has_key?(state.graph, qid),
      do: {:error, "duplicate class evidence identity"},
      else: {:ok, %{state | graph: Map.put(state.graph, qid, row)}}
  end

  defp add(%{"record_type" => "entity"} = row, state),
    do: {:ok, %{state | entities: [row | state.entities]}}

  defp add(row, _state),
    do: {:error, "unknown snapshot record type: #{inspect(row["record_type"])}"}

  defp complete({:error, _message} = error, _bytes), do: error

  defp complete({:ok, snapshot}, bytes) do
    entities = Enum.sort_by(snapshot.entities, & &1["object_id"])
    ids = Enum.map(entities, & &1["object_id"])

    cond do
      !(snapshot.info && snapshot.info["read_only"] == "on" && snapshot.lexical &&
          is_integer(snapshot.lexical["count"]) && entities != []) ->
        {:error, "incomplete or non-read-only snapshot"}

      length(ids) != length(Enum.uniq(ids)) ->
        {:error, "duplicate entity identity in input"}

      true ->
        {:ok, snapshot |> Map.put(:entities, entities) |> Map.put(:sha256, digest(bytes))}
    end
  end

  @doc "The proposed path for an evaluator result, or nil. A proposal, never an address."
  def candidate_path(%{status: status, family: family, label: label})
      when status in ["mapped", "needs_review"] and is_binary(family) do
    case Policy.slug(label) do
      nil -> nil
      slug -> "/#{family}/#{slug}"
    end
  end

  def candidate_path(_result), do: nil

  @doc "The SHA-256 of the routing policy files: the digest every audit and backfill records."
  def policy_digest do
    @policy_files
    |> Enum.map(&File.read!(Path.join(Policy.root(), &1)))
    |> IO.iodata_to_binary()
    |> digest()
  end

  @doc "A lowercase hex SHA-256."
  def digest(bytes), do: :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)
end
