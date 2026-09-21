defmodule DevilsDictionary.Discovery.Conformance.BingNewsFixture do
  @moduledoc """
  Conformance for `DevilsDictionary.Discovery.Providers.BingNews`.

  The responses here are **real**, captured from
  `https://www.bing.com/news/search?q=bestiality&format=rss&mkt=en-US` on
  2026-09-21 and trimmed to the fields the provider reads: the channel head is
  that response's own, `<copyright>` included, and every item's title,
  description, `pubDate`, `News:Source` and `apiclick` link are as the feed
  sent them.

  Because they are real their dates are real — 15 to 20 September 2026 — and a
  freshness gate read against the wall clock would pass in September and fail in
  October. `config/test.exs` pins `:bing_news, now:` to 21 September 2026 and
  `BingNews.now/0` reads it, so the window is measured from the day the feed
  was captured for as long as this fixture lives.

  Four items are in the `:results` page to be *refused*, and the expected ids
  say so by leaving them out:

    * **The Daily Telegraph, 13 December 2023** — real, and really in the feed's
      answer for this word. Almost three years outside the 30-day window. A
      provider that stopped filtering by `pubDate` would fail here rather than
      shipping a 2023 article under a heading that says News.
    * **A second copy of the Wired story** with `?utm_source=…&utm_medium=…`
      and a `#comments` fragment on the publisher URL. It is the same article,
      so it must fold into the first by identity rather than appear twice — and
      the count of expected ids is what proves the normalisation happened.
    * **A `#Bestialitygate` item**, the only constructed row in this file. No
      real item in the captured response lacks the word in its title, so the
      substring case has to be written: `bestialitygate` contains the term with
      a letter after it, which the Unicode-boundary gate refuses. The measured
      substring case is a two-word lemma — `q=red herring` answers *No Red
      **Herrings** Here* — and it is asserted in
      `test/devils_dictionary/discovery/providers/bing_news_test.exs`, where the
      term can be chosen.

  The external ids are written as literals rather than computed from the
  provider, so that changing how an article is identified breaks this suite
  instead of quietly agreeing with itself.
  """

  use DevilsDictionary.Discovery.Conformance.Fixture

  alias DevilsDictionary.Discovery.Providers.BingNews

  # The digest of each article's normalised publisher URL, written out so that a
  # change to how an article is identified fails here.
  @wired "ac7bbfad8c0c66c31fac22d9eb3b0711"
  @tribune "48b849b9dfcf2e9f6c719dde0081a25d"
  @cbs "136fcfeeff2b3d8fb87d5f9a1b01e4e9"
  @rolling_stone "de066b6af129783c10ed0a56e275f53e"
  @kxan "d7f9a0c3bf4d80ab0990b39174aee03a"

  @impl true
  def provider, do: BingNews

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
    # A real shape, measured: `q=referendum` answered `200` with a valid
    # channel and no `<item>` at all. An empty result and never a malformed
    # body — the discriminator in `parse_body/1` is the channel, not the items.
    respond([])
    %{pages: [[]]}
  end

  def stub(:results, _context) do
    # Five rows against a `result_limit` of three, of which two survive the
    # gate: a short page, so pagination ends rather than promising a page with
    # nothing behind it.
    respond([
      wired(),
      wired_with_tracking(),
      tribune(),
      telegraph_2023(),
      substring_noise()
    ])

    %{pages: [[@wired, @tribune]]}
  end

  def stub(:paged, _context) do
    respond([wired(), tribune(), cbs(), rolling_stone(), kxan()])
    %{pages: [[@wired, @tribune, @cbs], [@rolling_stone, @kxan]]}
  end

  # ---------------------------------------------------------------------------
  # The real items
  # ---------------------------------------------------------------------------

  defp wired do
    item(
      "The FBI Doubles Down on Easing ‘Bestiality’ Hiring Standards",
      "FBI director Kash Patel claimed to US senators that the removal of a bar on hiring " <>
        "people who had engaged in bestiality was aimed at protecting sexual assault survivors.",
      "Tue, 15 Sep 2026 06:50:00 GMT",
      "Wired",
      "https://www.wired.com/story/the-fbi-doubles-down-on-easing-bestiality-hiring-standards/"
    )
  end

  # The same article, linked again with the tracking parameters and fragment a
  # newsroom's social copy carries. One item, not two.
  defp wired_with_tracking do
    item(
      "The FBI Doubles Down on Easing ‘Bestiality’ Hiring Standards",
      "FBI director Kash Patel claimed to US senators that the removal of a bar on hiring " <>
        "people who had engaged in bestiality was aimed at protecting sexual assault survivors.",
      "Tue, 15 Sep 2026 06:50:00 GMT",
      "WIRED on MSN",
      "https://www.wired.com/story/the-fbi-doubles-down-on-easing-bestiality-hiring-standards/" <>
        "?utm_source=twitter&utm_medium=social&fbclid=IwAR9#comments"
    )
  end

  defp tribune do
    item(
      "FBI chief Kash Patel defends hiring policy changes on prostitution, bestiality at fiery hearing",
      "FBI Director Kash Patel on Tuesday defended the bureau’s loosening of hiring " <>
        "requirements regarding prostitution and bestiality, saying the changes were meant " <>
        "to enable victims of those acts to apply ...",
      "Tue, 15 Sep 2026 09:00:00 GMT",
      "Chicago Tribune",
      "https://www.chicagotribune.com/2026/09/15/fbi-kash-patel-employment-standards/"
    )
  end

  defp cbs do
    item(
      "Patel defends lowering hiring standards related to prostitution, bestiality",
      "Tuesday's hearing marked the first time that Patel has publicly addressed the new " <>
        "hiring standards related to prostitution, employment theft and bestiality.",
      "Tue, 15 Sep 2026 13:00:44 GMT",
      "CBS News on MSN",
      "https://www.msn.com/en-us/news/other/patel-defends-lowering-hiring-standards-related-to-prostitution-bestiality/ar-AA2ch9up"
    )
  end

  defp rolling_stone do
    item(
      "Kash Patel Defends Bestiality Standards at the FBI",
      "A Senate hearing with the man in charge of the nation's top law enforcement agency got weird ...",
      "Tue, 15 Sep 2026 08:46:00 GMT",
      "Rolling Stone on MSN",
      "https://www.msn.com/en-us/news/other/kash-patel-defends-bestiality-standards-at-the-fbi/ar-AA2ch0Ce"
    )
  end

  defp kxan do
    item(
      "GOP senator presses Patel on FBI policy change: 'Why would you get into bestiality?'",
      "The line of questioning on Tuesday was sparked by a shift in FBI hiring practices " <>
        "which lifted longtime bans on selecting new trainees if they have engaged in " <>
        "prostitution or bestiality.",
      "Sun, 20 Sep 2026 08:34:56 GMT",
      "KXAN Austin on MSN",
      "https://www.msn.com/en-us/news/other/gop-senator-presses-patel-on-fbi-policy-change-why-would-you-get-into-bestiality/ar-AA2cCa9s"
    )
  end

  # Real, and really what the feed returns for this word: a 2023 explainer,
  # three years outside the window.
  defp telegraph_2023 do
    item(
      "Bestiality: Analysing what causes people to have sex with animals",
      "With 57 recorded incidences of bestiality in Queensland in five years a clinical " <>
        "psychologist has broken down what makes people perform sex acts on animals. " <>
        "Full list of the nation’s worst offenders.",
      "Wed, 13 Dec 2023 13:18:00 GMT",
      "The Daily Telegraph",
      "https://www.dailytelegraph.com.au/news/bestiality-analysing-what-causes-people-to-have-sex-with-animals/news-story/15dc074c5d8e0722b7b579172413fd0c"
    )
  end

  # The one constructed row — see the moduledoc. The term is present as a
  # substring of a longer token and nowhere as a word.
  defp substring_noise do
    item(
      "FBI hiring row: #Bestialitygate trends as Patel testifies",
      "The hashtag outran the hearing it came from, and the agency spent the afternoon " <>
        "explaining a rule change nobody had read.",
      "Wed, 16 Sep 2026 11:00:00 GMT",
      "The Hill",
      "https://thehill.com/policy/national-security/fbi-hiring-row-hashtag/"
    )
  end

  # ---------------------------------------------------------------------------
  # The envelope
  # ---------------------------------------------------------------------------

  # Bing's own `apiclick` wrapper, with the publisher URL percent-encoded into
  # `url=` exactly as the feed writes it — lowercase hex included — and the
  # per-response `tid` and `mkt` that make the redirect useless as an identity.
  defp item(title, description, pub_date, source, url) do
    link =
      "http://www.bing.com/news/apiclick.aspx?ref=FexRss&amp;aid=&amp;" <>
        "tid=6ab1419874f441408c16c26484316ff0&amp;url=" <>
        percent_encode(url) <>
        "&amp;c=1486738033267397200&amp;mkt=en-us"

    """
    <item><title>#{escape(title)}</title><link>#{link}</link>\
    <description>#{escape(description)}</description><pubDate>#{pub_date}</pubDate>\
    <News:Source>#{escape(source)}</News:Source>\
    <News:Image>http://www.bing.com/th?id=ONUT.-O5NiPvjDJykMPofbjIGgQ&amp;pid=News</News:Image>\
    <News:ImageSize>w={0}&amp;h={1}&amp;c=14</News:ImageSize>\
    <News:ImageMaxWidth>700</News:ImageMaxWidth>\
    <News:ImageMaxHeight>466</News:ImageMaxHeight></item>\
    """
  end

  # Bing writes its percent escapes in lowercase hex (`%3a%2f%2f`), which
  # `URI.encode/2` does not. Decoding is case-insensitive either way; this is
  # here so the fixture is the bytes the feed actually sent.
  defp percent_encode(url) do
    url
    |> URI.encode(&URI.char_unreserved?/1)
    |> String.replace(~r/%[0-9A-F]{2}/, &String.downcase(&1))
  end

  defp escape(text) do
    text
    |> String.replace("&", "&amp;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
  end

  @doc """
  The captured channel head, `<copyright>` and all.

  The copyright element is kept because it is the feed's own statement of terms
  and `docs/integrations/bing-news.md` quotes it; a fixture that dropped it
  would make the parser's job look easier than it is.
  """
  def document(items) do
    ~s(<?xml version="1.0" encoding="utf-8" ?>) <>
      ~s(<rss version="2.0" xmlns:News="https://www.bing.com/news/search?format=rss&amp;q=bestiality">) <>
      "<channel><title>bestiality - BingNews</title>" <>
      "<link>https://www.bing.com/news/search?format=rss&amp;q=bestiality</link>" <>
      "<description>Search results</description>" <>
      "<image><url>http://www.bing.com/rsslogo.gif</url><title>bestiality</title>" <>
      "<link>https://www.bing.com/news/search?format=rss&amp;q=bestiality</link></image>" <>
      "<copyright>Copyright © 2026 Microsoft. All rights reserved. These XML results may " <>
      "not be used, reproduced or transmitted in any manner or for any purpose other than " <>
      "rendering Bing results within an RSS aggregator for your personal, non-commercial " <>
      "use. Any other use of these results requires express written permission from " <>
      "Microsoft Corporation. By accessing this web page or using these results in any " <>
      "manner whatsoever, you agree to be bound by the foregoing restrictions.</copyright>" <>
      Enum.join(items) <>
      "</channel></rss>"
  end

  # The feed answers the whole result set in one response whatever is asked of
  # it — `count=` is ignored, measured — so the stub does too, and the paging
  # the suite exercises is the provider's own offset into what survived the
  # gate.
  defp respond(items) do
    Req.Test.stub(BingNews, fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/xml")
      |> Plug.Conn.send_resp(200, document(items))
    end)
  end
end
