# Bing News

The News shelf's first provider (#135, from the live shootout in #134).
Keyless, undocumented and unsupported: `GET
https://www.bing.com/news/search?q=<term>&format=rss` answers RSS 2.0 with a
`News:` namespace.

## Read this first: the feed publishes its own terms

Issue #135 records *Terms: none published for the feed*. That is not what the feed
says. Every response carries a `<copyright>` element, and on 2026-09-21 it
read, in full:

> Copyright © 2026 Microsoft. All rights reserved. These XML results may not be
> used, reproduced or transmitted in any manner or for any purpose other than
> rendering Bing results within an RSS aggregator for your personal,
> non-commercial use. Any other use of these results requires express written
> permission from Microsoft Corporation. By accessing this web page or using
> these results in any manner whatsoever, you agree to be bound by the
> foregoing restrictions.

A public word page is not an RSS aggregator and is not personal
non-commercial use. This is recorded as the finding it is rather than
smoothed into the `license` column: `source_attrs/0` quotes the restriction
and points here. What is *kept* is metadata — a headline, a masthead, a date,
one sentence and the publisher's URL — which is the posture #100 records for
GDELT and the NYT, but the restriction is on the results themselves and not
only on the bytes. **Whether this ships is not a decision this integration
doc can make.** It is raised in the PR for #135.

The feed is also undocumented and unversioned, so there is no support channel
in which to ask. The Guardian (#63) is the keyed source on this shelf that
does publish terms, and it is the reason this shelf is designed to hold more
than one source.

## Posture

| | |
|---|---|
| Slug | `bing-news` |
| Archetype | discovery |
| Shipped state | **Disabled** (`enabled: false` in `config.exs`). `BING_NEWS_ENABLED=true` turns it on, and only the owner, having read the section above, should set it. Asked for by the CodeRabbit review of the PR |
| Licence | Undocumented public RSS feed; metadata only. The feed's own `<copyright>` restricts the results — see above |
| Key required | **No.** Nothing to register |
| User-Agent | The **project's own** string is accepted. Tested first, as #135 asked: `200` and the same seven items a Chrome UA got. No browser impersonation |
| Published rate limit | None published |
| Measured sustainable rate | 20 consecutive requests at 1 req/s: **20/20 `200`**, no `429`, no `Retry-After`, latency 238/262/409 ms min/median/max. Paced at **1 req/s** as a courtesy, not because it was forced |
| Images | `News:Image` is a Bing-hosted thumbnail with no licence statement. `thumbnail_keys` is empty; no image is shown and no bytes are downloaded |

## The four decisions

| Decision | Value | Why |
|---|---|---|
| **archetype** | `discovery` | live answers to a page; nothing to seed |
| **content type** | **`news`** — a new row in `DevilsDictionary.Discovery.ContentTypes` | a headline is not a *Text* (no line to cite) and not an image |
| **transport** | `get` | — |
| **pagination** | `offset` | the feed does not page, so the offset is an offset into the *gated* list the provider holds, as PoetryDB's is. One request per page whichever page it is |

And the rest of the spec, decided before the generator ran:

| | |
|---|---|
| Identifier | the publisher URL, normalised, hashed as `external_id` in namespace **`news_article`** |
| Evidence | **attestation**, with a dated locator |
| The gate | whole-word match of the term in `title`, else `description`, at a Unicode boundary; and `pubDate` inside `max_age_days` |
| Freshness window | `config :devils_dictionary, :bing_news, max_age_days: 30` |
| Market | `mkt=en-US`, pinned. **Not cosmetic** — see *Measured facts* 3 |
| Quoting | **bare, not quoted.** Measured — see *Measured facts* 4 |
| Persistence | `:persistent`, positive refresh **24 h** (`config/config.exs`'s `source_policies`), overridable by `BING_NEWS_DISCOVERY_POSITIVE_REFRESH_SECONDS`. Empty refresh stays the shipped 24 h |
| `covers?/1` | default `true`; any word can be searched, and the empty is cached negative |
| Identity | **no `identity_record/1`** (as Openverse) — every result persists as `:insufficient_evidence` |
| Tier | `:plebs` — an aggregator of other people's mastheads |
| Source row | slug `bing-news`, name *Bing News*, `attribution: "via Bing News"`, homepage `https://www.bing.com/news`, `url_template: nil` |

## Probe

Ceiling: **150 requests** (#135's own number, not the default 200). Spent:
**38**.

| # | requests | what was asked | what came back | running total |
|---|---|---|---|---|
| P1 | 2 | `bestiality`, once with the project's own User-Agent and once with a Chrome UA | Both `200`, `application/xml; charset=utf-8`, 6,580/6,583 bytes, **7 items each**, 411/131 ms. **The project's own UA is accepted** — the fallback #135 allowed is not needed | **2 / 150** |
| P2 | 7 | shape and quoting, unpinned market: `bestiality`, `"bestiality"`, `logomachy`, `"logomachy"`, `war`, `red herring`, `"red herring"` | All `200`. Item counts 7, 7, 2, 2, 6, 6, 3. **The market is geo-inferred and it was Poland**: channel titled `bestiality - BingWiadomości`, `mkt=pl-pl` in every `apiclick` link, and the `<copyright>` in Polish | **9 / 150** |
| P3 | 5 | the same words with `mkt=en-US`, plus one with `setmkt`/`setlang` instead | All `200`, channel `- BingNews`. `bestiality` **7 → 12** items; `war` went from Polish games sites to Newsweek, UPI, the NYT and the Atlantic; `logomachy` 2 → 1; `red herring` 6 → 4. `setmkt`+`setlang` gave byte-identical results to `mkt` | **14 / 150** |
| P4 | 20 | rate: twenty distinct words at 1 req/s with `mkt=en-US` (nepotism, gerrymander, filibuster, quorum, tariff, sanction, embargo, austerity, diaspora, insurgency, ceasefire, referendum, impeachment, subpoena, indictment, moratorium, plebiscite, sedition, treason, amnesty) | **20/20 `200`**. No `429`, no `Retry-After`, no rising latency: 238/262/409 ms min/median/max. Item counts 5–12, and **`referendum` answered `200` with zero items** | **34 / 150** |
| B1 | 1 | browser proof, first visit to `/define/bestiality`, port 4037, one node on `devils_dictionary_bing135` | 12 items, every one kept. The card showed the masthead **twice** — see *The card* below. This run was deleted to re-measure the card after the fix, which cascaded its ledger row; the request is counted here because it was spent | **35 / 150** |
| B2 | 1 | `/define/bestiality` again, after the card fix | 12 items, masthead once, dated *15 Sep 2026*, every link to the publisher | **36 / 150** |
| B3 | 1 | `/define/logomachy` | `no_results`, 0 items, **1** request. Two reloads afterwards spent **0** — the negative cache answered | **37 / 150** |
| B4 | 1 | `/define/war` | **2** items of the feed's 11: Newsweek (20 Sep) and UPI (19 Sep). The other nine were outside the 30-day window — the freshness gate doing exactly what it is for | **38 / 150** |

Browser-proof requests belong on this ledger too: they are the rows of
`discovery_request_attempts` for this source, which is the record of what was
actually spent. After the proof that table reads **3** for `bing-news` (one
per word); the fourth is B1's, whose run was deleted, and it is on this
ledger because the checklist says a deleted run leaves the count short by
exactly the requests it is trying to account for.

## What identity a result carries

Association is identity, not text — and for this source there is no identity
to be had, which is the honest reading rather than a gap:

- **Source identifier**: the publisher URL, decoded out of the `url=`
  parameter of Bing's `apiclick` link and normalised — scheme and host
  lowercased, fragment dropped, tracking parameters stripped, the remainder
  sorted — then hashed to 32 hex characters in namespace `news_article`.
- **Encyclopedia identifier**: **none.** A headline proposes no encyclopedia
  identity, so there is no `identity_record/1` and every result persists as
  `:insufficient_evidence`, exactly as Openverse's do.
- **Crosswalk**: none to the encyclopedia; the namespace is instead the
  crosswalk *between sources on this shelf*. A later keyed Guardian provider
  (#63) computing the same normalised URL under the same `news_article`
  namespace will fold into the same card through `Shelf.dedup/2`, without
  either provider knowing the other exists. The parameter sort is part of
  normalisation for this reason and not for tidiness: two feeds can name one
  article with the same parameters in a different order.

The evidence is therefore **attestation**, and its locator is the third shape
the kit has needed after PoetryDB's line and Open Library's (empty) page:
`a headline, Wired, 15 September 2026`.

## Measured facts

Things nobody should have to measure twice.

1. **The project's own User-Agent works.** `200` and the same items a Chrome
   UA received. #135 measured its numbers with a browser UA and allowed a
   fallback; it is not needed.
2. **The feed is a search, not a wire.** `nepotism` returns 2025 items;
   `logomachy`'s whole answer is one *Word of the day* piece from March 2026;
   one of `bestiality`'s own twelve is from December 2023. A freshness window
   is what makes this a News shelf, and without one the shelf would ship a
   three-year-old explainer under a heading that says News.
3. **`mkt` is inferred from the caller's address, and it changes the answer
   completely.** Unpinned, from this desk, the market was `pl-pl`:
   `/define/war` came back as six Polish games-site and Steam-store pages
   about *War Thunder* and *Total War*, two of them from 2006 and 2013, with
   mojibake-encoded Polish titles. With `mkt=en-US` the same word answered
   with the Iran war from Newsweek, UPI, the New York Times and the Atlantic.
   `bestiality` went from 7 items to 12 and picked up Wired, the Chicago
   Tribune, CBS, Rolling Stone and Al Jazeera. Pinning it also removes the
   need for Open Library's language gate, and makes the captured fixture
   reproducible from another desk.
4. **Do not quote the query, not even a multi-word lemma.** #135 guessed a
   multi-word lemma would need quoting; measured, it is the opposite. `q=red
   herring` answered six items, four using the phrase and two of those from
   the last three days; `q="red herring"` answered three, the freshest from
   2024. For a single word, `q="bestiality"` returned a different seven with
   no more of them usable. The whole-word gate enforces the phrase anyway, so
   quoting only narrows the candidates it has to choose from.
5. **`count=` is ignored** (#134). The feed returns its whole answer — at
   most 12 items measured — in one response, which is why the offset is an
   offset into the provider's own gated list.
6. **`qft=interval="7"`** (the freshness parameter) returned *fewer* items
   than the plain query and dropped the 15 September items (#134). Not used;
   `pubDate` is filtered here.
7. **A word with no news answers `200` with a valid channel and zero
   `<item>` elements** (`referendum`). That is an empty result and not a
   malformed one, so `parse_body/1` discriminates on the presence of
   `<channel>` and never on the item count.
8. **Floki lowercases namespaced tags and the escaped CSS selector does not
   find them.** `News:Source` is in the parsed tree as the tag name
   `"news:source"`, and `Floki.find(doc, "news\\:source")` returned **zero**
   matches on the captured fixture. The provider walks each `item`'s children
   by tag name instead. A selector that silently found none would have
   shipped a shelf that credited nobody.
9. **The `apiclick` link is not an identity.** It carries a per-response
   `tid` and the `mkt`, so hashing it would make the same article a new item
   on every fetch — and following it sends the reader to Bing. The `url=`
   parameter decodes in one step, with lowercase percent escapes
   (`%3a%2f%2f`).
10. **Every real `bestiality` item had the word in its title**, so the
    substring-noise case could not be captured for this word and is written
    into the fixture as the one constructed row. The measured substring case
    is a two-word lemma: `q=red herring` answers *No Red **Herrings** Here*,
    which the boundary gate refuses.

## The card

`:news` is a `:credited` row and `preview_metadata` carries the masthead, so
the first browser proof put it on the card twice — once as the creator line
and once as the credit beneath it:

    Kash Patel and GOP lawmaker have bizarre 'bestiality' debate
    15 Sep 2026 · News
    HuffPost on MSN
    HuffPost on MSN

Issue #135 asked for this decision to be made in the browser. The masthead now
goes to the creator keys (`author`, `artist`) only, which is the `text-sm`
unclamped line, and nothing is written to `"attribution"`, so the
`:credited` row renders no credit line for this source. The row stays
`:credited` rather than dropping to `:none`, because `:none` means *the shelf
byline is the whole credit* and the shelf byline is Bing — the one thing a
News shelf must not say about somebody else's journalism.

The date line is `published_at`, formatted *15 Sep 2026*, through one edit in
`DevilsDictionaryWeb.Culture`'s `year/1`. `year` remains the fallback, so
nothing that does not carry `published_at` changed.

## Browser proof

`mix compile` to completion, then **one** dev server on its own database.
`devils_dictionary_v2` already had three Oban nodes on it — the main checkout
on 4007, the #131 page-mockup worktree on 4017 and #136's Urban Dictionary
worktree on 4027, all confirmed by the checklist's `lsof` /
`pg_stat_activity` recipe — so this proof took port **4037** and a database
of its own, `devils_dictionary_bing135`, cloned from the idle
`devils_dictionary_74_verify` and migrated to head. Nothing else was on it.

Screenshots driven over CDP with `Emulation.setDeviceMetricsOverride`,
because headless Chrome's `--window-size` sets the window and not the layout
viewport.

| Page | Width | `scrollWidth` | News items | File |
|---|---|---|---|---|
| `/define/bestiality` | 1280 | 1280 | 12 | `issue-135-bestiality-1280-2026-09-21.jpg` |
| `/define/bestiality` | 375 | **375** | 12 | `issue-135-bestiality-375-2026-09-21.jpg` |
| `/define/logomachy` | 1280 | 1280 | 0 | `issue-135-logomachy-1280-2026-09-21.jpg` |
| `/define/logomachy` | 375 | **375** | 0 | `issue-135-logomachy-375-2026-09-21.jpg` |
| `/define/war` | 1280 | 1280 | 2 | `issue-135-war-1280-2026-09-21.jpg` |
| `/define/war` | 375 | **375** | 2 | `issue-135-war-375-2026-09-21.jpg` |

No horizontal page scroll at 375 on any of the three.

**The shelf.** Headed *News*, byline *Bing News · dated headlines*, twelve
cards on `/define/bestiality`, each a headline, *15 Sep 2026 · News*, the
masthead, and *Source ↗* reaching the publisher. No card links to
`bing.com` — asserted in the DOM, not just looked at.

**The order.** On `/define/war` the DOM reads
`culture-shelf-film`, `culture-shelf-text`, `culture-shelf-news`,
`culture-shelf-image`, `giphy-d2Fy`: News **after** Texts and **before**
GIFs, which is `@known`'s order. The Images shelf falls between News and
GIFs because a shelf nothing identified is demoted to the foot of the typed
shelves (D1 of #126), and the GIPHY shelf is a separate component always
rendered last. The GIF shelf needed its `sources` row inserted by hand on
this database: GIPHY is `transport: :browser`, so the pipeline never calls
`ensure_source/1` for it and `Giphy.browser_config/1` returns `nil` without
the row.

**The reason.** In *About these results*:

> The FBI Doubles Down on Easing ‘Bestiality’ Hiring Standards: Uses
> “bestiality” **at** a headline, Wired, 15 September 2026.

Note *at*, not *in*. #135 asks for *Uses “bestiality” in a headline, Wired,
15 September 2026.* and also says `MatchReason` needs no change; those two
cannot both hold. `MatchReason.describe/1`'s attestation clause is `"Uses "
<> quoted(term) <> at(locator)` and `at/1` is `" at " <> locator`, so the
preposition belongs to the renderer and not to the locator this provider
writes. The locator is exactly the string #135 specified. Changing the
preposition means editing `match_reason.ex`, which #135 put out of scope, so
it is reported rather than done.

**The empty.** `/define/logomachy` shows no News rail and no cards. What it
does show is the shared empty-state line — *In news · No matching news for
this term yet.* — which is what every content type renders for an empty run
(*In film*, *In text* are on the same screenshot) and is not this provider's
to suppress. One request spent, `no_results`, and two reloads afterwards
spent none.

**The source row.** Inserted by `ensure_source/1` on the first run and
checked on the database the server was on:

```text
   slug    | tier  |   name    |  attribution
-----------+-------+-----------+---------------
 bing-news | plebs | Bing News | via Bing News
```

No hand correction was needed, because this database had no `bing-news` row
to be stale.

## Conformance

    mix test test/devils_dictionary/discovery/conformance/bing_news_conformance_test.exs
    mix test test/devils_dictionary/discovery/providers/bing_news_test.exs

The fixture is a **real** capture of
`?q=bestiality&format=rss&mkt=en-US` from 2026-09-21, `<copyright>` and all,
so its `pubDate`s are real September dates. The clock is therefore injected:
`config :devils_dictionary, :bing_news, now: ~U[2026-09-21 12:00:00Z]` in
`config/test.exs`, read by `BingNews.now/0`. Without it the freshness gate
would have passed that week and failed the next.

Three of the `:results` page's five rows are there to be refused, and the
expected ids say so by leaving them out: the real Daily Telegraph item from
December 2023 (outside the window), a second copy of the Wired story with
`utm_*`, `fbclid` and a `#comments` fragment (folds into the first by
identity), and one constructed `#Bestialitygate` row (the substring the
boundary gate refuses).
