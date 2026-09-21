defmodule DevilsDictionary.Discovery.Conformance.GuardianFixture do
  @moduledoc """
  Conformance for `DevilsDictionary.Discovery.Providers.Guardian`.

  The responses here are **real**, captured on 2026-09-21 from

      GET https://content.guardianapis.com/search
          ?q="bestiality"&type=article&from-date=2026-08-22&order-by=newest
          &show-fields=headline,trailText,byline,bodyText,firstPublicationDate

  with the `api-key` parameter stripped before anything was written to disk.
  Every `id`, `webUrl`, `webPublicationDate`, `webTitle`, `headline`, `byline`,
  `trailText`, `sectionName` and `type` below is exactly what the API sent.

  ## Why `bodyText` is a window and not the whole body

  It is the one field that is not verbatim, and the reason is the terms rather
  than the file size. Clause 5 of the Open Platform terms says OP Content may
  not be kept for longer than 24 hours, **"whether or not published on Your
  Website"** — and a fixture committed to a git repository is the most
  permanent holding there is. So each `bodyText` is cut to roughly 120
  characters either side of the sentence that attests the word: enough real
  text for `Guardian.sentence/2` to walk backwards to a real sentence boundary
  and forwards to a real one, and no more of the article than that gate needs.
  The full bodies measured 3,268 / 4,432 / 6,080 / 7,013 / 7,538 characters.

  This is a compromise and it is written down as one: it holds less than a
  verbatim capture would, and it still holds five headlines, five bylines and
  five paragraphs indefinitely. `docs/integrations/guardian.md` records it
  under the retention decision.

  ## What the `:results` page is there to refuse

  Three rows, of which **two** survive, and the expected ids say which by
  leaving the third out:

    * **The Anthony Page obituary** passes on its body alone — the word is
      nowhere in its title — and its attesting sentence is the longest of the
      five at **383 characters**, so it is also what exercises the ~200
      character clamp.
    * **`#Bestialitygate`** is the one constructed row in this file. All six
      articles the API really returned for this word contain it as a word, so
      the substring case cannot be captured and has to be written:
      `bestialitygate` carries the term with a letter after it, which the
      Unicode-boundary gate refuses in the body and in the title alike.
    * **The Kash Patel piece** is the one that matters beyond this suite. It
      is the article Bing's feed also carries, and
      `guardian_test.exs` asserts that the `news_article` id written for it
      here equals `BingNews.article_id(BingNews.normalize(...))` of the same
      URL — which is what makes it one card on `/define/bestiality` and not
      two.

  The `:paged` scenario is the five real articles across the API's own paging,
  three then two, because unlike Bing's feed this API really does page and one
  page really is one request.

  The external ids are the Guardian's own `id` paths, written as literals so
  that changing how an article is identified fails here rather than quietly
  agreeing with itself.
  """

  use DevilsDictionary.Discovery.Conformance.Fixture

  alias DevilsDictionary.Discovery.Providers.Guardian

  @maga "commentisfree/2026/sep/19/maga-pro-life-miscarriages-pregnancy-ice-detention"
  @obituary "stage/2026/sep/18/anthony-page-obituary"
  @morning_mail "australia-news/2026/sep/16/morning-mail-wednesday-ntwnfb"
  @kash_patel "us-news/2026/sep/15/kash-patel-fbi-hiring-policy-bestiality"
  @roberts "australia-news/2026/aug/26/one-nation-malcolm-roberts-two-minds-gay-equal-rights-ntwnfb"

  @doc "The Kash Patel article's id — the one Bing also carries."
  def kash_patel_id, do: @kash_patel

  @doc "The Kash Patel article's `webUrl`, for the cross-provider identity check."
  def kash_patel_url,
    do: "https://www.theguardian.com/us-news/2026/sep/15/kash-patel-fbi-hiring-policy-bestiality"

  @impl true
  def provider, do: Guardian

  @impl true
  def covered_target(context) do
    word = word!(context, "bestiality", ~w(wordnet))

    %{
      object_id: word.object_id,
      term: word.lemma,
      language: word.language_tag,
      relevance: "term"
    }
  end

  @impl true
  def stub(:empty, _context) do
    # The real shape of an empty answer, measured on `q="logomachy"`: `200`,
    # `"status": "ok"`, `"total": 0` and no results. An empty result and never
    # a malformed one.
    respond([])
    %{pages: [[]]}
  end

  def stub(:results, _context) do
    respond([obituary(), substring_noise(), kash_patel()])
    %{pages: [[@obituary, @kash_patel]]}
  end

  def stub(:paged, _context) do
    respond([maga(), obituary(), morning_mail(), kash_patel(), roberts()])
    %{pages: [[@maga, @obituary, @morning_mail], [@kash_patel, @roberts]]}
  end

  # ---------------------------------------------------------------------------
  # The real articles
  # ---------------------------------------------------------------------------

  defp maga do
    result(
      @maga,
      "Opinion",
      "2026-09-19T12:00:47Z",
      "Maga wants more babies. But they don’t seem too worried about miscarriages in ICE detention | ",
      "https://www.theguardian.com/commentisfree/2026/sep/19/maga-pro-life-miscarriages-pregnancy-ice-detention",
      %{
        "headline" =>
          "Maga wants more babies. But they don’t seem too worried about miscarriages in ICE detention",
        "byline" => "Arwa Mahdawi",
        "trailText" =>
          "Officials lack data on miscarriages after October 2025. Detained women aren’t getting the prenatal healthcare they need",
        "bodyText" =>
          "el its effects most,” one member said of what motivated her to fight fires. “I thought I had to do something about it.” " <>
            "Kash Patel defends new FBI bestiality policy Patel told a Senate judiciary committee oversight hearing that the FBI " <>
            "“did not want to punish victims of bestiality” by automatically disqualifying them. At one point of this absurd " <>
            "hearing, a senator from Louisiana asked Patel whether the change “disqualified the animal”",
        "firstPublicationDate" => "2026-09-19T12:00:47Z"
      }
    )
  end

  # The word is nowhere in this title — it is a theatre obituary — and the
  # sentence that attests it is 383 characters, the longest of the five.
  defp obituary do
    result(
      @obituary,
      "Stage",
      "2026-09-18T16:56:13Z",
      "Anthony Page obituary",
      "https://www.theguardian.com/stage/2026/sep/18/anthony-page-obituary",
      %{
        "headline" => "Anthony Page obituary",
        "byline" => "Michael Coveney",
        "trailText" =>
          "Stage and screen director behind landmark productions of Samuel Beckett, John Osborne and Edward Albee",
        "bodyText" =>
          "me for himself at the expense of the text or script. This scrupulousness went right back to the early Royal Court days. " <>
            "And it went hand in hand with a sensitivity for the most difficult of Albee’s plays, for instance The Goat (at the " <>
            "Almeida and the West End in 2004), which dealt in the limits of tolerance rather than bestiality in the fable of a " <>
            "securely married architect (Jonathan Pryce) falling in love with, well, a goat; Eddie Redmayne made a touching West " <>
            "End debut as the architect’s gay son. His reinvention, almost, as a go-to director of American and European classics " <>
            "occurred in the West End and on Broadway",
        "firstPublicationDate" => "2026-09-18T16:56:13Z"
      }
    )
  end

  # Real, and a real quirk worth keeping: the `id` path says 16 September and
  # the `webPublicationDate` says the 15th. The locator is built from the date
  # and never from the path, which is why the two disagreeing costs nothing.
  defp morning_mail do
    result(
      @morning_mail,
      "Australia news",
      "2026-09-15T21:04:04Z",
      "Morning Mail: Hanson’s daughter faces scrutiny, Alzheimer’s anxieties, and AI’s ‘surreal’ Joycean dialect",
      "https://www.theguardian.com/australia-news/2026/sep/16/morning-mail-wednesday-ntwnfb",
      %{
        "headline" =>
          "Morning Mail: Hanson’s daughter faces scrutiny, Alzheimer’s anxieties, and AI’s ‘surreal’ Joycean dialect",
        "byline" => "Martin Farrer",
        "trailText" =>
          "Lee Hanson works remotely for NSW senator without required official permission; alarm that tech language could circumvent monitoring",
        "bodyText" =>
          "oring as US senator Bernie Sanders said Congress was “asleep at the wheel” over threats the technology poses to humans. " <>
            "Hegseth impeachment threat | A Republican congressman has proposed impeaching Pete Hegseth over his handling of the war " <>
            "with Iran, while FBI director Kash Patel defended his agency’s decision to roll back restrictions on agent applicants " <>
            "who have previously engaged in bestiality. Macklemore comments | Singer Ed Sheeran has responded to the backlash over " <>
            "the removal of Macklemore from his North Ame",
        "firstPublicationDate" => "2026-09-15T21:04:04Z"
      }
    )
  end

  # The one Bing's feed also carries. Both providers write the same
  # `news_article` id for it, and that is the whole point of the namespace.
  defp kash_patel do
    result(
      @kash_patel,
      "US news",
      "2026-09-15T17:20:47Z",
      "Kash Patel defends FBI hiring policy on applicants who have engaged in bestiality",
      kash_patel_url(),
      %{
        "headline" =>
          "Kash Patel defends FBI hiring policy on applicants who have engaged in bestiality",
        "byline" => "Ariana Baio",
        "trailText" =>
          "Senators question FBI chief on move to cut restrictions on agent applicants who have engaged in bestiality",
        "bodyText" =>
          "The FBI director, Kash Patel, defended his agency’s decision to roll back restrictions on agent applicants who have " <>
            "previously engaged in bestiality, arguing the FBI “did not want to punish victims of bestiality” by automatically " <>
            "disqualifying them. The unusual topic of bestiality emerged during a Senate judiciary committee oversight hearing on " <>
            "Tuesday after Democrat",
        "firstPublicationDate" => "2026-09-15T16:46:53Z"
      }
    )
  end

  # 25 August 2026 — twenty-seven days before the pinned clock, so inside the
  # thirty-day window and the nearest real article to its edge.
  defp roberts do
    result(
      @roberts,
      "Australia news",
      "2026-08-25T15:00:18Z",
      "One Nation’s Malcolm Roberts ‘in two minds’ about whether gay people should be equal",
      "https://www.theguardian.com/australia-news/2026/aug/26/one-nation-malcolm-roberts-two-minds-gay-equal-rights-ntwnfb",
      %{
        "headline" =>
          "One Nation’s Malcolm Roberts ‘in two minds’ about whether gay people should be equal",
        "byline" => "Tory Shepherd",
        "trailText" =>
          "Footage shows senator on stage at the Church and State conference responding to question about party’s director James Ashby",
        "bodyText" =>
          "rsonal sexuality should be kept behind closed doors”. Ashby has said as a “gay bloke” he doesn’t like the rainbow flag. " <>
            "Jason Virgo, who is gay, was elected as a One Nation MP in the South Australian election in March, while his newly " <>
            "elected colleague in the upper house, Cory Bernardi, said he stood by his 2012 comments linking same-sex marriage to " <>
            "polygamy and bestiality. In the Church and State footage, Roberts also discussed various conspiracy theories and said " <>
            "family law changes made si",
        "firstPublicationDate" => "2026-08-25T15:00:18Z"
      }
    )
  end

  # The only constructed row — see the moduledoc. The term is present as a
  # substring of a longer token, in the title and in the body, and nowhere as
  # a word.
  defp substring_noise do
    result(
      "us-news/2026/sep/16/fbi-hiring-row-bestialitygate-hashtag",
      "US news",
      "2026-09-16T11:00:00Z",
      "FBI hiring row: #Bestialitygate trends as Patel testifies",
      "https://www.theguardian.com/us-news/2026/sep/16/fbi-hiring-row-bestialitygate-hashtag",
      %{
        "headline" => "FBI hiring row: #Bestialitygate trends as Patel testifies",
        "byline" => "A Reporter",
        "trailText" => "The hashtag outran the hearing it came from.",
        "bodyText" =>
          "The hashtag #Bestialitygate outran the hearing it came from, and the agency spent the afternoon explaining a rule " <>
            "change nobody had read. Bestialitygate was still trending at close of business.",
        "firstPublicationDate" => "2026-09-16T11:00:00Z"
      }
    )
  end

  # ---------------------------------------------------------------------------
  # The envelope
  # ---------------------------------------------------------------------------

  # The captured envelope's own shape, field for field, including the keys the
  # provider does not read (`apiUrl`, `isHosted`, `pillarId`, `startIndex`,
  # `userTier`) so that a parser narrowing to what it happens to need fails
  # here rather than in production.
  defp result(id, section, published_at, web_title, web_url, fields) do
    %{
      "id" => id,
      "type" => "article",
      "sectionId" => section |> String.downcase() |> String.replace(" ", "-"),
      "sectionName" => section,
      "webPublicationDate" => published_at,
      "webTitle" => web_title,
      "webUrl" => web_url,
      "apiUrl" =>
        String.replace(web_url, "https://www.theguardian.com", "https://content.guardianapis.com"),
      "fields" => fields,
      "isHosted" => false,
      "pillarId" => "pillar/news",
      "pillarName" => "News"
    }
  end

  # The API pages for itself, so the stub does too: `page` and `page-size` are
  # read off the query string and `pages` is computed the way the real
  # envelope computes it. That is what the provider's `next_cursor` reads, so
  # a stub that answered everything at once would prove nothing about paging.
  defp respond(results) do
    Req.Test.stub(Guardian, fn conn ->
      conn = Plug.Conn.fetch_query_params(conn)
      page_size = String.to_integer(conn.params["page-size"] || "12")
      page = String.to_integer(conn.params["page"] || "1")
      total = length(results)

      Req.Test.json(conn, %{
        "response" => %{
          "status" => "ok",
          "userTier" => "developer",
          "total" => total,
          "startIndex" => (page - 1) * page_size + 1,
          "pageSize" => page_size,
          "currentPage" => page,
          "pages" => ceil(total / page_size),
          "orderBy" => "newest",
          "results" => Enum.slice(results, (page - 1) * page_size, page_size)
        }
      })
    end)
  end
end
