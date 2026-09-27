defmodule DevilsDictionary.Curation.CompositionsTest do
  @moduledoc """
  K1–K10 of `docs/curation/persistence-slice-1.md`: composition identity,
  scope, and manual versions with exact references.
  """
  use DevilsDictionary.DataCase, async: true

  import DevilsDictionary.CurationFixtures

  alias DevilsDictionary.Curation.{
    Composition,
    CompositionItem,
    CompositionVersion,
    Compositions,
    Configurations,
    Digest,
    ScopeChange
  }

  alias DevilsDictionary.Registry

  setup do
    world = world!()
    {config, config_version} = enabled_test_configuration!(world.reviewer, "test-a")
    Map.merge(world, %{config: config, config_version: config_version})
  end

  defp provision!(ctx, config \\ nil, ids \\ nil) do
    {:ok, c} =
      Compositions.provision(ctx.contributor, (config || ctx.config).id, %{
        scope_kind: :lexeme,
        lexeme_ids: ids || [ctx.love.object_id],
        language_tag: "en",
        reason: "curate love"
      })

    c
  end

  defp version!(ctx, composition, attrs) do
    {:ok, v} =
      Compositions.create_version(
        ctx.contributor,
        composition.id,
        Map.merge(%{reason: "manual arrangement", expected_parent: nil}, attrs)
      )

    v
  end

  describe "identity (K1–K3)" do
    test "the identity is (kind, signature, language, configuration) and provisioning is idempotent",
         ctx do
      c = provision!(ctx)
      assert c == provision!(ctx)

      assert %Composition{
               scope_kind: :lexeme,
               language_tag: "en",
               curation_configuration_id: config_id,
               scope_signature: signature
             } = c

      assert config_id == ctx.config.id
      assert signature == Digest.scope_signature([{:lexeme, ctx.love.object_id}])
      assert Compositions.member_ids(c.id) == [ctx.love.object_id]

      assert [
               %ScopeChange{
                 previous_signature: nil,
                 scope_signature: ^signature,
                 members: members
               }
             ] =
               Repo.all(from s in ScopeChange, where: s.composition_id == ^c.id)

      assert members == [["lexeme", ctx.love.object_id]]
      settle!()
    end

    test "two configurations over one scope keep independent histories, pointers and clocks",
         ctx do
      {config_b, _} = enabled_test_configuration!(ctx.reviewer, "test-b")
      a = provision!(ctx)
      b = provision!(ctx, config_b)

      refute a.id == b.id
      assert a.scope_signature == b.scope_signature

      lead = content_spec(ctx.bierce, ctx.love)
      va1 = version!(ctx, a, %{lead: lead})

      va2 =
        version!(ctx, a, %{
          lead: lead,
          highlights: [quotation_spec(ctx.sense, 1)],
          expected_parent: va1.id
        })

      vb1 = version!(ctx, b, %{lead: lead})

      # Each composition numbers its own versions and chains its own parents.
      assert {va1.version, va2.version, vb1.version} == {1, 2, 1}
      assert va2.parent_version_id == va1.id and is_nil(vb1.parent_version_id)
      assert vb1.configuration_version_id != va1.configuration_version_id

      # A version of one can never be the parent of, or published by, the other.
      assert {:refused, :foreign_key_violation, _} =
               refused(fn ->
                 Repo.query!(
                   "UPDATE editorial_compositions SET current_published_version_id = $1 WHERE id = $2",
                   [
                     va1.id,
                     b.id
                   ]
                 )
               end)

      assert {:error, {:stale_parent, id}} =
               Compositions.create_version(ctx.contributor, b.id, %{
                 lead: lead,
                 reason: "x",
                 expected_parent: va1.id
               })

      assert id == vb1.id
      settle!()
    end

    test "provisioning takes registry ids, refuses overlap and a mixed language", ctx do
      page =
        Compositions.provision(ctx.contributor, ctx.config.id, %{
          scope_kind: :lexical_page,
          lexeme_ids: [ctx.love.object_id, ctx.amor.object_id],
          language_tag: "en",
          reason: "love and amor share a page"
        })

      assert {:ok, %Composition{id: page_id}} = page

      assert {:error, {:overlapping_scope, [^page_id]}} =
               Compositions.provision(ctx.contributor, ctx.config.id, %{
                 scope_kind: :lexical_page,
                 lexeme_ids: [ctx.love.object_id],
                 language_tag: "en",
                 reason: "a split nobody reconciled"
               })

      # A lexeme scope is a different kind, and has exactly one member.
      assert {:ok, _} =
               Compositions.provision(ctx.contributor, ctx.config.id, %{
                 scope_kind: :lexeme,
                 lexeme_ids: [ctx.love.object_id],
                 language_tag: "en",
                 reason: "the lexeme itself"
               })

      assert {:error, :lexeme_scope_has_one_member} =
               Compositions.provision(ctx.contributor, ctx.config.id, %{
                 scope_kind: :lexeme,
                 lexeme_ids: [ctx.love.object_id, ctx.oats.object_id],
                 language_tag: "en",
                 reason: "x"
               })

      assert {:error, :language_mismatch} =
               Compositions.provision(ctx.contributor, ctx.config.id, %{
                 scope_kind: :lexeme,
                 lexeme_ids: [ctx.oats.object_id],
                 language_tag: "fr",
                 reason: "x"
               })

      assert {:error, {:not_lexemes, [id]}} =
               Compositions.provision(ctx.contributor, ctx.config.id, %{
                 scope_kind: :lexeme,
                 lexeme_ids: [ctx.bierce.object_id],
                 language_tag: "en",
                 reason: "a content item is not a scope"
               })

      assert id == ctx.bierce.object_id

      assert {:error, :unauthorized} =
               Compositions.provision(account(), ctx.config.id, %{
                 scope_kind: :lexeme,
                 lexeme_ids: [ctx.oats.object_id],
                 language_tag: "en",
                 reason: "x"
               })

      settle!()
    end

    test "a draft or disabled configuration has no compositions made under it", ctx do
      {:ok, draft} = Configurations.create_test_configuration(ctx.reviewer, "test-draft", "draft")

      assert {:error, :configuration_unavailable} =
               Compositions.provision(ctx.contributor, draft.id, %{
                 scope_kind: :lexeme,
                 lexeme_ids: [ctx.love.object_id],
                 language_tag: "en",
                 reason: "x"
               })
    end

    test "a scope change is explicit and audited; a signature that does not match fails at commit",
         ctx do
      {:ok, page} =
        Compositions.provision(ctx.contributor, ctx.config.id, %{
          scope_kind: :lexical_page,
          lexeme_ids: [ctx.love.object_id],
          language_tag: "en",
          reason: "love's page"
        })

      assert {:ok, changed} =
               Compositions.change_scope(
                 ctx.contributor,
                 page.id,
                 [ctx.love.object_id, ctx.amor.object_id],
                 reason: "amor merges into love's page"
               )

      assert changed.scope_signature ==
               Compositions.signature([ctx.love.object_id, ctx.amor.object_id])

      assert [first, second] =
               Repo.all(
                 from s in ScopeChange, where: s.composition_id == ^page.id, order_by: s.id
               )

      assert second.previous_signature == first.scope_signature
      settle!()

      assert {:refused, :integrity_constraint_violation, message} =
               refused(fn ->
                 Repo.query!(
                   "UPDATE editorial_compositions SET scope_signature = 'love' WHERE id = $1",
                   [
                     page.id
                   ]
                 )
               end)

      assert message =~ "scope does not match"

      assert {:refused, :integrity_constraint_violation, _} =
               refused(fn ->
                 Repo.query!(
                   "INSERT INTO editorial_composition_memberships (composition_id, object_id, role, inserted_at) VALUES ($1, $2, 'lexeme', now())",
                   [page.id, ctx.oats.object_id]
                 )
               end)
    end
  end

  describe "manual versions (K4–K9)" do
    test "a version is manual, human, reasoned, exact, and invents no history", ctx do
      c = provision!(ctx)

      v =
        version!(ctx, c, %{
          lead: content_spec(ctx.bierce, ctx.love),
          highlights: [
            quotation_spec(ctx.sense, 1),
            content_spec(ctx.definition, ctx.love)
            |> Map.put(:note, %{text: "a plain gloss beside it"}),
            catalog_spec(ctx.love)
          ]
        })

      settle!()

      assert %CompositionVersion{
               version: 1,
               origin: :manual,
               parent_version_id: nil,
               change_reason: "manual arrangement",
               lead_policy: :bierce_first_v1
             } = v

      assert v.created_by_actor_id == actor!(ctx.contributor).id
      assert v.resolution["lead_rule"] == "priority_source"
      assert v.resolution["priority_leads"] == [ctx.bierce.object_id]

      items = Compositions.items(v.id)

      assert Enum.map(items, &{&1.role, &1.position, &1.item_kind}) ==
               [
                 {:highlight, 1, :sense_quotation},
                 {:highlight, 2, :content},
                 {:highlight, 3, :work},
                 {:lead, 1, :content}
               ]

      assert Enum.all?(items, &(&1.selection_origin == :manual))
      assert v.arrangement_hash == Digest.arrangement_hash(items)

      note = Enum.find(items, & &1.note)

      assert {note.note_author_kind, note.note_author_label} ==
               {:human, actor!(ctx.contributor).label}

      # Manual work has no run, participant or ballot anywhere (#197 adds
      # them). Model configs exist since #195's runtime, whose attempts are
      # receipts: no composition table refers to a model.
      for table <- ~w(curation_runs curation_participants curation_ballots) do
        assert %{rows: [[false]]} =
                 Repo.query!("SELECT to_regclass($1) IS NOT NULL", [table])
      end

      assert %{rows: []} =
               Repo.query!("""
               SELECT conrelid::regclass::text FROM pg_constraint
               WHERE contype = 'f'
                 AND confrelid = 'local_model_configs'::regclass
                 AND conrelid::regclass::text LIKE 'editorial_composition%'
               """)

      # And no model-authored note can be written into it.
      assert {:error, {:note_invalid, :highlight, 1}} =
               Compositions.create_version(ctx.contributor, c.id, %{
                 lead: content_spec(ctx.bierce, ctx.love),
                 highlights: [
                   Map.put(content_spec(ctx.definition, ctx.love), :note, "model says")
                 ],
                 reason: "x",
                 expected_parent: v.id
               })
    end

    test "a version cannot be edited, removed or have items added", ctx do
      v = version!(ctx, provision!(ctx), %{lead: content_spec(ctx.bierce, ctx.love)})
      settle!()
      [lead] = Compositions.items(v.id)

      for sql <- [
            "UPDATE editorial_composition_versions SET change_reason = 'rewritten' WHERE id = $1",
            "DELETE FROM editorial_composition_versions WHERE id = $1"
          ] do
        assert {:refused, :integrity_constraint_violation, _} =
                 refused(fn -> Repo.query!(sql, [v.id]) end)
      end

      for sql <- [
            "UPDATE editorial_composition_items SET position = 2 WHERE id = $1",
            "UPDATE editorial_composition_items SET content_revision_id = content_revision_id + 1 WHERE id = $1",
            "DELETE FROM editorial_composition_items WHERE id = $1"
          ] do
        assert {:refused, _code, _} = refused(fn -> Repo.query!(sql, [lead.id]) end)
      end

      assert {:refused, :integrity_constraint_violation, message} =
               refused(fn ->
                 Repo.insert!(%CompositionItem{
                   composition_version_id: v.id,
                   role: :highlight,
                   position: 1,
                   item_kind: :content,
                   item_object_id: ctx.definition.object_id,
                   content_revision_id:
                     Registry.current_content_revision(ctx.definition.object_id).id,
                   meaning_lexeme_id: ctx.love.object_id
                 })
               end)

      assert message =~ "arrangement differs"
    end

    test "a fourth highlight or a second lead cannot be stored", ctx do
      c = provision!(ctx)
      v = version!(ctx, c, %{lead: content_spec(ctx.bierce, ctx.love)})
      q = quotation_spec(ctx.sense, 1)

      assert {:error, {:too_many_highlights, 3}} =
               Compositions.create_version(ctx.contributor, c.id, %{
                 lead: content_spec(ctx.bierce, ctx.love),
                 highlights: [q, q, q, q],
                 reason: "x",
                 expected_parent: v.id
               })

      item = fn role, position ->
        %CompositionItem{
          composition_version_id: v.id,
          role: role,
          position: position,
          item_kind: :content,
          item_object_id: ctx.definition.object_id,
          content_revision_id: Registry.current_content_revision(ctx.definition.object_id).id,
          meaning_lexeme_id: ctx.love.object_id
        }
      end

      assert {:refused, :check, _} = refused(fn -> Repo.insert!(item.(:highlight, 4)) end)
      assert {:refused, :check, _} = refused(fn -> Repo.insert!(item.(:lead, 2)) end)
      assert {:refused, :unique, _} = refused(fn -> Repo.insert!(item.(:lead, 1)) end)
    end

    test "cross-configuration, cross-composition and cross-object links are refused", ctx do
      {config_b, config_b_version} = enabled_test_configuration!(ctx.reviewer, "test-b")
      a = provision!(ctx)
      b = provision!(ctx, config_b)
      va = version!(ctx, a, %{lead: content_spec(ctx.bierce, ctx.love)})
      actor = actor!(ctx.contributor)

      raw_version = fn attrs ->
        Repo.insert!(
          struct(
            CompositionVersion,
            Map.merge(
              %{
                composition_id: a.id,
                curation_configuration_id: a.curation_configuration_id,
                configuration_version_id: va.configuration_version_id,
                version: 10 + System.unique_integer([:positive]),
                parent_version_id: va.id,
                change_reason: "raw",
                created_by_actor_id: actor.id,
                scope_signature: a.scope_signature,
                scope_members: [],
                resolution: %{},
                lead_policy: :bierce_first_v1,
                arrangement_hash: Digest.arrangement_hash([]),
                eligibility_fingerprint: key("fp")
              },
              attrs
            )
          )
        )
      end

      assert :accepted = refused(fn -> raw_version.(%{}) end)

      # Another configuration's version, or a parent from another composition.
      assert {:refused, :foreign_key, _} =
               refused(fn -> raw_version.(%{configuration_version_id: config_b_version.id}) end)

      vb = version!(ctx, b, %{lead: content_spec(ctx.bierce, ctx.love)})

      assert {:refused, :foreign_key, _} =
               refused(fn -> raw_version.(%{parent_version_id: vb.id}) end)

      # A revision of another object than the item names.
      assert {:refused, :foreign_key, _} =
               refused(fn ->
                 v = raw_version.(%{})

                 Repo.insert!(%CompositionItem{
                   composition_version_id: v.id,
                   role: :lead,
                   position: 1,
                   item_kind: :content,
                   item_object_id: ctx.definition.object_id,
                   content_revision_id:
                     Registry.current_content_revision(ctx.bierce.object_id).id,
                   meaning_lexeme_id: ctx.love.object_id
                 })
               end)

      # A bot is never an author.
      bot = bot_actor!(ctx.sources["wikidata"])

      assert {:refused, :integrity_constraint_violation, _} =
               refused(fn -> raw_version.(%{created_by_actor_id: bot.id}) end)
    end

    test "exact references are checked against the registry when the version is made", ctx do
      c = provision!(ctx)
      lead = content_spec(ctx.bierce, ctx.love)

      attempt = fn highlight ->
        Compositions.create_version(ctx.contributor, c.id, %{
          lead: lead,
          highlights: [highlight],
          reason: "x",
          expected_parent: nil
        })
      end

      # A meaning off the scope.
      assert {:error, {:ineligible, [{:highlight, 1, :meaning_off_scope}]}} =
               attempt.(content_spec(ctx.definition, ctx.oats))

      # Words that are not what the source says.
      assert {:error, {:ineligible, [{:highlight, 1, :words_changed}]}} =
               attempt.(%{
                 quotation_spec(ctx.sense, 1)
                 | words_sha256: Digest.sha256("other words")
               })

      # A locator at an example that is not a quotation.
      assert {:error, {:ineligible, [{:highlight, 1, :words_changed}]}} =
               attempt.(%{quotation_spec(ctx.sense, 1) | locator: "quotation:0"})

      # A catalog pin to a checksum or a row this build does not have.
      assert {:error, {:ineligible, [{:highlight, 1, :catalog_changed}]}} =
               attempt.(catalog_spec(ctx.love, %{checksum: "not-the-committed-one"}))

      assert {:error, {:ineligible, [{:highlight, 1, :catalog_row_missing}]}} =
               attempt.(catalog_spec(ctx.love, %{identity: "Q0"}))

      assert {:error, {:ineligible, [{:highlight, 1, :catalog_changed}]}} =
               attempt.(catalog_spec(ctx.love, %{manifest: "../../etc/passwd"}))

      # A superseded revision is not a pin to the current one.
      stale = content_spec(ctx.definition, ctx.love)

      {:ok, _} =
        Registry.add_content_revision(ctx.definition.object_id, %{body: "fixture revised body"})

      assert {:error, {:ineligible, [{:highlight, 1, :revision_superseded}]}} = attempt.(stale)

      # No meaning at all.
      assert {:error, {:meaning_required, :highlight, 1}} =
               attempt.(Map.delete(content_spec(ctx.definition, ctx.love), :meaning))
    end

    test "two authors cannot both write the next version", ctx do
      c = provision!(ctx)
      v1 = version!(ctx, c, %{lead: content_spec(ctx.bierce, ctx.love)})

      v2 =
        version!(ctx, c, %{
          lead: content_spec(ctx.bierce, ctx.love),
          highlights: [quotation_spec(ctx.sense, 1)],
          expected_parent: v1.id
        })

      assert {:error, {:stale_parent, id}} =
               Compositions.create_version(ctx.contributor, c.id, %{
                 lead: content_spec(ctx.bierce, ctx.love),
                 highlights: [content_spec(ctx.definition, ctx.love)],
                 reason: "from a stale screen",
                 expected_parent: v1.id
               })

      assert id == v2.id

      # And the same arrangement twice is one version.
      assert {:error, {:duplicate_version, id}} =
               Compositions.create_version(ctx.contributor, c.id, %{
                 lead: content_spec(ctx.bierce, ctx.love),
                 highlights: [quotation_spec(ctx.sense, 1)],
                 reason: "again",
                 expected_parent: v2.id
               })

      assert id == v2.id
      settle!()
    end
  end

  describe "Bierce first (K10)" do
    test "an applicable Bierce entry leads, and a version without it is refused", ctx do
      c = provision!(ctx)

      assert {:error, :priority_source_available} =
               Compositions.create_version(ctx.contributor, c.id, %{
                 lead: content_spec(ctx.definition, ctx.love),
                 reason: "x",
                 expected_parent: nil
               })

      assert {:error, :priority_source_missing} =
               Compositions.create_version(ctx.contributor, c.id, %{
                 lead: nil,
                 highlights: [quotation_spec(ctx.sense, 1)],
                 reason: "x",
                 expected_parent: nil
               })

      assert %CompositionVersion{} = version!(ctx, c, %{lead: content_spec(ctx.bierce, ctx.love)})
    end

    test "where Bierce has no entry, a person may choose a page definition, or none", ctx do
      c = provision!(ctx, nil, [ctx.oats.object_id])

      v = version!(ctx, c, %{lead: content_spec(ctx.oats_definition, ctx.oats)})
      assert v.resolution["lead_rule"] == "manual_fallback"

      # A definition from another page is not this page's to lead.
      assert {:error, :lead_not_on_scope} =
               Compositions.create_version(ctx.contributor, c.id, %{
                 lead: content_spec(ctx.definition, ctx.oats),
                 reason: "x",
                 expected_parent: v.id
               })

      empty = version!(ctx, c, %{lead: nil, expected_parent: v.id, reason: "no lead"})
      assert empty.resolution["lead_rule"] == "none"
      settle!()
    end
  end
end
