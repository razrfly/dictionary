defmodule DevilsDictionary.Health.StateFingerprint do
  @moduledoc "Exact same-database replay comparison, excluding only bookkeeping timestamps and run stamps."
  alias DevilsDictionary.Repo

  @tables ~w(objects lexemes senses sense_revisions entities person_details work_details edition_details
    content_items content_revisions lexeme_forms object_names external_identifiers
    assertions assertion_revisions assertion_evidence assertion_reviews assertion_votes
    review_contexts review_context_items source_materialized_outputs source_assertion_outputs)

  def capture(tables \\ @tables) do
    unless Enum.all?(tables, &(&1 in @tables)),
      do: raise(ArgumentError, "unknown fingerprint table")

    Repo.transaction(
      fn ->
        unless Repo.config()[:pool] == Ecto.Adapters.SQL.Sandbox do
          Repo.query!("SET TRANSACTION ISOLATION LEVEL REPEATABLE READ")
        end

        Map.new(tables, fn table ->
          # Bucketed sorted hashes preserve multiplicity without aggregating the whole corpus into one string.
          sql = """
          WITH hashes AS (
            SELECT encode(sha256(convert_to((to_jsonb(t) - ARRAY[
              'inserted_at','updated_at','last_seen_run_id','import_run_id'
            ])::text, 'UTF8')), 'hex') AS h FROM #{table} t
          )
          SELECT left(h, 2), count(*), encode(sha256(convert_to(string_agg(h, '' ORDER BY h), 'UTF8')), 'hex')
            FROM hashes GROUP BY left(h, 2) ORDER BY left(h, 2)
          """

          rows = Repo.query!(sql, [], timeout: :infinity).rows

          {table,
           %{
             "rows" => Enum.reduce(rows, 0, fn [_, n, _], acc -> acc + n end),
             "sha256" => Base.encode16(:crypto.hash(:sha256, Jason.encode!(rows)), case: :lower)
           }}
        end)
      end,
      timeout: :infinity
    )
    |> case do
      {:ok, state} -> state
      {:error, error} -> raise "fingerprint failed: #{inspect(error)}"
    end
  end
end
