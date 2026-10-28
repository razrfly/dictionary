defmodule DevilsDictionary.Curation.PublishedReaderTest do
  @moduledoc """
  The published opening reader (#255 §6, tests 1–8): a page finds its
  composition by its words under the active default, shows what
  `Published.current/1` answers and nothing else, withholds without
  substituting, and names every reason it withholds for.
  """

  use DevilsDictionary.DataCase, async: false

  import DevilsDictionary.CurationFixtures,
    only: [
      account: 1,
      defines_claim!: 2,
      enabled_default!: 1,
      key: 1
    ]

  import DevilsDictionary.OpeningFixtures
  import DevilsDictionary.WordFixtures

  alias DevilsDictionary.{Claims, Fixtures, Lexicon, Registry}

  alias DevilsDictionary.Curation.{
    Compositions,
    Configurations,
    Opening,
    PublishedReader,
    Publications,
    Reviews
  }

  alias DevilsDictionary.Curation.Opening.{Highlight, Lead, Reason}
  alias DevilsDictionary.Lexicon.WordPage
  alias DevilsDictionary.Sources.Actor

  @lead_note "Bierce's definition leads: the voice this dictionary is named for."
  @johnson_note "Johnson's four senses map the word before Bierce turned it."
  @milton_note "The plainest literary use, so the two leads can be compared."

  setup ctx do
    %{sources: sources} = Fixtures.seed_catalog!()
    ctx = Map.put(ctx, :sources, sources)
    ctx = Map.merge(ctx, love!(ctx))

    # *love* is a noun and a verb, so its On page and its exact noun page
    # reach different words (#255 §3.1).
    verb = word!(ctx, "love", ~w(wiktionary), pos: "verb", scope: nil)

    Map.merge(ctx, %{
      verb: verb,
      author: account([:contributor]),
      reviewer: account([:reviewer])
    })
  end

  defp on_page, do: "love" |> Lexicon.lookup() |> WordPage.build()

  defp exact_page(lexeme) do
    lexeme = Lexicon.by_object_id(lexeme.object_id)
    WordPage.build(%{lexemes: [lexeme], via: :lemma, matched: lexeme.lemma})
  end

  defp activate!(ctx) do
    {configuration, version} = enabled_default!(ctx.reviewer)
    Map.merge(ctx, %{configuration: configuration, configuration_version: version})
  end

  defp provision!(ctx, kind \\ :lexical_page, lexemes \\ nil) do
    {:ok, composition} =
      Compositions.provision(ctx.author, ctx.configuration.id, %{
        scope_kind: kind,
        lexeme_ids: Enum.map(lexemes || [ctx.love, ctx.verb], & &1.object_id),
        language_tag: "en",
        reason: "P1 #255 test"
      })

    composition
  end

  defp content_spec(content, lexeme),
    do:
      Map.put(DevilsDictionary.CurationFixtures.content_spec(content, lexeme), :note, %{
        text: "A fixture selection reason."
      })

  defp quotation_spec(sense, index),
    do:
      Map.put(DevilsDictionary.CurationFixtures.quotation_spec(sense, index), :note, %{
        text: "A fixture selection reason."
      })

  defp with_note(spec, text), do: Map.put(spec, :note, %{text: text})

  # The §5.3 arrangement: Bierce leads, Johnson's entry and a Wiktionary
  # quotation follow, each with its author's note.
  defp love_version!(ctx, composition) do
    {:ok, version} =
      Compositions.create_version(ctx.author, composition.id, %{
        lead: ctx.bierce |> content_spec(ctx.love) |> with_note(@lead_note),
        highlights: [
          ctx.johnson |> content_spec(ctx.love) |> with_note(@johnson_note),
          ctx.profound |> quotation_spec(1) |> with_note(@milton_note)
        ],
        reason: "P1 #255 test",
        expected_parent: nil
      })

    version
  end

  defp accept!(ctx, version) do
    {:ok, review} =
      Reviews.decide(ctx.reviewer, version.id, :accepted,
        reason: "P1 #255 test",
        idempotency_key: key("review")
      )

    review
  end

  defp publish!(ctx, version, expected \\ nil) do
    {:ok, receipt} =
      Publications.publish(ctx.reviewer, version.id,
        reason: "P1 #255 test",
        idempotency_key: key("publish"),
        expected_pointer: expected
      )

    receipt
  end

  defp published_love!(ctx) do
    ctx = activate!(ctx)
    composition = provision!(ctx)
    version = love_version!(ctx, composition)
    review = accept!(ctx, version)
    receipt = publish!(ctx, version)

    Map.merge(ctx, %{composition: composition, version: version, review: review, receipt: receipt})
  end

  # The label an account acts under, as the database recorded it.
  defp label(scope),
    do: Actor |> Repo.get_by!(user_id: scope.user.id) |> Compositions.author_label()

  describe "test 1: nothing to read" do
    test "no active configuration, no composition, or nothing published is no opening", ctx do
      # Not seeded at all, then seeded but never activated.
      assert PublishedReader.opening(on_page()) == nil
      Configurations.seed!()
      assert Configurations.resolve_default() == {:unavailable, :no_active_version}
      assert PublishedReader.opening(on_page()) == nil

      # Active, and nothing provisioned for these words.
      ctx = activate!(ctx)
      assert PublishedReader.opening(on_page()) == nil

      # Provisioned and versioned, but not published.
      composition = provision!(ctx)
      love_version!(ctx, composition)
      assert PublishedReader.opening(on_page()) == nil
    end
  end

  describe "test 2: a published composition" do
    test "is the record's lead, highlights in order, signed notes, and who published it", ctx do
      ctx = activate!(ctx)
      composition = provision!(ctx)
      version = love_version!(ctx, composition)
      accept!(ctx, version)

      # Another reviewer publishes what the first accepted, so the receipt's
      # actor and the review's are told apart.
      publisher = account([:reviewer])
      receipt = publish!(%{ctx | reviewer: publisher}, version)
      ctx = Map.merge(ctx, %{composition: composition, receipt: receipt})

      # The author's label as stored with the notes, then a new one on the
      # actor: notes keep what was recorded with them (K9).
      author = label(ctx.author)

      Repo.update_all(from(a in Actor, where: a.user_id == ^ctx.author.user.id),
        set: [label: "Renamed author"]
      )

      assert %Opening{origin: :published} = opening = PublishedReader.opening(on_page())
      assert opening.composition == %{id: ctx.composition.id, version: 1}
      assert opening.withheld == []

      assert opening.configuration.slug == "global-default"
      assert opening.configuration.version == 1
      assert opening.configuration.lead_rule == :bierce_first_v1
      assert opening.configuration.resolution_reason == :global_default

      assert %Lead{policy: :priority_source, register: :satire} = opening.lead
      assert opening.lead.reference.object_id == ctx.bierce.object_id
      assert opening.lead.excerpt.text =~ "A temporary insanity curable by marriage"
      assert opening.lead.excerpt.clipped?
      assert opening.lead.links.card_id == "card-bierce"

      assert [
               %Highlight{position: 1, kind: :definition},
               %Highlight{position: 2, kind: :quotation}
             ] =
               opening.highlights

      [johnson, milton] = opening.highlights
      assert johnson.reference.object_id == ctx.johnson.object_id
      assert johnson.excerpt.text == "1. The passion between the sexes."
      assert milton.quotation.text =~ "cordial love"
      assert milton.meaning.object_id == ctx.profound.object_id

      # Each reason is the stored note, signed with the label stored with it.
      for {item, text} <- [
            {opening.lead, @lead_note},
            {johnson, @johnson_note},
            {milton, @milton_note}
          ] do
        assert [%Reason{kind: :editorial, text: ^text, author: %{kind: :human, label: ^author}}] =
                 Enum.filter(item.reasons, &(&1.kind == :editorial))
      end

      # Who selected it is the version's author as the actor is named now;
      # who published it is the receipt's actor; who reviewed it, the review's.
      assert opening.review.state == :published
      assert opening.review.selected_by == %{kind: :human, label: "Renamed author"}
      assert opening.review.published_by == %{kind: :human, label: label(publisher)}
      assert opening.review.reviewed_by == label(ctx.reviewer)
      refute label(publisher) == label(ctx.reviewer)
      assert opening.review.receipt_id == ctx.receipt.id
      assert opening.review.published_on == DateTime.to_date(ctx.receipt.committed_at)
    end
  end

  describe "test 3: withdrawn" do
    test "a withdrawn composition is no opening", ctx do
      ctx = published_love!(ctx)
      assert %Opening{} = PublishedReader.opening(on_page())

      {:ok, _} =
        Publications.withdraw(ctx.reviewer, ctx.composition.id,
          reason: "P1 #255 test",
          idempotency_key: key("withdraw"),
          expected_pointer: ctx.version.id
        )

      assert PublishedReader.opening(on_page()) == nil
    end
  end

  describe "test 4: a superseded revision" do
    test "withholds that highlight with its reason and keeps the rest", ctx do
      ctx = published_love!(ctx)
      current = Registry.current_sense_revision(ctx.profound.object_id)

      {:ok, _newer} =
        Registry.add_sense_revision(ctx.profound.object_id, %{
          gloss: current.gloss,
          position: current.position,
          examples: current.examples,
          url: current.url,
          source_record_revision_id: current.source_record_revision_id
        })

      opening = PublishedReader.opening(on_page())

      assert opening.withheld == [%{role: :highlight, position: 2, reason: :revision_superseded}]
      assert opening.lead.reference.object_id == ctx.bierce.object_id
      assert [%Highlight{position: 1, kind: :definition}] = opening.highlights
    end
  end

  describe "test 5: Bierce first at read time" do
    test "a Johnson lead is withheld once a Bierce entry is on the page, and not replaced", ctx do
      ctx = activate!(ctx)
      patience = word!(ctx, "patience", ~w(johnson wiktionary), scope: nil)
      johnson = entry!(ctx, patience, "johnson", headword: "PATIENCE", pos: "n. s.")
      wiktionary = entry!(ctx, patience, "wiktionary", body: "The quality of being patient.")
      composition = provision!(ctx, :lexical_page, [patience])

      # No Bierce entry yet, so Johnson may lead (`:manual_fallback`).
      {:ok, version} =
        Compositions.create_version(ctx.author, composition.id, %{
          lead: content_spec(johnson, patience),
          highlights: [content_spec(wiktionary, patience)],
          reason: "P1 #255 test",
          expected_parent: nil
        })

      accept!(ctx, version)
      publish!(ctx, version)
      page = fn -> "patience" |> Lexicon.lookup() |> WordPage.build() end
      assert %Lead{policy: :manual_fallback} = PublishedReader.opening(page.()).lead

      entry!(ctx, patience, "bierce", body: "fixture later bierce entry")
      opening = PublishedReader.opening(page.())

      assert opening.lead == nil
      assert opening.withheld == [%{role: :lead, position: 1, reason: :priority_source_available}]
      assert [%Highlight{position: 1}] = opening.highlights
    end

    test "a Bierce card whose defining claim was rejected neither leads nor withholds the lead",
         ctx do
      # The page still shows the entry (its card does not read claim
      # reviews), but `LeadRule` does not count it, so Johnson may lead.
      {:ok, _} =
        Claims.review(defines_claim!(ctx.bierce, ctx.love).id, :rejected, %{
          reason: "P1 #255 test"
        })

      ctx = activate!(ctx)
      composition = provision!(ctx)

      {:ok, version} =
        Compositions.create_version(ctx.author, composition.id, %{
          lead: content_spec(ctx.johnson, ctx.love),
          reason: "P1 #255 test",
          expected_parent: nil
        })

      accept!(ctx, version)
      publish!(ctx, version)
      page = on_page()
      assert Enum.any?(page.cards, &(&1.id == "card-bierce"))

      opening = PublishedReader.opening(page)
      assert %Lead{policy: :manual_fallback, register: :definition} = opening.lead
      assert opening.lead.reference.object_id == ctx.johnson.object_id
      assert opening.withheld == []
    end
  end

  describe "test 6: not accepted" do
    test "a draft, a rejected version and a rejection after publication are no opening", ctx do
      ctx = activate!(ctx)
      composition = provision!(ctx)
      version = love_version!(ctx, composition)
      assert PublishedReader.opening(on_page()) == nil

      {:ok, _} =
        Reviews.decide(ctx.reviewer, version.id, :rejected,
          reason: "P1 #255 test",
          idempotency_key: key("reject")
        )

      assert {:error, :not_approved} =
               Publications.publish(ctx.reviewer, version.id,
                 reason: "P1 #255 test",
                 idempotency_key: key("publish"),
                 expected_pointer: nil
               )

      assert PublishedReader.opening(on_page()) == nil

      accept!(ctx, version)
      publish!(ctx, version)
      assert %Opening{} = PublishedReader.opening(on_page())

      {:ok, _} =
        Reviews.decide(ctx.reviewer, version.id, :rejected,
          reason: "P1 #255 test",
          idempotency_key: key("reject")
        )

      assert PublishedReader.opening(on_page()) == nil
    end
  end

  describe "test 7: the scope is the page's words" do
    test "the On page and the exact-word page resolve different compositions", ctx do
      ctx = activate!(ctx)
      on = provision!(ctx)
      noun = provision!(ctx, :lexeme, [ctx.love])
      refute on.id == noun.id
      refute on.scope_signature == noun.scope_signature

      # The exact-word page's own `:lexical_page` scope overlaps the On
      # page's, so it cannot be provisioned beside it (K3): in P1 that page
      # shows nothing (#255 §2.7).
      assert {:error, {:overlapping_scope, [on_id]}} =
               Compositions.provision(ctx.author, ctx.configuration.id, %{
                 scope_kind: :lexical_page,
                 lexeme_ids: [ctx.love.object_id],
                 language_tag: "en",
                 reason: "P1 #255 test"
               })

      assert on_id == on.id

      on_version = love_version!(ctx, on)
      accept!(ctx, on_version)
      publish!(ctx, on_version)

      assert %Opening{composition: %{id: on_id}} = PublishedReader.opening(on_page())
      assert on_id == on.id
      assert PublishedReader.opening(exact_page(ctx.love)) == nil

      # Publishing the noun's own composition puts nothing on either page
      # that is not its own.
      noun_version = love_version!(ctx, noun)
      accept!(ctx, noun_version)
      publish!(ctx, noun_version)

      assert %Opening{composition: %{id: ^on_id}} = PublishedReader.opening(on_page())
      assert PublishedReader.opening(exact_page(ctx.love)) == nil
      assert PublishedReader.opening(exact_page(ctx.verb)) == nil
    end
  end

  describe "test 8: every withheld reason has words" do
    # Every reason `Curation.Eligibility`, `Curation.LeadRule` and
    # `Curation.Published` give, and those this reader adds.
    @reasons ~w(
      revision_superseded revision_deleted revision_withdrawn object_deleted object_missing
      object_retired meaning_deleted meaning_off_scope meaning_mismatch display_restricted
      source_inactive work_identity_mismatch words_changed catalog_changed catalog_row_missing
      claim_deleted claim_not_current claim_not_accepted claim_not_visible claim_not_about_object
      claim_context_changed priority_source_available priority_source_missing lead_not_on_scope
      composition_retired configuration_changed scope_changed approval_withdrawn
      not_on_page meaning_off_page quotation_not_found unsupported_item observation_unbound revision_mismatch retention_expired payload_redacted claim_unlinked
      empty no_prose_opening no_sentence_boundary
    )a

    @fallback DevilsDictionaryWeb.Opening.withheld_reason(:no_such_reason)

    test "the fallback is plain, and nothing raises" do
      assert @fallback == "it could not be resolved"
      assert DevilsDictionaryWeb.Opening.withheld_reason(nil) == @fallback
      assert DevilsDictionaryWeb.Opening.withheld_reason({:ineligible, []}) == @fallback
    end

    for reason <- @reasons do
      test "#{reason} has a label of its own" do
        label = DevilsDictionaryWeb.Opening.withheld_reason(unquote(reason))
        assert is_binary(label) and label != ""
        refute label == @fallback
      end
    end

    # A reason added to the record without a label fails here, not on a page.
    test "the table covers every reason the record's modules name" do
      named =
        for file <- ~w(eligibility lead_rule published),
            source = File.read!("lib/devils_dictionary/curation/#{file}.ex"),
            pattern <- [
              ~r/\{:error, :([a-z_]+)\}/,
              ~r/(?:ensure|need)\((?:.*,\s*)?:([a-z_]+)\)/,
              ~r/^\s+:([a-z_]+)\s*$/m,
              ~r/&& :([a-z_]+)/,
              ~r/\{:[a-z_]+, :([a-z_]+_deleted)\}/
            ],
            [_, name] <- Regex.scan(pattern, source),
            uniq: true,
            do: String.to_atom(name)

      assert :revision_superseded in named
      assert :approval_withdrawn in named
      # `:ok` closes a clause; `:unpublished` and `:not_found` are answers
      # about the composition, which are no opening rather than an item
      # withheld.
      assert named -- (@reasons ++ [:ok, :unpublished, :not_found]) == []
    end
  end
end
