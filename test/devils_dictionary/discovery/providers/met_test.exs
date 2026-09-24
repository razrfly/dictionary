defmodule DevilsDictionary.Discovery.Providers.MetTest do
  @moduledoc """
  The Met through the shared pipeline, with identity as the only match proof.

  Every case here is written against the one rule that separates this provider
  from a text search: the Met's `q=` is a candidate generator and nothing else,
  and a candidate is kept only when a hydrated object carries a tag whose
  Wikidata QID is one the target's senses already point at, or reaches one in
  two `P31`/`P279` steps.
  """

  use DevilsDictionary.DataCase, async: false
  use Oban.Testing, repo: DevilsDictionary.Repo

  import Ecto.Query

  import DevilsDictionary.WordFixtures
  import Plug.Conn, only: [fetch_query_params: 1, send_resp: 3]

  alias DevilsDictionary.Absorb.Clients
  alias DevilsDictionary.Claims
  alias DevilsDictionary.Discovery
  alias DevilsDictionary.Discovery.Providers.Met
  alias DevilsDictionary.Discovery.{Mapping, Result, Run}
  alias DevilsDictionary.Repo

  setup do
    catalog = DevilsDictionary.Fixtures.seed_catalog!()

    providers = Application.fetch_env!(:devils_dictionary, :discovery_providers)
    req_options = Application.fetch_env!(:devils_dictionary, :discovery_req_options)

    Application.put_env(:devils_dictionary, :discovery_providers, [Met])
    Application.put_env(:devils_dictionary, :discovery_req_options, plug: {Req.Test, Met})

    on_exit(fn ->
      Application.put_env(:devils_dictionary, :discovery_providers, providers)
      Application.put_env(:devils_dictionary, :discovery_req_options, req_options)
    end)

    %{sources: catalog.sources, animals: catalog.scopes["animals"], slug: Met.slug()}
  end

  describe "automatic_mapping/1 — the QIDs are the encyclopedia's, not the Met's" do
    test "carries the QIDs a sense actively refers to, and the entity's label", ctx do
      word = word!(ctx, "soldier", ~w(wordnet))
      sense = sense!(ctx, word, "wordnet")
      entity = concept!("Q4991371", "soldier")
      {:ok, _} = Claims.assert(sense.object_id, "refers_to", entity.object_id, %{confidence: 0.9})

      assert {"tag_qid_discovery", parameters} = Met.automatic_mapping(target(word))

      assert parameters["entities"] == [
               %{
                 "qid" => "Q4991371",
                 "label" => "soldier",
                 "object_id" => entity.object_id,
                 "confidence" => 0.9,
                 "level" => "sense"
               }
             ]

      # The entity's label leads the query, because the sense chose the entity.
      assert parameters["search_terms"] == ["soldier"]
    end

    test "a withdrawn refers_to is not evidence", ctx do
      word = word!(ctx, "war", ~w(wordnet))
      sense = sense!(ctx, word, "wordnet")
      entity = concept!("Q198", "War")

      {:ok, assertion} =
        Claims.assert(sense.object_id, "refers_to", entity.object_id, %{confidence: 0.95})

      {:ok, _} = Claims.withdraw(assertion.id, reason: "issue #82")

      assert {_operation, %{"entities" => []}} = Met.automatic_mapping(target(word))

      # And reinstating it is what puts the QID back — this is D12's whole effect.
      {:ok, _} = Claims.reinstate(assertion.id, reason: "issue #102")

      assert {_operation, %{"entities" => [%{"qid" => "Q198"}]}} =
               Met.automatic_mapping(target(word))
    end

    test "the evidence is the page's, not the one lexeme the target resolved to", ctx do
      # `/define/war` is seven lexemes sharing one address, and
      # `target_for_page/3` resolves it to the lowest id — the verb. The QID for
      # Q198 hangs off a sense of the noun. Scoping the evidence to the target
      # lexeme alone would put no artwork on `/define/war` at all.
      verb = word!(ctx, "war", ~w(wordnet), pos: "verb")
      noun = word!(ctx, "war", ~w(wordnet), pos: "noun")
      assert verb.object_id < noun.object_id

      sense = sense!(ctx, noun, "wordnet")
      entity = concept!("Q198", "War")

      {:ok, _} =
        Claims.assert(sense.object_id, "refers_to", entity.object_id, %{confidence: 0.95})

      target = %{
        object_id: verb.object_id,
        term: "war",
        language: "en",
        relevance: "term_unverified"
      }

      assert Met.covers?(target)
      assert {_operation, %{"entities" => [%{"qid" => "Q198"}]}} = Met.automatic_mapping(target)
    end

    test "another word's senses are not this page's evidence", ctx do
      war = word!(ctx, "war", ~w(wordnet))
      peace = word!(ctx, "peace", ~w(wordnet))
      sense = sense!(ctx, peace, "wordnet")
      entity = concept!("Q454", "peace")
      {:ok, _} = Claims.assert(sense.object_id, "refers_to", entity.object_id, %{})

      refute Met.covers?(target(war))
      assert Met.covers?(target(peace))
    end

    test "an entity with no QID cannot be a match key", ctx do
      word = word!(ctx, "nepotism", ~w(wordnet))
      sense = sense!(ctx, word, "wordnet")
      entity = concept!(nil, "nepotism")
      {:ok, _} = Claims.assert(sense.object_id, "refers_to", entity.object_id, %{})

      assert {_operation, %{"entities" => [], "search_terms" => ["nepotism"]}} =
               Met.automatic_mapping(target(word))
    end
  end

  describe "retrieve/4 — a text hit is a candidate, a tag QID is the proof" do
    test "keeps the object whose tag QID is the sense's entity, and drops the rest", ctx do
      word = soldier_word(ctx)

      stub(fn
        :search ->
          %{"total" => 3, "objectIDs" => [1, 2, 3]}

        1 ->
          object(1, "Watch", tags: [{"Soldiers", "Q4991371"}])

        2 ->
          # A text hit with no tag at all: the Met's ranking put it here, and
          # nothing about it says it is about soldiers.
          object(2, "Sword", tags: [])

        3 ->
          object(3, "Teapot", tags: [{"Flowers", "Q506"}])
      end)

      assert {:queued, run} = Discovery.request(target(word), ctx.slug)
      assert :ok = Discovery.execute_run(run.id)

      state = Discovery.state(word.object_id, ctx.slug)
      assert state.status == :ready
      assert [%Result{external_id: "1"} = item] = state.items
      assert item.external_namespace == "met_object"

      assert item.match_details["tags"] == [
               %{
                 "term" => "Soldiers",
                 "qid" => "Q4991371",
                 "relation" => "exact",
                 "entity_qid" => "Q4991371",
                 "entity_label" => "soldier"
               }
             ]

      assert item.preview_metadata["content_type"] == "artwork"
      assert item.preview_metadata["image_url"] =~ "images.metmuseum.org"
      assert item.preview_metadata["credit_line"] == "Gift of a fixture, 1917"
      assert item.preview_metadata["source_url"] =~ "metmuseum.org"

      assert item.preview_metadata["matched_tags"] == [
               %{"term" => "Soldiers", "qid" => "Q4991371"}
             ]

      # One search plus one hydration per candidate — nothing else.
      assert Repo.get!(Run, run.id).request_count == 4
    end

    test "a non-public-domain object is dropped even though the search returned it", ctx do
      word = soldier_word(ctx)

      # Measured live: `isPublicDomain=true` on the search is not honoured, so
      # the gate has to be applied here or a copyrighted image reaches a page.
      stub(fn
        :search -> %{"total" => 2, "objectIDs" => [10, 11]}
        10 -> object(10, "Uniform", tags: [{"Soldiers", "Q4991371"}], public_domain: false)
        11 -> object(11, "Helmet", tags: [{"Soldiers", "Q4991371"}])
      end)

      assert {:queued, run} = Discovery.request(target(word), ctx.slug)
      assert :ok = Discovery.execute_run(run.id)

      assert [%Result{external_id: "11"}] = Discovery.state(word.object_id, ctx.slug).items
    end

    test "a public-domain object with no image is dropped", ctx do
      word = soldier_word(ctx)

      stub(fn
        :search -> %{"total" => 1, "objectIDs" => [12]}
        12 -> object(12, "Lost", tags: [{"Soldiers", "Q4991371"}], image: "")
      end)

      assert {:queued, run} = Discovery.request(target(word), ctx.slug)
      assert :ok = Discovery.execute_run(run.id)

      assert %{status: :empty} = Discovery.state(word.object_id, ctx.slug)
    end

    test "a target whose senses refer to nothing is declined before a run exists", ctx do
      word = word!(ctx, "nepotism", ~w(wordnet))
      _sense = sense!(ctx, word, "wordnet")
      calls = start_supervised!({Agent, fn -> 0 end})

      Req.Test.stub(Met, fn conn ->
        Agent.update(calls, &(&1 + 1))
        Req.Test.json(conn, %{})
      end)

      # No QID means no query the Met could answer and no result that could pass
      # the identity gate, so the provider declines the target outright: no
      # mapping, no run, no shelf, no request.
      refute Met.covers?(target(word))
      assert {:error, :target_not_covered} = Discovery.request(target(word), ctx.slug)

      assert Repo.aggregate(Run, :count) == 0
      assert Repo.aggregate(Mapping, :count) == 0
      assert Agent.get(calls, & &1) == 0
      assert Discovery.state(word.object_id, ctx.slug).status == :idle
    end

    test "a target that does refer to something is covered", ctx do
      assert Met.covers?(target(soldier_word(ctx)))
    end

    test "one object that will not hydrate does not lose the page", ctx do
      word = soldier_word(ctx)

      stub(fn
        :search -> %{"total" => 2, "objectIDs" => [20, 21]}
        20 -> :not_found
        21 -> object(21, "Drum", tags: [{"Soldiers", "Q4991371"}])
      end)

      assert {:queued, run} = Discovery.request(target(word), ctx.slug)
      assert :ok = Discovery.execute_run(run.id)

      assert [%Result{external_id: "21"}] = Discovery.state(word.object_id, ctx.slug).items
    end

    test "pages by offset over the candidate window", ctx do
      word = soldier_word(ctx)
      offsets = start_supervised!({Agent, fn -> [] end})
      window = Met.scan_window()

      first_page = Enum.to_list(1..window)
      second_page = [900]

      Req.Test.stub(Met, fn conn ->
        conn = fetch_query_params(conn)

        case conn.params["offset"] do
          nil ->
            id = conn.request_path |> Path.basename() |> String.to_integer()
            Req.Test.json(conn, object(id, "Piece #{id}", tags: [{"Soldiers", "Q4991371"}]))

          offset ->
            Agent.update(offsets, &(&1 ++ [offset]))
            ids = if offset == "0", do: first_page, else: second_page
            Req.Test.json(conn, %{"total" => window + 1, "objectIDs" => ids})
        end
      end)

      assert {:queued, first} = Discovery.request(target(word), ctx.slug)
      assert :ok = Discovery.execute_run(first.id)

      state = Discovery.state(word.object_id, ctx.slug)
      assert state.pagination == :offset
      # `"<term index>:<offset>"`. One search term, so the cycle is one leg long
      # and the next page is the next window of the same term.
      assert state.next_cursor == "0:#{window}"

      assert {:queued, second} =
               Discovery.request_next(
                 word.object_id,
                 ctx.slug,
                 state.page_context,
                 state.page,
                 state.next_cursor
               )

      assert :ok = Discovery.execute_run(second.id)

      assert Agent.get(offsets, & &1) == ["0", Integer.to_string(window)]
      assert Discovery.state(word.object_id, ctx.slug).next_cursor == nil
    end
  end

  describe "the broader walk — what the Met tags is never the abstraction" do
    test "a tag two P31/P279 steps below the sense's entity is kept as broader", ctx do
      word = word!(ctx, "war", ~w(wordnet))
      sense = sense!(ctx, word, "wordnet")
      entity = concept!("Q198", "War")

      {:ok, _} =
        Claims.assert(sense.object_id, "refers_to", entity.object_id, %{confidence: 0.95})

      stub(fn
        :search -> %{"total" => 2, "objectIDs" => [30, 31]}
        # World War I: two steps up — Q361 → Q103495 world war → Q198 war.
        30 -> object(30, "Battlefield", tags: [{"World War I", "Q361"}])
        # Trojan War: a war by name, and no path to Q198 within two steps.
        31 -> object(31, "Lekythos", tags: [{"Trojan War", "Q42937"}])
      end)

      stub_wikidata(%{
        "Q361" => ["Q103495"],
        "Q42937" => ["Q645883"],
        "Q103495" => ["Q198"],
        "Q645883" => ["Q1190554"]
      })

      assert {:queued, run} = Discovery.request(target(word), ctx.slug)
      assert :ok = Discovery.execute_run(run.id)

      assert [%Result{external_id: "30"} = item] = Discovery.state(word.object_id, ctx.slug).items

      assert item.match_details["tags"] == [
               %{
                 "term" => "World War I",
                 "qid" => "Q361",
                 "relation" => "broader",
                 "entity_qid" => "Q198",
                 "entity_label" => "War",
                 "via" => ["Q103495"]
               }
             ]
    end

    test "three steps is too far", ctx do
      word = word!(ctx, "war", ~w(wordnet))
      sense = sense!(ctx, word, "wordnet")
      entity = concept!("Q198", "War")
      {:ok, _} = Claims.assert(sense.object_id, "refers_to", entity.object_id, %{})

      stub(fn
        :search -> %{"total" => 1, "objectIDs" => [40]}
        40 -> object(40, "Skirmish", tags: [{"A small battle", "Q9001"}])
      end)

      stub_wikidata(%{"Q9001" => ["Q9002"], "Q9002" => ["Q9003"], "Q9003" => ["Q198"]})

      assert {:queued, run} = Discovery.request(target(word), ctx.slug)
      assert :ok = Discovery.execute_run(run.id)

      assert %{status: :empty} = Discovery.state(word.object_id, ctx.slug)
    end

    test "an exact tag costs no Wikidata request at all", ctx do
      word = soldier_word(ctx)
      calls = start_supervised!({Agent, fn -> 0 end})

      stub(fn
        :search -> %{"total" => 1, "objectIDs" => [50]}
        50 -> object(50, "Watch", tags: [{"Soldiers", "Q4991371"}])
      end)

      Req.Test.stub(Clients, fn conn ->
        Agent.update(calls, &(&1 + 1))
        Req.Test.json(conn, %{"entities" => %{}})
      end)

      assert {:queued, run} = Discovery.request(target(word), ctx.slug)
      assert :ok = Discovery.execute_run(run.id)

      assert [%Result{external_id: "50"}] = Discovery.state(word.object_id, ctx.slug).items
      assert Agent.get(calls, & &1) == 0
    end
  end

  describe "identity" do
    test "an object proposes a durable artwork keyed by its Met object id", _ctx do
      item = %{
        external_namespace: "met_object",
        external_id: "437853",
        identifiers: [
          %{namespace: "met_object_id", external_id: "437853"},
          %{namespace: "wikidata", external_id: "Q219831"}
        ],
        preview_metadata: %{
          "title" => "Wheat Field with Cypresses",
          "year" => "ca. 1889",
          "image_url" => "https://images.metmuseum.org/x.jpg",
          "credit_line" => "Purchase, 1993",
          "artist" => "Vincent van Gogh"
        }
      }

      assert {:ok, entry} = Met.identity_record(item)
      assert entry.entity_kind == :work
      assert entry.work_kind == "artwork"
      assert %{namespace: "met_object_id", external_id: "437853"} = entry.stable_identifier

      assert Enum.any?(
               entry.identifiers,
               &match?(%{namespace: "wikidata", external_id: "Q219831"}, &1)
             )

      assert entry.label == "Wheat Field with Cypresses"
      # `objectDate` is free text; the year is the first four-digit run in it.
      assert entry.year == 1889
      assert entry.metadata["credit_line"] == "Purchase, 1993"
      assert entry.retention == :durable
    end

    test "a title longer than the label column is clamped to it, not to 300", ctx do
      word = soldier_word(ctx)
      long_title = String.duplicate("Rebel Caisson Destroyed by Federal Shells. ", 8)
      assert String.length(long_title) > 255

      stub(fn
        :search -> %{"total" => 1, "objectIDs" => [61]}
        61 -> object(61, long_title, tags: [{"Soldiers", "Q4991371"}])
      end)

      assert {:queued, run} = Discovery.request(target(word), ctx.slug)
      assert :ok = Discovery.execute_run(run.id)

      [result] = Repo.all(from r in Result, where: r.run_id == ^run.id)
      assert result.resolution_state == :newly_created

      entity = Repo.get_by!(DevilsDictionary.Registry.Entity, object_id: result.object_id)
      assert String.length(entity.preferred_label) == 255
      assert String.starts_with?(long_title, entity.preferred_label)
    end

    test "an item from another provider is refused rather than guessed at", _ctx do
      assert {:error, :unsupported_met_identity} =
               Met.identity_record(%{external_namespace: "tmdb_movie", external_id: "10"})
    end

    test "a QID on the object travels with the result", ctx do
      word = soldier_word(ctx)

      stub(fn
        :search -> %{"total" => 1, "objectIDs" => [60]}
        60 -> object(60, "Portrait", tags: [{"Soldiers", "Q4991371"}], qid: "Q90000001")
      end)

      assert {:queued, run} = Discovery.request(target(word), ctx.slug)
      assert :ok = Discovery.execute_run(run.id)

      [result] = Repo.all(from r in Result, where: r.run_id == ^run.id)
      assert result.resolution_state == :newly_created
      assert result.object_id

      identifiers =
        Repo.all(
          from i in DevilsDictionary.Registry.ExternalIdentifier,
            where: i.object_id == ^result.object_id,
            select: {i.namespace, i.external_id}
        )

      assert {"met_object_id", "60"} in identifiers
      assert {"wikidata", "Q90000001"} in identifiers
    end
  end

  describe "the mapping is a snapshot" do
    test "the operation and adapter version key it", ctx do
      word = soldier_word(ctx)

      stub(fn
        :search -> %{"total" => 0, "objectIDs" => nil}
      end)

      assert {:queued, run} = Discovery.request(target(word), ctx.slug)
      mapping = Repo.get!(Mapping, run.mapping_id)

      assert mapping.operation == "tag_qid_discovery"
      assert mapping.mapping_key =~ Met.adapter_version()
      assert mapping.source_id == ctx.sources[Met.slug()].id
    end

    test "the QID set keys it too, so swapping the entity versions the mapping", ctx do
      word = word!(ctx, "soldier", ~w(wordnet))
      sense = sense!(ctx, word, "wordnet")
      soldiers = concept!("Q4991371", "soldier")

      {:ok, assertion} =
        Claims.assert(sense.object_id, "refers_to", soldiers.object_id, %{confidence: 0.9})

      stub(fn
        :search -> %{"total" => 0, "objectIDs" => nil}
      end)

      assert {:queued, first} = Discovery.request(target(word), ctx.slug)
      before = Repo.get!(Mapping, first.mapping_id)
      assert before.parameters["entities"] == [entity_snapshot(soldiers, "soldier", 0.9)]

      # The encyclopedia changes its mind: this sense refers to an infantryman,
      # not to a soldier in general. The set stays non-empty, so `covers?/1`
      # still says yes and nothing about coverage notices.
      {:ok, _} = Claims.withdraw(assertion.id, reason: "wrong concept")
      infantry = concept!("Q1071056", "infantry")

      {:ok, _} =
        Claims.assert(sense.object_id, "refers_to", infantry.object_id, %{confidence: 0.9})

      assert Met.covers?(target(word))
      assert {:queued, second} = Discovery.request(target(word), ctx.slug)
      refute second.mapping_id == first.mapping_id

      versioned = Repo.get!(Mapping, second.mapping_id)
      assert versioned.parameters["entities"] == [entity_snapshot(infantry, "infantry", 0.9)]
      refute versioned.mapping_key == before.mapping_key

      # And the mapping still holding Q4991371 is no longer readable, so no
      # later page or pagination run can query the withdrawn concept.
      refute Repo.get!(Mapping, before.id).enabled
      assert Discovery.state(word.object_id, ctx.slug).mapping_id == versioned.id
    end

    test "a run whose evidence is withdrawn while it is queued does not publish", ctx do
      word = word!(ctx, "soldier", ~w(wordnet))
      sense = sense!(ctx, word, "wordnet")
      entity = concept!("Q4991371", "soldier")

      {:ok, assertion} =
        Claims.assert(sense.object_id, "refers_to", entity.object_id, %{confidence: 0.9})

      stub(fn
        :search -> %{"total" => 1, "objectIDs" => [1]}
        1 -> object(1, "Watch", tags: [{"Soldiers", "Q4991371"}])
      end)

      assert {:queued, run} = Discovery.request(target(word), ctx.slug)

      # A run waits: behind Oban, behind the 1.5 s retry floor, behind a 403
      # ladder. The claim can be withdrawn in that window.
      {:ok, _} = Claims.withdraw(assertion.id, reason: "withdrawn mid-flight")

      assert :ok = Discovery.execute_run(run.id)

      completed = Repo.get!(Run, run.id)
      assert completed.status == :failed
      assert completed.error_code == "mapping_evidence_changed"
      assert Repo.aggregate(Result, :count) == 0
    end
  end

  describe "mapping_identity/1" do
    test "is nil-free, stable, and moves only when the QID set moves", ctx do
      word = word!(ctx, "war", ~w(wordnet))
      sense = sense!(ctx, word, "wordnet")

      assert Met.mapping_identity(recipe(word)) == "no-entities"

      war = concept!("Q198", "War")
      {:ok, _} = Claims.assert(sense.object_id, "refers_to", war.object_id, %{confidence: 0.95})

      one = Met.mapping_identity(recipe(word))
      assert one =~ ~r/\A[0-9a-f]{16}\z/
      assert Met.mapping_identity(recipe(word)) == one

      conflict = concept!("Q350604", "armed conflict")

      {:ok, _} =
        Claims.assert(sense.object_id, "refers_to", conflict.object_id, %{confidence: 0.8})

      refute Met.mapping_identity(recipe(word)) == one
    end

    test "reads the recipe and never the database", ctx do
      word = soldier_word(ctx)
      {_operation, parameters} = Met.automatic_mapping(target(word))

      assert evidence_queries(fn -> Met.mapping_identity(parameters) end) == 0
    end

    test "a recipe with no entities, or a malformed one, still names itself", _ctx do
      assert Met.mapping_identity(%{"entities" => []}) == "no-entities"
      assert Met.mapping_identity(%{}) == "no-entities"
      assert Met.mapping_identity(%{"entities" => "not a list"}) == "no-entities"
    end
  end

  describe "reading the evidence" do
    test "the page's QID set is one query, and coverage is one row", ctx do
      word = soldier_word(ctx)

      assert evidence_queries(fn -> Met.automatic_mapping(target(word)) end) == 1
      assert evidence_queries(fn -> Met.covers?(target(word)) end) == 1
    end

    test "a target that already knows its page does not read the scope again", ctx do
      word = soldier_word(ctx)
      page_target = Map.put(target(word), :lexeme_ids, [word.object_id])

      # K4 of #109: the page's lexeme set is the target. A target built by
      # `target_for_page/3` carries it, so coverage is the evidence row and
      # nothing else; one built from a mapping pays a query to resolve it.
      assert scope_queries(fn -> Met.covers?(page_target) end) == 0
      assert scope_queries(fn -> Met.covers?(target(word)) end) == 1
    end

    test "versioning the mapping by its evidence costs no extra read", ctx do
      word = soldier_word(ctx)

      stub(fn
        :search -> %{"total" => 0, "objectIDs" => nil}
      end)

      # `covers?/1` plus the one recipe the key is derived from — the whole
      # evidence cost of admitting a run, cache hit or miss alike.
      created =
        evidence_queries(fn -> {:queued, _} = Discovery.request(target(word), ctx.slug) end)

      reused = evidence_queries(fn -> Discovery.request(target(word), ctx.slug) end)

      assert created == 2
      assert reused == 2
    end
  end

  describe "pacing and search terms are capabilities, not private habits" do
    test "the sustained interval is declared where the shared transport reads it", _ctx do
      original = Application.fetch_env!(:devils_dictionary, :met)
      on_exit(fn -> Application.put_env(:devils_dictionary, :met, original) end)

      # The test environment pins it to 0; the measured rate is the default a
      # deployment gets, and it reaches the transport as a capability.
      assert Met.capabilities().request_interval_ms == 0
      assert DevilsDictionary.Discovery.Transport.request_interval_ms(Met) == 0

      Application.put_env(:devils_dictionary, :met, enabled: true)
      assert Met.capabilities().request_interval_ms == 3_000
      assert DevilsDictionary.Discovery.Transport.request_interval_ms(Met) == 3_000
    end

    test "the shared transport waits the declared interval between every request", ctx do
      original = Application.fetch_env!(:devils_dictionary, :met)
      Application.put_env(:devils_dictionary, :met, enabled: true, request_interval_ms: 150)
      on_exit(fn -> Application.put_env(:devils_dictionary, :met, original) end)

      word = soldier_word(ctx)

      stub(fn
        :search -> %{"total" => 3, "objectIDs" => [1, 2, 3]}
        id -> object(id, "Piece #{id}", tags: [{"Soldiers", "Q4991371"}])
      end)

      assert {:queued, run} = Discovery.request(target(word), ctx.slug)

      started = System.monotonic_time(:millisecond)
      assert :ok = Discovery.execute_run(run.id)
      elapsed = System.monotonic_time(:millisecond) - started

      # One search and three hydrations is four requests through the transport,
      # and three gaps between them, each the interval wide. The provider no
      # longer sleeps between its own hydrations, so if this held only inside
      # `fetch_objects/3` the search would be unpaced and the floor would be 300.
      assert Repo.get!(Run, run.id).request_count == 4
      assert elapsed >= 450
    end

    test "two concurrent runs on one provider share the interval instead of doubling it", ctx do
      original = Application.fetch_env!(:devils_dictionary, :met)
      Application.put_env(:devils_dictionary, :met, enabled: true, request_interval_ms: 150)
      on_exit(fn -> Application.put_env(:devils_dictionary, :met, original) end)

      soldier = soldier_word(ctx)
      war = word!(ctx, "war", ~w(wordnet))
      sense = sense!(ctx, war, "wordnet")

      {:ok, _} =
        Claims.assert(sense.object_id, "refers_to", concept!("Q198", "War").object_id, %{})

      stub(fn
        :search -> %{"total" => 3, "objectIDs" => [1, 2, 3]}
        id -> object(id, "Piece #{id}", tags: [{"Soldiers", "Q4991371"}])
      end)

      assert {:queued, first} = Discovery.request(target(soldier), ctx.slug)
      assert {:queued, second} = Discovery.request(target(war), ctx.slug)

      started = System.monotonic_time(:millisecond)

      outcomes =
        [first, second]
        |> Task.async_stream(&Discovery.execute_run(&1.id),
          max_concurrency: 2,
          timeout: :infinity
        )
        |> Enum.map(fn {:ok, outcome} -> outcome end)

      elapsed = System.monotonic_time(:millisecond) - started

      # `:provider_concurrency` lets both run at once. Four requests each is
      # eight through the transport and seven gaps between them, and the gap is
      # the Met's, not each run's: had each run kept the interval privately,
      # the two would have overlapped and finished in about three gaps.
      assert outcomes == [:ok, :ok]
      assert Repo.get!(Run, first.id).request_count == 4
      assert Repo.get!(Run, second.id).request_count == 4
      assert elapsed >= 1_050
    end

    test "every search term in the recipe is queried, round-robin across pages", ctx do
      word = word!(ctx, "war", ~w(wordnet))
      sense = sense!(ctx, word, "wordnet")

      {:ok, _} =
        Claims.assert(sense.object_id, "refers_to", concept!("Q198", "War").object_id, %{})

      {:ok, _} =
        Claims.assert(
          sense.object_id,
          "refers_to",
          concept!("Q350604", "armed conflict").object_id,
          %{}
        )

      # Both entity labels lead; the headword itself dedups against "War".
      {_operation, parameters} = Met.automatic_mapping(target(word))
      assert parameters["search_terms"] == ["War", "armed conflict"]

      asked = start_supervised!({Agent, fn -> [] end})
      stub_wikidata(%{})

      Req.Test.stub(Met, fn conn ->
        conn = fetch_query_params(conn)

        if term = conn.params["q"] do
          Agent.update(asked, &(&1 ++ [{term, conn.params["offset"]}]))
          Req.Test.json(conn, %{"total" => 0, "objectIDs" => nil})
        else
          send_resp(conn, 404, "not found")
        end
      end)

      assert {:queued, first} = Discovery.request(target(word), ctx.slug)
      assert :ok = Discovery.execute_run(first.id)

      # Only the first term was ever asked before K5. Each further page asks the
      # next term at the same offset.
      state = Discovery.state(word.object_id, ctx.slug)
      assert state.next_cursor == "1:0"

      assert {:queued, second} =
               Discovery.request_next(
                 word.object_id,
                 ctx.slug,
                 state.page_context,
                 state.page,
                 state.next_cursor
               )

      assert :ok = Discovery.execute_run(second.id)

      assert Agent.get(asked, & &1) == [
               {Enum.at(parameters["search_terms"], 0), "0"},
               {Enum.at(parameters["search_terms"], 1), "0"}
             ]
    end

    test "a full window earlier in the cycle advances the offset when the last leg is short",
         ctx do
      word = word!(ctx, "war", ~w(wordnet))
      sense = sense!(ctx, word, "wordnet")

      {:ok, _} =
        Claims.assert(sense.object_id, "refers_to", concept!("Q198", "War").object_id, %{})

      {:ok, _} =
        Claims.assert(
          sense.object_id,
          "refers_to",
          concept!("Q350604", "armed conflict").object_id,
          %{}
        )

      window = Met.scan_window()
      asked = start_supervised!({Agent, fn -> [] end})
      stub_wikidata(%{})

      # "War" has a full window at offset 0 and one more object behind it;
      # "armed conflict" has nothing at all.
      Req.Test.stub(Met, fn conn ->
        conn = fetch_query_params(conn)

        case {conn.params["q"], conn.params["offset"]} do
          {nil, _} ->
            id = conn.request_path |> Path.basename() |> String.to_integer()
            Req.Test.json(conn, object(id, "Piece #{id}", tags: [{"War", "Q198"}]))

          {"War", "0"} ->
            Agent.update(asked, &(&1 ++ [{"War", "0"}]))
            Req.Test.json(conn, %{"total" => window + 1, "objectIDs" => Enum.to_list(1..window)})

          {"War", offset} ->
            Agent.update(asked, &(&1 ++ [{"War", offset}]))
            Req.Test.json(conn, %{"total" => window + 1, "objectIDs" => [900]})

          {term, offset} ->
            Agent.update(asked, &(&1 ++ [{term, offset}]))
            Req.Test.json(conn, %{"total" => 0, "objectIDs" => nil})
        end
      end)

      assert {:queued, first} = Discovery.request(target(word), ctx.slug)
      assert :ok = Discovery.execute_run(first.id)

      # The first leg was full, and the cursor remembers that across the cycle.
      state = Discovery.state(word.object_id, ctx.slug)
      assert state.next_cursor == "1:0:more"

      assert {:queued, second} =
               Discovery.request_next(
                 word.object_id,
                 ctx.slug,
                 state.page_context,
                 state.page,
                 state.next_cursor
               )

      assert :ok = Discovery.execute_run(second.id)

      # The last leg came up empty, but the cycle had a full window in it, so
      # the next page is "War" at the next offset rather than the end. Judging
      # by the last leg alone would have returned nil here and lost object 900.
      state = Discovery.state(word.object_id, ctx.slug)
      assert state.next_cursor == "0:#{window}"

      assert {:queued, third} =
               Discovery.request_next(
                 word.object_id,
                 ctx.slug,
                 state.page_context,
                 state.page,
                 state.next_cursor
               )

      assert :ok = Discovery.execute_run(third.id)

      assert Agent.get(asked, & &1) == [
               {"War", "0"},
               {"armed conflict", "0"},
               {"War", Integer.to_string(window)}
             ]

      # A short first leg with nothing full behind it in this cycle: the flag
      # is not carried, and the cycle ends when its last leg is short too.
      assert Discovery.state(word.object_id, ctx.slug).next_cursor == "1:#{window}"
    end
  end

  # ── helpers ───────────────────────────────────────────────────────────────

  defp soldier_word(ctx) do
    word = word!(ctx, "soldier", ~w(wordnet))
    sense = sense!(ctx, word, "wordnet")
    entity = concept!("Q4991371", "soldier")
    {:ok, _} = Claims.assert(sense.object_id, "refers_to", entity.object_id, %{confidence: 0.9})
    word
  end

  # The `refers_to` read: every sense on the page, and the QIDs it points at.
  defp evidence_queries(fun), do: queries(fun, &(&1 =~ "FROM \"senses\""))

  # The page scope itself — lexemes and nothing else. Since K4 it is a shared
  # query a target can arrive already holding.
  defp scope_queries(fun),
    do: queries(fun, &(&1 =~ "FROM \"lexemes\"" and not (&1 =~ "\"senses\"")))

  # Only this provider's own evidence reads are counted: `Discovery.request/3`
  # does plenty of other database work, and none of it is what this is about.
  defp queries(fun, match?) do
    parent = self()
    ref = make_ref()

    handler = fn _event, _measurements, %{query: query}, _config ->
      if match?.(query), do: send(parent, {ref, :evidence_query})
    end

    :telemetry.attach({__MODULE__, ref}, [:devils_dictionary, :repo, :query], handler, nil)

    try do
      fun.()
    after
      :telemetry.detach({__MODULE__, ref})
    end

    count_evidence_queries(ref, 0)
  end

  defp count_evidence_queries(ref, seen) do
    receive do
      {^ref, :evidence_query} -> count_evidence_queries(ref, seen + 1)
    after
      0 -> seen
    end
  end

  defp recipe(word) do
    {_operation, parameters} = Met.automatic_mapping(target(word))
    parameters
  end

  defp entity_snapshot(entity, label, confidence) do
    %{
      "qid" =>
        hd(
          Repo.all(
            from ei in DevilsDictionary.Registry.ExternalIdentifier,
              where: ei.object_id == ^entity.object_id and ei.namespace == "wikidata",
              select: ei.external_id
          )
        ),
      "label" => label,
      "object_id" => entity.object_id,
      "confidence" => confidence,
      "level" => "sense"
    }
  end

  defp target(word) do
    %{object_id: word.object_id, term: word.lemma, language: word.language_tag, relevance: "term"}
  end

  # One stub for both endpoints: `/v1.1/search` is recognised by its query
  # parameters, `/v1/objects/{id}` by its path.
  defp stub(responder) do
    # A tag that matches nothing exactly is a broader-walk candidate, so every
    # case needs Wikidata answered even when the answer is "no parents".
    stub_wikidata(%{})

    Req.Test.stub(Met, fn conn ->
      conn = fetch_query_params(conn)

      if conn.params["q"] do
        Req.Test.json(conn, responder.(:search))
      else
        id = conn.request_path |> Path.basename() |> String.to_integer()

        case responder.(id) do
          :not_found -> send_resp(conn, 404, "not found")
          body -> Req.Test.json(conn, body)
        end
      end
    end)
  end

  defp stub_wikidata(parents) do
    Req.Test.stub(Clients, fn conn ->
      conn = fetch_query_params(conn)

      entities =
        conn.params["ids"]
        |> String.split("|")
        |> Map.new(fn qid ->
          claims =
            parents
            |> Map.get(qid, [])
            |> Enum.map(fn parent ->
              %{"mainsnak" => %{"datavalue" => %{"value" => %{"id" => parent}}}}
            end)

          {qid, %{"id" => qid, "claims" => %{"P279" => claims}}}
        end)

      Req.Test.json(conn, %{"entities" => entities})
    end)
  end

  defp object(id, title, opts) do
    tags =
      opts
      |> Keyword.get(:tags, [])
      |> Enum.map(fn {term, qid} ->
        %{"term" => term, "Wikidata_URL" => "https://www.wikidata.org/wiki/#{qid}"}
      end)

    %{
      "objectID" => id,
      "title" => title,
      "objectDate" => "ca. 1780",
      "isPublicDomain" => Keyword.get(opts, :public_domain, true),
      "primaryImageSmall" =>
        Keyword.get(opts, :image, "https://images.metmuseum.org/CRDImages/#{id}.jpg"),
      "objectURL" => "https://www.metmuseum.org/art/collection/search/#{id}",
      "creditLine" => "Gift of a fixture, 1917",
      "artistDisplayName" => "Anonymous",
      "objectWikidata_URL" =>
        case Keyword.get(opts, :qid) do
          nil -> ""
          qid -> "https://www.wikidata.org/wiki/#{qid}"
        end,
      "tags" => tags
    }
  end
end
