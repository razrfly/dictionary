defmodule DevilsDictionary.Repo.Migrations.DropLadderAssertionOwnership do
  use Ecto.Migration

  @moduledoc """
  The word ↔ thing ladder stops owning its links.

  Rungs 1–3 of `Absorb.Linker` registered each `refers_to` link in
  `source_assertion_outputs` under the Wiktionary or WordNet record they read,
  and `Materializer.reconcile/2` withdraws every output of a visited record
  that the run did not re-emit. A materialize run never emits a ladder link, so
  #183's WordNet re-materialization on 2026-09-24 withdrew all 24,196
  `wordnet_wikidata` and `wordnet_ili` links on the dev database. The rungs no
  longer write these rows; this removes the ones they already wrote, so the
  next Wiktionary re-materialization does not do the same to `wiktionary_qid`.

  Only rows, never claims: the record stays on each link as
  `metadata["source_record_id"]`, and a link already withdrawn stays withdrawn
  until the ladder re-runs over it. The key shape is the linker's own
  (`link|<method>|<subject>|<object>`); the materializer's links key on
  `link|<inspected lexeme>|…`, whose second segment is never a bare method name.
  """

  def up do
    execute("""
    DELETE FROM source_assertion_outputs
     WHERE output_key ~ '^link\\|(wiktionary_qid|wordnet_wikidata|wordnet_ili|title_match|disambiguation)\\|'
    """)
  end

  # Nothing to put back: the rows only ever made the links withdrawable.
  def down, do: :ok
end
