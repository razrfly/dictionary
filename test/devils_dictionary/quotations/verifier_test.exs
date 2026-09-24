defmodule DevilsDictionary.Quotations.VerifierTest do
  @moduledoc """
  #158 build 5 on its own test case. The five lines reach the registry the
  way they would in production — the register rows through the Wikiquote
  provider reading Voltaire's and Vonnegut's own pages (build 4a's captures),
  the two credited lines through the quote fixture provider — and the
  verifier then checks them against:

    * Wikidata, stubbed with the two authors' `enwikiquote` sitelinks
    * the SPARQL answers the spike received (`fixtures/verifier/sparql-*.json`)
    * Wikiquote's author pages and *Misquotations* (build 4a's captures)
    * Gutenberg #19942, *Candide*, exactly as the spike fetched it; the other
      five works the SPARQL answer names are not held and answer `404`

  No Google Books key, as the acceptance box says.
  """
  use DevilsDictionary.DataCase, async: false

  import ExUnit.CaptureLog

  import DevilsDictionary.WordFixtures

  alias DevilsDictionary.Claims
  alias DevilsDictionary.Claims.AssertionEvidence
  alias DevilsDictionary.Discovery
  alias DevilsDictionary.Discovery.{Conformance, RequestAttempt, Result}
  alias DevilsDictionary.Discovery.Conformance.WikiquoteFixture
  alias DevilsDictionary.Discovery.Providers.Wikiquote
  alias DevilsDictionary.FakeQuoteDiscoveryProvider, as: Quotes
  alias DevilsDictionary.Quotations.{VerificationRun, Verifier}
  alias DevilsDictionary.Registry
  alias DevilsDictionary.Registry.ContentItem
  alias DevilsDictionary.Sources
  alias DevilsDictionary.WikiquoteFixtures

  @candide File.read!("test/support/fixtures/verifier/pg19942.txt.gz") |> :zlib.gunzip()

  setup do
    catalog = DevilsDictionary.Fixtures.seed_catalog!()
    providers = Application.fetch_env!(:devils_dictionary, :discovery_providers)
    req = Application.fetch_env!(:devils_dictionary, :discovery_req_options)
    discovery = Application.fetch_env!(:devils_dictionary, :discovery)

    Application.put_env(:devils_dictionary, :discovery_providers, [Wikiquote, Quotes])
    Application.put_env(:devils_dictionary, :discovery_req_options, plug: {Req.Test, Wikiquote})
    Application.put_env(:devils_dictionary, :discovery, Keyword.put(discovery, :result_limit, 3))

    on_exit(fn ->
      Application.put_env(:devils_dictionary, :discovery_providers, providers)
      Application.put_env(:devils_dictionary, :discovery_req_options, req)
      Application.put_env(:devils_dictionary, :discovery, discovery)
      Quotes.clear_rows()
    end)

    Req.Test.stub(DevilsDictionary.Absorb.Clients, fn conn ->
      conn = Plug.Conn.fetch_query_params(conn)
      ids = String.split(conn.params["ids"] || "", "|", trim: true)
      Req.Test.json(conn, %{"entities" => Map.new(ids, &{&1, Conformance.human(&1, &1)})})
    end)

    requests = start_supervised!({Agent, fn -> [] end})
    stub_checkers(requests)

    ctx = %{sources: catalog.sources, requests: requests}
    voltaire = person_page!(ctx, "voltaire", "Q9068", "Voltaire")
    vonnegut = person_page!(ctx, "vonnegut", "Q49074", "Kurt Vonnegut")

    # The two credited lines, as a quotation provider would hold them.
    Quotes.put_rows("garden", Quotes.rows(~w(voltaire-candide-garden)))

    Quotes.put_rows("so", [
      %{
        "id" => "vonnegut-so-it-goes",
        "text" => "So it goes.",
        "author_qid" => "Q49074",
        "author_display" => "Kurt Vonnegut",
        "work" => "Slaughterhouse-Five",
        "year" => 1969,
        "source_url" => "https://en.wikiquote.org/wiki/Kurt_Vonnegut"
      }
    ])

    for term <- ~w(garden so), do: run!(ctx, term, Quotes.slug())

    Map.merge(ctx, %{voltaire: voltaire, vonnegut: vonnegut})
  end

  # A word whose sense refers to the person, so the Wikiquote provider reads
  # their own page and stores its register (build 4's path to an author page).
  defp person_page!(ctx, lemma, qid, label) do
    word = word!(ctx, lemma, ~w(wordnet))
    sense = sense!(ctx, word, "wordnet")
    person = concept!(qid, label, kind: :person)
    {:ok, _} = Claims.assert(sense.object_id, "refers_to", person.object_id, %{confidence: 0.95})

    WikiquoteFixture.respond(%{qid => label})

    {:queued, run} =
      Discovery.request(
        %{object_id: word.object_id, term: lemma, language: "en", relevance: "term"},
        Wikiquote.slug()
      )

    :ok = Discovery.execute_run(run.id)
    person.object_id
  end

  defp run!(ctx, term, slug) do
    word = word!(ctx, term, ~w(wordnet))

    {:queued, run} =
      Discovery.request(
        %{object_id: word.object_id, term: term, language: "en", relevance: "term"},
        slug
      )

    :ok = Discovery.execute_run(run.id)
  end

  defp stub_checkers(requests, overrides \\ %{}) do
    Req.Test.stub(Verifier, fn conn ->
      conn = Plug.Conn.fetch_query_params(conn)
      Agent.update(requests, &[{conn.host, conn.request_path} | &1])

      case Map.get(overrides, conn.host) do
        nil -> answer(conn)
        fun -> fun.(conn)
      end
    end)
  end

  defp answer(%{host: "wikidata.test"} = conn) do
    titles = %{"Q9068" => "Voltaire", "Q49074" => "Kurt Vonnegut"}

    entities =
      conn.params["ids"]
      |> String.split("|")
      |> Map.new(fn qid ->
        links =
          case titles[qid] do
            nil -> %{}
            title -> %{"enwikiquote" => %{"site" => "enwikiquote", "title" => title}}
          end

        {qid, %{"id" => qid, "sitelinks" => links}}
      end)

    Req.Test.json(conn, %{"entities" => entities})
  end

  defp answer(%{host: "sparql.test"} = conn) do
    qid = Regex.run(~r/wd:(Q\d+)/, conn.params["query"]) |> List.last()

    body =
      case File.read("test/support/fixtures/verifier/sparql-#{qid}.json") do
        {:ok, body} -> body
        {:error, :enoent} -> ~s({"results": {"bindings": []}})
      end

    conn
    |> Plug.Conn.put_resp_content_type("application/sparql-results+json")
    |> Plug.Conn.send_resp(200, body)
  end

  defp answer(%{host: "wikiquote.test"} = conn) do
    slug =
      conn.request_path
      |> Path.basename()
      |> URI.decode()
      |> String.downcase()
      |> String.replace(~r/[^a-z0-9]+/, "_")

    WikiquoteFixtures.respond(conn, slug)
  end

  defp answer(%{host: "gutenberg.test", request_path: "/cache/epub/19942/pg19942.txt"} = conn),
    do:
      conn |> Plug.Conn.put_resp_content_type("text/plain") |> Plug.Conn.send_resp(200, @candide)

  defp answer(%{host: "gutenberg.test"} = conn), do: Plug.Conn.send_resp(conn, 404, "")

  defp item(text) do
    Repo.one!(
      from r in Result,
        where: fragment("?->>'title' ILIKE ?", r.preview_metadata, ^"%#{text}%"),
        order_by: [desc: r.id],
        limit: 1
    )
    |> then(&Repo.get!(ContentItem, &1.object_id))
  end

  defp badge(text), do: item(text).metadata["provenance"]["badge"]

  test "the five test cases resolve as #158 said, without a Google Books key", ctx do
    runs = Verifier.run_due(10)
    assert Enum.map(runs, & &1.status) |> Enum.uniq() == [:succeeded]

    assert Enum.sort(Enum.map(runs, & &1.subject_object_id)) ==
             Enum.sort([ctx.voltaire, ctx.vonnegut])

    assert badge("I disapprove of what you say") == "disputed"
    assert badge("No snowflake in an avalanche") == "disputed"
    assert badge("Wear sunscreen") == "disputed"
    assert badge("We must cultivate our garden") == "verified"
    assert badge("So it goes") == "plausible"
  end

  test "Verified is two independent sources, one of them a primary text, at its line", ctx do
    Verifier.run_due(10)

    garden = item("We must cultivate our garden")

    assert %{"agreements" => 2, "sources" => ["gutenberg", "quote-fixture"]} =
             garden.metadata["provenance"]

    voltaire = ctx.voltaire
    [credit] = Claims.outgoing(garden.object_id, predicate: "authored_by")
    assert credit.object_object_id == voltaire
    assert credit.method == "verifier"
    assert credit.metadata["verifier"]
    assert credit.metadata["provider"] == "quote-fixture"

    [evidence] =
      Repo.all(from e in AssertionEvidence, where: e.assertion_revision_id == ^credit.id)

    assert evidence.evidence_role == :supports
    assert evidence.locator == "Candide (Gutenberg #19942), line 4121"
    assert evidence.source_record_revision_id
  end

  test "a line with two cited claims and no primary text is never Verified", _ctx do
    Verifier.run_due(10)

    # "So it goes" is cited by the provider that holds it and, inside a
    # passage, by Wikiquote's Vonnegut page under Slaughterhouse-Five: two
    # sources, no text of Slaughterhouse-Five to check against.
    so = item("So it goes")
    assert %{"badge" => "plausible", "agreements" => 2} = so.metadata["provenance"]

    [credit] = Claims.outgoing(so.object_id, predicate: "authored_by")

    # Three cited passages on his page contain it (one under *Mother Night*,
    # two under *Slaughterhouse-Five*); each is a supporting row.
    evidence = Repo.all(from e in AssertionEvidence, where: e.assertion_revision_id == ^credit.id)
    assert Enum.all?(evidence, &(&1.evidence_role == :supports))

    assert Enum.any?(
             evidence,
             &(&1.locator =~ "Kurt Vonnegut › Quotes › Slaughterhouse-Five (1969)")
           )
  end

  test "a register that agrees with a misattribution is recorded as its support", ctx do
    Verifier.run_due(10)

    disapprove = item("I disapprove of what you say")
    voltaire = ctx.voltaire

    assert [misattribution] =
             Claims.outgoing(disapprove.object_id, predicate: "misattributed_to")

    assert misattribution.object_object_id == voltaire
    assert Claims.outgoing(disapprove.object_id, predicate: "authored_by") == []

    locators =
      Repo.all(
        from e in AssertionEvidence,
          where: e.assertion_revision_id == ^misattribution.id and e.evidence_role == :supports,
          select: e.locator
      )

    # Voltaire's own register and *Misquotations* both say so.
    assert Enum.any?(locators, &(&1 =~ "Voltaire › Misattributed"))
    assert Enum.any?(locators, &(&1 =~ "Misquotations"))
  end

  test "every request is budgeted and ledgered on the run, per checker", ctx do
    [first | _] = runs = Verifier.run_due(10)

    by_source =
      Repo.all(
        from a in RequestAttempt,
          join: s in assoc(a, :source),
          where: a.verification_run_id in ^Enum.map(runs, & &1.id),
          group_by: s.slug,
          select: {s.slug, count(a.id)}
      )
      |> Map.new()

    # Per person: a sitelink and the works list (Wikidata), their page
    # (Wikiquote), and each work's text (Gutenberg: Voltaire 4, Vonnegut 2).
    # *Misquotations* once, cached for the second person.
    assert by_source == %{"wikidata" => 4, "wikiquote" => 3, "gutenberg" => 6}
    assert Enum.sum(Enum.map(runs, & &1.request_count)) == 13
    assert first.refresh_after
    _ = ctx
  end

  test "re-verification is the refresh clock: not due before it, free and idempotent after it",
       ctx do
    runs = Verifier.run_due(10)
    assert Verifier.due(10) == []

    garden = item("We must cultivate our garden")
    [credit] = Claims.outgoing(garden.object_id, predicate: "authored_by")
    revisions = length(Claims.history(credit.assertion_id))

    # The clock runs out.
    Repo.update_all(from(r in VerificationRun, where: r.id in ^Enum.map(runs, & &1.id)),
      set: [refresh_after: DateTime.add(DateTime.utc_now(), -1, :second)]
    )

    Agent.update(ctx.requests, fn _ -> [] end)
    again = Verifier.run_due(10)

    assert length(again) == 2
    # Every answer was cached as a source record: nothing fetched again, and
    # nothing written, because nothing changed.
    assert Agent.get(ctx.requests, & &1) == []
    assert length(Claims.history(credit.assertion_id)) == revisions
  end

  test "a 429 defers the pass and sets the clock; nothing is written", ctx do
    stub_checkers(ctx.requests, %{
      "wikiquote.test" => fn conn ->
        conn |> Plug.Conn.put_resp_header("retry-after", "120") |> Plug.Conn.send_resp(429, "")
      end
    })

    [run | _] = Verifier.run_due(10)
    assert run.status == :deferred
    assert DateTime.diff(run.refresh_after, run.completed_at) == 120
    refute item("We must cultivate our garden").metadata["provenance"]

    # The host's backoff is the source's, so the discovery provider waits too.
    assert Sources.get_source_by_slug!("wikiquote").discovery_retry_after
  end

  test "a provider refresh never overwrites the verifier's revision (#164 C3)", ctx do
    Verifier.run_due(10)
    garden = item("We must cultivate our garden")
    [verified] = Claims.outgoing(garden.object_id, predicate: "authored_by")

    discovery = Application.fetch_env!(:devils_dictionary, :discovery)

    Application.put_env(
      :devils_dictionary,
      :discovery,
      Keyword.put(discovery, :refresh_cooldown_seconds, 0)
    )

    word = Registry.lexeme_by_key("en", "garden", "noun")

    mapping =
      Repo.one!(
        from m in Discovery.Mapping, where: m.target_object_id == ^word.object_id, limit: 1
      )

    {:queued, run} = Discovery.request_mapping(mapping, refresh: true)
    :ok = Discovery.execute_run(run.id)

    assert [%{id: id}] = Claims.outgoing(garden.object_id, predicate: "authored_by")
    assert id == verified.id
    _ = ctx
  end

  test "Misquotations never counts against the right author's credit", ctx do
    # A source credits the line to the person *Misquotations* says did write
    # it. Her pass matches the row; it must not dispute her.
    disapprove = item("I disapprove of what you say")
    hall = concept!("Q1373916", "Evelyn Beatrice Hall", kind: :person).object_id
    {:ok, _} = Claims.assert(disapprove.object_id, "authored_by", hall, %{confidence: 0.9})

    runs = Verifier.run_due(10)
    # Her pass ran to the end: a failed one would leave no evidence to refute.
    assert %{status: :succeeded} = Enum.find(runs, &(&1.subject_object_id == hall))

    [credit] = Claims.outgoing(disapprove.object_id, predicate: "authored_by")
    assert credit.object_object_id == hall

    roles =
      Repo.all(
        from e in AssertionEvidence,
          where: e.assertion_revision_id == ^credit.id,
          select: e.evidence_role
      )

    refute :contradicts in roles

    # The line's badge is the item's, from every claim on it: Voltaire's pass
    # and hers agree on it whichever runs last.
    after_hall =
      Map.delete(item("I disapprove of what you say").metadata["provenance"], "computed_at")

    assert after_hall["badge"] == "disputed"

    Verifier.verify_author(ctx.voltaire)

    assert Map.delete(item("I disapprove of what you say").metadata["provenance"], "computed_at") ==
             after_hall
  end

  test "one person's pass raising fails that pass and not the batch", ctx do
    stub_checkers(ctx.requests, %{
      "sparql.test" => fn conn ->
        if conn.params["query"] =~ "wd:Q9068" do
          conn |> Plug.Conn.put_resp_content_type("text/plain") |> Plug.Conn.send_resp(200, "<")
        else
          answer(conn)
        end
      end
    })

    {runs, log} = with_log(fn -> Verifier.run_due(10) end)

    by_person = Map.new(runs, &{&1.subject_object_id, &1})
    assert %{status: :failed, error_code: "exception"} = by_person[ctx.voltaire]
    assert by_person[ctx.voltaire].refresh_after
    assert %{status: :succeeded} = by_person[ctx.vonnegut]
    assert log =~ "quotation verifier"
  end

  test "a source switched off is skipped, and a source under a backoff defers", ctx do
    gutenberg = Sources.get_source_by_slug!("gutenberg")
    Repo.update!(Ecto.Changeset.change(gutenberg, active: false))

    Verifier.run_due(10)

    # No text to check against: the provider's citation and nothing primary.
    assert badge("We must cultivate our garden") == "plausible"
    refute Enum.any?(Agent.get(ctx.requests, & &1), &match?({"gutenberg.test", _}, &1))
    refute Enum.any?(Agent.get(ctx.requests, & &1), &(elem(&1, 0) == "sparql.test"))

    wikiquote = Sources.get_source_by_slug!("wikiquote")
    later = DateTime.add(DateTime.utc_now(), 300, :second)
    Repo.update!(Ecto.Changeset.change(wikiquote, discovery_retry_after: later))
    Agent.update(ctx.requests, fn _ -> [] end)

    run = Verifier.verify_author(ctx.vonnegut, max_age: 0)
    assert run.status == :deferred
    refute Enum.any?(Agent.get(ctx.requests, & &1), &(elem(&1, 0) == "wikiquote.test"))
  end
end
