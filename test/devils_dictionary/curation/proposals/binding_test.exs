defmodule DevilsDictionary.Curation.Proposals.BindingTest do
  @moduledoc """
  #264 §8 tests 1–5: binding, activation and enablement are three acts
  (R1), and the generic editor's identity and narrow admission (R2).
  """
  use DevilsDictionary.DataCase, async: false

  import DevilsDictionary.CurationFixtures
  import DevilsDictionary.ProposalFixtures
  import DevilsDictionary.RefreshFixtures
  import DevilsDictionary.RuntimeFixtures

  alias DevilsDictionary.Curation.{
    Configuration,
    ConfigurationVersion,
    Configurations,
    Profile,
    Profiles,
    Proposal,
    Published
  }

  alias DevilsDictionary.Curation.Runtime.Attempt

  defp seeded!(world, config) do
    {:ok, seed} = Profiles.seed_generic_editor(world.reviewer, config, reason: "seed")
    seed
  end

  defp admitted!(world, seed) do
    {:ok, profile} =
      Profiles.admit(world.reviewer, seed.profile.id, seed.version.id,
        reason: "admit",
        bot_actor_id: seed.bot_actor.id
      )

    profile
  end

  defp v2_config!(slug \\ nil) do
    model_config!(%{
      instruction_version: "generic-editor-v2",
      slug: slug || "qwen3.5-9b-v2-#{System.unique_integer([:positive])}",
      tag: "9b"
    })
  end

  defp bind(world, attrs),
    do:
      Configurations.create_version(world.reviewer, world.configuration.id, %{
        reason: "bind",
        editor: attrs
      })

  describe "test 1 (R1.1): the binding" do
    test "writes the resolved binding into a new immutable version, and refuses what does not stand" do
      world = love_world!()
      v1 = Repo.reload!(world.configuration_version)
      config = v2_config!()
      seed = seeded!(world, config)

      # Not admitted yet.
      assert {:error, :editor_not_admitted} =
               bind(world, %{
                 profile_id: seed.profile.id,
                 profile_version_id: seed.version.id,
                 model_config_id: config.id
               })

      profile = admitted!(world, seed)

      # A persona is not the generic editor.
      [persona | _] = Profiles.seed_proposed!()

      assert {:error, :editor_not_admitted} =
               bind(world, %{
                 profile_id: persona.id,
                 profile_version_id: seed.version.id,
                 model_config_id: config.id
               })

      assert {:error, :model_config_unknown} =
               bind(world, %{
                 profile_id: profile.id,
                 profile_version_id: seed.version.id,
                 model_config_id: 0
               })

      # The bot is labelled for its own config; another config's label differs.
      other = v2_config!()

      assert {:error, :editor_label_mismatch} =
               bind(world, %{
                 profile_id: profile.id,
                 profile_version_id: seed.version.id,
                 model_config_id: other.id
               })

      assert {:ok, %ConfigurationVersion{} = v2} =
               bind(world, %{
                 profile_id: profile.id,
                 profile_version_id: seed.version.id,
                 model_config_id: config.id
               })

      settle!()

      assert v2.manifest["mode"] == "manual"

      assert v2.manifest["editor"] == %{
               "profile_id" => profile.id,
               "profile_version_id" => seed.version.id,
               "bot_actor_id" => seed.bot_actor.id,
               "model_config_id" => config.id,
               "model_config_hash" => config.config_hash,
               "instruction_version" => "generic-editor-v2"
             }

      assert seed.bot_actor.label == "generic-editor-v2 · #{config.slug}"
      assert v2.manifest_hash != v1.manifest_hash
      assert Repo.reload!(v1).manifest == v1.manifest
      refute Map.has_key?(v1.manifest, "editor")
    end
  end

  describe "test 2 (R1.2): ready?/1" do
    test "accepts an editor manifest, refuses a malformed one, and asks the database nothing" do
      world = love_world!()
      editor = editor!(world)
      version = Repo.reload!(editor.editor_version)
      manual = Repo.reload!(world.configuration_version)

      malformed = [
        Map.put(version.manifest["editor"], "extra", 1),
        Map.delete(version.manifest["editor"], "model_config_hash"),
        Map.put(version.manifest["editor"], "profile_id", "1"),
        "an editor"
      ]

      ref = make_ref()
      test = self()

      :telemetry.attach(
        {__MODULE__, ref},
        [:devils_dictionary, :repo, :query],
        fn _event, _measure, _meta, _config -> send(test, {:query, ref}) end,
        nil
      )

      try do
        assert Configurations.ready?(version)
        assert Configurations.ready?(manual)

        for editor <- malformed do
          refute Configurations.ready?(%{
                   version
                   | manifest: Map.put(version.manifest, "editor", editor)
                 })
        end

        refute Configurations.ready?(%{
                 version
                 | manifest: Map.put(version.manifest, "mode", "panel")
               })

        refute_received {:query, ^ref}
      after
        :telemetry.detach({__MODULE__, ref})
      end

      # The editor's version resolves as the default, and current/1 answers it.
      assert {:ok, %{version: %{id: id}}} = Configurations.resolve_default()
      assert id == version.id
      assert {:ok, _c, %{id: ^id}} = Configurations.current(world.configuration.id)
    end

    test "a manual manifest resolves as before" do
      world = love_world!()
      assert {:ok, %{version: v}} = Configurations.resolve_default()
      assert v.id == world.configuration_version.id
      assert Configurations.editor(v) == :none
    end
  end

  describe "test 3 (R1.4): activation" do
    test "withholds a version published under the previous one until one is published under it" do
      world = love_world!()
      composition = provision!(world)
      %{version: v1} = publish!(world, composition)
      assert {:ok, _shown} = Published.current(composition.id)

      editor!(world)
      settle!()

      assert Published.current(composition.id) == {:withheld, [:configuration_changed]}

      world = Map.put(world, :configuration, Repo.reload!(world.configuration))
      # The same arrangement under the new configuration version is a new
      # version, re-published by the owner (OD-3).
      publish!(world, composition, v1.id)
      settle!()

      assert {:ok, _shown} = Published.current(composition.id)
    end

    test "obsoletes the pending proposals of another configuration version" do
      world = editor_world!()

      stub_answer!(
        world,
        answer_for(frozen!(), world.bierce.object_id, [world.johnson.object_id])
      )

      {:ok, _row} = run!(world)
      assert %Proposal{state: :pending} = proposal = Repo.one!(Proposal)

      {:ok, manual} =
        Configurations.create_version(world.reviewer, world.configuration.id, %{
          reason: "a manual version",
          max_highlights: 2
        })

      {:ok, _} =
        Configurations.activate(world.reviewer, world.configuration.id, manual.id,
          reason: "back to manual",
          idempotency_key: key("activate"),
          expected: world.editor_version.id
        )

      settle!()

      assert %Proposal{state: :obsolete, resolution_reason: "configuration_changed"} =
               Repo.reload!(proposal)

      assert is_nil(Repo.reload!(proposal).resolved_by_actor_id)
    end
  end

  describe "test 4 (R1.5): enablement" do
    test "is a reviewer's act, needs a binding and the current version, and an activation turns it off" do
      world = editor_world!(%{}, enable: false)
      configuration = Repo.reload!(world.configuration)

      assert {:error, :unauthorized} =
               Configurations.enable_editor(world.author, configuration.id,
                 reason: "x",
                 expected: configuration.current_version_id
               )

      assert {:error, {:required, :reason}} =
               Configurations.enable_editor(world.reviewer, configuration.id,
                 reason: " ",
                 expected: configuration.current_version_id
               )

      assert {:error, {:stale, _current}} =
               Configurations.enable_editor(world.reviewer, configuration.id,
                 reason: "x",
                 expected: world.configuration_version.id - 1
               )

      # The database checks the switch itself: a person who is no reviewer,
      # no reason, or a version that is not current.
      contributor = actor!(world.author)
      reviewer = actor!(world.reviewer)

      for set <- [
            [
              editor_enabled_version_id: configuration.current_version_id,
              editor_switched_by_actor_id: contributor.id,
              editor_switched_at: DateTime.utc_now(),
              editor_switch_reason: "x"
            ],
            [
              editor_enabled_version_id: configuration.current_version_id,
              editor_switched_by_actor_id: reviewer.id,
              editor_switched_at: DateTime.utc_now(),
              editor_switch_reason: nil
            ],
            [
              editor_enabled_version_id: world.editor_version.id - 1,
              editor_switched_by_actor_id: reviewer.id,
              editor_switched_at: DateTime.utc_now(),
              editor_switch_reason: "x"
            ]
          ] do
        assert {:refused, _code, _message} =
                 refused(fn ->
                   Repo.update_all(from(c in Configuration, where: c.id == ^configuration.id),
                     set: set
                   )
                 end)
      end

      assert {:ok, enabled} =
               Configurations.enable_editor(world.reviewer, configuration.id,
                 reason: "window",
                 expected: configuration.current_version_id
               )

      settle!()
      assert enabled.editor_enabled_version_id == configuration.current_version_id
      assert {:ok, _editor} = Configurations.editor_enabled(configuration.current_version_id)

      assert {:error, :already_enabled} =
               Configurations.enable_editor(world.reviewer, configuration.id,
                 reason: "again",
                 expected: configuration.current_version_id
               )

      # A new activation leaves the switch where it was: off for the new version.
      {:ok, manual} =
        Configurations.create_version(world.reviewer, configuration.id, %{
          reason: "manual",
          max_highlights: 2
        })

      {:ok, _} =
        Configurations.activate(world.reviewer, configuration.id, manual.id,
          reason: "manual",
          idempotency_key: key("activate"),
          expected: configuration.current_version_id
        )

      settle!()
      assert Configurations.editor_enabled(manual.id) == :off
      assert Repo.reload!(configuration).editor_enabled_version_id == world.editor_version.id

      # Enabling a version without a binding is refused.
      assert {:error, :no_editor_binding} =
               Configurations.enable_editor(world.reviewer, configuration.id,
                 reason: "x",
                 expected: manual.id
               )

      assert {:ok, disabled} =
               Configurations.disable_editor(world.reviewer, configuration.id, reason: "end")

      assert is_nil(disabled.editor_enabled_version_id)

      assert {:error, :editor_not_enabled} =
               Configurations.disable_editor(world.reviewer, configuration.id, reason: "end")
    end

    test "while disabled, a needs-editor check completes as P5's does and calls nothing" do
      world = editor_world!(%{}, enable: false)
      stub_answer!(world, abstain())

      assert {:ok, row} = run!(world)
      assert {row.last_outcome, row.last_outcome_reason} == {:needs_editor, "requested"}
      refute_received :chat_called
      assert Repo.aggregate(Attempt, :count) == 0
      assert Repo.aggregate(Proposal, :count) == 0
    end
  end

  describe "test 5 (R2): the generic editor's identity" do
    test "is admitted from an empty version, and from nothing else; personas keep their rule" do
      world = love_world!()
      config = v2_config!()
      seed = seeded!(world, config)

      assert seed.profile.kind == :generic_editor
      assert seed.source.kind == :bot and seed.source.active == false
      assert seed.version.dossier == %{} and seed.version.source_refs == []

      # A version with a dossier is not the editor's.
      {:ok, dossier} =
        Profiles.add_version(world.reviewer, seed.profile.id, %{
          dossier: %{"voice" => "fixture"},
          template_version: "generic-editor-v2",
          reason: "a dossier"
        })

      assert {:error, :not_an_empty_editor_version} =
               Profiles.admit(world.reviewer, seed.profile.id, dossier.id,
                 reason: "x",
                 bot_actor_id: seed.bot_actor.id
               )

      reviewer = actor!(world.reviewer)

      admitted = fn profile_id, version_id, bot_id ->
        refused(fn ->
          Repo.update_all(from(p in Profile, where: p.id == ^profile_id),
            set: [
              state: :admitted,
              current_version_id: version_id,
              bot_actor_id: bot_id,
              admitted_by_actor_id: reviewer.id,
              admitted_at: DateTime.utc_now(),
              admission_reason: "direct"
            ]
          )
        end)
      end

      assert {:refused, _, _} = admitted.(seed.profile.id, dossier.id, seed.bot_actor.id)

      # A persona with empty references is still refused, in code and by the database.
      [persona | _] = Profiles.seed_proposed!()

      {:ok, empty} =
        Profiles.add_version(world.reviewer, persona.id, %{
          template_version: "generic-editor-v2",
          reason: "empty persona"
        })

      bot = bot_actor!(Repo.get_by!(DevilsDictionary.Sources.Source, slug: "wiktionary"))

      assert {:error, :sources_missing} =
               Profiles.admit(world.reviewer, persona.id, empty.id,
                 reason: "x",
                 bot_actor_id: bot.id
               )

      assert {:refused, _, _} = admitted.(persona.id, empty.id, bot.id)

      # The editor is admitted from its empty version.
      profile = admitted!(world, seed)
      settle!()
      assert profile.state == :admitted

      # Its kind is fixed, and there is one.
      assert {:refused, _, _} =
               refused(fn ->
                 Repo.update_all(from(p in Profile, where: p.id == ^persona.id),
                   set: [kind: :generic_editor]
                 )
               end)

      assert {:refused, _, _} =
               refused(fn ->
                 Repo.insert!(%Profile{
                   slug: "second-editor",
                   label: "x",
                   subject_label: "none",
                   kind: :generic_editor
                 })
               end)
    end
  end
end
