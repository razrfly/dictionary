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
                 "confidence" => 0.9
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
      assert state.next_cursor == Integer.to_string(window)

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
  end

  # ── helpers ───────────────────────────────────────────────────────────────

  defp soldier_word(ctx) do
    word = word!(ctx, "soldier", ~w(wordnet))
    sense = sense!(ctx, word, "wordnet")
    entity = concept!("Q4991371", "soldier")
    {:ok, _} = Claims.assert(sense.object_id, "refers_to", entity.object_id, %{confidence: 0.9})
    word
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
