defmodule DevilsDictionary.Discovery.Providers.GuardianTest do
  @moduledoc """
  The readings the conformance fixture cannot cover.

  A fixture installs one captured response and asserts the ids the pipeline
  delivered from it. These are the cases either side of that: the request the
  provider builds and the one thing in it that must never be logged, the gate
  asked of terms the fixture cannot choose, the sentence a reader checks, the
  two identities — one of which has to agree byte for byte with a provider
  this one never calls into — and the two refusals a keyed API has that a
  keyless feed does not.

  It also holds the retention proof, which is not really about this provider:
  `Discovery.cleanup/0` now honours a per-source `retention_seconds`, and the
  test that matters is that it deletes the Guardian's day-old rows **and
  leaves Bing's alone**.
  """

  use DevilsDictionary.DataCase, async: false

  import Ecto.Query
  import DevilsDictionary.WordFixtures

  alias DevilsDictionary.Discovery
  alias DevilsDictionary.Discovery.{MatchReason, RequestAttempt, Result, Run, Transport}
  alias DevilsDictionary.Discovery.Conformance.GuardianFixture
  alias DevilsDictionary.Discovery.Providers.{BingNews, Guardian}
  alias DevilsDictionary.Sources
  alias DevilsDictionary.Sources.SourceRecord

  @kash_patel_url GuardianFixture.kash_patel_url()

  # ---------------------------------------------------------------------------
  # The request
  # ---------------------------------------------------------------------------

  describe "request_options/1 — the query, and the one parameter that is a secret" do
    test "the term is always a quoted phrase" do
      params = params(%{"term" => "bestiality", "page" => "1", "page_size" => "12"})

      # Measured 2026-09-21 and the whole reason this differs from Bing:
      # `q=red herring` over 90 days answered 2,615 articles — every article
      # holding both words anywhere — and `q="red herring"` answered 9. Bing's
      # probe (#135) measured the reverse and sends its term bare. Two
      # indexes, two measurements, no contradiction.
      assert params["q"] == ~s("bestiality")

      multi_word = params(%{"term" => "red herring", "page" => "1", "page_size" => "12"})
      assert multi_word["q"] == ~s("red herring")
    end

    test "type=article, which is what excludes the live blogs" do
      # Measured: `"bestiality"` over 30 days is 6 results unfiltered and 5
      # with `type=article`, and the one it drops is a 62,683-character
      # running live blog in which the word is buried five times.
      assert params(%{"term" => "war", "page" => "1", "page_size" => "12"})["type"] == "article"
    end

    test "from-date is the injected clock minus the freshness window" do
      # `config/test.exs` pins the clock to 2026-09-21 and `max_age_days` to
      # 30, so the API is asked for exactly the window the gate will admit.
      # Asking wider would spend the budget on candidates dropped on arrival.
      assert Guardian.from_date() == "2026-08-22"

      assert params(%{"term" => "war", "page" => "1", "page_size" => "12"})["from-date"] ==
               "2026-08-22"
    end

    test "the page is the offset's, one-based, and the page size the limit's" do
      assert params(%{"term" => "war", "page" => "3", "page_size" => "12"})["page"] == "3"
      assert params(%{"term" => "war", "page" => "3", "page_size" => "12"})["page-size"] == "12"

      assert params(%{"term" => "war", "page" => "1", "page_size" => "12"})["order-by"] ==
               "newest"

      assert params(%{"term" => "war", "page" => "1", "page_size" => "12"})["show-fields"] ==
               "headline,trailText,byline,bodyText,firstPublicationDate"
    end

    test "the key is in the request and nowhere else" do
      assert params(%{"term" => "war", "page" => "1", "page_size" => "12"})["api-key"] ==
               "test-key-not-a-secret"

      # And it is not in the things that outlive the request. This is the
      # assertion that stands in for the grep: `source_attrs/0` is what
      # reaches the `sources` row, `capabilities/0` what reaches the registry.
      refute inspect(Guardian.source_attrs()) =~ "test-key-not-a-secret"
      refute inspect(Guardian.capabilities()) =~ "test-key-not-a-secret"
    end

    test "enabled?/0 is false without a key, and the provider still registers" do
      assert Guardian.enabled?()
      assert Guardian in Application.fetch_env!(:devils_dictionary, :discovery_providers)

      with_config([api_key: nil], fn -> refute Guardian.enabled?() end)
      with_config([api_key: ""], fn -> refute Guardian.enabled?() end)
      with_config([enabled: false], fn -> refute Guardian.enabled?() end)
    end
  end

  # ---------------------------------------------------------------------------
  # The gate
  # ---------------------------------------------------------------------------

  describe "the gate — the search proposes, the body disposes" do
    test "the body is read first, and names itself as the locator's part" do
      row = row(%{"bodyText" => "A sentence about bestiality.", "webTitle" => "Something else"})

      assert {"the text", text} = Guardian.matched_text("bestiality", row)
      assert text == "A sentence about bestiality."
    end

    test "the title is the fallback, and says so rather than claiming the text" do
      row = row(%{"bodyText" => "Nothing here.", "webTitle" => "A bestiality hearing"})

      assert {"the headline", "A bestiality hearing"} = Guardian.matched_text("bestiality", row)
    end

    test "a row with the word in neither is no match at all" do
      row = row(%{"bodyText" => "Nothing here.", "webTitle" => "Nor here"})

      assert Guardian.matched_text("bestiality", row) == nil
    end

    test "the boundary is Unicode, so a longer token is not a match" do
      # The constructed fixture row's case, asked directly.
      row =
        row(%{"bodyText" => "The hashtag #Bestialitygate outran the hearing.", "webTitle" => ""})

      assert Guardian.matched_text("bestiality", row) == nil

      # And the classic: `warden` is not `war`, `swarm` is not `war`.
      assert Guardian.matched_text("war", row(%{"bodyText" => "The warden swarmed."})) == nil

      assert {"the text", _} =
               Guardian.matched_text("war", row(%{"bodyText" => "The war ended."}))
    end

    test "a multi-word lemma matches as a phrase" do
      assert {"the text", _} =
               Guardian.matched_text("red herring", row(%{"bodyText" => "It was a red herring."}))

      # The plural is a different word and the boundary says so.
      assert Guardian.matched_text("red herring", row(%{"bodyText" => "No red herrings here."})) ==
               nil
    end

    test "the case does not matter and the possessive does not break it" do
      assert {"the text", _} =
               Guardian.matched_text("bestiality", row(%{"bodyText" => "Bestiality’s critics."}))
    end
  end

  describe "published_at/1 and the freshness window" do
    test "an ISO 8601 date with a Z, which is every one measured" do
      assert {:ok, at} = Guardian.published_at("2026-09-15T17:20:47Z")
      assert at == ~U[2026-09-15 17:20:47Z]
    end

    test "an unreadable date is an error and never a fresh item" do
      assert Guardian.published_at("the fifteenth") == :error
      assert Guardian.published_at("") == :error
      assert Guardian.published_at(nil) == :error
    end

    test "the window is thirty days, shared with Bing by decision" do
      assert Guardian.max_age_days() == 30
      assert Guardian.max_age_days() == BingNews.max_age_days()
    end
  end

  # ---------------------------------------------------------------------------
  # The sentence
  # ---------------------------------------------------------------------------

  describe "sentence/2 — what the reader checks the reason against" do
    test "the sentence around the first hit, not the paragraph and not the body" do
      text =
        "One sentence before it. The FBI defended its policy on bestiality on Tuesday. " <>
          "And one after."

      assert Guardian.sentence(text, pattern("bestiality")) ==
               "The FBI defended its policy on bestiality on Tuesday."
    end

    test "a body with no punctuation before the hit starts at the body's own start" do
      assert Guardian.sentence(
               "Bestiality was the topic. Then something else.",
               pattern("bestiality")
             ) ==
               "Bestiality was the topic."
    end

    test "a body with no punctuation after the hit falls back to a window" do
      text = "There is no full stop after the word bestiality anywhere in this body at all"

      assert Guardian.sentence(text, pattern("bestiality")) == text
    end

    test "a long sentence is clamped at a word, with an ellipsis" do
      # The Anthony Page obituary's real sentence: 383 characters.
      long =
        "And it went hand in hand with a sensitivity for the most difficult of Albee’s plays, " <>
          "for instance The Goat (at the Almeida and the West End in 2004), which dealt in the " <>
          "limits of tolerance rather than bestiality in the fable of a securely married " <>
          "architect (Jonathan Pryce) falling in love with, well, a goat; Eddie Redmayne made a " <>
          "touching West End debut as the architect’s gay son."

      assert String.length(long) == 383

      clamped = Guardian.sentence(long, pattern("bestiality"))

      assert String.length(clamped) <= 201
      assert String.ends_with?(clamped, "…")
      assert String.starts_with?(clamped, "And it went hand in hand")

      # Cut at a word: what precedes the ellipsis is a prefix of the real
      # sentence ending on a whole token, never half of one. Asserted as
      # those two properties rather than as the word it happens to land on,
      # so a one-character change to the clamp does not rewrite this test.
      trimmed = String.trim_trailing(clamped, "…")
      assert String.starts_with?(long, trimmed)
      assert String.at(long, String.length(trimmed)) in [" ", nil]
    end

    test "a sentence already short enough is untouched" do
      short = "A short sentence about bestiality."

      assert Guardian.sentence(short, pattern("bestiality")) == short
      refute Guardian.sentence(short, pattern("bestiality")) =~ "…"
    end

    test "a body without the word has no sentence" do
      assert Guardian.sentence("Nothing here at all.", pattern("bestiality")) == nil
    end
  end

  # ---------------------------------------------------------------------------
  # The two identities
  # ---------------------------------------------------------------------------

  describe "the identities — the Guardian's own, and the one it shares with Bing" do
    test "article_url/1 takes an absolute http(s) URL and normalises it" do
      assert {:ok, url} = Guardian.article_url(@kash_patel_url)
      assert url == @kash_patel_url
    end

    test "an item that names nowhere to send the reader is dropped" do
      # The standard `Culture.external_href/1` applies to anything reaching an
      # `href` (#116 Phase 3): absolute, `http(s)`, with a host.
      assert Guardian.article_url("/us-news/2026/sep/15/kash-patel") == :error
      assert Guardian.article_url("javascript:alert(1)") == :error
      assert Guardian.article_url("ftp://theguardian.com/x") == :error
      assert Guardian.article_url("https://") == :error
      assert Guardian.article_url("") == :error
      assert Guardian.article_url(nil) == :error
    end

    test "the shared id is byte for byte what Bing computes for the same article" do
      # The assertion the whole `news_article` namespace exists for. Written
      # as the issue writes it — `BingNews.article_id(BingNews.normalize(
      # URI.parse(webUrl)))` — and compared against what the provider puts on
      # its item, so a provider that stopped calling into Bing and started
      # copying it would fail here.
      {:ok, url} = Guardian.article_url(@kash_patel_url)

      assert Guardian.news_article_id(url) ==
               BingNews.article_id(BingNews.normalize(URI.parse(@kash_patel_url)))
    end

    test "the same article spelled two ways is one shared id" do
      tracked = @kash_patel_url <> "?utm_source=twitter&utm_medium=social#comments"

      {:ok, plain} = Guardian.article_url(@kash_patel_url)
      {:ok, decorated} = Guardian.article_url(tracked)

      assert Guardian.news_article_id(plain) == Guardian.news_article_id(decorated)
    end

    test "the namespaces are the two the shelf reads" do
      assert Guardian.namespace() == "guardian_article"
      assert Guardian.shared_namespace() == BingNews.namespace()
      assert Guardian.shared_namespace() == "news_article"
    end
  end

  describe "the locator, and the sentence it becomes" do
    test "a dated locator names where, in what, and when" do
      assert Guardian.locator("the text", ~D[2026-09-15]) ==
               "the text, The Guardian, 15 September 2026"

      assert Guardian.locator("the headline", ~D[2026-09-05]) ==
               "the headline, The Guardian, 5 September 2026"
    end

    test "MatchReason renders it as the sentence #142 asks for" do
      details = %{
        "kind" => "attestation",
        "query" => "bestiality",
        "lines" => [
          %{
            "locator" => "the text, The Guardian, 15 September 2026",
            "text" => "The FBI director, Kash Patel, defended his agency’s decision."
          }
        ]
      }

      assert [reason] = MatchReason.from_result(details, "bestiality")
      assert reason.kind == :attestation
      assert MatchReason.evidence(reason) == :attestation

      # *in the text*, not *at the text*. #140 measured the preposition as
      # wrong for a locator naming a part of a work and reported it because
      # #135 put `match_reason.ex` out of scope; #142 was editing these tests
      # anyway and took the one-line fix. `at/1` now reads a leading
      # determiner, which is exactly what separates a named part (*a
      # headline*, *the text*) from a numbered point (*line 4*, *page 12*).
      assert MatchReason.describe(reason) ==
               "Uses “bestiality” in the text, The Guardian, 15 September 2026."
    end

    test "a numbered locator still reads at, which is what PoetryDB writes" do
      details = %{
        "kind" => "attestation",
        "query" => "war",
        "lines" => [%{"number" => 4, "text" => "war"}]
      }

      assert [reason] = MatchReason.from_result(details, "war")
      assert MatchReason.describe(reason) == "Uses “war” at line 4."
    end
  end

  # ---------------------------------------------------------------------------
  # The two refusals a keyed API has
  # ---------------------------------------------------------------------------

  describe "401 and 429" do
    setup :isolate_provider

    test "a bad key is authentication_failed and is not retried", context do
      target = target(context, "bestiality")

      # Measured against the live API with a deliberately wrong key:
      # `401`, `{"message": "Unauthorized"}`, `www-authenticate: Key`, and
      # none of the rate-limit headers a `200` carries.
      Req.Test.stub(Guardian, fn conn ->
        conn
        |> Plug.Conn.put_resp_header("www-authenticate", "Key")
        |> json(401, %{"message" => "Unauthorized"})
      end)

      assert {:queued, run} = Discovery.request(target, "guardian")
      assert :ok = Discovery.execute_run(run.id)

      run = Repo.get!(Run, run.id)
      assert run.status == :failed
      assert run.error_code == "authentication_failed"

      # One attempt, not `max_retries + 1`. A wrong key is a verdict and
      # retrying into it spends a budget shared with the running app.
      assert Repo.aggregate(from(a in RequestAttempt), :count) == 1
    end

    test "a 429 is deferred for as long as ratelimit-reset says", context do
      target = target(context, "bestiality")

      Req.Test.stub(Guardian, fn conn ->
        conn
        |> Plug.Conn.put_resp_header("ratelimit-reset", "44")
        |> Plug.Conn.put_resp_header("x-ratelimit-remaining-minute", "0")
        |> json(429, %{"message" => "API rate limit exceeded"})
      end)

      assert {:queued, run} = Discovery.request(target, "guardian")

      # The seconds the header named, carried all the way out to Oban: the run
      # is snoozed for 44 and not retried into the throttle that produced it.
      assert {:snooze, 44} = Discovery.execute_run(run.id)

      run = Repo.get!(Run, run.id)
      assert run.status == :pending
      assert run.error_code == "provider_retry_after"

      # Deferred once and not retried into the throttle that produced it.
      assert Repo.aggregate(from(a in RequestAttempt), :count) == 1

      # And the wait is the header's, written to the source so every run on
      # this provider waits rather than only this one.
      source = Sources.get_source_by_slug("guardian")
      assert source.discovery_retry_after != nil
      assert DateTime.diff(source.discovery_retry_after, DateTime.utc_now()) > 30
    end

    test "the transport reads ratelimit-reset because the capability names it" do
      # The Guardian sends no `Retry-After` at all — measured — so a transport
      # that only ever read that one header would ignore a plainly stated
      # throttle and retry straight back into it.
      assert Transport.retry_after_headers(Guardian) == ["retry-after", "ratelimit-reset"]
      assert Transport.retry_after_headers(BingNews) == ["retry-after"]

      response = Req.Response.new(status: 429) |> Req.Response.put_header("ratelimit-reset", "44")

      assert Transport.retry_after_seconds(response) == nil

      assert Transport.retry_after_seconds(
               response,
               DateTime.utc_now(),
               Transport.retry_after_headers(Guardian)
             ) == 44
    end

    test "a Retry-After still wins where one is sent" do
      response =
        Req.Response.new(status: 429)
        |> Req.Response.put_header("retry-after", "120")
        |> Req.Response.put_header("ratelimit-reset", "44")

      assert Transport.retry_after_seconds(
               response,
               DateTime.utc_now(),
               Transport.retry_after_headers(Guardian)
             ) == 120
    end
  end

  # ---------------------------------------------------------------------------
  # The pipeline
  # ---------------------------------------------------------------------------

  describe "the pipeline, end to end" do
    setup :isolate_provider

    test "every item carries both identities, its byline and its credit", context do
      target = target(context, "bestiality")
      GuardianFixture.stub(:results, context)

      assert {:queued, run} = Discovery.request(target, "guardian")
      assert :ok = Discovery.execute_run(run.id)

      state = Discovery.state(target.object_id, "guardian")
      assert length(state.items) == 2

      kash = Enum.find(state.items, &(&1.external_id == GuardianFixture.kash_patel_id()))
      assert kash

      # Its own identity is the Guardian's `id` path.
      assert kash.external_namespace == "guardian_article"

      # And both identities are on the item, persisted, so the keys come back
      # as strings. The `news_article` one is what folds this card into Bing's.
      namespaces = Enum.map(kash.identifiers, & &1["namespace"]) |> Enum.sort()
      assert namespaces == ["guardian_article", "news_article"]

      shared = Enum.find(kash.identifiers, &(&1["namespace"] == "news_article"))

      assert shared["external_id"] ==
               BingNews.article_id(BingNews.normalize(URI.parse(@kash_patel_url)))

      metadata = kash.preview_metadata
      assert metadata["source_url"] == @kash_patel_url
      # Clause 6(b)(i): the byline, retained.
      assert metadata["author"] == "Ariana Baio"
      assert metadata["artist"] == "Ariana Baio"
      # And the credit, which is distinct from the creator — the first item on
      # this `:credited` row that has one, which is what #140 left it for.
      assert metadata["attribution"] == "The Guardian"
      assert metadata["published_at"] == "2026-09-15T17:20:47Z"
      assert metadata["year"] == "2026"
      assert metadata["content_type"] == "news"

      assert [%{"locator" => locator, "text" => text}] = kash.match_details["lines"]
      assert locator == "the text, The Guardian, 15 September 2026"
      assert text =~ "Kash Patel"
      assert String.length(text) <= 201
    end

    test "nothing the run persists carries the key", context do
      target = target(context, "bestiality")
      GuardianFixture.stub(:results, context)

      assert {:queued, run} = Discovery.request(target, "guardian")
      assert :ok = Discovery.execute_run(run.id)

      # The grep the brief asks for, as an assertion: every row this run wrote,
      # and the ledger rows beside them.
      persisted =
        inspect(
          {Repo.all(Result), Repo.all(Run), Repo.all(RequestAttempt), Repo.all(SourceRecord),
           Repo.all(DevilsDictionary.Corpus.SourceRecordRevision)},
          limit: :infinity,
          printable_limit: :infinity
        )

      refute persisted =~ "test-key-not-a-secret"
      refute persisted =~ "api-key"
    end

    test "the obituary passes on its body alone, with the word nowhere in its title",
         context do
      target = target(context, "bestiality")
      GuardianFixture.stub(:results, context)

      assert {:queued, run} = Discovery.request(target, "guardian")
      assert :ok = Discovery.execute_run(run.id)

      state = Discovery.state(target.object_id, "guardian")

      obituary =
        Enum.find(state.items, &(&1.external_id == "stage/2026/sep/18/anthony-page-obituary"))

      assert obituary
      refute obituary.preview_metadata["title"] =~ "bestiality"
      assert [%{"locator" => locator, "text" => text}] = obituary.match_details["lines"]
      assert locator == "the text, The Guardian, 18 September 2026"
      # Its 383-character sentence, clamped.
      assert String.ends_with?(text, "…")
    end

    test "a word with no coverage spends one request and caches the empty", context do
      target = target(context, "logomachy")

      # Real, measured: `q="logomachy"` over 30 days answers `200`, `ok`,
      # total 0.
      GuardianFixture.stub(:empty, context)

      assert {:queued, run} = Discovery.request(target, "guardian")
      assert :ok = Discovery.execute_run(run.id)

      run = Repo.get!(Run, run.id)
      assert run.status == :succeeded
      assert run.completion_reason == :no_results
      assert run.result_count == 0

      spent = Repo.aggregate(from(a in RequestAttempt), :count)
      assert spent == 1

      # And the reload is answered by the negative cache, not the API.
      assert {:cached, cached} = Discovery.request(target, "guardian")
      assert cached.id == run.id
      assert Repo.aggregate(from(a in RequestAttempt), :count) == spent
    end

    test "an envelope the API could not have sent fails as malformed_response", context do
      target = target(context, "bestiality")

      Req.Test.stub(Guardian, fn conn -> Req.Test.json(conn, %{"results" => []}) end)

      assert {:queued, run} = Discovery.request(target, "guardian")
      assert :ok = Discovery.execute_run(run.id)

      run = Repo.get!(Run, run.id)
      assert run.status == :failed
      assert run.error_code == "malformed_response"
    end

    test "a response whose own status is not ok is a provider error", context do
      target = target(context, "bestiality")

      Req.Test.stub(Guardian, fn conn ->
        Req.Test.json(conn, %{"response" => %{"status" => "error", "message" => "nope"}})
      end)

      assert {:queued, run} = Discovery.request(target, "guardian")
      assert :ok = Discovery.execute_run(run.id)

      assert Repo.get!(Run, run.id).error_code == "provider_api_error"
    end
  end

  # ---------------------------------------------------------------------------
  # Retention — the one design decision, proved
  # ---------------------------------------------------------------------------

  describe "the 24-hour rule" do
    setup :isolate_provider

    test "the policy says a day, and it is the only source that says anything" do
      assert Discovery.Policy.for!("guardian").retention_seconds == 86_400
      assert Discovery.Policy.for!("guardian").positive_refresh_seconds == 86_400
      assert Discovery.Policy.for!("guardian").request_budget_limit == 400
      assert Discovery.Policy.for!("guardian").request_budget_window_seconds == 86_400

      # Bing keeps the shared window.
      assert Discovery.Policy.for!("bing-news").retention_seconds ==
               Keyword.fetch!(
                 Application.fetch_env!(:devils_dictionary, :discovery),
                 :retention_seconds
               )

      assert Discovery.Policy.source_retentions() == [{"guardian", 86_400}]
    end

    test "a 25-hour-old Guardian run is deleted by cleanup/0 and Bing's is not", context do
      word = word!(context, "bestiality", ~w(wordnet))
      guardian = aged_run(word, Guardian, "guardian", hours: 25)
      bing = aged_run(word, BingNews, "bing-news", hours: 25)

      assert Repo.get(Run, guardian.run.id)
      assert Repo.get(Run, bing.run.id)

      assert %{expired: expired} = Discovery.cleanup()

      # The Guardian's is gone — including its results, which cascade, and
      # including the fact that it was the run currently on display. The
      # general sweep protects a displayed run; a retention window does not
      # admit that exception, because clause 5 says "whether or not published
      # on Your Website".
      refute Repo.get(Run, guardian.run.id)
      refute Repo.get(Result, guardian.result.id)
      assert expired["guardian"].runs == 1

      # And Bing's day-old run, on the same shelf, in the same database, at the
      # same age, is untouched: its licence names no retention window, so it
      # keeps the shared seven days.
      assert Repo.get(Run, bing.run.id)
      assert Repo.get(Result, bing.result.id)
      refute Map.has_key?(expired, "bing-news")
    end

    test "the provider's own payload goes too, not just the shelf's copy", context do
      guardian =
        aged_run(word!(context, "bestiality", ~w(wordnet)), Guardian, "guardian", hours: 25)

      # The source record holds the provider's own payload — the headline, the
      # byline and the attested sentence — in a revision that outlives the run
      # unless something deletes it. It is the half of the cache a
      # run-only sweep would leave behind, and clause 5 counts it.
      record = Repo.get!(SourceRecord, guardian.result.source_record_id)
      assert Repo.aggregate(revisions(record.id), :count) == 1

      assert %{expired: expired} = Discovery.cleanup()

      refute Repo.get(SourceRecord, record.id)
      assert Repo.aggregate(revisions(record.id), :count) == 0
      assert expired["guardian"].source_records == 1
    end

    test "a Guardian run inside the window is left alone", context do
      guardian =
        aged_run(word!(context, "bestiality", ~w(wordnet)), Guardian, "guardian", hours: 23)

      assert %{expired: expired} = Discovery.cleanup()

      assert Repo.get(Run, guardian.run.id)
      assert Repo.get(Result, guardian.result.id)
      refute Map.has_key?(expired, "guardian")
    end
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  # `Req.Test.json/2` always sends 200; a refusal needs its own status.
  defp json(conn, status, body) do
    conn
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.send_resp(status, Jason.encode!(body))
  end

  defp params(mapping) do
    Guardian.request_options(mapping) |> Keyword.fetch!(:params)
  end

  defp pattern(term) do
    Regex.compile!("(?<![\\p{L}\\p{N}])#{Regex.escape(term)}(?![\\p{L}\\p{N}])", "iu")
  end

  defp row(fields) do
    %{
      "webTitle" => fields["webTitle"] || "A headline with nothing in it",
      "fields" => %{"bodyText" => fields["bodyText"]}
    }
  end

  defp with_config(overrides, fun) do
    original = Application.get_env(:devils_dictionary, :guardian, [])

    try do
      Application.put_env(:devils_dictionary, :guardian, Keyword.merge(original, overrides))
      fun.()
    after
      Application.put_env(:devils_dictionary, :guardian, original)
    end
  end

  defp isolate_provider(_context) do
    catalog = DevilsDictionary.Fixtures.seed_catalog!()
    providers = Application.fetch_env!(:devils_dictionary, :discovery_providers)
    req_options = Application.fetch_env!(:devils_dictionary, :discovery_req_options)

    Application.put_env(:devils_dictionary, :discovery_providers, [Guardian])
    Application.put_env(:devils_dictionary, :discovery_req_options, plug: {Req.Test, Guardian})

    on_exit(fn ->
      Application.put_env(:devils_dictionary, :discovery_providers, providers)
      Application.put_env(:devils_dictionary, :discovery_req_options, req_options)
    end)

    %{sources: catalog.sources, scopes: catalog.scopes}
  end

  defp target(context, lemma) do
    word = word!(context, lemma, ~w(wordnet))

    %{
      object_id: word.object_id,
      term: word.lemma,
      language: word.language_tag,
      relevance: "term"
    }
  end

  # `Discovery.ensure_source/1` is private and is the pipeline's own writer; a
  # test that needs the row before any run has made one writes it from the same
  # `source_attrs/0`, which is what that function does.
  defp register_source!(provider) do
    %DevilsDictionary.Sources.Source{}
    |> DevilsDictionary.Sources.Source.changeset(provider.source_attrs())
    |> Repo.insert(on_conflict: :nothing, conflict_target: [:slug])

    Sources.get_source_by_slug(provider.slug())
  end

  # The same shape `Discovery.ensure_process_actor/0` writes: an `:import`
  # principal, because a mapping the pipeline made is accountable to the
  # process that made it.
  defp process_actor! do
    Repo.insert!(
      DevilsDictionary.Sources.Actor.changeset(%DevilsDictionary.Sources.Actor{}, %{
        actor_kind: :import,
        label: "retention test",
        metadata: %{"process" => "guardian_retention_test"}
      })
    )
  end

  defp revisions(record_id) do
    from(r in DevilsDictionary.Corpus.SourceRecordRevision,
      where: r.source_record_id == ^record_id
    )
  end

  # One succeeded run with one result and one source record, aged backwards so
  # `cleanup/0` sees it as old. Written through `Discovery.ensure_source/1` and
  # the real schemas rather than by hand, so the FK shapes the sweep depends on
  # are the real ones.
  defp aged_run(word, provider, slug, hours: hours) do
    source = register_source!(provider)
    actor = process_actor!()
    then = DateTime.add(DateTime.utc_now(), -hours * 3_600, :second)

    mapping =
      Repo.insert!(%Discovery.Mapping{
        mapping_key: "#{slug}:#{word.object_id}:retention",
        version: 1,
        target_object_id: word.object_id,
        source_id: source.id,
        operation: "#{slug}_attestation",
        parameters: %{"term" => "bestiality"},
        configured_by_actor_id: actor.id,
        enabled: true
      })

    run =
      Repo.insert!(%Run{
        mapping_id: mapping.id,
        adapter_version: provider.adapter_version(),
        request_parameters: %{"term" => "bestiality"},
        request_key: "#{slug}:retention",
        position_key: "#{slug}:retention:0",
        page_context: Ecto.UUID.generate(),
        page: 0,
        status: :succeeded,
        started_at: then,
        completed_at: then,
        # `discovery_runs_terminal_shape` requires both on a succeeded run.
        refresh_after: DateTime.add(then, 86_400, :second),
        expires_at: DateTime.add(then, 7 * 86_400, :second),
        completion_reason: :results,
        result_count: 1,
        display_allowed: true
      })

    {:ok, record} =
      Sources.upsert_record(source, %{
        external_id: "#{slug}:retention",
        url: @kash_patel_url,
        raw: %{"preview_metadata" => %{"title" => "Kash Patel defends FBI hiring policy"}}
      })

    # `fetched_at` is stamped now by `upsert_record/2`; age it, because that is
    # the column the retention sweep reads.
    Repo.update_all(
      from(r in SourceRecord, where: r.id == ^record.id),
      set: [fetched_at: then]
    )

    result =
      Repo.insert!(%Result{
        run_id: run.id,
        external_namespace: "#{slug}_article",
        external_id: "#{slug}-retention",
        source_record_id: record.id,
        position: 0,
        match_details: %{},
        preview_metadata: %{},
        resolution_state: :insufficient_evidence
      })

    %{run: run, result: result, source: source}
  end
end
