defmodule Mix.Tasks.Dd.Links.Reinstate do
  @shortdoc "Reinstates withdrawn claims whose rationale matches a phrase"

  @moduledoc """
  Reverses a bulk withdrawal by adding a new active revision to each claim.

      mix dd.links.reinstate --predicate refers_to --rationale-match "issue #82"
      mix dd.links.reinstate --predicate refers_to --rationale-match "issue #82" --apply \\
        --rationale "Reinstated for discovery association under issue #102"

  Without `--apply` this prints counts and changes nothing, which is the only
  way to see what a phrase actually selects before 14,116 claims move.

  Every reinstatement goes through `DevilsDictionary.Claims.reinstate/2`, so
  each one is a new revision carrying its own rationale and the withdrawal stays
  in the history exactly as it was. Nothing here edits a revision in place.

  ## Why this task exists

  #82 bounded an out-of-scope QID exception to people and withdrew every
  `refers_to` link that fell outside it. Those links are the encyclopedia's own
  statement that *war* means Q198, and #102's D11 makes them the Met's match
  key: without them the Met can match nothing at all for a common noun. D12
  reinstates them for that reason, and the reason is recorded on every revision
  so this is reversible by withdrawing again with the same tool's counterpart.
  """

  use Mix.Task

  import Ecto.Query

  alias DevilsDictionary.Claims
  alias DevilsDictionary.Claims.{AssertionRevision, Predicate}
  alias DevilsDictionary.Repo

  @switches [
    predicate: :string,
    rationale_match: :string,
    rationale: :string,
    apply: :boolean,
    limit: :integer
  ]

  @default_rationale "Reinstated for discovery association under issue #102"

  @impl Mix.Task
  def run(args) do
    Mix.Task.run("app.start")

    {opts, rest, invalid} = OptionParser.parse(args, strict: @switches)

    predicate = opts[:predicate]
    match = opts[:rationale_match]

    if rest != [] or invalid != [] or blank?(predicate) or blank?(match) do
      Mix.raise(
        "invalid arguments; --predicate and --rationale-match are required " <>
          "(run `mix help dd.links.reinstate`)"
      )
    end

    predicate_id = predicate_id!(predicate)
    query = candidates(predicate_id, match)

    report(predicate, match, query)

    if opts[:apply] do
      apply_reinstatement(query, opts[:rationale] || @default_rationale, opts[:limit])
    else
      Mix.shell().info("\nDry run. Nothing changed. Re-run with --apply to reinstate.")
    end
  end

  @doc """
  The withdrawn, current revisions of `predicate` whose rationale contains `match`.

  Exposed so a test can assert on the same selection the task acts on rather
  than on a re-derived one.
  """
  def candidates(predicate_id, match) do
    pattern = "%" <> match <> "%"

    from r in AssertionRevision,
      where:
        r.predicate_id == ^predicate_id and r.is_current and
          r.lifecycle_state == :withdrawn and like(r.rationale, ^pattern)
  end

  defp predicate_id!(key) do
    case Repo.one(from p in Predicate, where: p.key == ^key, select: p.id) do
      nil -> Mix.raise("no predicate named #{inspect(key)}")
      id -> id
    end
  end

  defp report(predicate, match, query) do
    total = Repo.aggregate(query, :count, :id)

    by_method =
      Repo.all(
        from r in query,
          group_by: r.method,
          order_by: [desc: count(r.id)],
          select: {r.method, count(r.id)}
      )

    Mix.shell().info("predicate:      #{predicate}")
    Mix.shell().info("rationale like: #{match}")
    Mix.shell().info("withdrawn, current, matching: #{total}")
    Mix.shell().info("\nby method:")

    for {method, count} <- by_method do
      Mix.shell().info("  #{String.pad_trailing(to_string(method || "(none)"), 20)} #{count}")
    end
  end

  # One `reinstate/2` per claim, each its own transaction. Slower than a bulk
  # update by a wide margin, and the only version of this that leaves an
  # auditable revision behind for every claim it moves.
  defp apply_reinstatement(query, rationale, limit) do
    ids =
      query
      |> maybe_limit(limit)
      |> select([r], r.assertion_id)
      |> Repo.all()

    Mix.shell().info("\nReinstating #{length(ids)} claims with rationale: #{rationale}")

    {reinstated, failed} =
      ids
      |> Enum.with_index(1)
      |> Enum.reduce({0, []}, fn {assertion_id, index}, {ok, errors} ->
        if rem(index, 1_000) == 0, do: Mix.shell().info("  #{index}/#{length(ids)}…")

        case Claims.reinstate(assertion_id, reason: rationale) do
          {:ok, _revision} -> {ok + 1, errors}
          {:error, reason} -> {ok, [{assertion_id, reason} | errors]}
        end
      end)

    Mix.shell().info("reinstated: #{reinstated}")
    Mix.shell().info("failed:     #{length(failed)}")

    for {assertion_id, reason} <- Enum.take(failed, 10) do
      Mix.shell().error("  #{assertion_id}: #{inspect(reason)}")
    end

    if failed != [], do: Mix.raise("#{length(failed)} claims could not be reinstated")
  end

  defp maybe_limit(query, nil), do: query
  defp maybe_limit(query, limit) when is_integer(limit) and limit > 0, do: limit(query, ^limit)

  defp maybe_limit(_query, limit),
    do: Mix.raise("--limit must be a positive integer, got #{limit}")

  defp blank?(value), do: is_nil(value) or String.trim(value) == ""
end
