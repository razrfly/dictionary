defmodule DevilsDictionary.Absorb.DropLadderAssertionOwnershipTest do
  @moduledoc """
  The #188 migration against rows of both kinds.

  Before #188 the ladder's identifier rungs registered each link as an output
  of the record they read, keyed `link|<method>|<subject>|<object>`. The
  materializer owns claims too — its relations as `rel|…`, its own links as
  `link|<inspected lexeme>|…` — and `reconcile/2` depends on those rows. The
  migration has to remove the first kind and leave every row of the second.

  Driven through `Ecto.Migrator.up/4` under a throwaway version, inside the
  sandbox, so the real migration module runs its real SQL and the version row
  rolls back with the test.
  """
  use DevilsDictionary.DataCase, async: false

  alias DevilsDictionary.{Claims, Fixtures, Registry, Repo}
  alias DevilsDictionary.WordFixtures

  @migration "priv/repo/migrations/20260924222346_drop_ladder_assertion_ownership.exs"

  setup do
    %{sources: sources} = Fixtures.seed_catalog!()
    %{sources: sources}
  end

  defp owned!(record, assertion_id, key) do
    now = DateTime.utc_now()

    Repo.insert_all("source_assertion_outputs", [
      %{
        source_record_id: record.id,
        output_key: key,
        assertion_id: assertion_id,
        inserted_at: now,
        updated_at: now
      }
    ])
  end

  defp keys do
    Repo.all(from o in "source_assertion_outputs", select: o.output_key) |> MapSet.new()
  end

  test "removes the ladder's ownership rows and keeps the materializer's", ctx do
    record = WordFixtures.record!(ctx, "wordnet")

    {:ok, lexeme} =
      Registry.create_lexeme(%{language_tag: "en", lemma: "owned", part_of_speech: "noun"})

    {:ok, entity} = Registry.create_entity(%{entity_kind: :concept, preferred_label: "Owned"})
    {:ok, claim} = Claims.assert(lexeme.object_id, "lexeme_entity_candidate", entity.object_id)

    ladder =
      for method <- ~w(wiktionary_qid wordnet_wikidata wordnet_ili title_match disambiguation),
          do: "link|#{method}|#{lexeme.object_id}|#{entity.object_id}"

    genuine = [
      ~s(link|"owned"|| Q1|source),
      ~s(link|{"en", "owned", "noun"}|owned#1|Q1|wikidata),
      "link|nil|owned#1|Q1|source",
      "rel|wordnet|owned#1|hypernym|thing",
      "assertion:#{claim.id}",
      # A method name as a prefix of a longer segment is not a ladder key.
      "link|wordnet_wikidata_extra|1|2"
    ]

    for key <- ladder ++ genuine, do: owned!(record, claim.id, key)

    [{module, _}] = Code.require_file(@migration)

    :ok =
      Ecto.Migrator.up(Repo, 99_990_000_000_188, module,
        log: false,
        migration_lock: false
      )

    assert keys() == MapSet.new(genuine)
    # Rows only: the claim itself is untouched.
    assert Claims.current_revision(claim.id).lifecycle_state == :active
  end
end
