defmodule DevilsDictionary.Discovery.Providers.BingNewsTest do
  @moduledoc """
  The readings the conformance fixture cannot cover.

  A fixture holds one captured response and asserts the ids the pipeline
  delivered from it. These are the cases either side of that: the two bodies
  the shared transport's new `body: :xml` capability has to tell apart, the
  gate asked of a term the fixture cannot choose, and the sentence the dated
  locator becomes once `MatchReason` and `Culture` are done with it.
  """

  use DevilsDictionary.DataCase, async: false

  import Ecto.Query
  import DevilsDictionary.WordFixtures
  import Phoenix.LiveViewTest

  alias DevilsDictionary.Discovery
  alias DevilsDictionary.Discovery.{MatchReason, Run, Transport}
  alias DevilsDictionary.Discovery.Conformance.BingNewsFixture
  alias DevilsDictionary.Discovery.Providers.BingNews
  alias DevilsDictionaryWeb.Culture

  @wired_url "https://www.wired.com/story/the-fbi-doubles-down-on-easing-bestiality-hiring-standards/"

  describe "parse_body/1 — the transport's new XML capability" do
    test "an RSS body becomes the map the rest of the pipeline expects" do
      document = BingNewsFixture.document([wired_item()])

      assert {:ok, %{"items" => [item]}} = BingNews.parse_body(document)

      # Floki lowercases the namespaced tag, and the escaped CSS selector
      # `news\\:source` matches nothing — measured on the captured fixture — so
      # the provider walks the tree instead. This is the assertion that keeps it
      # walking: the masthead is the one field the card's credit line is made
      # of, and a selector that silently found none would ship a shelf that
      # credited nobody.
      assert item["news:source"] == "Wired"
      assert item["title"] =~ "Bestiality"
      assert item["pubdate"] == "Tue, 15 Sep 2026 06:50:00 GMT"
      assert item["link"] =~ "apiclick.aspx"
    end

    test "a channel with no items is an empty answer and not a malformed one" do
      # Measured: `q=referendum` answered 200 with a valid channel and no
      # `<item>` at all.
      assert {:ok, %{"items" => []}} = BingNews.parse_body(BingNewsFixture.document([]))
    end

    test "garbage is refused" do
      assert BingNews.parse_body("") == :error
      assert BingNews.parse_body("this is not a feed") == :error

      assert BingNews.parse_body("<html><body><p>Something went wrong</p></body></html>") ==
               :error

      assert BingNews.parse_body(~s({"results": []})) == :error
      assert BingNews.parse_body(<<0xFF, 0xFE, 0x00>>) == :error
      assert BingNews.parse_body(nil) == :error
    end

    test "the transport reads the capability and no other provider's" do
      assert Transport.body_format(BingNews) == :xml
      assert Transport.body_format(DevilsDictionary.Discovery.Providers.Poetrydb) == :json
      assert BingNews.capabilities().body == :xml
    end
  end

  describe "publisher_url/1 — the apiclick link is never the item" do
    test "the url= parameter is decoded out of the redirect" do
      link =
        "http://www.bing.com/news/apiclick.aspx?ref=FexRss&aid=&tid=6ab14198&url=" <>
          "https%3a%2f%2fwww.wired.com%2fstory%2fthe-fbi-doubles-down-on-easing-bestiality-hiring-standards%2f" <>
          "&c=1486738033267397200&mkt=en-us"

      assert {:ok, @wired_url} = BingNews.publisher_url(link)
    end

    test "a link with no url= parameter is refused rather than pointed at Bing" do
      assert BingNews.publisher_url("http://www.bing.com/news/apiclick.aspx?ref=FexRss") == :error
      assert BingNews.publisher_url("http://www.bing.com/news/apiclick.aspx") == :error
      assert BingNews.publisher_url(nil) == :error
    end

    test "a url= that is not an absolute http(s) URL with a host is refused" do
      # The same standard `Culture.external_href/1` applies to anything that
      # reaches an `href` (#116 Phase 3): a scheme an upstream record carried is
      # not a link we pass on.
      refused = [
        "/relative/path",
        "javascript:alert(1)",
        "data:text/html,x",
        "mailto:a@b.c",
        "http://",
        "not a url at all"
      ]

      for value <- refused do
        assert BingNews.publisher_url(
                 "http://www.bing.com/news/apiclick.aspx?url=" <> URI.encode_www_form(value)
               ) == :error
      end
    end
  end

  describe "normalize/1 and article_id/1 — one article, one identity" do
    test "scheme and host are lowercased and the fragment is dropped" do
      assert BingNews.normalize(URI.parse("HTTPS://WWW.Wired.COM/story/x/#comments")) ==
               "https://www.wired.com/story/x/"
    end

    test "tracking parameters are stripped and what is left is sorted" do
      assert BingNews.normalize(
               URI.parse("https://www.theguardian.com/x?utm_source=t&b=2&fbclid=9&a=1&CMP=share")
             ) == "https://www.theguardian.com/x?a=1&b=2"
    end

    test "a URL whose only parameters were tracking loses its query entirely" do
      assert BingNews.normalize(URI.parse("https://example.com/x?utm_medium=social&smid=tw")) ==
               "https://example.com/x"
    end

    test "the same article reached two ways is one id" do
      plain = BingNews.article_id(BingNews.normalize(URI.parse(@wired_url)))

      decorated =
        BingNews.article_id(
          BingNews.normalize(URI.parse(@wired_url <> "?utm_source=twitter&fbclid=IwAR9#top"))
        )

      assert plain == decorated

      # And the redirect is not the identity. Bing's `apiclick` link carries a
      # per-response `tid`, so hashing it would make the same article a new
      # item on every fetch.
      refute plain == BingNews.article_id("http://www.bing.com/news/apiclick.aspx?tid=6ab14198")
    end

    test "different articles are different ids" do
      refute BingNews.article_id("https://example.com/a") ==
               BingNews.article_id("https://example.com/b")
    end
  end

  describe "the gate — the search proposes, the text disposes" do
    test "a whole word in the headline is a headline" do
      assert BingNews.matched_text("bestiality", %{
               "title" => "Kash Patel Defends Bestiality Standards at the FBI",
               "description" => "A Senate hearing got weird ..."
             }) == {"a headline", "Kash Patel Defends Bestiality Standards at the FBI"}
    end

    test "a headline without the word falls through to the description, and says so" do
      assert BingNews.matched_text("bestiality", %{
               "title" => "Patel grilled at fiery Senate hearing",
               "description" => "The hearing turned on bestiality and prostitution."
             }) == {"a summary", "The hearing turned on bestiality and prostitution."}
    end

    test "a substring is not a use of the word" do
      # The measured case, and the reason the gate is a Unicode boundary rather
      # than a `String.contains?`: `q=red herring` answered with *No Red
      # Herrings Here: Why Plain Language Wins at Trial* (JD Supra, 15 September
      # 2026). *Herrings* is not *herring*, and a card reading *Uses “red
      # herring” at a headline* over it would be the shelf citing a plural it
      # was not shown.
      assert BingNews.matched_text("red herring", %{
               "title" => "No Red Herrings Here: Why Plain Language Wins at Trial",
               "description" => "Trial lawyers spend significant time refining themes."
             }) == nil

      # And the constructed shape the conformance fixture carries.
      assert BingNews.matched_text("bestiality", %{
               "title" => "FBI hiring row: #Bestialitygate trends as Patel testifies",
               "description" => "The hashtag outran the hearing it came from."
             }) == nil
    end

    test "a hyphen is a boundary and an apostrophe is not a different word" do
      assert {"a headline", _} =
               BingNews.matched_text("war", %{"title" => "The war-weary voter"})

      assert {"a headline", _} =
               BingNews.matched_text("war", %{"title" => "The war's fourth year"})

      assert BingNews.matched_text("war", %{"title" => "A warm reception in Warsaw"}) == nil
      assert BingNews.matched_text("war", %{"title" => "Steps toward a deal"}) == nil
    end

    test "the match is case-insensitive, because a headline is title case" do
      assert {"a headline", _} =
               BingNews.matched_text("bestiality", %{"title" => "BESTIALITY AT THE FBI"})
    end

    test "a row with neither field is not a match" do
      assert BingNews.matched_text("war", %{}) == nil
      assert BingNews.matched_text("war", %{"title" => "", "description" => "   "}) == nil
    end
  end

  describe "published_at/1 and the freshness window" do
    test "an RFC 1123 pubDate is read" do
      assert {:ok, ~U[2026-09-15 06:50:00Z]} =
               BingNews.published_at("Tue, 15 Sep 2026 06:50:00 GMT")

      # Without the day name, and with a single-digit day: both are legal RSS.
      assert {:ok, ~U[2026-09-05 17:00:00Z]} = BingNews.published_at("5 Sep 2026 17:00:00 GMT")
    end

    test "a date it cannot read is not treated as fresh" do
      for value <- [
            "",
            "yesterday",
            "Tue, 32 Sep 2026 06:50:00 GMT",
            "Tue, 15 Foo 2026 06:50:00 GMT"
          ] do
        assert BingNews.published_at(value) == :error
      end

      assert BingNews.published_at(nil) == :error
    end

    test "the window is thirty days by default and configurable" do
      assert BingNews.max_age_days() == 30
    end

    test "the clock is injected, so the fixture's real dates stay deterministic" do
      assert BingNews.now() == ~U[2026-09-21 12:00:00Z]
    end
  end

  describe "the locator, and the sentence it becomes" do
    test "a dated locator names where, who and when" do
      assert BingNews.locator("a headline", "Wired", ~D[2026-09-15]) ==
               "a headline, Wired, 15 September 2026"

      # Not zero-padded: this is a sentence, not a timestamp.
      assert BingNews.locator("a headline", "The Guardian", ~D[2026-09-05]) ==
               "a headline, The Guardian, 5 September 2026"

      # A feed item with no `News:Source` still cites its date.
      assert BingNews.locator("a summary", nil, ~D[2026-09-15]) ==
               "a summary, 15 September 2026"
    end

    test "MatchReason renders it as one sentence, with no change to MatchReason" do
      details = %{
        "kind" => "attestation",
        "query" => "bestiality",
        "lines" => [
          %{
            "locator" => "a headline, Wired, 15 September 2026",
            "text" => "The FBI Doubles Down on Easing ‘Bestiality’ Hiring Standards"
          }
        ]
      }

      assert [reason] = MatchReason.from_result(details, "bestiality")
      assert reason.kind == :attestation
      assert MatchReason.evidence(reason) == :attestation

      # The sentence the reader gets, and the one #135 asked for. It read *at
      # a headline* until #142: `MatchReason`'s attestation clause composes
      # `"Uses " <> term <> at(locator)` and `at/1` was hardcoded to *at*,
      # which is right for a numbered point (*line 4*) and wrong for a named
      # part of a work. #140 measured it in the browser and reported it
      # rather than fixing it, because #135 put `match_reason.ex` out of
      # scope; #142 was editing the attestation tests anyway and took the
      # one-line fix, so this provider's shelf reads correctly now without
      # this provider changing at all.
      assert MatchReason.describe(reason) ==
               "Uses “bestiality” in a headline, Wired, 15 September 2026."
    end
  end

  describe "the card's date line" do
    test "a news card prints the day" do
      html = render_news(published_at: "2026-09-15T06:50:00Z", year: "2026")

      assert html =~ "15 Sep 2026"
    end

    test "an item with no published_at still prints its year, unchanged" do
      html = render_news(published_at: nil, year: "1925")

      # The date line itself, not the page: *15 September 2026* is still in the
      # About note's locator, which is the reason and not the card's date.
      assert html =~ "<span>1925</span>"
      refute html =~ "<span>1925 Sep"
    end

    test "an unreadable published_at falls back rather than printing rubbish" do
      html = render_news(published_at: "the fifteenth", year: "2026")

      assert html =~ "2026"
      refute html =~ "the fifteenth"
    end

    test "a day without a leading zero, because this is a sentence" do
      html = render_news(published_at: "2026-09-05T17:00:00Z", year: "2026")

      assert html =~ "5 Sep 2026"
      refute html =~ "05 Sep 2026"
    end

    test "the masthead is on the card once" do
      html = render_news(published_at: "2026-09-15T06:50:00Z", year: "2026")

      # Measured on `/define/bestiality` at 1280 px before this was settled:
      # the card read the masthead twice, once as the creator line and once as
      # the `:credited` row's credit beneath it. The provider writes it to the
      # creator keys only, so the credit line does not render — see the comment
      # on `item/6`.
      card =
        Regex.run(~r|<li id="culture-result-news_article-[^"]*".*?</li>|s, html) |> List.first()

      assert [_one] = Regex.scan(~r/Wired/, card)

      # The `:credited` row renders its line only when the item carries one,
      # and this item deliberately does not.
      refute html =~ "culture-attribution-news_article-"
    end
  end

  describe "the pipeline, end to end" do
    setup do
      catalog = DevilsDictionary.Fixtures.seed_catalog!()
      providers = Application.fetch_env!(:devils_dictionary, :discovery_providers)
      req_options = Application.fetch_env!(:devils_dictionary, :discovery_req_options)

      Application.put_env(:devils_dictionary, :discovery_providers, [BingNews])
      Application.put_env(:devils_dictionary, :discovery_req_options, plug: {Req.Test, BingNews})

      on_exit(fn ->
        Application.put_env(:devils_dictionary, :discovery_providers, providers)
        Application.put_env(:devils_dictionary, :discovery_req_options, req_options)
      end)

      %{sources: catalog.sources, scopes: catalog.scopes}
    end

    test "an XML body Bing could not have sent fails as malformed_response", context do
      target = target(context, "bestiality")

      Req.Test.stub(BingNews, fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/xml")
        |> Plug.Conn.send_resp(200, "<html><body>Something went wrong.</body></html>")
      end)

      assert {:queued, run} = Discovery.request(target, "bing-news")
      assert :ok = Discovery.execute_run(run.id)

      run = Repo.get!(Run, run.id)
      assert run.status == :failed
      assert run.error_code == "malformed_response"
    end

    test "the run is dated, credited and linked to the publisher", context do
      target = target(context, "bestiality")
      BingNewsFixture.stub(:results, context)

      assert {:queued, run} = Discovery.request(target, "bing-news")
      assert :ok = Discovery.execute_run(run.id)

      state = Discovery.state(target.object_id, "bing-news")
      assert [first | _] = state.items

      metadata = first.preview_metadata
      assert metadata["source_url"] == @wired_url
      refute metadata["source_url"] =~ "bing.com"
      assert metadata["author"] == "Wired"
      assert metadata["artist"] == "Wired"
      # Once, not twice: the `:credited` row would render this as a second
      # line under the creator line that already says it.
      refute Map.has_key?(metadata, "attribution")
      assert metadata["published_at"] == "2026-09-15T06:50:00Z"
      assert metadata["content_type"] == "news"

      assert [%{"locator" => locator}] = first.match_details["lines"]
      assert locator == "a headline, Wired, 15 September 2026"

      # Every item carries its own namespaced identity, which is what lets a
      # later keyed Guardian provider (#63) fold into it on the same URL.
      assert first.external_namespace == "news_article"

      # Persisted, so the keys come back as strings.
      assert [%{"namespace" => "news_article", "external_id" => id}] = first.identifiers
      assert id == first.external_id
    end

    test "a word whose only coverage is old spends one request and caches the empty",
         context do
      target = target(context, "logomachy")

      # Real, measured: the feed's whole answer for this word is two *Word of
      # the day* pieces from March 2026, outside any freshness window.
      Req.Test.stub(BingNews, fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/xml")
        |> Plug.Conn.send_resp(200, BingNewsFixture.document([logomachy_item()]))
      end)

      assert {:queued, run} = Discovery.request(target, "bing-news")
      assert :ok = Discovery.execute_run(run.id)

      run = Repo.get!(Run, run.id)
      assert run.status == :succeeded
      assert run.completion_reason == :no_results
      assert run.result_count == 0

      spent = Repo.aggregate(from(a in DevilsDictionary.Discovery.RequestAttempt), :count)
      assert spent == 1

      # And the negative cache answers the reload rather than the feed.
      assert {:cached, cached} = Discovery.request(target, "bing-news")
      assert cached.id == run.id
      assert Repo.aggregate(from(a in DevilsDictionary.Discovery.RequestAttempt), :count) == spent
    end
  end

  # ---------------------------------------------------------------------------

  defp target(context, lemma) do
    word = word!(context, lemma, ~w(wordnet))

    %{
      object_id: word.object_id,
      term: word.lemma,
      language: word.language_tag,
      relevance: "term"
    }
  end

  # The shape `Discovery.state/2` returns, as `culture_chrome_test.exs` builds
  # it: the renderer can be asked this question directly because a transient
  # item, a persisted item and a catalog item are all this shape.
  defp render_news(published_at: published_at, year: year) do
    metadata =
      %{
        "title" => "The FBI Doubles Down on Easing ‘Bestiality’ Hiring Standards",
        "author" => "Wired",
        "artist" => "Wired",
        "year" => year,
        "published_at" => published_at,
        "source_url" => @wired_url,
        "content_type" => "news",
        "provider" => "Bing News"
      }
      |> Enum.reject(fn {_key, value} -> is_nil(value) end)
      |> Map.new()

    item = %{
      external_namespace: "news_article",
      external_id: "ac7bbfad8c0c66c31fac22d9eb3b0711",
      preview_metadata: metadata,
      match_details: %{
        "kind" => "attestation",
        "query" => "bestiality",
        "lines" => [
          %{"locator" => "a headline, Wired, 15 September 2026", "text" => metadata["title"]}
        ]
      }
    }

    render_component(&Culture.section/1,
      states: %{
        "bing-news" => %{
          status: :ready,
          items: [item],
          provider: "bing-news",
          provider_name: "Bing News",
          provider_detail: "dated headlines",
          content_types: [:news],
          mapping_id: 1,
          tier: :plebs,
          term: "bestiality",
          relevance: "term",
          page: 0
        }
      }
    )
  end

  defp wired_item do
    ~s(<item><title>The FBI Doubles Down on Easing ‘Bestiality’ Hiring Standards</title>) <>
      ~s(<link>http://www.bing.com/news/apiclick.aspx?ref=FexRss&amp;aid=&amp;tid=6ab14198&amp;url=) <>
      ~s(https%3a%2f%2fwww.wired.com%2fstory%2fthe-fbi-doubles-down-on-easing-bestiality-hiring-standards%2f) <>
      ~s(&amp;c=1486738033267397200&amp;mkt=en-us</link>) <>
      ~s(<description>FBI director Kash Patel claimed to US senators that the removal of a bar ) <>
      ~s(on hiring people who had engaged in bestiality was aimed at protecting sexual assault ) <>
      ~s(survivors.</description>) <>
      ~s(<pubDate>Tue, 15 Sep 2026 06:50:00 GMT</pubDate>) <>
      ~s(<News:Source>Wired</News:Source>) <>
      ~s(<News:Image>http://www.bing.com/th?id=ONUT.x&amp;pid=News</News:Image></item>)
  end

  defp logomachy_item do
    ~s(<item><title>Word of the day: Logomachy</title>) <>
      ~s(<link>http://www.bing.com/news/apiclick.aspx?url=) <>
      ~s(https%3a%2f%2fwww.msn.com%2fen-us%2fnews%2fother%2fword-of-the-day-logomachy%2far-AA1x) <>
      ~s(&amp;mkt=en-us</link>) <>
      ~s(<description>Expanding the lexicon of rare and intellectually stimulating English ) <>
      ~s(expressions, today’s Word of the Day is “logomachy”.</description>) <>
      ~s(<pubDate>Mon, 30 Mar 2026 05:03:00 GMT</pubDate>) <>
      ~s(<News:Source>MSN</News:Source></item>)
  end
end
