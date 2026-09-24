defmodule DevilsDictionary.Discovery.Providers.WikiquoteTest do
  @moduledoc """
  #158 build 4 beyond the shared suite: what the Wikiquote provider does with
  a redirect, a missing page, a throttle and an oversized page; the era bands;
  the register (the test case's Voltaire and Vonnegut misattributions); and
  Wiktionary's line and Wikiquote's folding to one card that names both.
  Every run goes through `Discovery.execute_run/1` over build 4a's captured
  pages.
  """
  use DevilsDictionary.DataCase, async: false

  import DevilsDictionary.WordFixtures
  import Phoenix.LiveViewTest

  alias DevilsDictionary.Claims
  alias DevilsDictionary.Claims.{Assertion, AssertionEvidence}
  alias DevilsDictionary.Discovery
  alias DevilsDictionary.Discovery.{Conformance, Result}
  alias DevilsDictionary.Discovery.Conformance.WikiquoteFixture
  alias DevilsDictionary.Discovery.Providers.Wikiquote
  alias DevilsDictionary.FakeWiktionaryQuoteProvider, as: Wiktionary
  alias DevilsDictionary.Quotations.Fingerprint
  alias DevilsDictionary.Registry
  alias DevilsDictionaryWeb.Culture

  @slug "wikiquote"

  setup do
    catalog = DevilsDictionary.Fixtures.seed_catalog!()
    providers = Application.fetch_env!(:devils_dictionary, :discovery_providers)
    req = Application.fetch_env!(:devils_dictionary, :discovery_req_options)

    Application.put_env(:devils_dictionary, :discovery_providers, [Wikiquote, Wiktionary])
    Application.put_env(:devils_dictionary, :discovery_req_options, plug: {Req.Test, Wikiquote})

    on_exit(fn ->
      Application.put_env(:devils_dictionary, :discovery_providers, providers)
      Application.put_env(:devils_dictionary, :discovery_req_options, req)
      Wiktionary.clear_rows()
    end)

    # Creator identity mints what the registry lacks; this Wikidata knows the
    # two authors of the test case.
    Req.Test.stub(DevilsDictionary.Absorb.Clients, fn conn ->
      conn = Plug.Conn.fetch_query_params(conn)

      entities =
        (conn.params["ids"] || "")
        |> String.split("|", trim: true)
        |> Map.new(fn
          "Q9068" -> {"Q9068", Conformance.human("Q9068", "Voltaire")}
          "Q49074" -> {"Q49074", Conformance.human("Q49074", "Kurt Vonnegut")}
          qid -> {qid, Conformance.human(qid, qid)}
        end)

      Req.Test.json(conn, %{"entities" => entities})
    end)

    %{sources: catalog.sources}
  end

  # A word page whose sense refers to `qid`, `kind` being what the registry
  # already holds it as — a person for an author page, as the registry would
  # after #165's seed; a concept for a theme.
  defp target(ctx, lemma, qid, kind \\ :concept) do
    word = word!(ctx, lemma, ~w(wordnet))
    sense = sense!(ctx, word, "wordnet")
    entity = concept!(qid, String.capitalize(lemma), kind: kind)
    {:ok, _} = Claims.assert(sense.object_id, "refers_to", entity.object_id, %{confidence: 0.95})
    %{object_id: word.object_id, term: lemma, language: "en", relevance: "term"}
  end

  defp run!(target, slug \\ @slug) do
    {:queued, run} = Discovery.request(target, slug)
    result = Discovery.execute_run(run.id)

    {result, Repo.get!(Discovery.Run, run.id),
     Repo.all(from r in Result, where: r.run_id == ^run.id, order_by: r.position)}
  end

  describe "the page request" do
    test "a redirect is followed once: Bank answers 307 and Banking is read", ctx do
      WikiquoteFixture.respond(%{"Q900710" => "Bank"})
      {:ok, run, results} = ctx |> target("bank", "Q900710") |> run!() |> ok()

      assert run.status == :succeeded
      assert results != []
      assert Enum.all?(results, &(&1.preview_metadata["page"] == "Banking"))
    end

    test "a missing page is a successful empty, not a failure", ctx do
      WikiquoteFixture.respond(%{"Q900711" => "Situationship"})
      {:ok, run, results} = ctx |> target("situationship", "Q900711") |> run!() |> ok()

      assert run.status == :succeeded
      assert run.completion_reason == :no_results
      assert results == []
    end

    test "a 429 with Retry-After defers the run and backs the provider off", ctx do
      target = target(ctx, "grief", "Q900700")

      Req.Test.stub(Wikiquote, fn conn ->
        conn = Plug.Conn.fetch_query_params(conn)

        if conn.host == "wikiquote.test",
          do: DevilsDictionary.WikiquoteFixtures.respond(conn, "throttled"),
          else: WikiquoteFixture.answer(conn, %{"Q900700" => "Grief"}, %{})
      end)

      {result, run, results} = run!(target)

      assert {:snooze, 60} = result
      assert run.status == :pending
      assert run.error_code == "provider_retry_after"
      assert results == []
      assert Discovery.Providers.get(@slug)
      assert DevilsDictionary.Sources.get_source_by_slug!(@slug).discovery_retry_after
    end

    test "a page over 2 MB is refused whole, never parsed in part", ctx do
      target = target(ctx, "love", "Q900712")

      big =
        "<html><body><section><h2>Quotes</h2><ul>" <>
          String.duplicate("<li>#{String.duplicate("love ", 40)}</li>", 11_000) <>
          "</ul></section></body></html>"

      assert byte_size(big) > 2 * 1024 * 1024

      Req.Test.stub(Wikiquote, fn conn ->
        conn = Plug.Conn.fetch_query_params(conn)

        if conn.host == "wikiquote.test",
          do:
            conn |> Plug.Conn.put_resp_content_type("text/html") |> Plug.Conn.send_resp(200, big),
          else: WikiquoteFixture.answer(conn, %{"Q900712" => "Love"}, %{})
      end)

      {_result, run, results} = run!(target)
      assert run.status == :failed
      assert run.error_code == "response_too_large"
      assert results == []
    end

    test "a concept with no Wikiquote page costs one Wikidata request and caches empty", ctx do
      WikiquoteFixture.respond(%{})
      {:ok, run, []} = ctx |> target("zyzzyva", "Q900713") |> run!() |> ok()

      assert run.completion_reason == :no_results
      assert run.request_count == 1
    end

    defp ok({:ok, run, results}), do: {:ok, run, results}
  end

  describe "what the shelf shows" do
    test "Grief's lines carry their era, and the shelf is banded by it", ctx do
      target = target(ctx, "grief", "Q900700")
      WikiquoteFixture.respond(%{"Q900700" => "Grief"}, %{"Joseph Addison" => "Q900714"})
      {:ok, _run, results} = run!(target) |> ok()

      # 1713, 1992, 2021: one line in each band.
      assert Enum.map(results, &{&1.preview_metadata["year"], &1.preview_metadata["era"]}) ==
               [{1713, "aristocracy"}, {1992, "middle"}, {2021, "plebs"}]

      assert Enum.all?(results, &(&1.preview_metadata["provenance"] == "plausible"))

      assert Enum.all?(
               results,
               &(&1.preview_metadata["attribution"] == "Wikiquote, CC BY-SA 4.0")
             )

      html =
        render_component(&Culture.section/1,
          states: %{@slug => Discovery.state(target.object_id, @slug)}
        )

      for era <- ~w(aristocracy middle plebs) do
        assert html =~ ~s(id="culture-band-quote-#{era}")
      end

      # The 1713 line is Addison's, by his page's sitelink, as a candidate.
      [addison | _] = results
      assert [%{confidence: 0.5}] = Claims.outgoing(addison.object_id, predicate: "authored_by")
    end

    test "the reason names the sitelink, not a search", ctx do
      target = target(ctx, "nepotism", "Q900701")
      WikiquoteFixture.respond(%{"Q900701" => "Nepotism"})
      {:ok, _run, [first | _]} = run!(target) |> ok()

      [reason] =
        DevilsDictionary.Discovery.MatchReason.from_result(first.match_details, "nepotism")

      assert DevilsDictionary.Discovery.MatchReason.evidence(reason) == :identity

      assert DevilsDictionary.Discovery.MatchReason.describe(reason) ==
               "From Wikiquote's page “Nepotism”, the page of the concept this meaning refers to (Q900701)."
    end
  end

  describe "credits by the linked page's item (CodeRabbit on #169)" do
    test "a citation linking an author's alias page is credited through the redirect", ctx do
      target = target(ctx, "nepotism", "Q900701")
      # Nepotism's citation links `Ambrose Bierce`; here that title is an alias
      # page redirecting to `Bierce`, whose item is Q191050.
      WikiquoteFixture.respond(%{"Q900701" => "Nepotism"}, %{
        "Ambrose Bierce" => {:redirect, "Bierce"},
        "Bierce" => "Q191050"
      })

      {:ok, _run, results} = run!(target) |> ok()
      bierce = Enum.find(results, &(&1.preview_metadata["title"] =~ "NEPOTISM"))
      bierce_id = Registry.by_external_id("wikidata", "Q191050")

      assert bierce.preview_metadata["author_qid"] == "Q191050"

      assert [%{object_object_id: ^bierce_id}] =
               Claims.outgoing(bierce.object_id, predicate: "authored_by")
    end

    test "a linked page with no item is reported, not silently dropped", ctx do
      target = target(ctx, "nepotism", "Q900701")
      WikiquoteFixture.respond(%{"Q900701" => "Nepotism"}, %{})

      {:ok, _run, results} = run!(target) |> ok()
      bierce = Enum.find(results, &(&1.preview_metadata["title"] =~ "NEPOTISM"))

      assert bierce.preview_metadata["author_unresolved"] == "Ambrose Bierce"
      refute bierce.preview_metadata["author_qid"]
      assert Claims.outgoing(bierce.object_id, predicate: "authored_by") == []
    end

    test "a throttled author lookup defers the run with the request, per the contract", ctx do
      target = target(ctx, "nepotism", "Q900701")

      Req.Test.stub(Wikiquote, fn conn ->
        conn = Plug.Conn.fetch_query_params(conn)

        if conn.request_path == "/w/api.php",
          do: DevilsDictionary.WikiquoteFixtures.respond(conn, "throttled"),
          else: WikiquoteFixture.answer(conn, %{"Q900701" => "Nepotism"}, %{})
      end)

      {result, run, results} = run!(target)
      assert {:snooze, 60} = result
      assert run.status == :pending
      assert run.error_code == "provider_retry_after"
      assert results == []
    end
  end

  describe "the register" do
    setup ctx do
      # Author pages are not targets in this build (#158 open question 5), but
      # the test case's two misattributions live on Voltaire's and
      # Vonnegut's pages, so a sense referring to the person is the way in.
      %{
        voltaire: target(ctx, "voltaire", "Q9068", :person),
        vonnegut: target(ctx, "vonnegut", "Q49074", :person)
      }
    end

    test "Voltaire's misattributions are never an authored_by, and are misattributed_to him",
         ctx do
      WikiquoteFixture.respond(%{"Q9068" => "Voltaire"})
      {:ok, _run, results} = run!(ctx.voltaire) |> ok()

      register = Enum.filter(results, & &1.preview_metadata["register"])
      kept = Enum.reject(results, & &1.preview_metadata["register"])
      voltaire_id = Registry.by_external_id("wikidata", "Q9068")

      # 15 misattributed and 5 disputed rows; Attributed (63) is set aside and
      # not the register.
      assert length(register) == 20
      assert length(kept) == 3

      for line <- ["I disapprove of what you say", "No snowflake in an avalanche"] do
        row = Enum.find(register, &(&1.preview_metadata["title"] =~ line))
        assert row.preview_metadata["register"] == "misattributed"
        assert Claims.outgoing(row.object_id, predicate: "authored_by") == []

        assert [%{object_object_id: ^voltaire_id, rationale: rationale, confidence: 0.5}] =
                 Claims.outgoing(row.object_id, predicate: "misattributed_to")

        # The register's own sentence, verbatim.
        assert rationale == row.preview_metadata["register_note"]
      end

      # His own cited lines are his, verified by his own page.
      for line <- kept do
        assert [%{object_object_id: ^voltaire_id, confidence: 1.0}] =
                 Claims.outgoing(line.object_id, predicate: "authored_by")
      end

      # Never cards: the rail has the three lines, the disclosure the twenty.
      html =
        render_component(&Culture.section/1,
          states: %{@slug => Discovery.state(ctx.voltaire.object_id, @slug)}
        )

      doc = LazyHTML.from_fragment(html)
      assert doc |> LazyHTML.query(~s(li[id^="culture-result-"])) |> Enum.count() == 3
      assert doc |> LazyHTML.query(~s(li[id^="culture-register-row-"])) |> Enum.count() == 20
      assert html =~ "20 lines filed as misattributed or disputed"

      # And the person's page shows them under Misattributed only.
      page = DevilsDictionary.Encyclopedia.EntityPage.build(voltaire_id)
      assert page.pagination.misattributed.count == 20
      refute Enum.any?(page.quotations, &(&1.body =~ "I disapprove"))
    end

    test "Wear sunscreen is Vonnegut's misattribution and never his credit", ctx do
      WikiquoteFixture.respond(%{"Q49074" => "Kurt Vonnegut"})
      {:ok, _run, results} = run!(ctx.vonnegut) |> ok()
      vonnegut_id = Registry.by_external_id("wikidata", "Q49074")

      row = Enum.find(results, &(&1.preview_metadata["title"] =~ "Wear sunscreen"))
      assert row.preview_metadata["register"] == "misattributed"
      assert row.preview_metadata["register_note"] =~ "Mary Schmich"
      assert Claims.outgoing(row.object_id, predicate: "authored_by") == []

      assert [%{object_object_id: ^vonnegut_id}] =
               Claims.outgoing(row.object_id, predicate: "misattributed_to")
    end

    test "a register row is counterevidence to another source's credit for the same line",
         ctx do
      # Wiktionary (the fixture) holds the line and credits Voltaire with it.
      Wiktionary.put_rows("voltaire", [
        %{
          "id" => "wikt-disapprove",
          "text" =>
            "I disapprove of what you say, but I will defend to the death your right to say it",
          "author_qid" => "Q9068",
          "author_display" => "Voltaire",
          "source_url" => "https://en.wiktionary.org/wiki/defend"
        }
      ])

      {:ok, _, [wikt]} = run!(ctx.voltaire, Wiktionary.slug()) |> ok()
      [credit] = Claims.outgoing(wikt.object_id, predicate: "authored_by")

      WikiquoteFixture.respond(%{"Q9068" => "Voltaire"})
      {:ok, _run, results} = run!(ctx.voltaire) |> ok()

      # One line, one subject: the register row folded onto Wiktionary's item.
      row = Enum.find(results, &(&1.preview_metadata["title"] =~ "I disapprove"))
      assert row.object_id == wikt.object_id

      assert [%AssertionEvidence{evidence_role: :contradicts, attribution_text: text}] =
               Repo.all(from e in AssertionEvidence, where: e.assertion_revision_id == ^credit.id)

      assert text =~ "Evelyn Beatrice Hall"

      # Attached, never applied: Wiktionary's credit still stands for build 5.
      assert [%{id: id}] = Claims.outgoing(wikt.object_id, predicate: "authored_by")
      assert id == credit.id
      assert Repo.get!(Assertion, credit.assertion_id)
    end

    test "a kept line the page's own register disputes is badged, with the register's note",
         ctx do
      page =
        ~s(<html about="x/revision/1"><head><title>Doubt</title></head><body>) <>
          "<section><h2>Quotes</h2><ul><li>Doubt is not a pleasant condition, but certainty is absurd.<ul><li><i>A letter</i> (1770)</li></ul></li></ul></section>" <>
          "<section><h2>Misattributed</h2><ul><li>“Doubt is not a pleasant condition, but certainty is absurd”<ul><li>Actually from a later paraphrase (1901).</li></ul></li></ul></section>" <>
          "</body></html>"

      target = target(ctx, "doubt", "Q900715")

      Req.Test.stub(Wikiquote, fn conn ->
        conn = Plug.Conn.fetch_query_params(conn)

        if conn.host == "wikiquote.test",
          do:
            conn |> Plug.Conn.put_resp_content_type("text/html") |> Plug.Conn.send_resp(200, page),
          else: WikiquoteFixture.answer(conn, %{"Q900715" => "Doubt"}, %{})
      end)

      {:ok, _run, results} = run!(target) |> ok()
      [kept] = Enum.reject(results, & &1.preview_metadata["register"])

      assert kept.preview_metadata["provenance"] == "disputed"

      assert kept.preview_metadata["provenance_note"] ==
               "Actually from a later paraphrase (1901)."
    end
  end

  describe "a register that changes its mind (CodeRabbit on #169)" do
    test "a new register sentence is a revision; the same one again writes nothing", ctx do
      target = target(ctx, "doubtful", "Q900716", :person)

      page = fn note ->
        ~s(<html about="x/revision/1"><head><title>Doubtful</title></head><body>) <>
          "<section><h2>Misattributed</h2><ul><li>A line often put in this person's mouth.<ul><li>#{note}</li></ul></li></ul></section>" <>
          "</body></html>"
      end

      serve = fn note ->
        Req.Test.stub(Wikiquote, fn conn ->
          conn = Plug.Conn.fetch_query_params(conn)

          if conn.host == "wikiquote.test" and conn.request_path =~ "/page/html/",
            do:
              conn
              |> Plug.Conn.put_resp_content_type("text/html")
              |> Plug.Conn.send_resp(200, page.(note)),
            else: WikiquoteFixture.answer(conn, %{"Q900716" => "Doubtful"}, %{})
        end)
      end

      refresh = fn ->
        discovery = Application.fetch_env!(:devils_dictionary, :discovery)

        Application.put_env(
          :devils_dictionary,
          :discovery,
          Keyword.put(discovery, :refresh_cooldown_seconds, 0)
        )

        mapping =
          Repo.one!(
            from m in Discovery.Mapping,
              where: m.target_object_id == ^target.object_id,
              limit: 1
          )

        {:queued, run} = Discovery.request_mapping(mapping, refresh: true)
        :ok = Discovery.execute_run(run.id)
        Application.put_env(:devils_dictionary, :discovery, discovery)
      end

      serve.("First found in a 1901 anthology.")
      {:ok, _run, [row]} = run!(target) |> ok()
      [first] = Claims.outgoing(row.object_id, predicate: "misattributed_to")
      assert first.rationale == "First found in a 1901 anthology."

      serve.("First found in a 1901 anthology.")
      refresh.()
      assert Claims.history(first.assertion_id) |> length() == 1

      serve.("First found in an 1899 newspaper.")
      refresh.()
      history = Claims.history(first.assertion_id)
      assert length(history) == 2
      assert List.last(history).rationale == "First found in an 1899 newspaper."
      assert List.last(history).is_current
    end
  end

  describe "two sources, one line" do
    test "Wiktionary's Bierce line and Wikiquote's fold to one card naming both", ctx do
      target = target(ctx, "nepotism", "Q900701")

      Wiktionary.put_rows("nepotism", [
        %{
          "id" => "wikt-nepotism-bierce",
          # Wiktionary's own transcription: capitalised differently, and a
          # full stop Wikiquote has too — one fingerprint either way.
          "text" =>
            "Nepotism, n. Appointing your grandmother to office for the good of the party.",
          "author_qid" => "Q191050",
          "author_display" => "Ambrose Bierce",
          "year" => 1911,
          "source_url" => "https://en.wiktionary.org/wiki/nepotism"
        }
      ])

      WikiquoteFixture.respond(%{"Q900701" => "Nepotism"}, %{"Ambrose Bierce" => "Q191050"})

      {:ok, _, [wikt]} = run!(target, Wiktionary.slug()) |> ok()
      {:ok, _, wq} = run!(target) |> ok()
      bierce_line = Enum.find(wq, &(&1.preview_metadata["title"] =~ "NEPOTISM"))

      assert Fingerprint.fingerprint(wikt.preview_metadata["title"]) ==
               Fingerprint.fingerprint(bierce_line.preview_metadata["title"])

      assert bierce_line.object_id == wikt.object_id

      states = %{
        @slug => Discovery.state(target.object_id, @slug),
        Wiktionary.slug() => Discovery.state(target.object_id, Wiktionary.slug())
      }

      doc = render_component(&Culture.section/1, states: states) |> LazyHTML.from_fragment()

      # Three Wikiquote lines and Wiktionary's one, and the shared line once.
      assert doc |> LazyHTML.query(~s(li[id^="culture-result-"])) |> Enum.count() == 3

      kept =
        [wikt, bierce_line]
        |> Enum.map(&"culture-result-#{&1.external_namespace}-#{&1.external_id}")
        |> Enum.filter(&(LazyHTML.query(doc, "##{&1}") |> Enum.count() == 1))

      assert [card_id] = kept
      card = LazyHTML.query(doc, "##{card_id}")

      for slug <- [@slug, Wiktionary.slug()] do
        assert LazyHTML.query(card, ~s([id$="-#{slug}"])) |> Enum.count() == 1,
               "the folded card does not name #{slug}"
      end
    end
  end

  describe "the concept hop (#172 build A)" do
    # /define/coward, as it was on 2026-09-24: the noun sense refers to
    # Q104605901 "cowardly or fearful person", which has no Wikiquote page and
    # says has characteristic (P1552) Q1401607 cowardice, which has. The page
    # is the one captured that day; the Wikidata answers are the live ones,
    # trimmed to the properties the hop reads.
    @coward %{
      "Q104605901" => %{
        "title" => nil,
        "claims" => %{
          "P1552" => ["Q1401607"],
          "P279" => ["Q215627"],
          "P31" => ["Q122213544"]
        }
      },
      "Q1401607" => "Cowardice"
    }

    # Every host a run asked, in order, so a test can count what it cost.
    defp respond_counting(sitelinks) do
      test = self()

      Req.Test.stub(Wikiquote, fn conn ->
        send(test, {:asked, conn.host, Plug.Conn.fetch_query_params(conn).params["ids"]})
        WikiquoteFixture.answer(conn, sitelinks, %{})
      end)
    end

    defp asked(acc \\ []) do
      receive do
        {:asked, host, ids} -> asked([{host, ids} | acc])
      after
        0 -> Enum.reverse(acc)
      end
    end

    test "coward reaches Cowardice by has-characteristic, and every result says so", ctx do
      respond_counting(@coward)
      {:ok, run, results} = ctx |> target("coward", "Q104605901") |> run!() |> ok()

      assert run.status == :succeeded
      assert results != []
      assert Enum.all?(results, &(&1.preview_metadata["page"] == "Cowardice"))

      assert Enum.all?(results, fn result ->
               result.match_details["sitelinks"] == [
                 %{
                   "qid" => "Q1401607",
                   "title" => "Cowardice",
                   "site" => "enwikiquote",
                   "wiki" => "Wikiquote",
                   "from" => "Q104605901",
                   "via" => [%{"property" => "P1552", "qid" => "Q1401607"}],
                   "reached" => ["P1552"]
                 }
               ]
             end)

      [reason] =
        DevilsDictionary.Discovery.MatchReason.from_result(hd(results).match_details, "coward")

      assert DevilsDictionary.Discovery.MatchReason.evidence(reason) == :identity

      assert DevilsDictionary.Discovery.MatchReason.describe(reason) ==
               "From Wikiquote's page “Cowardice”, the concept a sense of “coward” has as " <>
                 "its characteristic (Q1401607)."

      # The sitelinks request carried the claims; the hop cost one more, for
      # the items the first step reached, and then the page was read. Not
      # Q122213544: coward is a subclass (P279), so its P31 is a metaclass
      # and is not read.
      assert [
               {"wikidata.test", "Q104605901"},
               {"wikidata.test", "Q1401607|Q215627"},
               {"wikiquote.test", nil} | _
             ] = asked()
    end

    test "a direct sitelink costs one Wikidata request and reads as it always has", ctx do
      respond_counting(%{
        "Q900701" => %{"title" => "Nepotism", "claims" => %{"P279" => ["Q900702"]}}
      })

      {:ok, _run, [first | _]} = ctx |> target("nepotism", "Q900701") |> run!() |> ok()

      assert [%{"qid" => "Q900701"} = link] = first.match_details["sitelinks"]
      refute Map.has_key?(link, "via") or Map.has_key?(link, "reached")
      assert [{"wikidata.test", "Q900701"}, {"wikiquote.test", nil} | _] = asked()
    end

    test "a hop to a human is refused, though the human has a page", ctx do
      # The concept's characteristic is, by a bad edit, Voltaire: an author
      # page, and a person. The shelf stays empty rather than land on him.
      respond_counting(%{
        "Q900720" => %{"title" => nil, "claims" => %{"P1552" => ["Q9068"]}},
        "Q9068" => %{"title" => "Voltaire", "claims" => %{"P31" => ["Q5"]}}
      })

      {:ok, run, results} = ctx |> target("sycophancy", "Q900720") |> run!() |> ok()

      assert run.completion_reason == :no_results
      assert results == []
      refute Enum.any?(asked(), &match?({"wikiquote.test", _}, &1))
    end

    test "a person the page's sense refers to never hops", ctx do
      respond_counting(%{
        "Q900721" => %{"title" => nil, "claims" => %{"P279" => ["Q1401607"]}},
        "Q1401607" => "Cowardice"
      })

      {:ok, run, []} = ctx |> target("somebody", "Q900721", :person) |> run!() |> ok()

      assert run.completion_reason == :no_results
      assert [{"wikidata.test", "Q900721"}] = asked()
    end

    test "the recipe freezes the hop's rule, and a changed rule is a changed recipe", ctx do
      {"wikiquote_page", parameters} =
        Wikiquote.automatic_mapping(target(ctx, "coward", "Q104605901"))

      assert parameters["hop"] == DevilsDictionary.Discovery.ConceptHop.rule()
      assert :ok = Wikiquote.validate_mapping("wikiquote_page", parameters)

      identity = Wikiquote.mapping_identity(parameters)
      without = Wikiquote.mapping_identity(Map.delete(parameters, "hop"))
      one_step = Wikiquote.mapping_identity(put_in(parameters, ["hop", "max_steps"], 1))

      fewer =
        Wikiquote.mapping_identity(
          put_in(parameters, ["hop", "properties"], ~w(P1552 P279 P1269))
        )

      assert identity == Wikiquote.mapping_identity(parameters)
      assert length(Enum.uniq([identity, without, one_step, fewer])) == 4
      # A recipe from before the hop keeps the identity it had.
      assert without == DevilsDictionary.Discovery.PageEvidence.digest(parameters["entities"])

      assert {:error, :invalid_mapping} =
               Wikiquote.validate_mapping(
                 "wikiquote_page",
                 put_in(parameters, ["hop", "max_steps"], 3)
               )
    end
  end

  describe "a credit is a person (the audit of #169, residual 1)" do
    # Grief's Horace line cites "… / Horace, Carmina …" and links the theme
    # page *Impropriety* before Horace. Read through `retrieve/4` with the
    # answers written here, so the only thing under test is which link is
    # credited.
    @grief_page DevilsDictionary.Discovery.Providers.Wikiquote.Parser.parse(
                  DevilsDictionary.WikiquoteFixtures.body("grief")
                )

    defp horace_run(humans) do
      kept = Enum.filter(@grief_page.quotations, &(is_binary(&1.work) or is_integer(&1.year)))
      at = Enum.find_index(kept, &(&1.citation_links == ["Impropriety", "Horace"]))
      assert is_integer(at), "the fixture no longer has the Horace line"

      mapping = %{
        "term" => "grief",
        "resolution_strategy" => "sitelink_qid_v1",
        "entities" => [
          %{"qid" => "Q900700", "label" => "Grief", "object_id" => 1, "kind" => "concept"}
        ]
      }

      request_fun = fn
        "sitelinks", _ ->
          {:ok,
           %{
             "entities" => %{
               "Q900700" => %{"sitelinks" => %{"enwikiquote" => %{"title" => "Grief"}}}
             }
           }}

        "page", _ ->
          {:ok, %{"page" => @grief_page}}

        "authors", %{"titles" => titles} ->
          items = %{"Impropriety" => "Q900720", "Horace" => "Q6197"}

          {:ok,
           %{
             "query" => %{
               "pages" =>
                 for title <- titles, qid = items[title] do
                   %{"title" => title, "pageprops" => %{"wikibase_item" => qid}}
                 end
             }
           }}

        "humans", %{"qids" => qids} ->
          send(self(), {:humans_asked, qids})

          case humans do
            {:error, code} ->
              {:error, code}

            people ->
              {:ok,
               %{
                 "results" => %{
                   "bindings" =>
                     for qid <- qids, qid in people do
                       %{"item" => %{"value" => "http://www.wikidata.org/entity/#{qid}"}}
                     end
                 }
               }}
          end
      end

      {:ok, %{items: [item | _]}} =
        Wikiquote.retrieve(
          "wikiquote_page",
          mapping,
          %{"after" => "#{at}", "first" => 1},
          request_fun
        )

      item.preview_metadata
    end

    test "the theme page linked first is skipped for the person linked after it" do
      line = horace_run(["Q6197"])

      assert line["author_qid"] == "Q6197"
      assert line["artist"] == "Horace"
      refute line["author_unresolved"]
      assert_received {:humans_asked, qids}
      assert "Q900720" in qids and "Q6197" in qids
    end

    test "a citation whose linked items are no one credits nobody and opens no case" do
      line = horace_run([])

      refute line["author_qid"]
      refute line["author_unresolved"]
      refute line["artist"]
    end

    test "when the query service cannot say, the first link is credited, as before" do
      line = horace_run({:error, "provider_unavailable"})

      assert line["author_qid"] == "Q900720"
      assert line["artist"] == "Impropriety"
    end
  end
end
