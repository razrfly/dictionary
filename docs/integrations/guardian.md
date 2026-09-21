# The Guardian

The News shelf's second provider and its first with published terms (#142,
Phase 1 of #134). Keyed: `GET https://content.guardianapis.com/search` with a
registered `api-key`, answering JSON.

Where Bing (#135) is a keyless search over other people's mastheads and can
only ever see a headline, this reads the publisher's own `bodyText` — so the
shelf's reason moves from *in a headline* to **in the text** and carries the
sentence a reader can check.

## Read this first: the terms are stricter than #142 assumed

Read in full on 2026-09-21 at
<https://www.theguardian.com/open-platform/terms-and-conditions> (last varied
25 January 2024). #142 anticipated two clauses and there are five that bear on
this code. Three are satisfied; **two are not**, and they are the first thing
anyone reading this needs to know.

### Clause 5 — retention. Satisfied, and it cost a shared change

> You must either replace (by re-requesting) or delete all OP Content you
> hold (whether or not published on Your Website) at least every 24 hours. For
> legal reasons, you must not keep any OP Content for longer than 24 hours.

**"Whether or not published on Your Website"** is the phrase that decides the
design, and #142 guessed it right: a 24-hour *refresh* satisfies the *replace*
half only for a page somebody opens, and a page nobody opens keeps its rows
until cleanup reaches them. See *The retention decision* below.

### Clause 6(b)(i) and 6(b)(iv) — byline and link back. Satisfied

> (i) Retain the full headline, byline and copyright notice from the original
> OP Content supplied. … (iv) Include a link to the original article published
> on www.theguardian.com in all OP Content published on Your Website.

Every card carries `fields.byline` in the creator line and `webUrl` in
`source_url`, which is the *Source ↗* link. Measured in the browser proof: ten
`theguardian.com` links on `/define/bestiality` and no link to anything else.

### Clause 6(b)(vi) — the "Powered by The Guardian" mark. **NOT satisfied**

> Include a "Powered by The Guardian" logo (or such other Guardian logo as we
> may require from time to time) on the same webpage as any republished OP
> Content, or any tool or function that is based on OP Content. Such logo must
> be a reproduction of the "Powered By" file found at
> http://www.theguardian.com/open-platform/logos, and comply with any special
> terms set out by us.

This is a "You will", not a nicety, and it is not in this branch. #142 puts
*"A 'Powered by Guardian' shelf mark beyond what the terms require"* out of
scope and also says *"satisfy whatever attribution the current terms actually
require"* — and the terms require one, so the two sentences point opposite
ways. It is left undone rather than guessed at because every way of doing it
edits a shared file that #142's own list forbids, and because which mark goes
where is the owner's decision and not a provider's:

* **`preview_metadata["attribution"]`** already renders *The Guardian* beneath
  each card's byline, which satisfies a *credit* but is text and not the
  logo the clause names.
* **The shelf byline** says *Bing News · The Guardian*, again text.
* **A real logo** needs `DevilsDictionaryWeb.Culture` to learn that a source
  can carry a mark. There is precedent one component over: the GIPHY shelf
  renders a *POWERED BY GIPHY* badge, visible in
  `issue-142-bestiality-1280-2026-09-21.jpg` — but that is `GiphyShelf`, its
  own component outside the shared chrome (K10 of #109), so it is a precedent
  for the idea and not a mechanism this provider can reuse.

**This is the #140 situation again**: the provider is built and green, and
whether it ships on a public host is a decision this file cannot make.

### Clause 6(g) — AI, text and data mining, automated tools. **Unresolved**

Inserted 25 January 2024 and not mentioned in #142 at all:

> (g)(i) use, copy, scrape, reproduce, alter, modify, collect, mine and/or
> extract the Content API, OP Content or Guardian Digital Network: (A) for any
> machine learning, machine learning language models and/or artificial
> intelligence-related purposes …; (B) for any text and data aggregation,
> analysis or mining purposes (including to generate any patterns, trends or
> correlations); or (C) with any machine learning and/or artificial
> intelligence technologies … OR (ii) use, or facilitate … any: (A) "robot",
> "bot", "spider", "crawler" or "scraper"; or (B) other automated device,
> program, technique, tool, process, algorithm or method (whether for data
> gathering, mining, collection, reading, scraping, extraction or other
> purposes), in each case, with the Content API …

Read literally, 6(g)(ii)(B) forbids using the Content API from a program,
which the Content API exists to be used from; that reading cannot be the
intended one. But 6(g)(i)(B) — *text and data … analysis … purposes* — and
6(g)(ii)(B)'s *extraction* are a fair description of what this provider does
to `bodyText`: it runs a pattern over an article's text and **extracts** the
sentence around the match. A dictionary's word page is arguably exactly the
"aggregation, analysis" the clause reserves.

Recorded as the open question it is. The sentence extraction is what #142
specifies and what makes the reason checkable, so it is built as specified;
the clause is quoted here so the decision is taken with it in view rather than
without. `licensing@theguardian.com` is the address clause 18 names for asking.

### Clauses 4(b) and 7(a) — quota and non-commercial. Satisfied

> (4b) You may make up to 500 requests for OP Content per API key per day …
> (7a) You may make OP Content available to end users of Your Website strictly
> for their personal and non-commercial use only …

The app's budget is **400** a day, so its own ledger refuses before the API
does. Clause 1(c) also makes the key personal to one registered website and
3(b)(iii) forbids sharing it; it lives in `GUARDIAN_API_KEY` and reaches
`request_options/1` and nothing else.

## Posture

| | |
|---|---|
| Slug | `guardian` |
| Archetype | discovery |
| Shipped state | **Key-gated.** `enabled?/0` is false without `GUARDIAN_API_KEY`, so a host with no key registers the provider, makes no call and shows no item. Removing the key is the whole off switch — the Unsplash pattern (#116 Phase 3), and no second flag |
| Licence | Guardian Open Platform, Developer tier. See above |
| Key required | **Yes.** `GUARDIAN_API_KEY`, server-only, read in `runtime.exs` from the shell or the local `.env`, added to `allowed_provider_env` |
| User-Agent | The project's own string, accepted |
| Published rate limit | 60/minute, 500/day (clause 4b), 1 call/s |
| Measured rate | **70 consecutive requests in 3.9 s all answered `200`** — no `429`. The published per-minute limit was not enforced. Paced at 1 req/s anyway, which is the published rate rather than the tolerated one |
| Images | Thumbnails are available in `show-fields` and are **not requested**. `:news` has no `thumbnail_keys`, no image is shown and no bytes are downloaded — which also avoids clause 6(b)(ii)'s watermark obligation entirely |

## The four decisions

| Decision | Value | Why |
|---|---|---|
| **archetype** | `discovery` | live answers to a page; nothing to seed |
| **content type** | `news` | the row exists since #135; this is its second source |
| **transport** | `get`, JSON | Req decodes it; no `body:` declaration |
| **pagination** | `offset` (`page=`) | the API really pages, unlike Bing's feed. `page = offset / limit + 1`, one request per page. Measured: `page-size=2&page=2` of a 5-result answer returns results 3–4 and `pages: 3` |

And the rest of the spec:

| | |
|---|---|
| Identifier | **two on every item.** `guardian_article` = the result's own `id` path; `news_article` = the sha256 of the normalised `webUrl`, computed by calling `BingNews.normalize/1` and `BingNews.article_id/1` |
| Evidence | **attestation**, verified in `bodyText`, with a dated locator |
| The gate | whole-word (Unicode boundary) in `bodyText` else `webTitle`; `webPublicationDate` inside `max_age_days`; `webUrl` an absolute `http(s)` URL |
| Freshness window | 30 days — `BingNews`'s default, shared deliberately so one shelf has one idea of "current". It is also what `from-date` asks the API for |
| Quoting | **always a quoted phrase.** The opposite of Bing — see *Measured facts* 1 |
| Live blogs | **excluded**, `type=article` — see *Measured facts* 2 |
| Persistence | `:persistent`, 24-hour positive refresh **and** 24-hour `retention_seconds` — see below |
| Budget | `request_budget_limit: 400`, `request_budget_window_seconds: 86_400`, `request_interval_ms: 1_000`, `min_retry_interval_ms: 60_000` |
| `covers?/1` | default `true` |
| Identity | **no `identity_record/1`** — every result persists as `:insufficient_evidence` |
| Tier | `:plebs` — #100's, and the same as Bing's, so the turns go by slug and `bing-news` leads `guardian` |
| Source row | slug `guardian`, name *The Guardian*, `access: :api`, `attribution: "The Guardian"`, `url_template: "https://www.theguardian.com/{id}"` |

## The retention decision: option 1, and it needed more than #142 thought

**Option 1 was taken** — persistent, 24-hour refresh, plus a per-source
`retention_seconds` that `Discovery.cleanup/0` honours. Option 2
(`:transient`) was rejected on arithmetic: 500 requests a day is a few hundred
page views, and a News shelf that degrades to Bing alone after lunch is worse
than one that is a day stale.

But implementing option 1 honestly took **two** steps that #142's sketch has
one of, and the second is the one that matters:

1. **The runs.** `cleanup/0`'s existing sweep protects the runs currently on
   display — *the page's answer is never the thing that gets collected*, which
   is right for a cache-size policy and **wrong for a retention rule**. Clause
   5 says "whether or not published on Your Website", so a displayed row is
   precisely what has to go. `Discovery.expire_by_source_retention/1` runs
   first, on the source's own window, without the display exemption.
2. **The source records.** Deleting a run cascades to its
   `discovery_results` and its `discovery_request_attempts` — and **not** to
   its `source_records`, which hold the provider's own payload (the headline,
   the byline, the attested sentence) in a `source_record_revisions` row that
   would outlive the run indefinitely. A run-only sweep would have satisfied
   the letter of a cache policy and left the content held. So step 2 deletes
   this source's now-unreferenced source records past the same window, and
   their revisions cascade. The order is forced:
   `discovery_results.source_record_id` is `ON DELETE RESTRICT`.

Proved by three tests in
`test/devils_dictionary/discovery/providers/guardian_test.exs`:

* a 25-hour-old Guardian run **and its result** are gone after `cleanup/0`,
  and a 25-hour-old **Bing** run at the same age in the same database is
  untouched;
* the Guardian's source record and its revision go too;
* a 23-hour-old Guardian run is left alone.

### What is still held for longer than 24 hours, and it is not nothing

**The committed fixture.** `test/support/discovery/conformance/guardian_fixture.ex`
holds five real headlines, five real bylines, five real URLs and a window of
each article's `bodyText`, in git, for ever. That is OP Content held past 24
hours by any reading of clause 5.

It was mitigated rather than solved: each `bodyText` is cut to roughly 120
characters either side of the attesting sentence rather than committed
verbatim (the real bodies were 3,268 / 4,432 / 6,080 / 7,013 / 7,538
characters). Everything else in the fixture is exactly what the API sent.
#142 asks for "a real captured response … dates real", and a wholly synthetic
fixture would not be that — so the trade is recorded here and in the fixture's
own moduledoc rather than made quietly. **If the owner wants clause 5 honoured
strictly, the fixture is the thing to make synthetic**, and the cost is that
the suite stops proving the extraction works on real Guardian prose.

## Probe

Ceiling: **120 requests** (#142's own number). Spent: **80**.

| # | requests | what was asked | what came back | running total |
|---|---|---|---|---|
| P1 | 1 | the real envelope: `q="bestiality"`, `type` unset, `from-date=2026-08-22`, `order-by=newest`, all five `show-fields`, `page-size=12` | `200` in 447 ms, `total: 6`, `pages: 1`. Five `article` and one `liveblog`. `x-ratelimit-remaining-day: 498` | **1 / 120** |
| P2 | 0 | the whole-word gate and the sentence extraction, run locally over P1's five real bodies | **All six results carry the word in `bodyText`; one carries it in `webTitle`.** Body hit counts 13, 5, 2, 1, 1, 1. Extracted sentences 145 / 199 / 249 / 256 / 280 / **383** characters | **1 / 120** |
| P3 | 2 | `type=article`; then `q="logomachy"` | `type=article` takes `bestiality` **6 → 5** and the one it drops is the live blog. `logomachy` is `total: 0` | **3 / 120** |
| P4 | 1 | a deliberately wrong key | **`401`**, `{"message": "Unauthorized"}`, `www-authenticate: Key`, **and none of the rate-limit headers**. A bad key does not spend quota | **4 / 120** |
| P5 | 70 | the 60/minute limit, provoked once as #142 permits | **No `429`. 70/70 `200` in 3.9 s**, latency 44–303 ms and flat. `x-ratelimit-remaining-minute` fell only 59 → 37 across those 70 — see *Measured facts* 4 | **74 / 120** |
| P6 | 2 | the fixture capture with the exact production parameters; then `page-size=2&page=2` | `total: 5`, `pages: 1`. Paging: page 2 of 2-per-page gives results 3–4, `pages: 3`, `currentPage: 2` | **76 / 120** |
| B1 | 1 | browser proof, `/define/bestiality`, port 4047, one node on `devils_dictionary_bing135` | **5** items, every one kept. Shelf byline *Bing News · The Guardian*, 17 items interleaved | **77 / 120** |
| B2 | 1 | `/define/logomachy` | `no_results`, 0 items, **1** request. Two reloads afterwards spent **0** | **78 / 120** |
| B3 | 1 | `/define/war` | **12** items | **79 / 120** |
| L | 1 | the closing ledger read | `x-ratelimit-remaining-day` = **471 of 500** | **80 / 120** |

`discovery_request_attempts` reads **3** for `guardian` after the proof, which
is B1–B3; the other 77 were the probe and are not the app's.

**The final `x-ratelimit-remaining-day` was 471, and 79 requests had been
spent against the quota.** The header is not a ledger — see below.

## Measured facts

Things nobody should have to measure twice.

1. **Quote the query, always — the opposite of Bing.** #142 measured `red
   herring` over 90 days at **2,615** articles against **9** for `"red
   herring"`; this probe confirmed the mechanism on `bestiality`. Bing's probe
   (#135, *Measured facts* 4) measured the reverse and sends its term bare.
   Two different indexes, two measurements, no contradiction — and it is worth
   saying plainly because a session that assumed one provider's finding
   generalised would get the other one wrong.
2. **`type=article` excludes exactly the live blogs, and should.** `6 → 5` on
   this query, and the dropped result was
   `us-news/live/2026/sep/15/…`: a **62,683-character** `bodyText` with five
   whole-word hits buried in a day's unrelated politics. Its extracted
   sentence read *"More here Earlier, FBI director Kash Patel clashed with
   lawmakers in a Senate judiciary committee hearing over … bestiality (among
   other issues)."* — because a live blog's `bodyText` is its blocks
   concatenated with no sentence boundary between them. A live blog is not an
   article that uses a word; it is a day.
3. **The body is where the word is.** Six of six results had it in
   `bodyText`, one of six in `webTitle`. That single ratio is the whole
   argument for a keyed source on this shelf: Bing can only ever see the one.
4. **The rate-limit headers are advisory and the day counter undercounts.**
   Seventy requests in 3.9 seconds drew no `429` at all, against a published
   60/minute. Worse, `x-ratelimit-remaining-day` moves **non-monotonically** —
   observed 498, 495, 497 on three consecutive requests, and 498 → 476 across
   a 70-request burst. It is evidently sampled per edge node rather than
   counted. **Do not use it as a ledger.** `discovery_request_attempts` is the
   record of what was spent; the header is recorded here because #142 asked
   for it, with the caveat that it read **471** where the true figure was
   **429**.
5. **A `401` carries no rate-limit headers and spends no quota.** So a
   misconfigured host hammering a wrong key burns no budget — but it is still
   treated as a verdict and not retried: `authentication_failed`, one attempt.
6. **The API sends `ratelimit-reset`, never `Retry-After`.** Present on every
   `200` (seconds to the minute window's reset) and, by inference, on a
   refusal. The shared transport read only `retry-after`, so honouring the
   Guardian's backoff needed a capability — see *Shared files*.
7. **`webPublicationDate` and the `id` path can disagree.** The real
   `australia-news/2026/sep/16/morning-mail-wednesday-ntwnfb` was published
   `2026-09-15T21:04:04Z`. The locator is built from the date and never from
   the path, so it costs nothing — but a provider that parsed the path for a
   date would be wrong about this article.
8. **`webTitle` is not always `fields.headline`.** The Opinion piece's
   `webTitle` ends `… in ICE detention | ` — a trailing pipe and space where a
   byline was templated in. `fields.headline` is clean. The card shows
   `headline`; `webTitle` is only ever read by the gate.

## Conformance

    mix test test/devils_dictionary/discovery/conformance/guardian_conformance_test.exs   # 19/19
    mix test test/devils_dictionary/discovery/providers/guardian_test.exs                 # 43/43

The fixture is a real capture from 2026-09-21, so its dates are real
September dates and the clock is injected:
`config :devils_dictionary, :guardian, now: ~U[2026-09-21 12:00:00Z]` in
`config/test.exs`, read by `Guardian.now/0`. Without it the freshness gate —
and `from_date/0`, which derives `2026-08-22` from it — would pass this week
and fail next.

`config/test.exs` also repeats this source's `source_policies` entry, because
that map **replaces** `config.exs`'s rather than merging with it. Worth
knowing: `bing-news`'s 24-hour positive refresh is absent from the test
config for exactly that reason, and has been since #140.

## Browser proof

`mix compile` to completion, then **one** dev server on its own database.
`devils_dictionary_v2` already had a node on it — the #131 page-mockup
worktree on port 4007, confirmed with the checklist's `lsof` /
`pg_stat_activity` recipe — so this proof took port **4047** and
`devils_dictionary_bing135`, the database #135 left behind: idle, migrated to
head, fully seeded, already holding Bing's cached News results, and with **no
`guardian` row to be stale**.

Screenshots driven over CDP with `Emulation.setDeviceMetricsOverride`, because
headless Chrome's `--window-size` sets the window and not the layout viewport.

| Page | Width | `scrollWidth` | News items | File |
|---|---|---|---|---|
| `/define/bestiality` | 1280 | 1280 | 17 | `issue-142-bestiality-1280-2026-09-21.jpg` |
| `/define/bestiality` | 375 | **375** | 17 | `issue-142-bestiality-375-2026-09-21.jpg` |
| `/define/logomachy` | 1280 | 1280 | 0 | `issue-142-logomachy-1280-2026-09-21.jpg` |
| `/define/logomachy` | 375 | **375** | 0 | `issue-142-logomachy-375-2026-09-21.jpg` |
| `/define/war` | 1280 | 1280 | 14 | `issue-142-war-1280-2026-09-21.jpg` |
| `/define/war` | 375 | **375** | 14 | `issue-142-war-375-2026-09-21.jpg` |

No horizontal page scroll at 375 on any of the three.

**The shelf.** One rail headed *News*, bylined **Bing News · The Guardian**,
17 cards on `/define/bestiality` — Bing's 12 and the Guardian's 5, taking
turns: HuffPost, *Maga wants more babies*, Reuters, *Anthony Page obituary*,
Chicago Tribune, *Morning Mail*, Wired, *Kash Patel defends FBI hiring
policy*, … Both are `:plebs`, so the order inside the turn is by slug and
`bing-news` leads.

**The credit.** A Guardian card reads

    Maga wants more babies. But they don't seem too worried about
    miscarriages in ICE detention
    19 Sep 2026 · News
    Arwa Mahdawi
    The Guardian

which is the first time the `:credited` row has rendered a credit at all —
#140 left it `:credited` for a source whose credit differs from its creator,
and this is that source. Bing's cards beside it still show one line.

**The reason.** In *About these results*, all 17 news reasons:

> Uses "bestiality" **in the text**, The Guardian, 15 September 2026.
> Uses "bestiality" **in a headline**, HuffPost on MSN, 15 September 2026.

Zero read *at*. See *The preposition* below.

**The links.** Ten `theguardian.com` hrefs on `/define/bestiality` (five
items, title and *Source ↗*) and **zero** to anything else — asserted in the
DOM, not looked at.

**The empty.** `/define/logomachy`: no Guardian item, `no_results`, **one**
request, and two reloads afterwards spent **none**. What the page does show is
the shared empty-state line, which is every content type's and not this
provider's to suppress (the same box #140 declined to tick).

**The order.** On all three words the DOM reads `culture-shelf-film`,
`culture-shelf-text`, `culture-shelf-news`, `culture-shelf-image`, `giphy-…`
— News after Texts, unchanged by this provider joining.

**The source row**, on the database the server was on:

```text
   slug    | tier  |     name     | access |  attribution  |           url_template
-----------+-------+--------------+--------+---------------+----------------------------------
 guardian  | plebs | The Guardian | api    | The Guardian  | https://www.theguardian.com/{id}
```

Inserted by `ensure_source/1` on the first run. No hand correction was needed
because this database had no `guardian` row to be stale — but
**`devils_dictionary_v2` has none either and will get whatever `source_attrs/0`
says on its first run there.**

### The one thing the browser could not prove

#142 says *"The Guardian's 15 September Kash Patel piece appears **once** even
though Bing also returns it"*. **Bing does not return it.** Its twelve cached
items for this word are HuffPost, Reuters, Chicago Tribune, Wired, CBS,
Rolling Stone, US Magazine, The Advocate, Newsweek, Instinct, NBC News and Al
Jazeera — every masthead that covered the story except the Guardian's own.
So there was no duplicate on the page to fold, and the shelf showed 12 + 5 =
**17** rather than a merged 16.

The mechanism is proved where it can be: `guardian_test.exs` asserts that the
`news_article` id this provider writes for that article is byte-for-byte
`BingNews.article_id(BingNews.normalize(URI.parse(webUrl)))`, and that the
same URL with `utm_*` and a fragment yields the same id. The occasion simply
did not arise on this word on this day. It is left as a finding rather than
manufactured.

## The preposition, fixed

#140 measured Bing's reason rendering as *Uses "bestiality" **at** a headline,
Wired, 15 September 2026* and reported it rather than fixing it, because #135
put `match_reason.ex` out of scope. #142 permits the fix if it is touching the
reason's tests anyway, and it was, so it is taken: `at/1` now renders *in*
when the locator begins with a determiner and *at* otherwise.

That is the discriminator because it is what separates the two classes of
locator the kit writes — a numbered **point** never has a determiner (*line
4*, *page 12*) and a named **part** always does (*a headline*, *the text*).
PoetryDB still reads *at line 4*; Open Library's empty locator still renders
nothing; Bing's shelf reads correctly now without Bing changing at all.
