defmodule DevilsDictionary.Curation.ConfigurationsTest do
  @moduledoc """
  C1–C8 of `docs/curation/persistence-slice-1.md`: configuration identities,
  immutable versions, rosters, profile admission, activation and default
  resolution.
  """
  use DevilsDictionary.DataCase, async: true

  import DevilsDictionary.CurationFixtures

  alias DevilsDictionary.Curation.{
    Composition,
    CompositionPublication,
    Configuration,
    ConfigurationActivation,
    ConfigurationMember,
    ConfigurationVersion,
    Digest,
    Profile,
    Profiles,
    Configurations
  }

  alias DevilsDictionary.Fixtures

  setup do
    ctx = Fixtures.seed_catalog!()
    Map.merge(ctx, %{reviewer: account([:reviewer]), contributor: account([:contributor])})
  end

  describe "seeding" do
    test "creates a draft default with a manual-only version and five proposed identities" do
      %{configuration: c, version: v, profiles: profiles} = Configurations.seed!()
      settle!()

      assert %Configuration{
               slug: "global-default",
               role: :global_default,
               ownership_kind: :system,
               state: :draft,
               current_version_id: nil
             } = c

      assert %ConfigurationVersion{version: 1, lead_policy: :bierce_first_v1, max_highlights: 3} =
               v

      assert v.manifest["mode"] == "manual"
      assert v.manifest["roster"] == []
      assert v.roster_hash == Digest.roster_hash([])
      refute Map.has_key?(v.manifest, "model")

      assert Enum.map(profiles, & &1.slug) == ~w(bierce voltaire vonnegut hitchens le-guin)

      for p <- profiles do
        assert %Profile{state: :proposed, current_version_id: nil, bot_actor_id: nil} = p
      end

      # A seed is not a human: nothing it makes is approved or active.
      assert Configurations.resolve_default() == {:unavailable, :no_active_version}
      assert Repo.aggregate(ConfigurationActivation, :count) == 0
    end

    test "is idempotent and never changes an existing row's state", %{reviewer: reviewer} do
      {c, v} = enabled_default!(reviewer)

      %{configuration: again, version: v_again} = Configurations.seed!()
      settle!()

      assert again.id == c.id and v_again.id == v.id
      assert Repo.reload!(c).state == :enabled
      assert Repo.aggregate(Configuration, :count) == 1
      assert Repo.aggregate(ConfigurationVersion, :count) == 1
      assert Repo.aggregate(Profile, :count) == 5
    end
  end

  describe "resolution (C7)" do
    test "answers the default or an explicit unavailable, never another configuration",
         %{reviewer: reviewer} do
      assert Configurations.resolve_default() == {:unavailable, :missing}

      # An enabled *test* configuration is never the default.
      enabled_test_configuration!(reviewer, "test-a")
      assert Configurations.resolve_default() == {:unavailable, :missing}

      %{configuration: c, version: v} = Configurations.seed!()
      assert Configurations.resolve_default() == {:unavailable, :no_active_version}

      {:ok, _} =
        Configurations.activate(reviewer, c.id, v.id,
          reason: "go",
          idempotency_key: key(),
          expected: nil
        )

      assert {:ok, %{configuration: %{id: id}, version: %{id: vid}}} =
               Configurations.resolve_default()

      assert {id, vid} == {c.id, v.id}

      {:ok, _} =
        Configurations.disable(reviewer, c.id,
          reason: "stop",
          idempotency_key: key(),
          expected: v.id
        )

      assert Configurations.resolve_default() == {:unavailable, :disabled}
      settle!()
    end

    test "a panel is never available, and a version this build cannot run is unready",
         %{reviewer: reviewer} do
      assert Configurations.resolve_default(purpose: :panel) ==
               {:unavailable, :panel_not_available}

      %{configuration: c} = Configurations.seed!()
      actor = actor!(reviewer)

      # A version from some later build: its mode is not one this build runs.
      panel =
        Repo.insert!(%ConfigurationVersion{
          configuration_id: c.id,
          version: 2,
          manifest_hash: "later",
          manifest: %{"mode" => "panel"},
          lead_policy: :bierce_first_v1,
          roster_hash: Digest.roster_hash([]),
          created_by_actor_id: actor.id,
          change_reason: "a version this build cannot run"
        })

      assert {:error, :unready} =
               Configurations.activate(reviewer, c.id, panel.id,
                 reason: "go",
                 idempotency_key: key(),
                 expected: nil
               )

      assert Configurations.resolve_default() == {:unavailable, :no_active_version}

      assert Configurations.resolve_default(purpose: :panel) ==
               {:unavailable, :panel_not_available}
    end
  end

  describe "ownership and uniqueness (C1, C2)" do
    test "only system ownership exists and one global default is enabled", %{reviewer: reviewer} do
      {_c, _v} = enabled_default!(reviewer)
      actor = actor!(reviewer)

      assert {:refused, :check_violation, _} =
               refused(fn ->
                 Repo.query!(
                   "INSERT INTO curation_configurations (slug, name, ownership_kind, role, state, created_by_actor_id, inserted_at, updated_at) VALUES ('mine', 'x', 'personal', 'internal_test', 'draft', $1, now(), now())",
                   [actor.id]
                 )
               end)

      # A second global default can exist as a draft, but never be enabled
      # beside the first: refused by the service, and by the index.
      second =
        Repo.insert!(%Configuration{
          slug: "second-default",
          name: "second",
          role: :global_default,
          created_by_actor_id: actor.id
        })

      {:ok, v2} = Configurations.create_version(reviewer, second.id, %{reason: "v1"})

      assert {:error, :another_default_enabled} =
               Configurations.activate(reviewer, second.id, v2.id,
                 reason: "go",
                 idempotency_key: key(),
                 expected: nil
               )

      assert {:refused, :unique_violation, _} =
               refused(fn ->
                 Repo.query!(
                   "UPDATE curation_configurations SET state = 'enabled', current_version_id = $1 WHERE id = $2",
                   [v2.id, second.id]
                 )
               end)
    end

    test "a pointer to another configuration's version is refused", %{reviewer: reviewer} do
      {a, _va} = enabled_test_configuration!(reviewer, "test-a")
      {_b, vb} = enabled_test_configuration!(reviewer, "test-b")

      assert {:refused, :foreign_key_violation, _} =
               refused(fn ->
                 Repo.query!(
                   "UPDATE curation_configurations SET current_version_id = $1 WHERE id = $2",
                   [
                     vb.id,
                     a.id
                   ]
                 )
               end)

      assert {:error, :version_not_found} =
               Configurations.activate(reviewer, a.id, vb.id,
                 reason: "cross",
                 idempotency_key: key(),
                 expected: a.current_version_id
               )
    end
  end

  describe "receipts (C3, C8)" do
    test "a pointer moved without a receipt fails at commit", %{reviewer: reviewer} do
      {c, _v} = enabled_test_configuration!(reviewer, "test-a")

      {:ok, v2} =
        Configurations.create_version(reviewer, c.id, %{reason: "v2", max_highlights: 2})

      settle!()

      assert {:refused, :integrity_constraint_violation, message} =
               refused(fn ->
                 Repo.query!(
                   "UPDATE curation_configurations SET current_version_id = $1 WHERE id = $2",
                   [
                     v2.id,
                     c.id
                   ]
                 )
               end)

      assert message =~ "latest activation receipt"

      # And a receipt that does not continue the one before it is refused too.
      actor = actor!(reviewer)

      assert {:refused, :integrity_constraint_violation, _} =
               refused(fn ->
                 Repo.insert!(%ConfigurationActivation{
                   configuration_id: c.id,
                   action: :activate,
                   configuration_version_id: v2.id,
                   previous_version_id: nil,
                   actor_id: actor.id,
                   reason: "forged",
                   idempotency_key: key()
                 })

                 Repo.query!(
                   "UPDATE curation_configurations SET current_version_id = $1 WHERE id = $2",
                   [v2.id, c.id]
                 )
               end)
    end

    test "activation is a reviewer's audited, idempotent act and publishes nothing",
         %{reviewer: reviewer, contributor: contributor} = ctx do
      %{configuration: c, version: v} = Configurations.seed!()
      k = key()
      opts = [reason: "launch the manual default", idempotency_key: k, expected: nil]

      assert {:error, :unauthorized} = Configurations.activate(contributor, c.id, v.id, opts)
      assert {:error, :unauthorized} = Configurations.activate(nil, c.id, v.id, opts)

      assert {:ok, %ConfigurationActivation{} = receipt} =
               Configurations.activate(reviewer, c.id, v.id, opts)

      assert receipt.actor_id == actor!(reviewer).id
      assert receipt.previous_version_id == nil and receipt.configuration_version_id == v.id

      # The same key replays the same receipt; a different use of it is refused.
      assert {:ok, ^receipt} = Configurations.activate(reviewer, c.id, v.id, opts)

      assert {:error, :idempotency_conflict} =
               Configurations.disable(reviewer, c.id,
                 reason: "x",
                 idempotency_key: k,
                 expected: v.id
               )

      # An identical version is the same version, not a second one.
      assert {:error, {:duplicate_version, v_id}} =
               Configurations.create_version(reviewer, c.id, %{reason: "again"})

      assert v_id == v.id

      # A stale screen cannot move the pointer.
      {:ok, v2} =
        Configurations.create_version(reviewer, c.id, %{reason: "v2", max_highlights: 2})

      assert {:error, {:stale, v_id}} =
               Configurations.activate(reviewer, c.id, v2.id,
                 reason: "x",
                 idempotency_key: key(),
                 expected: nil
               )

      assert v_id == v.id
      assert Repo.aggregate(ConfigurationActivation, :count) == 1
      assert Repo.aggregate(Composition, :count) == 0
      assert Repo.aggregate(CompositionPublication, :count) == 0

      # The database refuses a bot or a non-reviewer receipt outright.
      bot = bot_actor!(ctx.sources["wikidata"])

      for actor <- [bot, actor!(contributor)] do
        assert {:refused, :integrity_constraint_violation, _} =
                 refused(fn ->
                   Repo.insert!(%ConfigurationActivation{
                     configuration_id: c.id,
                     action: :activate,
                     configuration_version_id: v2.id,
                     previous_version_id: v.id,
                     actor_id: actor.id,
                     reason: "not a reviewer",
                     idempotency_key: key()
                   })
                 end)
      end

      settle!()
    end

    test "a revoked reviewer is refused, rechecked under the account lock", %{reviewer: reviewer} do
      %{configuration: c, version: v} = Configurations.seed!()
      revoke!(reviewer)

      assert {:error, :unauthorized} =
               Configurations.activate(reviewer, c.id, v.id,
                 reason: "go",
                 idempotency_key: key(),
                 expected: nil
               )
    end
  end

  describe "immutability and rosters (C4, C5)" do
    setup %{reviewer: reviewer} do
      profile = admitted_test_profile!(reviewer)
      {c, _} = enabled_test_configuration!(reviewer, "test-roster")

      {:ok, v} =
        Configurations.create_version(reviewer, c.id, %{
          reason: "one seat",
          members: [%{profile_id: profile.id, profile_version_id: profile.current_version_id}]
        })

      settle!()
      %{profile: profile, configuration: c, version: v}
    end

    test "versions and rosters cannot be edited, removed or extended", ctx do
      assert [%ConfigurationMember{slot: 1, voting_weight: 1}] =
               Repo.all(
                 from m in ConfigurationMember,
                   where: m.configuration_version_id == ^ctx.version.id
               )

      assert {:refused, :integrity_constraint_violation, _} =
               refused(fn ->
                 Repo.query!(
                   "UPDATE curation_configuration_versions SET max_highlights = 1 WHERE id = $1",
                   [
                     ctx.version.id
                   ]
                 )
               end)

      assert {:refused, :integrity_constraint_violation, _} =
               refused(fn ->
                 Repo.query!(
                   "DELETE FROM curation_configuration_members WHERE configuration_version_id = $1",
                   [
                     ctx.version.id
                   ]
                 )
               end)

      # A seat added after the version's own transaction breaks its roster hash.
      other = admitted_test_profile!(ctx.reviewer, "test-second")

      assert {:refused, :integrity_constraint_violation, message} =
               refused(fn ->
                 Repo.insert!(%ConfigurationMember{
                   configuration_version_id: ctx.version.id,
                   profile_id: other.id,
                   profile_version_id: other.current_version_id,
                   slot: 2
                 })
               end)

      assert message =~ "roster differs"
    end

    test "a seat's profile version is its profile's, one per slot and profile, weight 1", ctx do
      other = admitted_test_profile!(ctx.reviewer, "test-third")
      actor = actor!(ctx.reviewer)

      insert_version = fn members ->
        v =
          Repo.insert!(%ConfigurationVersion{
            configuration_id: ctx.configuration.id,
            version: 99,
            manifest_hash: key("manifest"),
            manifest: %{"mode" => "manual"},
            lead_policy: :bierce_first_v1,
            roster_hash: Digest.roster_hash(members),
            created_by_actor_id: actor.id,
            change_reason: "raw"
          })

        for m <- members,
            do:
              Repo.insert!(
                struct(ConfigurationMember, Map.put(m, :configuration_version_id, v.id))
              )
      end

      seat = fn profile, version_id, slot, weight ->
        %{
          profile_id: profile.id,
          profile_version_id: version_id,
          slot: slot,
          voting_weight: weight
        }
      end

      assert {:refused, :foreign_key, _} =
               refused(fn ->
                 insert_version.([seat.(ctx.profile, other.current_version_id, 1, 1)])
               end)

      assert {:refused, :unique, _} =
               refused(fn ->
                 insert_version.([
                   seat.(ctx.profile, ctx.profile.current_version_id, 1, 1),
                   seat.(other, other.current_version_id, 1, 1)
                 ])
               end)

      assert {:refused, :check, _} =
               refused(fn ->
                 insert_version.([seat.(ctx.profile, ctx.profile.current_version_id, 1, 2)])
               end)

      assert :accepted =
               refused(fn ->
                 insert_version.([
                   seat.(ctx.profile, ctx.profile.current_version_id, 1, 1),
                   seat.(other, other.current_version_id, 2, 1)
                 ])
               end)
    end

    test "a roster seat must be an admitted profile's admitted version", ctx do
      [bierce | _] = Profiles.seed_proposed!()

      assert {:error, :profile_not_admitted} =
               Configurations.create_version(ctx.reviewer, ctx.configuration.id, %{
                 reason: "unadmitted seat",
                 members: [%{profile_id: bierce.id, profile_version_id: -1}]
               })
    end
  end

  describe "admission (C6)" do
    test "needs a reviewer, a sourced version with deceased-status evidence, and a bot principal",
         ctx do
      {:ok, profile} = test_profile!()

      {:ok, unsourced} =
        Profiles.add_version(ctx.contributor, profile.id, %{
          template_version: "test-v1",
          reason: "draft dossier",
          source_refs: [],
          deceased_evidence_refs: []
        })

      bot = bot_actor!(ctx.sources["wikidata"])
      opts = [reason: "reviewed", bot_actor_id: bot.id]

      assert {:error, :unauthorized} =
               Profiles.admit(ctx.contributor, profile.id, unsourced.id, opts)

      assert {:error, :sources_missing} =
               Profiles.admit(ctx.reviewer, profile.id, unsourced.id, opts)

      {:ok, sourced} =
        Profiles.add_version(ctx.contributor, profile.id, %{
          template_version: "test-v1",
          reason: "sourced dossier",
          source_refs: [%{"ref" => "test:source-1"}],
          deceased_evidence_refs: [%{"ref" => "test:evidence-1"}]
        })

      assert {:error, :bot_actor_missing} =
               Profiles.admit(ctx.reviewer, profile.id, sourced.id, reason: "reviewed")

      assert {:ok, %Profile{state: :admitted} = admitted} =
               Profiles.admit(ctx.reviewer, profile.id, sourced.id, opts)

      assert admitted.admitted_by_actor_id == actor!(ctx.reviewer).id
      settle!()

      # The database refuses the same shortcuts on its own.
      {:ok, raw} = test_profile!("test-raw")

      # The admission trigger answers first; the check constraint stands behind it.
      assert {:refused, _code, _} =
               refused(fn ->
                 Repo.query!("UPDATE curator_profiles SET state = 'admitted' WHERE id = $1", [
                   raw.id
                 ])
               end)

      {:ok, raw_version} =
        Profiles.add_version(ctx.contributor, raw.id, %{
          template_version: "test-v1",
          reason: "sourced",
          source_refs: [%{"ref" => "test:s"}],
          deceased_evidence_refs: [%{"ref" => "test:e"}]
        })

      other_bot = bot_actor!(ctx.sources["wiktionary"])

      assert {:refused, :integrity_constraint_violation, message} =
               refused(fn ->
                 Repo.query!(
                   """
                   UPDATE curator_profiles SET state = 'admitted', bot_actor_id = $2,
                     admitted_by_actor_id = $3, admitted_at = now(), admission_reason = 'self'
                    WHERE id = $1
                   """,
                   [raw.id, other_bot.id, actor!(ctx.contributor).id]
                 )
               end)

      assert message =~ "human reviewer"
      assert raw_version.profile_id == raw.id
    end
  end

  @bot_sources %{
    "test-admitted" => "wordnet",
    "test-second" => "johnson",
    "test-third" => "wikipedia"
  }

  # A test profile with test references: no real person's dossier is written.
  defp test_profile!(slug \\ "test-profile") do
    {:ok,
     Repo.insert!(%Profile{
       slug: slug,
       label: "Test profile",
       subject_label: "Nobody (test)",
       state: :proposed
     })}
  end

  defp admitted_test_profile!(reviewer, slug \\ "test-admitted") do
    {:ok, profile} = test_profile!(slug)
    author = account([:contributor])

    {:ok, version} =
      Profiles.add_version(author, profile.id, %{
        template_version: "test-v1",
        reason: "sourced",
        source_refs: [%{"ref" => "test:#{slug}:source"}],
        deceased_evidence_refs: [%{"ref" => "test:#{slug}:evidence"}]
      })

    # One bot principal per profile, each on its own source.
    source_slug = Map.fetch!(@bot_sources, slug)
    source = Repo.one!(from s in DevilsDictionary.Sources.Source, where: s.slug == ^source_slug)
    bot = bot_actor!(source)

    {:ok, admitted} =
      Profiles.admit(reviewer, profile.id, version.id, reason: "test", bot_actor_id: bot.id)

    admitted
  end
end
