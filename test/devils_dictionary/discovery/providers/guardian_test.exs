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
  import Phoenix.LiveViewTest

  alias DevilsDictionary.Discovery
  alias DevilsDictionary.Discovery.{MatchReason, RequestAttempt, Result, Run, Transport}
  alias DevilsDictionary.Discovery.Conformance.GuardianFixture
  alias DevilsDictionary.Discovery.Provider.Helpers
  alias DevilsDictionary.Discovery.Providers.{BingNews, Guardian}
  alias DevilsDictionary.Sources
  alias DevilsDictionary.Sources.SourceRecord
  alias DevilsDictionaryWeb.Culture

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

    test "the window after a hit is cut between characters, never inside one" do
      # No sentence end after the word, and every character after it is two
      # bytes: a window counted in bytes lands inside one of them (the 200th
      # byte after the hit is the first byte of an `é`) and the result is not
      # a string at all — `clamp/1` counts graphemes and leaves it alone, and
      # the JSON encoder at insert is what finally refuses it, taking the run
      # with it.
      text = "bestiality " <> String.duplicate("é ", 120)

      sentence = Guardian.sentence(text, pattern("bestiality"))

      assert String.valid?(sentence)
      assert String.starts_with?(sentence, "bestiality")
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
      # as the issue writes it — `Helpers.News.article_id(Helpers.News.normalize(
      # URI.parse(webUrl)))` — and compared against what the provider puts on
      # its item, so a provider that stopped calling into Bing and started
      # copying it would fail here.
      {:ok, url} = Guardian.article_url(@kash_patel_url)

      assert Guardian.news_article_id(url) ==
               Helpers.News.article_id(Helpers.News.normalize(URI.parse(@kash_patel_url)))
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

    test "a result without an id is dropped, and the rest of the page survives", context do
      # The API always sends one. The day it does not, the item must fall out
      # here rather than reach the result changeset, where one nil
      # `external_id` fails the run and every good item with it.
      target = target(context, "bestiality")

      # `Guardian.now/0` and not the wall clock: the suite pins the provider's
      # clock to September 2026 so the fixture's real dates stay fresh, and an
      # article stamped an hour before *today* is more than a day in this
      # provider's future once the wall clock passes the pin — which the
      # freshness gate drops, taking the test's subject with it.
      published_at =
        Guardian.now() |> DateTime.add(-3600, :second) |> DateTime.to_iso8601()

      row = fn id, url ->
        %{
          "id" => id,
          "type" => "article",
          "sectionId" => "us-news",
          "sectionName" => "US news",
          "webPublicationDate" => published_at,
          "webTitle" => "A headline",
          "webUrl" => url,
          "fields" => %{
            "headline" => "A headline",
            "byline" => "A Reporter",
            "bodyText" => "The word bestiality is used in this sentence. And another."
          }
        }
      end

      results = [
        row.(nil, "https://www.theguardian.com/us-news/2026/sep/15/no-id") |> Map.delete("id"),
        row.(
          "us-news/2026/sep/15/has-id",
          "https://www.theguardian.com/us-news/2026/sep/15/has-id"
        )
      ]

      Req.Test.stub(Guardian, fn conn ->
        Req.Test.json(conn, %{
          "response" => %{
            "status" => "ok",
            "total" => 2,
            "startIndex" => 1,
            "pageSize" => 12,
            "currentPage" => 1,
            "pages" => 1,
            "results" => results
          }
        })
      end)

      assert {:queued, run} = Discovery.request(target, "guardian")
      assert :ok = Discovery.execute_run(run.id)

      assert Repo.get!(Run, run.id).status == :succeeded

      state = Discovery.state(target.object_id, "guardian")
      assert Enum.map(state.items, & &1.external_id) == ["us-news/2026/sep/15/has-id"]
    end

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
               Helpers.News.article_id(Helpers.News.normalize(URI.parse(@kash_patel_url)))

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
  # The mark clause 6(b)(vi) makes a condition
  # ---------------------------------------------------------------------------

  describe "the \"Powered by The Guardian\" mark" do
    test "the provider declares it, and declares the Guardian's own file" do
      mark = Guardian.attribution_mark()

      # Clause 6(b)(vi): "a reproduction of the 'Powered By' file found at
      # http://www.theguardian.com/open-platform/logos". Not redrawn, not
      # retraced, not recoloured — the file, committed.
      assert mark.light == "/images/guardian-powered-by.png"
      assert mark.dark == "/images/guardian-powered-by-dark.png"
      assert mark.alt == "Powered by The Guardian"
      # And the logos page: "Please ensure that the image links back to
      # theguardian.com".
      assert mark.href == "https://www.theguardian.com/"
      assert mark.width == 80

      # Clause 6(b)(vi) again: "adjacent to our content". Where a mark goes is
      # the licence's answer and travels as data, so the reader can draw this
      # one beside the rail and Spotify's on each card without knowing either
      # source by name (#144 followups).
      assert mark.placement == :shelf
      assert Culture.mark(mark) == Map.put(mark, :link_text, nil)
    end

    test "both files are committed, are PNGs, and are the ones published" do
      for path <- ["guardian-powered-by.png", "guardian-powered-by-dark.png"] do
        file = Path.join("priv/static/images", path)
        assert File.exists?(file), "#{path} is not committed"

        # 140x45 RGBA, the dimensions the Guardian publishes. Read out of the
        # IHDR chunk rather than trusted, so a file swapped for a redrawn one
        # of another size fails here.
        assert <<0x89, "PNG\r\n", 0x1A, "\n", _len::32, "IHDR", width::32, height::32,
                 _rest::binary>> = File.read!(file)

        assert {width, height} == {140, 45}
      end
    end

    test "the shelf renders it, linked and in both themes" do
      html = render_shelf(with_mark: true)

      assert html =~ ~s(id="culture-mark-guardian")
      assert html =~ ~s(href="https://www.theguardian.com/")
      assert html =~ ~s(aria-label="Powered by The Guardian")

      # Both variants ship and CSS picks one, so the mark is legible in either
      # theme without JavaScript and without a filter over the wrong file.
      assert html =~ ~s(src="/images/guardian-powered-by.png")
      assert html =~ ~s(src="/images/guardian-powered-by-dark.png")
      assert html =~ "dark:hidden"
      assert html =~ "dark:block"

      # Never clamped and never behind a pointer: a condition of the licence
      # that only some readers see is not met. Asserted on the mark's own
      # markup, because the cards beside it clamp their titles and credits
      # legitimately.
      mark = mark_markup(html)
      refute mark =~ "line-clamp"
      refute mark =~ "group-hover"
      refute mark =~ "sr-only"

      # Exactly one of the two variants is visible in each theme: the light
      # file carries `dark:hidden` and the dark file `hidden … dark:block`.
      # (The dark one being hidden in light mode is the mechanism, not a
      # violation — what would be one is neither of them showing.)
      assert mark =~ ~s(class="max-w-full dark:hidden")
      assert mark =~ ~s(class="hidden max-w-full dark:block")
    end

    test "a source that declares no mark gains none" do
      html = render_shelf(with_mark: false)

      refute html =~ "culture-mark-"
      refute html =~ "guardian-powered-by"
    end

    test "Culture knows no provider by name — it draws whatever the state carried" do
      # Promise 9, asserted rather than grepped for: a source this component
      # has never heard of, carrying a mark of its own, is drawn exactly the
      # same way. If `Culture` had learned the word "guardian" anywhere, this
      # would render nothing.
      html =
        render_shelf(
          with_mark: true,
          provider: "gazette",
          provider_name: "The Gazette",
          mark: %{
            light: "/images/gazette.png",
            dark: nil,
            alt: "Powered by The Gazette",
            href: "https://gazette.test/",
            width: 64,
            placement: :shelf
          }
        )

      assert html =~ ~s(id="culture-mark-gazette")
      assert html =~ ~s(href="https://gazette.test/")
      assert html =~ ~s(src="/images/gazette.png")
      assert html =~ ~s(width="64")

      # And a mark with no dark variant ships one image, unconditionally: the
      # `dark:hidden` that hides the light one is only correct when there is a
      # dark one to show instead.
      refute html =~ "dark:hidden"
      refute html =~ "dark:block"
    end

    test "and the other placement the same way: a card mark on a source it has never heard of" do
      # The second half of promise 9 since the followups to #144. One shape,
      # two placements, and the component asks the mark where it goes rather
      # than asking which provider sent it — so a fictional source's `:card`
      # mark lands on the card, under the credit, with the wording its licence
      # dictates for the link back.
      html =
        render_shelf(
          with_mark: true,
          provider: "gazette",
          provider_name: "The Gazette",
          mark: %{
            light: "/images/gazette-black.svg",
            dark: "/images/gazette-white.svg",
            alt: "The Gazette",
            href: nil,
            link_text: "Read on The Gazette",
            width: 70,
            placement: :card
          }
        )

      # On the card, keyed by the item it attributes...
      assert html =~ ~s(id="culture-mark-guardian_article-#{GuardianFixture.kash_patel_id()}")
      assert html =~ ~s(src="/images/gazette-black.svg")
      assert html =~ ~s(src="/images/gazette-white.svg")
      assert html =~ ~s(width="70")
      # ...and the link back reads what the licence permits, not "Source".
      assert html =~ "Read on The Gazette ↗"
      refute html =~ "Source ↗"

      # ...and nowhere near the byline, which is the other licence's answer.
      refute html =~ ~s(id="culture-mark-gazette")
    end
  end

  # ---------------------------------------------------------------------------
  # Retention — the one design decision, proved
  # ---------------------------------------------------------------------------

  describe "the 24-hour rule" do
    setup :isolate_provider

    test "the policy says a day, and it is the only source that says anything" do
      # An hour under the day: the sweep runs every fifteen minutes, so a
      # window of exactly 86_400 would let a record live 24h15m, and clause 5
      # says twenty-four.
      assert Discovery.Policy.for!("guardian").retention_seconds == 82_800
      assert Discovery.Policy.for!("guardian").retention_seconds + 15 * 60 <= 86_400
      assert Discovery.Policy.for!("guardian").positive_refresh_seconds == 86_400
      assert Discovery.Policy.for!("guardian").request_budget_limit == 400
      assert Discovery.Policy.for!("guardian").request_budget_window_seconds == 86_400

      # Bing keeps the shared window.
      assert Discovery.Policy.for!("bing-news").retention_seconds ==
               Keyword.fetch!(
                 Application.fetch_env!(:devils_dictionary, :discovery),
                 :retention_seconds
               )

      # Spotify (#143) names a window of its own — seven days, the terms'
      # *delete older data*. Since #144 Phase 2 the window is a policy key
      # like any other, read per source by the sweep.
      assert Discovery.Policy.retention_seconds("guardian") == 82_800
      assert Discovery.Policy.retention_seconds("spotify") == 7 * 24 * 60 * 60
    end

    test "a 25-hour-old Guardian run is withdrawn by cleanup/0 and Bing's, inside its window, is not",
         context do
      # Each source against its own window (#144 Phase 2): the Guardian's is
      # twenty-three hours, and the shared one the suite configures is two,
      # so Bing's run is aged one hour to sit inside it. Under the shipped
      # seven days it would sit inside at twenty-five too.
      word = word!(context, "bestiality", ~w(wordnet))
      guardian = aged_run(word, Guardian, "guardian", hours: 25)
      bing = aged_run(word, BingNews, "bing-news", hours: 1)

      assert Repo.get(Run, guardian.run.id).display_allowed
      assert Repo.get(Run, bing.run.id).display_allowed

      assert %{withdrawn: 1, expired_results: 1} = Discovery.cleanup()

      # The Guardian's content is gone — its result, and with it the fact
      # that it was the run currently on display. The bounded sweep protects
      # a displayed run; a retention window does not admit that exception,
      # because clause 5 says "whether or not published on Your Website". The
      # run row is withdrawn rather than deleted: it is the ledger of what
      # was spent, and the bounded sweep may still collect it afterwards.
      refute Repo.get(Result, guardian.result.id)
      refute match?(%Run{display_allowed: true}, Repo.get(Run, guardian.run.id))

      # And Bing's run, on the same shelf, in the same database, is untouched:
      # its licence names no window, so it keeps the shared one.
      assert Repo.get(Run, bing.run.id).display_allowed
      assert Repo.get(Result, bing.result.id)
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

      assert %{expired_source_records: 1} = Discovery.cleanup()

      refute Repo.get(SourceRecord, record.id)
      assert Repo.aggregate(revisions(record.id), :count) == 0
    end

    test "a Guardian run inside the window is left alone", context do
      # Twenty-two hours: the window is twenty-three, an hour under the day
      # so that a sweep every fifteen minutes still deletes inside it.
      guardian =
        aged_run(word!(context, "bestiality", ~w(wordnet)), Guardian, "guardian", hours: 22)

      assert %{withdrawn: 0, expired_results: 0} = Discovery.cleanup()

      assert Repo.get(Run, guardian.run.id).display_allowed
      assert Repo.get(Result, guardian.result.id)
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

  # Just the mark's own anchor, so an assertion about it is not an assertion
  # about the cards beside it.
  defp mark_markup(html) do
    case Regex.run(~r/<a[^>]*id="culture-mark-[^"]*".*?<\/a>/s, html) do
      [markup] -> markup
      _ -> flunk("no attribution mark in the rendered shelf")
    end
  end

  # One News shelf with one item, as `Discovery.state/2` shapes it.
  defp render_shelf(options) do
    with_mark = Keyword.fetch!(options, :with_mark)
    provider = Keyword.get(options, :provider, "guardian")
    provider_name = Keyword.get(options, :provider_name, "The Guardian")
    mark = Keyword.get(options, :mark, Guardian.attribution_mark())

    state =
      %{
        status: :ready,
        items: [
          %{
            external_namespace: "guardian_article",
            external_id: GuardianFixture.kash_patel_id(),
            preview_metadata: %{
              "title" => "Kash Patel defends FBI hiring policy",
              "author" => "Ariana Baio",
              "artist" => "Ariana Baio",
              "attribution" => "The Guardian",
              "published_at" => "2026-09-15T17:20:47Z",
              "year" => "2026",
              "source_url" => @kash_patel_url,
              "content_type" => "news"
            },
            match_details: %{
              "kind" => "attestation",
              "query" => "bestiality",
              "lines" => [
                %{
                  "locator" => "the text, The Guardian, 15 September 2026",
                  "text" => "A sentence."
                }
              ]
            }
          }
        ],
        provider: provider,
        provider_name: provider_name,
        provider_detail: "dated reporting",
        content_types: [:news],
        mapping_id: 1,
        tier: :plebs,
        term: "bestiality",
        relevance: "term",
        page: 0
      }
      |> then(fn state ->
        if with_mark, do: Map.put(state, :attribution_mark, mark), else: state
      end)

    render_component(&Culture.section/1, states: %{provider => state})
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
        # `expires_at` is what the sweep reads since #144 Phase 2 — the
        # source's own window from `completed_at`, as `publish` writes it.
        refresh_after: DateTime.add(then, 86_400, :second),
        expires_at: DateTime.add(then, Discovery.Policy.retention_seconds(slug), :second),
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
