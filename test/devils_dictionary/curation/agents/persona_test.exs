defmodule DevilsDictionary.Curation.Agents.PersonaTest do
  use DevilsDictionary.DataCase, async: false

  import DevilsDictionary.CurationFixtures
  import DevilsDictionary.ProposalFixtures
  import DevilsDictionary.RefreshFixtures
  import DevilsDictionary.RuntimeFixtures

  alias DevilsDictionary.Curation.{
    Compositions,
    Configurations,
    Profiles,
    Proposal,
    Proposals,
    Receipt
  }

  alias DevilsDictionary.Curation.Agents.Persona
  alias DevilsDictionary.Curation.Runtime.{Attempt, Packet}

  defp config! do
    model_config!(%{instruction_version: Persona.instruction_version(), tag: "9b"}) |> ready!()
  end

  defp persona_world! do
    world = love_world!()
    config = config!()
    {:ok, seed} = Persona.prepare(world.reviewer, config, reason: "test sourced lens")

    {:ok, profile} =
      Profiles.admit(world.reviewer, seed.profile.id, seed.version.id,
        reason: "reviewed sources and deceased evidence",
        bot_actor_id: seed.bot_actor.id
      )

    {:ok, version} =
      Configurations.create_version(world.reviewer, world.configuration.id, %{
        reason: "test persona binding",
        refresh_window: 86_400,
        editor: %{
          profile_id: profile.id,
          profile_version_id: seed.version.id,
          model_config_id: config.id
        }
      })

    {:ok, _} =
      Configurations.activate(world.reviewer, world.configuration.id, version.id,
        reason: "test only",
        idempotency_key: key(),
        expected: world.configuration_version.id
      )

    world =
      Map.merge(world, %{
        model_config: config,
        profile: profile,
        profile_version: seed.version,
        bot: seed.bot_actor,
        configuration_version: version,
        editor_version: version,
        configuration: Repo.reload!(world.configuration),
        runtime: bind!(service_key: key(), actor_id: seed.bot_actor.id)
      })

    composition = provision!(world)
    world = Map.put(world, :composition, composition)
    world = Map.put(world, :published, publish!(world, composition))
    enable!(world)
    world
  end

  test "prepare is idempotent, reviewer-only, sourced, unadmitted and does not activate or call a model" do
    world = love_world!()
    config = config!()
    assert {:error, :unauthorized} = Persona.prepare(world.author, config, reason: "no")
    before = Repo.reload!(world.configuration)
    assert {:ok, first} = Persona.prepare(world.reviewer, config, reason: "import")
    assert {:ok, again} = Persona.prepare(world.reviewer, config, reason: "again")
    assert first.version.id == again.version.id
    assert first.bot_actor.id == again.bot_actor.id
    assert first.profile.state == :proposed
    assert first.source.active == false
    assert first.version.source_refs != [] and first.version.deceased_evidence_refs != []
    assert Persona.valid_version?(first.profile, first.version)
    assert Repo.reload!(world.configuration) == before
    assert Repo.aggregate(Attempt, :count) == 0
    assert byte_size(Persona.selection_instruction()) < 1800
    assert Packet.instruction!(Persona.instruction_version()) =~ Persona.selection_instruction()
  end

  test "mismatched model and changed dossier cannot bind; old versions remain unchanged" do
    world = persona_world!()
    wrong = model_config!(%{instruction_version: "generic-editor-v2"})

    attrs = %{
      reason: "mismatch",
      editor: %{
        profile_id: world.profile.id,
        profile_version_id: world.profile_version.id,
        model_config_id: wrong.id
      }
    }

    assert {:error, :editor_profile_mismatch} =
             Configurations.create_version(world.reviewer, world.configuration.id, attrs)

    old = world.profile_version

    assert {:ok, changed} =
             Profiles.add_version(world.reviewer, world.profile.id, %{
               reason: "new dossier",
               template_version: old.template_version,
               dossier: Map.put(old.dossier, "selection", "a changed lens"),
               source_refs: old.source_refs,
               deceased_evidence_refs: old.deceased_evidence_refs
             })

    assert Repo.reload!(old) == old
    refute Persona.valid_version?(world.profile, changed)

    assert {:ok, _} =
             Profiles.admit(world.reviewer, world.profile.id, changed.id,
               reason: "test admission",
               bot_actor_id: world.bot.id
             )

    assert {:error, :editor_not_admitted} = Configurations.editor(world.editor_version)
    attrs = put_in(attrs.editor.profile_version_id, changed.id)
    attrs = put_in(attrs.editor.model_config_id, world.model_config.id)

    assert {:error, :editor_profile_mismatch} =
             Configurations.create_version(world.reviewer, world.configuration.id, attrs)
  end

  test "real proposal path receives the persona instruction, retains ancestry, and only owner Take publishes" do
    world = persona_world!()

    {:ok, packet} =
      Packet.for_page(page("love"), instruction_version: Persona.instruction_version())

    {:ok, frozen} = Packet.freeze(packet)
    content = answer_for(frozen, world.bierce.object_id, [world.johnson.object_id])
    parent = Repo.reload!(world.composition).current_published_version_id
    test = self()

    stub_ollama!(world.model_config,
      chat: fn request ->
        send(test, {:messages, request["messages"]})
        {:json, answer(content)}
      end
    )

    assert {:ok, %{last_outcome: :proposed}} = run!(world)
    assert_received {:messages, messages}
    assert hd(messages)["content"] =~ Persona.selection_instruction()
    assert Repo.reload!(world.composition).current_published_version_id == parent
    proposal = Repo.one!(Proposal)
    assert proposal.profile_id == world.profile.id
    assert proposal.profile_version_id == world.profile_version.id
    assert proposal.model_config_id == world.model_config.id
    offered = Compositions.items(proposal.version_id)

    assert {:ok, %{version: version}} =
             Proposals.take(world.reviewer, proposal.id,
               reason: "test reviewer accepts",
               expected_pointer: parent,
               answers: all_yes(offered)
             )

    assert version.parent_version_id == proposal.version_id
    assert Repo.reload!(world.composition).current_published_version_id == version.id
    settle!()
    # The shared receipt resolves the original model choice through Take ancestry.
    assert {:ok, receipt} = Receipt.read("love", version.version)

    assert Enum.any?(receipt.items, fn item ->
             item.chooser.model_config_id == world.model_config.id and
               item.chooser.profile["profile_version_id"] == world.profile_version.id
           end)
  end

  test "persona abstention records an assessment without publishing or fabricating a proposal" do
    world = persona_world!()
    parent = Repo.reload!(world.composition).current_published_version_id
    stub_answer!(world, abstain())
    assert {:ok, %{last_outcome: :abstained}} = run!(world)
    assert Repo.aggregate(Proposal, :count) == 0
    assert Repo.reload!(world.composition).current_published_version_id == parent
    assert Repo.aggregate(Attempt, :count) == 1
  end
end
