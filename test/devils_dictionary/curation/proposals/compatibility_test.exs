defmodule DevilsDictionary.Curation.Proposals.CompatibilityTest do
  @moduledoc """
  #264 §8 test 35 (R19): the migration is additive. On the migrated schema,
  every row the code before #264 writes is accepted exactly as before (its
  schemas select only their own columns, and its writers set none of the new
  ones), and the migration's `down` refuses once a model row exists.
  """
  use DevilsDictionary.DataCase, async: false

  import DevilsDictionary.CurationFixtures
  import DevilsDictionary.ProposalFixtures
  import DevilsDictionary.RefreshFixtures

  alias DevilsDictionary.Curation.{Profiles, Published, Refresh}

  @migration 20_261_027_175_309

  # The columns the code before #264 knew, by table: what its schemas
  # select and its writers write.
  @old_columns %{
    "editorial_composition_versions" =>
      ~w(id composition_id curation_configuration_id configuration_version_id version
         parent_version_id origin change_reason created_by_actor_id scope_signature
         scope_members resolution lead_policy arrangement_hash eligibility_fingerprint inserted_at),
    "editorial_composition_items" =>
      ~w(id composition_version_id role position item_kind item_object_id content_revision_id
         sense_revision_id source_record_revision_id catalog_manifest catalog_checksum
         catalog_identity locator words_sha256 meaning_sense_revision_id meaning_lexeme_id
         assertion_revision_id selection_origin note note_author_kind note_author_label
         note_author_actor_id required_references inserted_at)
  }

  test "the old writers write exactly as before on the migrated schema" do
    world = love_world!()

    # Provision, a manual version with human notes, a review, a publish, a
    # withdrawal and a re-publish: P1, P2 and P5's writers, unchanged.
    composition = provision!(world)
    %{version: v1} = publish!(world, composition)
    settle!()
    assert {:ok, _shown} = Published.current(composition.id)

    for item <- DevilsDictionary.Curation.Compositions.items(v1.id) do
      assert item.selection_origin == :manual
      assert is_nil(item.copied_from_item_id)
      assert item.note_author_kind in [nil, :human]
    end

    assert v1.origin == :manual and is_nil(v1.attempt_id)
    withdraw!(world, composition)
    Refresh.reopen(composition.id)

    publish!(world, composition, nil,
      highlights: [world.johnson |> content_spec(world.love) |> Map.put(:note, %{text: "J."})]
    )

    settle!()

    # A P5 check completes with an outcome the old CHECK allowed.
    visit!()
    drain!()
    assert row!(composition).last_outcome in [:unchanged, :needs_editor]

    # A persona admitted from a sourced version, as before.
    [persona | _] = Profiles.seed_proposed!()

    {:ok, version} =
      Profiles.add_version(world.reviewer, persona.id, %{
        source_refs: [%{"url" => "https://example.test/source"}],
        deceased_evidence_refs: [%{"url" => "https://example.test/evidence"}],
        template_version: "generic-editor-v2",
        reason: "fixture persona"
      })

    bot = bot_actor!(Repo.get_by!(DevilsDictionary.Sources.Source, slug: "wiktionary"))

    assert {:ok, %{state: :admitted, kind: :persona}} =
             Profiles.admit(world.reviewer, persona.id, version.id,
               reason: "fixture",
               bot_actor_id: bot.id
             )

    settle!()

    # A row written with only the old columns, as the old code's insert
    # would write it, is accepted.
    v = DevilsDictionary.Curation.Compositions.latest_version(composition.id)
    columns = @old_columns["editorial_composition_versions"] -- ["id", "inserted_at"]

    row =
      v
      |> Map.from_struct()
      |> Map.take(Enum.map(columns, &String.to_existing_atom/1))
      |> Map.merge(%{
        version: v.version + 1,
        parent_version_id: v.id,
        origin: "manual",
        lead_policy: "bierce_first_v1",
        change_reason: "an old writer's row",
        arrangement_hash: DevilsDictionary.Curation.Digest.arrangement_hash([]),
        eligibility_fingerprint: "old-#{System.unique_integer([:positive])}",
        inserted_at: DateTime.utc_now()
      })

    assert :accepted = refused(fn -> Repo.insert_all("editorial_composition_versions", [row]) end)
  end

  test "down refuses once a model row exists" do
    module = DevilsDictionary.Repo.Migrations.CreateCurationProposals

    # Loaded already when `mix test` migrated in this VM; else from its file.
    unless Code.ensure_loaded?(module),
      do: Code.require_file("priv/repo/migrations/#{@migration}_create_curation_proposals.exs")

    # With no model row, the guard lets a rollback through.
    assert %Postgrex.Result{} = Repo.query!(apply(module, :down_guard, []))

    world = editor_world!()
    stub_answer!(world, answer_for(frozen!(), world.bierce.object_id, [world.johnson.object_id]))
    {:ok, %{last_outcome: :proposed}} = run!(world)

    assert_raise Postgrex.Error, ~r/cannot be rolled back/, fn ->
      Repo.transaction(fn -> Repo.query!(apply(module, :down_guard, [])) end)
    end
  end
end
