defmodule DevilsDictionary.Curation.WholeEntryTest do
  use DevilsDictionary.DataCase, async: false
  import DevilsDictionary.CurationFixtures
  import DevilsDictionary.RefreshFixtures
  import DevilsDictionary.ProposalFixtures
  import DevilsDictionary.RuntimeFixtures
  import Phoenix.ConnTest
  @endpoint DevilsDictionaryWeb.Endpoint
  alias DevilsDictionary.Curation.{
    Configurations,
    Profiles,
    Compositions,
    Receipt,
    WholeEntry,
    CompositionVersion,
    CompositionPublication
  }

  alias DevilsDictionary.Curation.Agents.Persona
  alias DevilsDictionary.Curation.Runtime.{Packet, Contract}

  @namespaces %{
    "guardian" => "guardian_article",
    "bing-news" => "news_article",
    "spotify" => "spotify_track",
    "pexels" => "pexels_photo",
    "unsplash" => "unsplash_photo",
    "openverse" => "openverse_media",
    "commons" => "commons_file",
    "met" => "met_object",
    "cinegraph" => "tmdb_movie",
    "open-library" => "olid",
    "poetrydb" => "poetrydb_poem",
    "wikiquote" => "wikiquote_item"
  }
  setup do
    w = love_world!()

    config =
      model_config!(%{
        instruction_version: WholeEntry.instruction(),
        output_contract_version: "selection-output-v2",
        tag: "9b"
      })
      |> ready!()

    {:ok, seed} = Persona.prepare(w.reviewer, config, reason: "test whole-entry lens")

    {:ok, profile} =
      Profiles.admit(w.reviewer, seed.profile.id, seed.version.id,
        reason: "same reviewed source dossier, new bounded instruction",
        bot_actor_id: seed.bot_actor.id
      )

    attrs = %{
      reason: "whole-entry test",
      selection_scope: "whole_entry_v1",
      editor_publication: "single_editor_v1",
      refresh_window: 86_400,
      editor: %{
        profile_id: profile.id,
        profile_version_id: seed.version.id,
        model_config_id: config.id
      }
    }

    {:ok, version} = Configurations.create_version(w.reviewer, w.configuration.id, attrs)

    {:ok, _} =
      Configurations.activate(w.reviewer, w.configuration.id, version.id,
        reason: "test",
        idempotency_key: key(),
        expected: w.configuration_version.id
      )

    w =
      Map.merge(w, %{
        model_config: config,
        bot: seed.bot_actor,
        profile: profile,
        profile_version: seed.version,
        configuration_version: version,
        editor_version: version,
        attrs: attrs,
        runtime: bind!(service_key: key(), actor_id: seed.bot_actor.id)
      })

    w = Map.put(w, :composition, provision!(w))
    enable!(w)
    w
  end

  defp packet do
    {:ok, packet} = Packet.for_page(page("love"), instruction_version: WholeEntry.instruction())
    {:ok, frozen} = Packet.freeze(packet)
    frozen
  end

  defp answer_all(frozen) do
    lead =
      Enum.find(
        frozen.packet["candidates"],
        &(&1["candidate_id"] in frozen.packet["priority_candidates"])
      )

    choices =
      frozen.packet["candidates"]
      |> Enum.reject(&(&1 == lead))
      |> Enum.group_by(&WholeEntry.section/1)
      |> Enum.flat_map(fn {section, rows} -> Enum.take(rows, WholeEntry.limit(section)) end)
      |> Enum.take(12)

    selection(
      lead && {lead["candidate_id"], lead["required_meaning"]},
      Enum.map(choices, &{&1["candidate_id"], &1["required_meaning"], nil})
    )
  end

  test "v4 covers all seven shelf types, offers bounded diverse material, publishes grouped choices",
       w do
    for provider <- DevilsDictionary.Curation.Shelf.providers(),
        do:
          DevilsDictionary.CitationFixtures.observation!(w, provider,
            namespace: @namespaces[provider]
          )

    frozen = packet()
    assert frozen.packet["packet_version"] == "runtime-packet-v4"
    assert length(frozen.packet["candidates"]) <= 24
    assert length(frozen.packet["meanings"]) <= 12
    assert :ok = Packet.verify(frozen)
    shelves = Enum.filter(frozen.packet["candidates"], &(&1["kind"] == "shelf"))

    assert Enum.sort(Enum.uniq(Enum.map(shelves, &WholeEntry.section/1))) ==
             Enum.sort(DevilsDictionary.Curation.Shelf.kinds())

    assert length(answer_all(frozen)["highlights"]) > 3
    assert Contract.schema(frozen.packet)["properties"]["highlights"]["maxItems"] == 12
    stub_answer!(w, answer_all(frozen))
    assert {:ok, %{last_outcome_reason: "published_automatically"}} = run!(w)
    settle!()
    receipt = Repo.one!(CompositionPublication)
    v = Repo.get!(CompositionVersion, receipt.published_version_id)
    assert length(Compositions.items(v.id)) > 4
    assert {:ok, history} = Receipt.read("love", v.version)
    assert Enum.all?(history.items, &(&1.chooser.attempt_id == v.attempt_id))
    conn = build_conn() |> get("/on/love")
    html = html_response(conn, 200)
    assert html =~ "curation-summary"
    assert html =~ "Selected definition"
    assert html =~ "curated-news"
    assert html =~ "curated-images"
    assert html =~ "curated-quotes"
    assert html =~ "Voltaire"
  end

  test "packet and output contract cannot mix whole-entry and legacy versions", _w do
    frozen = packet()

    assert {:error, :packet_instruction_mismatch} =
             Packet.freeze(Map.put(frozen.packet, "instruction_version", "generic-editor-v2"))

    assert {:error, :packet_instruction_mismatch} =
             Packet.freeze(Map.put(frozen.packet, "packet_version", "runtime-packet-v3"))

    assert Contract.schema()["properties"]["highlights"]["maxItems"] == 3

    assert {:ok, _} =
             Packet.freeze(
               DevilsDictionary.Curation.Runtime.smoke_packet(WholeEntry.instruction())
             )
  end

  test "configuration requires coherent scope, instruction and limit", w do
    assert {:error, :incoherent_whole_entry_configuration} =
             Configurations.create_version(
               w.reviewer,
               w.configuration.id,
               Map.delete(w.attrs, :selection_scope)
             )

    assert {:error, :incoherent_whole_entry_configuration} =
             Configurations.create_version(
               w.reviewer,
               w.configuration.id,
               Map.put(w.attrs, :max_highlights, 3)
             )

    assert w.editor_version.max_highlights == 12
    assert Configurations.ready?(w.editor_version)
  end

  test "final section cap preserves kept precedence", w do
    item = %DevilsDictionary.Curation.CompositionItem{
      item_kind: :sense_quotation,
      role: :highlight,
      position: 1
    }

    plan = [
      {:copy, %{item | id: 1}},
      {:copy, %{item | id: 2, position: 2}},
      {:model, %{item | position: 3}}
    ]

    assert [{:copy, _}, {:copy, _}] = WholeEntry.limit_plan(plan)

    assert {:error, _} =
             Compositions.create_version(w.reviewer, w.composition.id, %{
               reason: "bad cap",
               lead: content_spec(w.bierce, w.love),
               highlights: [],
               expected_parent: 123
             })
  end

  test "shelf round robin accounts for every candidate beyond24 in one section" do
    queue = for id <- 1..40, do: %{packet: %{"shelf" => %{"shelf_kind" => "images"}}, sort: id}
    ordered = WholeEntry.shelf_order(queue, 0)
    assert length(ordered) == 40
    assert Enum.sort(Enum.map(ordered, & &1.sort)) == Enum.to_list(1..40)
  end

  test "no Bierce: exact sense definition leads and links to an actual source card", w do
    source = DevilsDictionary.Sources.get_source_by_slug("bierce")
    source |> Ecto.Changeset.change(active: false) |> Repo.update!()
    frozen = packet()
    definition = Enum.find(frozen.packet["candidates"], &(&1["kind"] == "sense_definition"))
    assert definition
    stub_answer!(w, selection({definition["candidate_id"], definition["required_meaning"]}, []))
    assert {:ok, %{last_outcome_reason: "published_automatically"}} = run!(w)
    settle!()

    opening =
      DevilsDictionary.Curation.Opening.for_page(
        page("love"),
        DevilsDictionary.Curation.PublishedReader
      )

    assert opening.lead.reference.sense_revision_id == definition["sense_revision_id"]

    assert opening.lead.excerpt.text ==
             Repo.get!(DevilsDictionary.Registry.SenseRevision, definition["sense_revision_id"]).gloss

    html = build_conn() |> get("/on/love") |> html_response(200)
    assert html =~ ~s(id="#{opening.lead.links.card_id}")
    assert html =~ ~s(href="##{opening.lead.links.card_id}")
    assert html =~ "Selected definition"
  end

  defp legacy!(w) do
    original =
      Repo.get_by!(DevilsDictionary.Curation.ConfigurationVersion,
        configuration_id: w.configuration.id,
        version: 1
      )

    {:ok, _} =
      Configurations.activate(w.reviewer, w.configuration.id, original.id,
        reason: "legacy test",
        idempotency_key: key(),
        expected: w.editor_version.id
      )

    original
  end

  test "legacy configuration retains three slots and does not offer a sense lead", w do
    legacy = legacy!(w)
    assert legacy.max_highlights == 3
    candidates = DevilsDictionary.Curation.Candidates.for_page(page("love"))
    refute Enum.any?(candidates.leads, &(&1.kind == :sense_definition))
    candidate = Enum.find(candidates.highlights, &(&1.kind == :sense_definition))

    assert {:error, :lead_not_on_scope} =
             Compositions.create_version(w.reviewer, w.composition.id, %{
               lead: candidate.spec,
               highlights: [],
               reason: "not permitted under legacy",
               expected_parent: nil
             })

    {:ok, old} = Packet.for_page(page("love"), instruction_version: "generic-editor-v2")
    assert old["packet_version"] == "runtime-packet-v3"
    assert length(old["candidates"]) <= 12
    assert Contract.schema(old)["properties"]["highlights"]["maxItems"] == 3
  end

  test "raw SQL cannot widen a configuration without whole-entry opt-in", w do
    manifest = Map.delete(w.editor_version.manifest, "selection_scope")

    assert {:refused, _, message} =
             refused(fn ->
               Repo.insert!(%DevilsDictionary.Curation.ConfigurationVersion{
                 configuration_id: w.configuration.id,
                 version: 999,
                 manifest: manifest,
                 manifest_hash: DevilsDictionary.Curation.Digest.term(manifest),
                 lead_policy: :bierce_first_v1,
                 max_highlights: 12,
                 roster_hash: w.editor_version.roster_hash,
                 created_by_actor_id: w.editor_version.created_by_actor_id,
                 change_reason: "forged limit"
               })
             end)

    assert message =~ "curation_configuration_versions_shape"
  end

  test "raw SQL cannot append a fourth highlight under a legacy configuration", w do
    legacy!(w)
    publication = publish!(w, w.composition)
    item = Enum.find(Compositions.items(publication.version.id), &(&1.role == :highlight))

    assert {:refused, _, message} =
             refused(fn ->
               Repo.query!("SET CONSTRAINTS editorial_whole_entry_limits IMMEDIATE")
               Repo.insert!(%{item | id: nil, position: 4, copied_from_item_id: nil})
             end)

    assert message =~ "editorial_composition_items_shape"
  end

  test "raw SQL cannot insert a sense lead under a legacy configuration", w do
    legacy!(w)
    source = DevilsDictionary.Sources.get_source_by_slug("bierce")
    source |> Ecto.Changeset.change(active: false) |> Repo.update!()
    candidates = DevilsDictionary.Curation.Candidates.for_page(page("love"))
    sense = Enum.find(candidates.highlights, &(&1.kind == :sense_definition))
    quote = Enum.find(candidates.highlights, &(&1.kind == :sense_quotation))

    {:ok, version} =
      Compositions.create_version(w.reviewer, w.composition.id, %{
        lead: nil,
        highlights: [Map.put(quote.spec, :note, %{text: "Fixture quotation."})],
        reason: "legacy",
        expected_parent: nil
      })

    assert {:refused, _, message} =
             refused(fn ->
               Repo.query!("SET CONSTRAINTS editorial_whole_entry_limits IMMEDIATE")

               Repo.insert!(%{
                 sense.item
                 | id: nil,
                   composition_version_id: version.id,
                   role: :lead,
                   position: 1
               })
             end)

    assert message =~ "editorial_composition_items_shape"
  end

  test "expiry remains visibly withheld in grouped whole-entry presentation", w do
    DevilsDictionary.CitationFixtures.observation!(w)
    frozen = packet()
    stub_answer!(w, answer_all(frozen))
    assert {:ok, %{last_outcome_reason: "published_automatically"}} = run!(w)
    settle!()
    config = Application.fetch_env!(:devils_dictionary, :discovery)
    policies = Keyword.get(config, :source_policies, %{})

    Application.put_env(
      :devils_dictionary,
      :discovery,
      Keyword.put(config, :source_policies, Map.put(policies, "guardian", retention_seconds: 0))
    )

    on_exit(fn -> Application.put_env(:devils_dictionary, :discovery, config) end)
    html = build_conn() |> get("/on/love") |> html_response(200)
    assert html =~ "curated-unavailable"
    assert html =~ "retention"
    refute html =~ "No item selected in this version"
  end

  test "section clipping cannot publish a kept-only replacement", w do
    first = DevilsDictionary.CitationFixtures.observation!(w)
    frozen = packet()

    lead =
      Enum.find(
        frozen.packet["candidates"],
        &(&1["candidate_id"] in frozen.packet["priority_candidates"])
      )

    news =
      Enum.find(
        frozen.packet["candidates"],
        &(&1["kind"] == "shelf" && &1["shelf"]["result"] == first.result.id)
      )

    stub_answer!(
      w,
      selection({lead["candidate_id"], lead["required_meaning"]}, [
        {news["candidate_id"], news["required_meaning"], nil}
      ])
    )

    assert {:ok, %{last_outcome_reason: "published_automatically"}} = run!(w)
    settle!()
    receipt = Repo.one!(CompositionPublication)

    for item <- Compositions.items(receipt.published_version_id),
        do: Compositions.keep(w.reviewer, w.composition.id, item.id, [])

    next =
      DevilsDictionary.CitationFixtures.observation!(w, "bing-news", namespace: "news_article")

    frozen = packet()

    lead =
      Enum.find(
        frozen.packet["candidates"],
        &(&1["candidate_id"] in frozen.packet["priority_candidates"])
      )

    news =
      Enum.find(
        frozen.packet["candidates"],
        &(&1["kind"] == "shelf" && &1["shelf"]["result"] == next.result.id)
      )

    stub_answer!(
      w,
      selection({lead["candidate_id"], lead["required_meaning"]}, [
        {news["candidate_id"], news["required_meaning"], nil}
      ])
    )

    outcome = run!(w)
    assert {:ok, %{last_outcome: :no_change, last_outcome_reason: "kept_only"}} = outcome
    settle!()
    assert Repo.aggregate(CompositionVersion, :count) == 1
    assert Repo.aggregate(CompositionPublication, :count) == 1
  end

  test "v4 refuses more than12 meanings even when caller raises an option", _w do
    frozen = packet()

    many =
      for n <- 1..13, do: %{"meaning_id" => "m#{n}", "kind" => "lexeme", "label" => "fixture"}

    assert {:error, {:too_many_meanings, 13}} =
             Packet.freeze(Map.put(frozen.packet, "meanings", many), max_meanings: 99)

    {:ok, packet} =
      Packet.for_page(page("love"),
        instruction_version: WholeEntry.instruction(),
        max_meanings: 99,
        max_candidates: 99
      )

    assert length(packet["meanings"]) <= 12
    assert length(packet["candidates"]) <= 24
  end

  test "whole-entry selection cannot omit an available definition", _w do
    frozen = packet()
    decoded = %{"decision" => "select", "lead" => nil, "highlights" => []}
    assert [["lead", "definition_required"]] = WholeEntry.validate(decoded, frozen.packet)
  end

  test "whole-entry prompt fits the existing8K context and exposes source sections", w do
    for provider <- DevilsDictionary.Curation.Shelf.providers(),
        do:
          DevilsDictionary.CitationFixtures.observation!(w, provider,
            namespace: @namespaces[provider]
          )

    frozen = packet()
    assert :ok = Packet.fits?(frozen, w.model_config.generation)
    messages = Packet.messages(frozen)
    assert List.last(messages).content =~ "section"
    assert List.first(messages).content =~ "entire encyclopedia entry"
  end

  test "all choices withheld still show the whole-entry record and reasons", w do
    DevilsDictionary.CitationFixtures.observation!(w)
    frozen = packet()

    lead =
      Enum.find(
        frozen.packet["candidates"],
        &(&1["candidate_id"] in frozen.packet["priority_candidates"])
      )

    news = Enum.find(frozen.packet["candidates"], &(&1["kind"] == "shelf"))

    stub_answer!(
      w,
      selection({lead["candidate_id"], lead["required_meaning"]}, [
        {news["candidate_id"], news["required_meaning"], nil}
      ])
    )

    assert {:ok, %{last_outcome_reason: "published_automatically"}} = run!(w)
    settle!()
    config = Application.fetch_env!(:devils_dictionary, :discovery)
    policies = Keyword.get(config, :source_policies, %{})

    Application.put_env(
      :devils_dictionary,
      :discovery,
      Keyword.put(config, :source_policies, Map.put(policies, "guardian", retention_seconds: 0))
    )

    on_exit(fn -> Application.put_env(:devils_dictionary, :discovery, config) end)
    source = DevilsDictionary.Sources.get_source_by_slug("bierce")
    source |> Ecto.Changeset.change(active: false) |> Repo.update!()
    html = build_conn() |> get("/on/love") |> html_response(200)
    assert html =~ "curation-summary"
    assert html =~ "opening-withheld-lead"
    assert html =~ "curated-unavailable"
  end
end
