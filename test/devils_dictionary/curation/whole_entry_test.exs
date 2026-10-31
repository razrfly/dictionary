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
  @legacy_instruction "voltaire-whole-entry-v2"
  setup ctx do
    w = love_world!()

    config =
      model_config!(%{
        instruction_version: Map.get(ctx, :instruction, @legacy_instruction),
        output_contract_version:
          Contract.version(Map.get(ctx, :instruction, @legacy_instruction)),
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

  defp packet(instruction \\ @legacy_instruction) do
    {:ok, packet} = Packet.for_page(page("love"), instruction_version: instruction)
    {:ok, frozen} = Packet.freeze(packet)
    frozen
  end

  test "the operator can explicitly admit a prepared newer profile version", w do
    model =
      model_config!(%{
        instruction_version: "voltaire-whole-entry-v5",
        output_contract_version: "selection-output-v4"
      })
      |> ready!()

    {:ok, prepared} = Persona.prepare(w.reviewer, model, reason: "prepare explicit upgrade")
    assert Repo.reload!(prepared.profile).current_version_id == w.profile_version.id

    args = [
      "admit",
      "--profile",
      "voltaire",
      "--as",
      w.reviewer.user.email,
      "--model-config",
      model.slug,
      "--version",
      Integer.to_string(prepared.version.version),
      "--reason",
      "explicit sourced version upgrade"
    ]

    preview =
      ExUnit.CaptureIO.capture_io(fn ->
        Mix.Tasks.Dd.Curation.Editor.run(args ++ ["--dry-run"])
      end)

    assert preview =~ "version ##{prepared.version.id}"
    assert Repo.reload!(prepared.profile).current_version_id == w.profile_version.id
    ExUnit.CaptureIO.capture_io(fn -> Mix.Tasks.Dd.Curation.Editor.run(args) end)
    assert Repo.reload!(prepared.profile).current_version_id == prepared.version.id
    assert Repo.reload!(prepared.profile).bot_actor_id == prepared.bot_actor.id
  end

  @tag instruction: "voltaire-whole-entry-v5"
  test "relevance instruction uses the same typed contract, publishes a suitable definition with sparse extras and keeps abstention available",
       w do
    frozen = packet("voltaire-whole-entry-v5")
    wire = section_answer(frozen)

    empty =
      Map.new(WholeEntry.sections(), &{&1, if(&1 in ["examples", "quotes"], do: [], else: nil)})

    wire = Map.put(wire, "selections", empty)
    assert Contract.schema(frozen.packet)["properties"]["selections"]

    assert {:ok, %{result: %{"contract" => "selection-output-v4"}}} =
             Contract.validate(answer(wire), frozen)

    abstention = %{
      "decision" => "abstain",
      "lead" => nil,
      "selections" => empty,
      "abstain_reason" => "No sufficiently supported choice in the supplied evidence."
    }

    assert {:ok, %{outcome: :abstained}} = Contract.validate(answer(abstention), frozen)
    quotation = Enum.find(frozen.packet["candidates"], &(&1["kind"] == "sense_quotation"))

    bad_quote = %{
      "candidate_id" => quotation["candidate_id"],
      "meaning_id" => quotation["required_meaning"],
      "reason" => "A supplied quotation.",
      "quote" => quotation["excerpt"]
    }

    assert {:refused, errors, _} =
             Contract.validate(
               answer(put_in(wire, ["selections", "quotes"], [bad_quote])),
               frozen
             )

    assert Enum.any?(errors, &(List.last(&1) == "quote_not_allowed"))
    stub_answer!(w, wire)
    assert {:ok, %{last_outcome_reason: "published_automatically"}} = run!(w)
    settle!()
    publication = Repo.one!(CompositionPublication)
    version = Repo.get!(CompositionVersion, publication.published_version_id)
    assert [%{role: :lead}] = Compositions.items(version.id)
    assert {:ok, receipt} = Receipt.read("love", version.version)
    assert hd(receipt.items).chooser.model_config_id == w.model_config.id
  end

  @tag instruction: "voltaire-whole-entry-v5"
  test "headless due checks wait on coalesced discovery then admit once cached", w do
    alias DevilsDictionary.Curation.{DueDispatcher, RefreshState}

    read = fn
      "love" -> page("love")
      _ -> %{headword: %{lexemes: []}}
    end

    parent = self()
    target = DevilsDictionary.Discovery.target_for_page(page("love"), nil, false)

    queued = fn page ->
      DueDispatcher.prepare_sources(page, fn actual ->
        send(parent, {:source_target, actual})
        [{"open-library", {:queued, %{id: 42}}}]
      end)
    end

    before_rows = Repo.aggregate(RefreshState, :count)

    for _ <- 1..2 do
      assert {"love", :discovery_pending} in DueDispatcher.dispatch(
               w.editor_version,
               read,
               queued
             )

      assert_receive {:source_target, ^target}
      assert Repo.aggregate(RefreshState, :count) == before_rows
      assert Repo.aggregate(DevilsDictionary.Curation.Runtime.Attempt, :count) == 0
    end

    ready = fn page ->
      DueDispatcher.prepare_sources(page, fn _ ->
        [
          {"open-library", {:cached, %{id: 42}}},
          {"guardian", {:deferred, :backoff}},
          {"met", {:error, :target_not_covered}}
        ]
      end)
    end

    assert {"love", {:ok, :admitted}} in DueDispatcher.dispatch(w.editor_version, read, ready)
    count = Repo.aggregate(Oban.Job, :count)
    assert {"love", {:ok, :in_flight}} in DueDispatcher.dispatch(w.editor_version, read, ready)
    assert Repo.aggregate(Oban.Job, :count) == count
    assert Repo.aggregate(DevilsDictionary.Curation.Runtime.Attempt, :count) == 0
  end

  @tag instruction: "voltaire-whole-entry-v5"
  test "held unprovisioned and legacy pages do not request discovery", w do
    alias DevilsDictionary.Curation.DueDispatcher
    DevilsDictionary.WordFixtures.word!(w, "war", ["wiktionary"], scope: nil)

    read = fn
      slug when slug in ["love", "war"] -> page(slug)
      _ -> %{headword: %{lexemes: []}}
    end

    parent = self()

    prepare = fn _ ->
      send(parent, :unexpected_preparation)
      :pending
    end

    {:ok, _} = Compositions.set_mode(w.reviewer, w.composition.id, :mine, [])
    results = DueDispatcher.dispatch(w.editor_version, read, prepare)
    assert {"love", :held_or_unprovisioned} in results
    assert {"war", :held_or_unprovisioned} in results
    refute_received :unexpected_preparation
    legacy = legacy!(w)
    {:ok, _} = Compositions.set_mode(w.reviewer, w.composition.id, :open, [])
    DueDispatcher.dispatch(legacy, read, prepare)
    refute_received :unexpected_preparation
  end

  test "source preparation isolates deferred failed and unsupported providers" do
    alias DevilsDictionary.Curation.DueDispatcher
    p = page("love")

    assert :ready =
             DueDispatcher.prepare_sources(p, fn _ ->
               [
                 {"guardian", {:deferred, :backoff}},
                 {"spotify", {:error, :provider_disabled}},
                 {"met", {:error, :target_not_covered}},
                 {"open-library", {:cached, %{result_count: 0}}}
               ]
             end)

    assert :pending =
             DueDispatcher.prepare_sources(p, fn _ ->
               [
                 {"guardian", {:deferred, :backoff}},
                 {"open-library", {:queued, %{id: 42}}}
               ]
             end)
  end

  defp section_answer(frozen) do
    candidates = frozen.packet["candidates"]
    priority = frozen.packet["priority_candidates"]
    lead = Enum.find(candidates, &(&1["candidate_id"] in priority))

    choice = fn c ->
      %{
        "candidate_id" => c["candidate_id"],
        "meaning_id" => c["required_meaning"],
        "reason" => "Illuminates a distinct aspect of the word.",
        "quote" => nil
      }
    end

    sections =
      Map.new(WholeEntry.sections(), fn section ->
        rows =
          Enum.filter(
            candidates,
            &(WholeEntry.section(&1) == section and &1["candidate_id"] not in priority)
          )

        values = Enum.map(Enum.take(rows, WholeEntry.limit(section)), choice)
        {section, if(section in ["examples", "quotes"], do: values, else: List.first(values))}
      end)

    %{
      "decision" => "select",
      "lead" => lead && Map.delete(choice.(lead), "quote"),
      "selections" => sections,
      "abstain_reason" => nil
    }
  end

  @tag instruction: "voltaire-whole-entry-v3"
  test "typed sections publish through the common writer and refuse malformed raw choices", w do
    for provider <- DevilsDictionary.Curation.Shelf.providers(),
        do:
          DevilsDictionary.CitationFixtures.observation!(w, provider,
            namespace: @namespaces[provider]
          )

    frozen = packet("voltaire-whole-entry-v3")
    wire = section_answer(frozen)
    schema = Contract.schema(frozen.packet)
    assert schema["properties"]["selections"]["properties"]["quotes"]["maxItems"] == 2
    assert schema["properties"]["selections"]["properties"]["definitions"]["anyOf"] != []

    assert {:ok, %{result: %{"contract" => "selection-output-v4"}}} =
             Contract.validate(answer(wire), frozen)

    for altered <- [
          put_in(wire, ["selections", "rogue"], nil),
          update_in(wire["selections"], &Map.delete(&1, "news")),
          put_in(wire, ["selections", "definitions"], []),
          put_in(wire, ["selections", "images"], wire["selections"]["books"]),
          put_in(wire, ["selections", "definitions"], Map.put(wire["lead"], "quote", nil))
        ] do
      assert {:refused, _, _} = Contract.validate(answer(altered), frozen)
    end

    for altered <- [
          put_in(wire, ["lead", "reason"], String.duplicate("x", 101)),
          update_in(wire, ["selections", "quotes"], fn [first | rest] ->
            [Map.put(first, "reason", String.duplicate("x", 101)) | rest]
          end),
          %{
            "decision" => "abstain",
            "lead" => nil,
            "abstain_reason" => String.duplicate("x", 101),
            "selections" =>
              Map.new(
                WholeEntry.sections(),
                &{&1, if(&1 in ["examples", "quotes"], do: [], else: nil)}
              )
          }
        ] do
      assert {:refused, errors, _} = Contract.validate(answer(altered), frozen)
      assert Enum.any?(errors, &(List.last(&1) == "reason_too_long"))
    end

    legacy = packet()
    legacy_lead = hd(legacy.packet["priority_candidates"])

    legacy_candidate =
      Enum.find(legacy.packet["candidates"], &(&1["candidate_id"] == legacy_lead))

    legacy_answer =
      selection({legacy_lead, legacy_candidate["required_meaning"]}, [])
      |> put_in(["lead", "reason"], String.duplicate("x", 101))

    assert {:ok, _} = Contract.validate(answer(legacy_answer), legacy)

    first_quote = hd(wire["selections"]["quotes"])

    repeated =
      put_in(wire, ["selections", "quotes"], [
        first_quote,
        Map.put(first_quote, "reason", "A different reason does not make a different record.")
      ])

    assert {:refused, errors, _} = Contract.validate(answer(repeated), frozen)
    assert ["selection", "duplicate_candidate"] in errors

    quoted =
      put_in(wire, ["selections", "quotes"], [Map.put(first_quote, "quote", "not allowed")])

    assert {:refused, errors, _} = Contract.validate(answer(quoted), frozen)

    assert ["highlight_4", "quote_not_allowed"] in errors or
             Enum.any?(errors, &(List.last(&1) == "quote_not_allowed"))

    stub_answer!(w, wire)
    assert {:ok, %{last_outcome_reason: "published_automatically"}} = run!(w)
    settle!()
    receipt = Repo.one!(CompositionPublication)
    version = Repo.get!(CompositionVersion, receipt.published_version_id)

    assert Repo.get!(DevilsDictionary.Curation.Runtime.Attempt, version.attempt_id).result[
             "contract"
           ] == "selection-output-v4"

    assert {:ok, history} = Receipt.read("love", version.version)
    assert length(history.items) > 4
    html = build_conn() |> get("/on/love") |> html_response(200)
    assert html =~ "Selected reading"
    assert html =~ "curated-news"
    assert html =~ "Voltaire"
  end

  @tag instruction: "voltaire-whole-entry-v3"
  test "typed fallback does not invent a fixed lead or permit lead duplication", _w do
    source = DevilsDictionary.Sources.get_source_by_slug("bierce")
    source |> Ecto.Changeset.change(active: false) |> Repo.update!()
    frozen = packet("voltaire-whole-entry-v3")
    assert frozen.packet["priority_candidates"] == []

    candidates =
      Enum.filter(frozen.packet["candidates"], &(&1["kind"] in ["content", "sense_definition"]))

    assert length(candidates) > 1
    c = hd(candidates)

    choice = %{
      "candidate_id" => c["candidate_id"],
      "meaning_id" => c["required_meaning"],
      "reason" => "A sourced fallback definition.",
      "quote" => nil
    }

    sections =
      Map.new(WholeEntry.sections(), &{&1, if(&1 in ["examples", "quotes"], do: [], else: nil)})

    wire = %{
      "decision" => "select",
      "lead" => Map.delete(choice, "quote"),
      "selections" => Map.put(sections, "definitions", choice),
      "abstain_reason" => nil
    }

    assert {:refused, errors, _} = Contract.validate(answer(wire), frozen)
    assert ["selection", "duplicate_candidate"] in errors

    assert {:ok, _} =
             Contract.validate(answer(put_in(wire, ["selections", "definitions"], nil)), frozen)
  end

  defp claim_choice(candidate),
    do: %{
      "candidate_id" => candidate["candidate_id"],
      "meaning_id" => candidate["required_meaning"],
      "reason" => "A sourced meaning context.",
      "quote" => nil
    }

  defp linked_claims(w, same?) do
    entity = DevilsDictionary.WordFixtures.concept!("Q270991", "Fixture affection concept")

    other =
      if same?,
        do: entity,
        else: DevilsDictionary.WordFixtures.concept!("Q270992", "Fixture second concept")

    DevilsDictionary.WordFixtures.link!(w.love, entity, sense: w.profound)
    DevilsDictionary.WordFixtures.link!(w.love, other, sense: w.benevolent)
    {entity, other}
  end

  @tag instruction: "voltaire-whole-entry-v3"
  test "distinct claims showing one entity publish once with a visible exact omission record",
       w do
    {entity, _} = linked_claims(w, true)
    frozen = packet("voltaire-whole-entry-v3")

    claims =
      Enum.filter(
        frozen.packet["candidates"],
        &(&1["kind"] == "claim" and get_in(&1, ["basis", "shown_object_id"]) == entity.object_id)
      )

    assert length(claims) == 2

    wire =
      section_answer(frozen)
      |> put_in(["selections", "examples"], Enum.map(claims, &claim_choice/1))

    assert length(wire["selections"]["examples"]) == 2
    stub_answer!(w, wire)
    assert {:ok, %{last_outcome_reason: "published_automatically"}} = run!(w)
    settle!()
    publication = Repo.one!(CompositionPublication)
    version = Repo.get!(CompositionVersion, publication.published_version_id)
    items = Compositions.items(version.id)
    assert Enum.count(items, &(&1.item_kind == :claim)) == 1
    assert :ok == Compositions.one_display_identity(items)
    assert {:ok, receipt} = Receipt.read("love", version.version)
    assert [omitted] = receipt.omitted_model_choices
    assert omitted["reason"] == "duplicate_display_identity"
    assert omitted["selection_reason"] == "A sourced meaning context."
    assert omitted["candidate_id"] == Enum.at(wire["selections"]["examples"], 1)["candidate_id"]
    assert omitted["kept_candidate_id"] == hd(wire["selections"]["examples"])["candidate_id"]
    assert is_map(omitted["reference"]) and is_map(omitted["kept_reference"])
    html = build_conn() |> get("/on/love/receipt/#{version.version}") |> html_response(200)
    assert html =~ "Recommendations not placed"
    assert html =~ "duplicate_display_identity"

    assert Repo.get!(DevilsDictionary.Curation.Runtime.Attempt, version.attempt_id).result[
             "highlights"
           ]
           |> Enum.count(fn c -> c["candidate_id"] in Enum.map(claims, & &1["candidate_id"]) end) ==
             2
  end

  @tag instruction: "voltaire-whole-entry-v3"
  test "claims showing different entities are both published", w do
    {first, second} = linked_claims(w, false)
    frozen = packet("voltaire-whole-entry-v3")

    claims =
      Enum.filter(
        frozen.packet["candidates"],
        &(&1["kind"] == "claim" and
            get_in(&1, ["basis", "shown_object_id"]) in [first.object_id, second.object_id])
      )

    assert length(claims) == 2

    wire =
      section_answer(frozen)
      |> put_in(["selections", "examples"], Enum.map(claims, &claim_choice/1))

    assert length(wire["selections"]["examples"]) == 2
    stub_answer!(w, wire)
    assert {:ok, %{last_outcome_reason: "published_automatically"}} = run!(w)
    settle!()
    publication = Repo.one!(CompositionPublication)
    version = Repo.get!(CompositionVersion, publication.published_version_id)
    assert Enum.count(Compositions.items(version.id), &(&1.item_kind == :claim)) == 2
    assert {:ok, %{omitted_model_choices: []}} = Receipt.read("love", version.version)
  end

  @tag instruction: "voltaire-whole-entry-v3"
  test "an owner-kept display wins and the omitted recommendation names its immutable item", w do
    {entity, _} = linked_claims(w, true)

    candidates =
      DevilsDictionary.Curation.Candidates.for_page(page("love")).highlights
      |> Enum.filter(
        &(&1.kind == :claim and &1.spec.basis["shown_object_id"] == entity.object_id)
      )

    assert length(candidates) == 2
    [owner_choice, _] = candidates
    spec = Map.put(owner_choice.spec, :note, %{text: "The owner kept this context."})
    published = publish!(w, w.composition, nil, highlights: [spec])
    kept = Enum.find(Compositions.items(published.version.id), &(&1.item_kind == :claim))
    {:ok, _} = Compositions.keep(w.reviewer, w.composition.id, kept.id, [])
    frozen = packet("voltaire-whole-entry-v3")
    wire = section_answer(frozen)

    recommended_candidate =
      Enum.find(frozen.packet["candidates"], fn candidate ->
        candidate["kind"] == "claim" and
          get_in(candidate, ["basis", "shown_object_id"]) == entity.object_id and
          candidate["assertion_revision_id"] != kept.assertion_revision_id
      end)

    assert recommended_candidate
    recommendation = claim_choice(recommended_candidate)
    wire = put_in(wire, ["selections", "examples"], [recommendation])
    stub_answer!(w, wire)
    assert {:ok, %{last_outcome_reason: "published_automatically"}} = run!(w)
    settle!()
    current = Repo.reload!(w.composition).current_published_version_id
    version = Repo.get!(CompositionVersion, current)
    assert :ok == Compositions.one_display_identity(Compositions.items(current))
    copied = Enum.find(Compositions.items(current), &(&1.item_kind == :claim))
    assert copied.copied_from_item_id == kept.id
    assert {:ok, receipt} = Receipt.read("love", version.version)
    assert [omitted] = receipt.omitted_model_choices
    assert omitted["kept_item_id"] == kept.id
    assert omitted["kept_version_id"] == published.version.id
    assert omitted["reason"] == "duplicate_display_identity"
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

    assert Repo.get!(DevilsDictionary.Curation.Runtime.Attempt, v.attempt_id).result["contract"] ==
             "selection-output-v3"

    assert {:ok, %{result: %{"contract" => "selection-output-v3"}}} =
             Contract.validate(answer(abstain()), frozen)

    assert length(Compositions.items(v.id)) > 4
    assert {:ok, history} = Receipt.read("love", v.version)
    assert Enum.all?(history.items, &(&1.chooser.attempt_id == v.attempt_id))
    conn = build_conn() |> get("/on/love")
    html = html_response(conn, 200)
    assert html =~ "curation-summary"
    assert html =~ "Selected reading"
    assert html =~ "curated-news"
    assert html =~ "curated-images"
    assert html =~ "curated-quotes"
    assert html =~ "Voltaire"
  end

  test "revised instruction refuses quoted fields and combined definition overflow while old instruction stays valid",
       _w do
    frozen = packet()

    assert Contract.schema(frozen.packet)["properties"]["highlights"]["items"]["properties"][
             "quote"
           ] == %{"type" => "null"}

    choices = frozen.packet["candidates"]
    lead = Enum.find(choices, &(&1["candidate_id"] in frozen.packet["priority_candidates"]))
    quote = Enum.find(choices, &(&1["kind"] == "sense_quotation"))

    selection =
      selection({lead["candidate_id"], lead["required_meaning"]}, [
        {quote["candidate_id"], quote["required_meaning"], quote["excerpt"]}
      ])

    assert {:refused, errors, _} = Contract.validate(answer(selection), frozen)
    assert ["highlight_1", "quote_not_allowed"] in errors

    definitions =
      Enum.filter(choices, &(&1 != lead and WholeEntry.section(&1) == "definitions"))
      |> Enum.take(2)

    assert length(definitions) == 2

    overflow =
      selection(
        {lead["candidate_id"], lead["required_meaning"]},
        Enum.map(definitions, &{&1["candidate_id"], &1["required_meaning"], nil})
      )

    assert {:refused, errors, _} = Contract.validate(answer(overflow), frozen)
    assert ["section", "definitions_over_limit"] in errors

    {:ok, old_packet} =
      Packet.for_page(page("love"), instruction_version: "voltaire-whole-entry-v1")

    {:ok, old_frozen} = Packet.freeze(old_packet)

    assert {:ok, %{result: %{"contract" => "selection-output-v2"}}} =
             Contract.validate(answer(selection), old_frozen)
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
    assert html =~ ~s(href="/on/love?view=records##{opening.lead.links.card_id}")
    sources = build_conn() |> get("/on/love?view=records") |> html_response(200)
    assert sources =~ ~s(id="#{opening.lead.links.card_id}")
    assert html =~ "Selected reading"
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
