defmodule DevilsDictionary.CreatorIdentityAuditTest do
  @moduledoc """
  #164, the acceptance boxes that are about the pipeline rather than one
  provider: minting, matching, the assertion lifecycle, failures, and the hint
  against the truth. Every run goes through `Discovery.execute_run/1`, so the
  prepare phase, the `wikidata` budget and the publication transaction are the
  real ones; the provider is `FakeQuoteDiscoveryProvider` reading the #158
  fixture, because no real quotation provider may write one until this closes.
  """
  use DevilsDictionary.DataCase, async: false

  import DevilsDictionary.WordFixtures
  import Phoenix.LiveViewTest

  alias DevilsDictionary.Claims
  alias DevilsDictionary.Claims.{Assertion, AssertionRevision}
  alias DevilsDictionary.Discovery
  alias DevilsDictionary.Discovery.{RequestAttempt, Result}
  alias DevilsDictionary.Discovery.Conformance
  alias DevilsDictionary.Encyclopedia.EntityPage
  alias DevilsDictionary.FakeQuoteDiscoveryProvider, as: Quotes
  alias DevilsDictionary.Registry
  alias DevilsDictionary.Registry.{ContentItem, ContentRevision, Entity, ExternalIdentifier}
  alias DevilsDictionary.Registry.PersonDetails
  alias DevilsDictionary.SourceIdentity
  alias DevilsDictionary.SourceIdentity.{Creators, Entry}
  alias DevilsDictionary.Sources
  alias DevilsDictionary.Sources.{MaterializedOutput, ReconciliationCase, Source}
  alias DevilsDictionaryWeb.Culture

  @slug "quote-fixture"

  setup tags do
    catalog = DevilsDictionary.Fixtures.seed_catalog!()

    providers = Application.fetch_env!(:devils_dictionary, :discovery_providers)
    discovery = Application.fetch_env!(:devils_dictionary, :discovery)

    Application.put_env(:devils_dictionary, :discovery_providers, [Quotes])
    # A refresh inside a test must not wait out the cooldown.
    Application.put_env(
      :devils_dictionary,
      :discovery,
      Keyword.put(discovery, :refresh_cooldown_seconds, 0)
    )

    on_exit(fn ->
      Application.put_env(:devils_dictionary, :discovery_providers, providers)
      Application.put_env(:devils_dictionary, :discovery, discovery)
      Quotes.clear_rows()
    end)

    requests = start_supervised!({Agent, fn -> [] end})

    unless tags[:unboxed], do: stub_wikidata(requests)

    %{sources: catalog.sources, scopes: catalog.scopes, requests: requests}
  end

  # ── helpers ───────────────────────────────────────────────────────────────

  # Wikidata as the fixture knows it: Voltaire, plus anything a test adds.
  # Every request is recorded, so a test can say how many were spent.
  defp stub_wikidata(requests, extra \\ %{}) do
    known =
      Quotes.fixture()["wikidata"]
      |> Map.new(fn {qid, facts} ->
        {qid,
         Conformance.human(qid, facts["label"],
           description: facts["description"],
           born: Date.from_iso8601!(facts["born"]),
           died: Date.from_iso8601!(facts["died"])
         )}
      end)
      |> Map.merge(extra)

    stub = fn conn ->
      conn = Plug.Conn.fetch_query_params(conn)
      Agent.update(requests, &[conn.params | &1])

      entities =
        (conn.params["ids"] || "")
        |> String.split("|", trim: true)
        |> Enum.flat_map(fn qid ->
          case Map.get(known, qid) do
            nil -> []
            entity -> [{qid, entity}]
          end
        end)
        |> Map.new()

      Req.Test.json(conn, %{"entities" => entities})
    end

    Req.Test.stub(DevilsDictionary.Absorb.Clients, stub)
  end

  defp entity_requests(requests),
    do: requests |> Agent.get(& &1) |> Enum.count(&Map.has_key?(&1, "ids"))

  defp run!(ctx, term, rows) do
    Quotes.put_rows(term, rows)
    word = find_or_create_word(ctx, term)
    target = target(word)

    run =
      case Discovery.request(target, @slug) do
        {:queued, run} -> run
        {:cached, _run} -> refresh!(target)
      end

    assert :ok = Discovery.execute_run(run.id)
    %{word: word, target: target, run: run, results: results(run)}
  end

  defp refresh!(target) do
    mapping =
      Repo.one!(
        from m in Discovery.Mapping,
          where: m.target_object_id == ^target.object_id,
          order_by: [desc: m.id],
          limit: 1
      )

    {:queued, run} = Discovery.request_mapping(mapping, refresh: true)
    run
  end

  defp rerun!(ctx, term, rows) do
    Quotes.put_rows(term, rows)
    word = find_or_create_word(ctx, term)
    run = refresh!(target(word))
    assert :ok = Discovery.execute_run(run.id)
    %{word: word, target: target(word), run: run, results: results(run)}
  end

  defp find_or_create_word(ctx, term) do
    Registry.lexeme_by_key("en", term, "noun") || word!(ctx, term, ~w(wordnet))
  end

  defp target(word),
    do: %{object_id: word.object_id, term: word.lemma, language: "en", relevance: "term"}

  defp results(run) do
    Repo.all(from r in Result, where: r.run_id == ^run.id, order_by: r.position)
    |> Map.new(&{&1.external_id, &1})
  end

  defp person(qid), do: Registry.by_external_id("wikidata", qid)

  defp authored_by(subject_id),
    do: Claims.outgoing(subject_id, predicate: "authored_by", lifecycle_state: :any)

  defp assertion_for(subject_id) do
    [revision] = authored_by(subject_id)
    Repo.get!(Assertion, revision.assertion_id)
  end

  defp rows(ids), do: Quotes.rows(ids)

  defp with_author(row, qid), do: Map.put(row, "author_qid", qid)

  # ── minting and matching ─────────────────────────────────────────────────

  test "a Voltaire quotation mints Q9068 once; a second quotation reuses the person", ctx do
    assert person("Q9068") == nil

    %{results: %{"voltaire-candide-garden" => garden}} =
      run!(ctx, "garden", rows(~w(voltaire-candide-garden)))

    voltaire_id = person("Q9068")
    assert is_integer(voltaire_id)

    # The quotation is content, resolved like an entity is.
    assert garden.resolution_state == :newly_created
    assert %ContentItem{content_kind: :quotation} = Repo.get!(ContentItem, garden.object_id)

    assert %ContentRevision{body: "We must cultivate our garden.", year: 1759} =
             Registry.current_content_revision(garden.object_id)

    # One authored_by, from the quotation to the person, the provider's own.
    assert [revision] = authored_by(garden.object_id)
    assert revision.object_object_id == voltaire_id
    assert revision.subject_kind == "content" and revision.subject_subkind == "quotation"
    assert revision.object_kind == "entity" and revision.object_subkind == "person"
    assert revision.method == "provider_relationship"
    assert revision.confidence == 1.0

    assert revision.metadata == %{
             "provider" => @slug,
             "adapter_version" => "quote.fixture.v1",
             "certainty" => "verified",
             "provider_identifier" => "wikidata:Q9068"
           }

    assertion = Repo.get!(Assertion, revision.assertion_id)
    assert assertion.origin_key == "authored_by:quote_fixture:voltaire-candide-garden"
    assert assertion.source_id == Sources.get_source_by_slug!(@slug).id
    assert is_integer(assertion.origin_actor_id)

    # A minted person is an ordinary Wikidata-sourced person: a person row, a
    # person_details row, a verified QID pointing at the Wikidata source
    # record revision the mint fetched, and that record's entity output.
    entity = Repo.get!(Entity, voltaire_id)
    assert entity.entity_kind == :person
    assert entity.preferred_label == "Voltaire"
    assert entity.description == "French Enlightenment writer, historian and philosopher"
    assert entity.metadata["minted_by"] == @slug

    assert %PersonDetails{birth_date: ~D[1694-11-21], death_date: ~D[1778-05-30]} =
             Repo.get!(PersonDetails, voltaire_id)

    identifier =
      Repo.get_by!(ExternalIdentifier, namespace: "wikidata", external_id: "Q9068")

    assert identifier.status == :verified
    record = Repo.get_by!(Sources.SourceRecord, external_id: "Q9068")
    assert Repo.get!(Source, record.source_id).slug == "wikidata"
    assert Sources.raw(record)["claims"]["P569"]
    assert identifier.source_record_revision_id

    assert Repo.get_by!(MaterializedOutput,
             source_record_id: record.id,
             output_role: "entity"
           ).output_object_id == voltaire_id

    # The card's hint says so too.
    assert [%{"qid" => "Q9068", "state" => "minted", "object_id" => ^voltaire_id}] =
             garden.preview_metadata["creators"]

    # The fetch was one request, drawn against the `wikidata` budget.
    assert entity_requests(ctx.requests) == 1
    wikidata = Sources.get_source_by_slug!("wikidata")

    assert Repo.aggregate(
             from(a in RequestAttempt, where: a.source_id == ^wikidata.id),
             :count
           ) == 1

    # A second Voltaire line: the person is matched, nothing is minted and
    # nothing is fetched.
    %{results: %{"voltaire-dangerous-right" => dangerous}} =
      run!(ctx, "authority", rows(~w(voltaire-dangerous-right)))

    assert [%{object_object_id: ^voltaire_id}] = authored_by(dangerous.object_id)

    assert [%{"state" => "matched", "object_id" => ^voltaire_id}] =
             dangerous.preview_metadata["creators"]

    assert entity_requests(ctx.requests) == 1

    assert Repo.aggregate(
             from(i in ExternalIdentifier, where: i.external_id == "Q9068"),
             :count
           ) == 1

    # The reverse view: both lines under the person's quotations, not their
    # definitions.
    page = EntityPage.build(voltaire_id)

    assert Enum.map(page.quotations, & &1.object_id) |> Enum.sort() ==
             Enum.sort([garden.object_id, dangerous.object_id])

    assert page.definitions == []
    assert page.pagination.quotations.count == 2
    assert Enum.all?(page.quotations, &match?([%{slug: @slug}], &1.sources))
  end

  test "Bierce's nepotism line resolves to the seeded Ambrose Bierce by QID, never by label",
       ctx do
    bierce_id = person("Q191050")
    assert is_integer(bierce_id), "the catalog seeds Bierce with Q191050"

    # The label on the provider's row is not Bierce's preferred label, and it
    # does not matter: the QID is what is matched.
    row = hd(rows(~w(nepotism-bierce))) |> Map.put("author_display", "A. G. Bierce (sic)")

    %{results: %{"nepotism-bierce" => line}} = run!(ctx, "nepotism", [row])

    assert [%{object_object_id: ^bierce_id}] = authored_by(line.object_id)

    assert [%{"state" => "matched", "object_id" => ^bierce_id}] =
             line.preview_metadata["creators"]

    assert entity_requests(ctx.requests) == 0
  end

  test "a result with no creator identifier keeps its text line and writes nothing", ctx do
    %{target: target, results: %{"nepotism-report-on-business" => line}} =
      run!(ctx, "nepotism", rows(~w(nepotism-report-on-business)))

    assert line.resolution_state == :newly_created
    assert authored_by(line.object_id) == []
    refute Map.has_key?(line.preview_metadata, "creators")

    assert Repo.aggregate(
             from(c in ReconciliationCase, where: c.kind == "unresolved_creator"),
             :count
           ) == 0

    state = Discovery.state(target.object_id, @slug)
    html = render_component(&Culture.section/1, states: %{@slug => state})
    assert html =~ "Report on Business Magazine"
    refute html =~ ~s(id="culture-creator-quote_fixture-nepotism-report-on-business")
  end

  test "an organization is minted as one, and credited through the organization endpoint",
       ctx do
    org =
      "Q900400"
      |> Conformance.human("The Fixture Gazette")
      |> put_in(["claims", "P31"], [
        %{"mainsnak" => %{"datavalue" => %{"value" => %{"id" => "Q11032"}}}, "rank" => "normal"}
      ])

    stub_wikidata(ctx.requests, %{"Q900400" => org})
    row = hd(rows(~w(nepotism-report-on-business))) |> with_author("Q900400")

    %{results: %{"nepotism-report-on-business" => line}} = run!(ctx, "nepotism", [row])

    org_id = person("Q900400")
    assert Repo.get!(Entity, org_id).entity_kind == :organization
    assert is_nil(Repo.get(PersonDetails, org_id))

    assert [%{object_object_id: ^org_id, object_subkind: "organization"}] =
             authored_by(line.object_id)
  end

  test "coauthors cost a row each, keyed by their position", ctx do
    stub_wikidata(ctx.requests, %{"Q900401" => Conformance.human("Q900401", "Second Author")})
    row = hd(rows(~w(voltaire-candide-garden))) |> Map.put("author_qids", ["Q9068", "Q900401"])

    %{results: %{"voltaire-candide-garden" => line}} = run!(ctx, "garden", [row])

    keys =
      Repo.all(
        from a in Assertion,
          join: r in AssertionRevision,
          on: r.assertion_id == a.id and r.is_current,
          where: r.subject_object_id == ^line.object_id,
          order_by: a.origin_key,
          select: {a.origin_key, r.object_object_id}
      )

    assert keys == [
             {"authored_by:quote_fixture:voltaire-candide-garden", person("Q9068")},
             {"authored_by:quote_fixture:voltaire-candide-garden:2", person("Q900401")}
           ]
  end

  # ── the lifecycle (C3) ───────────────────────────────────────────────────

  test "re-running a provider with unchanged output writes no new revision", ctx do
    %{results: %{"voltaire-candide-garden" => first}} =
      run!(ctx, "garden", rows(~w(voltaire-candide-garden)))

    counts = fn ->
      {Repo.aggregate(Assertion, :count), Repo.aggregate(AssertionRevision, :count),
       Repo.aggregate(ContentItem, :count), Repo.aggregate(ContentRevision, :count),
       Repo.aggregate(Entity, :count)}
    end

    before = counts.()

    %{results: %{"voltaire-candide-garden" => second}} =
      rerun!(ctx, "garden", rows(~w(voltaire-candide-garden)))

    assert second.run_id != first.run_id
    assert second.object_id == first.object_id
    assert second.resolution_state == :matched
    assert counts.() == before
  end

  test "a second source's different text is recorded beside the first and does not replace it",
       ctx do
    %{results: %{"voltaire-candide-garden" => first}} =
      run!(ctx, "garden", rows(~w(voltaire-candide-garden)))

    variant =
      hd(rows(~w(voltaire-candide-garden)))
      |> Map.put("text", "Let us cultivate our garden.")

    rerun!(ctx, "garden", [variant])
    rerun!(ctx, "garden", [variant])

    revisions =
      Repo.all(
        from r in ContentRevision,
          where: r.content_id == ^first.object_id,
          order_by: r.revision_number
      )

    assert Enum.map(revisions, &{&1.body, &1.is_current}) == [
             {"We must cultivate our garden.", true},
             {"Let us cultivate our garden.", false}
           ]
  end

  test "a corrected creator is a revision; a dropped one is withdrawn; a restored one reinstated",
       ctx do
    %{results: %{"nepotism-bierce" => line}} =
      run!(ctx, "nepotism", [hd(rows(~w(nepotism-bierce))) |> with_author("Q9068")])

    assertion = assertion_for(line.object_id)
    voltaire_id = person("Q9068")
    bierce_id = person("Q191050")

    # A → B: the provider now names Bierce.
    rerun!(ctx, "nepotism", rows(~w(nepotism-bierce)))

    [first, second] = Claims.history(assertion.id)
    assert {first.object_object_id, first.is_current} == {voltaire_id, false}
    assert {second.object_object_id, second.is_current} == {bierce_id, true}
    assert second.lifecycle_state == :active
    assert Repo.aggregate(from(a in Assertion, where: a.id == ^assertion.id), :count) == 1

    # B → nobody: withdrawn, with the reason.
    rerun!(ctx, "nepotism", [hd(rows(~w(nepotism-bierce))) |> with_author(nil)])

    current = Claims.current_revision(assertion.id)
    assert current.lifecycle_state == :withdrawn
    assert current.rationale == Creators.removed_reason()
    assert Claims.outgoing(line.object_id, predicate: "authored_by") == []

    # Nobody → B again: the provider's own withdrawal is reinstated.
    rerun!(ctx, "nepotism", rows(~w(nepotism-bierce)))

    current = Claims.current_revision(assertion.id)
    assert current.lifecycle_state == :active
    assert current.object_object_id == bierce_id
    assert length(Claims.history(assertion.id)) == 4
  end

  test "a human withdrawal is never reinstated by a provider refresh", ctx do
    %{results: %{"nepotism-bierce" => line}} = run!(ctx, "nepotism", rows(~w(nepotism-bierce)))
    assertion = assertion_for(line.object_id)

    {:ok, _} = Claims.withdraw(assertion.id, reason: "curator: not this Bierce")

    %{results: %{"nepotism-bierce" => again}} = rerun!(ctx, "nepotism", rows(~w(nepotism-bierce)))

    assert Claims.current_revision(assertion.id).rationale == "curator: not this Bierce"
    assert [%{"state" => "overridden"}] = again.preview_metadata["creators"]
  end

  test "a revision the provider did not write survives a refresh and is reported overridden",
       ctx do
    %{results: %{"nepotism-bierce" => line}} = run!(ctx, "nepotism", rows(~w(nepotism-bierce)))
    assertion = assertion_for(line.object_id)
    bierce_id = person("Q191050")

    # A verifier (build 5) or a curator writes over the provider's revision.
    {:ok, verified} =
      Claims.revise(assertion.id, %{
        method: "primary_text_verifier",
        confidence: 0.95,
        metadata: %{"verifier" => "gutenberg"}
      })

    # The provider now names somebody else. It does not win.
    %{results: %{"nepotism-bierce" => again}} =
      rerun!(ctx, "nepotism", [hd(rows(~w(nepotism-bierce))) |> with_author("Q9068")])

    assert Claims.current_revision(assertion.id).id == verified.id

    assert [%{"state" => "overridden", "object_id" => ^bierce_id}] =
             again.preview_metadata["creators"]

    # A review decision protects a provider revision the same way.
    %{results: %{"voltaire-candide-garden" => garden}} =
      run!(ctx, "garden", rows(~w(voltaire-candide-garden)))

    garden_assertion = assertion_for(garden.object_id)
    reviewed = Claims.current_revision(garden_assertion.id)
    {:ok, _} = Claims.review(reviewed.id, :accepted)

    rerun!(ctx, "garden", [hd(rows(~w(voltaire-candide-garden))) |> with_author(nil)])
    assert Claims.current_revision(garden_assertion.id).id == reviewed.id
  end

  # ── misattribution (C4) ──────────────────────────────────────────────────

  test "a register row never yields an authored_by, and the person page shows it apart", ctx do
    %{results: %{"voltaire-misattributed-defend" => line}} =
      run!(ctx, "defend", rows(~w(voltaire-misattributed-defend)))

    voltaire_id = person("Q9068")
    assert authored_by(line.object_id) == []

    assert [%{object_object_id: ^voltaire_id, confidence: 0.5}] =
             Claims.outgoing(line.object_id, predicate: "misattributed_to")

    page = EntityPage.build(voltaire_id)
    assert Enum.map(page.misattributed, & &1.object_id) == [line.object_id]
    assert page.quotations == []
    assert page.pagination.misattributed.count == 1

    # And the kit refuses the combination outright, whatever a provider sends.
    assert {:error, :register_target_cannot_be_authored_by} =
             Entry.new(%{
               source_slug: @slug,
               object_kind: :content,
               content_kind: :quotation,
               stable_identifier: %{namespace: "quote_fixture", external_id: "x"},
               label: "x",
               content: %{body: "x"},
               relationships: [
                 %{
                   role: "authored_by",
                   register: true,
                   target_identifiers: [%{namespace: "wikidata", external_id: "Q9068"}],
                   certainty: :candidate
                 }
               ]
             })
  end

  # ── the reader (C5) ──────────────────────────────────────────────────────

  test "a resolved quotation is never an entry: no /entities link, an evidence link instead",
       ctx do
    %{target: target, results: %{"voltaire-candide-garden" => garden}} =
      run!(ctx, "garden", rows(~w(voltaire-candide-garden)))

    state = Discovery.state(target.object_id, @slug)
    [item] = state.items
    assert item.object_kind == :content

    html = render_component(&Culture.section/1, states: %{@slug => state})
    doc = LazyHTML.from_fragment(html)

    refute html =~ "/entities/#{garden.object_id}/"
    revision = Registry.current_content_revision(garden.object_id)

    assert LazyHTML.query(doc, "#culture-evidence-voltaire-candide-garden")
           |> LazyHTML.attribute("href") == ["/evidence/content/#{revision.id}"]

    # The creator is linked, and it is the person, not the quotation.
    voltaire_id = person("Q9068")

    assert LazyHTML.query(doc, "#culture-creator-quote_fixture-voltaire-candide-garden a")
           |> LazyHTML.attribute("href")
           |> hd() =~ "/entities/#{voltaire_id}/voltaire"
  end

  test "the creator link is the assertion as it is now: withdrawing it unlinks the next render",
       ctx do
    %{target: target, results: %{"voltaire-candide-garden" => garden}} =
      run!(ctx, "garden", rows(~w(voltaire-candide-garden)))

    render = fn ->
      state = Discovery.state(target.object_id, @slug)
      render_component(&Culture.section/1, states: %{@slug => state})
    end

    assert render.() =~ ~s(id="culture-creator-quote_fixture-voltaire-candide-garden")

    assertion = assertion_for(garden.object_id)
    {:ok, _} = Claims.withdraw(assertion.id, reason: "curator")

    # Nothing was invalidated and the hint still says minted; the card reads
    # the truth.
    assert [%{"state" => "minted"}] =
             Repo.get!(Result, garden.id).preview_metadata["creators"]

    html = render.()
    refute html =~ ~s(id="culture-creator-quote_fixture-voltaire-candide-garden")
    refute html =~ "/entities/#{person("Q9068")}/"
  end

  # ── failures (C7) ────────────────────────────────────────────────────────

  test "a 429 during prepare defers the relationship; the next refresh resolves it", ctx do
    Req.Test.stub(DevilsDictionary.Absorb.Clients, fn conn ->
      conn
      |> Plug.Conn.put_resp_header("retry-after", "30")
      |> Plug.Conn.send_resp(429, "")
    end)

    %{results: %{"voltaire-candide-garden" => garden}} =
      run!(ctx, "garden", rows(~w(voltaire-candide-garden)))

    # The quotation itself is durable; its credit waits.
    assert garden.resolution_state == :newly_created
    assert [%{"state" => "deferred", "object_id" => nil}] = garden.preview_metadata["creators"]
    assert person("Q9068") == nil
    assert authored_by(garden.object_id) == []
    assert Repo.aggregate(ReconciliationCase, :count) == 0

    stub_wikidata(ctx.requests)

    %{results: %{"voltaire-candide-garden" => again}} =
      rerun!(ctx, "garden", rows(~w(voltaire-candide-garden)))

    assert [%{"state" => "minted"}] = again.preview_metadata["creators"]
    assert [%{object_object_id: voltaire_id}] = authored_by(again.object_id)
    assert voltaire_id == person("Q9068")
  end

  test "an exhausted wikidata budget defers rather than fetching", ctx do
    discovery = Application.fetch_env!(:devils_dictionary, :discovery)

    policies =
      discovery[:source_policies]
      |> Map.put("wikidata", request_budget_limit: 1, request_budget_window_seconds: 3_600)

    Application.put_env(
      :devils_dictionary,
      :discovery,
      Keyword.put(discovery, :source_policies, policies)
    )

    %{run: spent} = run!(ctx, "nepotism", rows(~w(nepotism-report-on-business)))

    Repo.insert!(%RequestAttempt{
      run_id: spent.id,
      source_id: Sources.get_source_by_slug!("wikidata").id,
      stage: "wikidata:entity",
      attempted_at: DateTime.utc_now()
    })

    %{results: %{"voltaire-candide-garden" => garden}} =
      run!(ctx, "garden", rows(~w(voltaire-candide-garden)))

    assert [%{"state" => "deferred"}] = garden.preview_metadata["creators"]
    assert entity_requests(ctx.requests) == 0
  end

  test "an identifier Wikidata cannot supply opens one case per source and QID, never two",
       ctx do
    city =
      "Q900402"
      |> Conformance.human("Somewhere")
      |> put_in(["claims", "P31"], [
        %{"mainsnak" => %{"datavalue" => %{"value" => %{"id" => "Q515"}}}, "rank" => "normal"}
      ])

    stub_wikidata(ctx.requests, %{"Q900402" => city})

    missing = hd(rows(~w(voltaire-candide-garden))) |> with_author("Q900499")
    not_creator = hd(rows(~w(voltaire-dangerous-right))) |> with_author("Q900402")

    %{results: results} = run!(ctx, "garden", [missing, not_creator])
    rerun!(ctx, "garden", [missing, not_creator])

    cases =
      Repo.all(
        from c in ReconciliationCase,
          where: c.kind == "unresolved_creator" and c.status == :open,
          order_by: c.payload["qid"]
      )

    assert Enum.map(cases, &{&1.payload["qid"], &1.payload["reason"]}) == [
             {"Q900402", "not_a_creator_kind"},
             {"Q900499", "missing"}
           ]

    assert Enum.all?(cases, &(&1.payload["provider_creator"] == "Voltaire"))

    for {_id, result} <- results do
      assert [%{"state" => "unresolved"}] = result.preview_metadata["creators"]
      assert authored_by(result.object_id) == []
    end

    assert person("Q900402") == nil
  end

  test "a creator the registry already holds is matched without a prepare step", ctx do
    # `resolve/2` with nothing prepared: a held QID needs no network; an absent
    # one is deferred rather than fetched inside the transaction.
    source = Sources.get_source_by_slug!("wikidata")

    entry = fn id, qid ->
      {:ok, entry} =
        Entry.new(%{
          source_slug: "wikidata",
          source_id: source.id,
          object_kind: :content,
          content_kind: :quotation,
          stable_identifier: %{namespace: "fixture_line", external_id: id},
          label: id,
          content: %{body: id},
          relationships: [
            %{
              role: "authored_by",
              target_identifiers: [%{namespace: "wikidata", external_id: qid}],
              certainty: :candidate
            }
          ]
        })

      entry
    end

    held = SourceIdentity.resolve(entry.("held", "Q191050"))
    assert [%{state: :matched, object_id: bierce}] = held.relationships
    assert bierce == person("Q191050")
    assert [%{confidence: 0.5}] = authored_by(held.object_id)

    absent = SourceIdentity.resolve(entry.("absent", "Q9068"))
    assert [%{state: :deferred, reason: "not_prepared"}] = absent.relationships
    assert entity_requests(ctx.requests) == 0
  end

  test "an Open Library author key is crosswalked by P648 once and cached on the person", ctx do
    source = Sources.get_source_by_slug!("open-library")
    searches = start_supervised!({Agent, fn -> 0 end}, id: :searches)

    Req.Test.stub(DevilsDictionary.Absorb.Clients, fn conn ->
      conn = Plug.Conn.fetch_query_params(conn)

      case conn.params do
        %{"action" => "query", "srsearch" => "haswbstatement:P648=OL900003A"} ->
          Agent.update(searches, &(&1 + 1))
          Req.Test.json(conn, %{"query" => %{"search" => [%{"title" => "Q9068"}]}})

        %{"ids" => "Q9068"} ->
          Req.Test.json(conn, %{
            "entities" => %{"Q9068" => Conformance.human("Q9068", "Voltaire")}
          })
      end
    end)

    entry = fn work ->
      {:ok, entry} =
        Entry.new(%{
          source_slug: "open-library",
          source_id: source.id,
          object_kind: :entity,
          entity_kind: :work,
          work_kind: "book",
          stable_identifier: %{namespace: "olid", external_id: work},
          label: work,
          relationships: [
            %{
              role: "authored_by",
              target_identifiers: [%{namespace: "olid", external_id: "OL900003A"}],
              certainty: :verified
            }
          ]
        })

      entry
    end

    claim = fn _stage -> {:ok, 0} end
    first = entry.("OL900010W")
    prepared = Creators.prepare([first], claim: claim)
    assert prepared[{"olid", "OL900003A"}] == {:ok, "Q9068"}

    resolution = SourceIdentity.resolve(first, prepared: prepared)
    assert [%{state: :minted, qid: "Q9068", object_id: voltaire_id}] = resolution.relationships
    assert Registry.by_external_id("olid", "OL900003A") == voltaire_id

    # The next work by the same author: the key is held, nothing is asked.
    second = entry.("OL900011W")
    assert Creators.prepare([second], claim: claim) == %{}

    assert [%{state: :matched, object_id: ^voltaire_id}] =
             SourceIdentity.resolve(second, prepared: %{}).relationships

    assert Agent.get(searches, & &1) == 1
    _ = ctx
  end

  test "classification: a redirected or missing item is permanent, a human is mintable" do
    human = Conformance.human("Q1", "One")
    assert {:ok, %{kind: :person, label: "One"}} = Creators.classify("Q1", %{"Q1" => human})
    assert {:permanent, :missing} = Creators.classify("Q2", %{})

    assert {:permanent, :redirected} =
             Creators.classify("Q3", %{"Q4" => Map.put(human, "redirects", %{"from" => "Q3"})})
  end

  # ── concurrency (C1) ─────────────────────────────────────────────────────

  @tag :unboxed
  test "two runs crediting one absent QID at once mint one person and write two assertions",
       ctx do
    parent = self()
    requests = ctx.requests

    Quotes.put_rows("garden", rows(~w(voltaire-candide-garden)))
    Quotes.put_rows("authority", rows(~w(voltaire-dangerous-right)))

    runs =
      for term <- ~w(garden authority) do
        {:queued, run} = Discovery.request(target(word!(ctx, term, ~w(wordnet))), @slug)
        run
      end

    gate = make_ref()

    tasks =
      for run <- runs do
        Task.async(fn ->
          # Each task owns its stub: Req.Test stubs are per process.
          stub_wikidata(requests)
          send(parent, {:ready, self()})
          receive do: ({:go, ^gate} -> Discovery.execute_run(run.id))
        end)
      end

    for _ <- tasks, do: assert_receive({:ready, _pid}, 5_000)
    Enum.each(tasks, fn task -> send(task.pid, {:go, gate}) end)
    assert Enum.map(tasks, &Task.await(&1, 15_000)) == [:ok, :ok]

    assert Repo.aggregate(
             from(i in ExternalIdentifier,
               where: i.namespace == "wikidata" and i.external_id == "Q9068"
             ),
             :count
           ) == 1

    voltaire_id = person("Q9068")

    assert Repo.aggregate(
             from(r in AssertionRevision,
               where: r.object_object_id == ^voltaire_id and r.is_current
             ),
             :count
           ) == 2

    states =
      Repo.all(from r in Result, where: r.run_id in ^Enum.map(runs, & &1.id))
      |> Enum.flat_map(& &1.preview_metadata["creators"])
      |> Enum.map(& &1["state"])
      |> Enum.sort()

    # Both prepared the fetch (neither held Q9068 when it looked); one minted
    # under the lock, and the other found that person when it got the lock.
    assert states == ["matched", "minted"]
  end

  # ── #164 audit residuals ─────────────────────────────────────────────────

  test "a provider adapter-version bump alone writes no new revision", ctx do
    %{results: %{"voltaire-candide-garden" => result}} =
      run!(ctx, "garden", rows(~w(voltaire-candide-garden)))

    [revision] = authored_by(result.object_id)
    assert revision.metadata["adapter_version"] == Quotes.adapter_version()
    revisions_before = Repo.aggregate(AssertionRevision, :count)

    record = Repo.get!(Sources.SourceRecord, result.source_record_id)

    revision =
      Repo.one!(
        from r in DevilsDictionary.Corpus.SourceRecordRevision,
          where: r.source_record_id == ^record.id and r.revision_key == ^record.content_hash
      )

    source = Repo.get_by!(Source, slug: @slug)
    [row] = rows(~w(voltaire-candide-garden))

    {:ok, entry} = Quotes.identity_record(%{external_namespace: "quote_fixture", row: row})

    resolution =
      entry
      |> Map.merge(%{
        source_id: source.id,
        source_record_id: record.id,
        source_record_revision_id: revision.id
      })
      |> SourceIdentity.resolve(prepared: %{}, adapter_version: "quote.fixture.v2")

    assert resolution.state == :matched
    assert [%{state: :matched, write: :unchanged}] = resolution.relationships
    assert Repo.aggregate(AssertionRevision, :count) == revisions_before

    assert [%{metadata: %{"adapter_version" => "quote.fixture.v1"}}] =
             authored_by(result.object_id)
  end

  test "a creator QID held as an untyped concept stays text and opens a case", ctx do
    {:ok, concept} =
      Registry.create_entity(%{entity_kind: :concept, preferred_label: "Voltaire, as a topic"})

    {:ok, _} = Registry.add_external_id(concept.object_id, "wikidata", "Q9068", %{})

    %{results: %{"voltaire-candide-garden" => result}} =
      run!(ctx, "garden", rows(~w(voltaire-candide-garden)))

    assert entity_requests(ctx.requests) == 0, "a held QID is never fetched"
    assert authored_by(result.object_id) == []

    assert [%{"state" => "unresolved", "qid" => "Q9068", "object_id" => nil}] =
             result.preview_metadata["creators"]

    assert [case] =
             Repo.all(
               from c in ReconciliationCase,
                 where: c.kind == "unresolved_creator" and c.status == :open
             )

    assert case.payload["qid"] == "Q9068"
    assert case.payload["reason"] == "endpoint_not_allowed"
    assert person("Q9068") == concept.object_id, "nothing was minted beside the concept"

    # A second run finds the open case and does not open another.
    rerun!(ctx, "garden", rows(~w(voltaire-candide-garden)))
    assert Repo.aggregate(ReconciliationCase, :count) == 1
  end
  @tag :audit_probe
  test "audit: changing author to an unresolved QID removes the previous public credit", ctx do
    %{results: %{"nepotism-bierce" => line}} = run!(ctx, "nepotism", rows(~w(nepotism-bierce)))
    corrected = hd(rows(~w(nepotism-bierce))) |> with_author("Q900999")
    %{results: %{"nepotism-bierce" => again}} = rerun!(ctx, "nepotism", [corrected])
    assert [%{"state" => "unresolved"}] = again.preview_metadata["creators"]
    assert Claims.outgoing(line.object_id, predicate: "authored_by") == []
  end

  @tag :audit_probe
  test "audit: a register arriving before a credit still supplies contradicting evidence", ctx do
    base = hd(rows(~w(voltaire-candide-garden)))
    register = base |> Map.put("id", "garden-register") |> with_author(nil) |> Map.put("misattributed_to_qid", "Q9068")
    run!(ctx, "register-first", [register])
    %{results: %{"voltaire-candide-garden" => line}} = run!(ctx, "credit-later", [base])
    [credit] = Claims.outgoing(line.object_id, predicate: "authored_by")
    assert Enum.any?(Claims.evidence(credit.id), &(&1.evidence_role == :contradicts))
  end

  @tag :audit_probe
  test "audit: two incompatible target QIDs cannot silently credit the first", ctx do
    run!(ctx, "source-setup", rows(~w(nepotism-report-on-business)))
    source = Repo.get_by!(Source, slug: @slug)
    [row] = rows(~w(voltaire-candide-garden))
    {:ok, entry} = Quotes.identity_record(%{external_namespace: "quote_fixture", row: row})
    [relationship] = entry.relationships
    conflicting = %{relationship | target_identifiers: [
      %{namespace: "wikidata", external_id: "Q191050", metadata: %{}, exclusive: true},
      %{namespace: "wikidata", external_id: "Q9068", metadata: %{}, exclusive: true}
    ]}
    entry = %{entry | source_id: source.id, relationships: [conflicting]}
    resolution = SourceIdentity.resolve(entry)
    assert [%{state: :unresolved}] = resolution.relationships
    assert Claims.outgoing(resolution.object_id, predicate: "authored_by") == []
  end

  @tag :audit_probe
  test "audit: merging a work preserves the creators on its card", ctx do
    %{results: %{"voltaire-candide-garden" => line}} = run!(ctx, "garden", rows(~w(voltaire-candide-garden)))
    {:ok, survivor} = Registry.create_content(%{content_kind: :quotation, body: "We must cultivate our garden."})
    {:ok, _} = Registry.merge([line.object_id], survivor.object_id, reason: "audit duplicate identity")
    assert [_] = Claims.outgoing(survivor.object_id, predicate: "authored_by")
    assert [_] = Map.fetch!(Creators.credited([survivor.object_id]), survivor.object_id)
  end

end
