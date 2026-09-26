# Historical draft — preserved 26 September 2026

This is retained research, not an implementation instruction or current product policy. Provider status, priorities and policy interpretations describe 21 September. Subsequent provider and discovery-kit PRs have landed; verify current code and source terms before acting on this draft. Use [the current README](../../../README.md), [routing ADR 0004](../../adr/0004-public-routing.md), and curation issues [#193](https://github.com/razrfly/dictionary/issues/193) / [#196](https://github.com/razrfly/dictionary/issues/196) for current direction. The original text follows unchanged.

---

# API saturation audit — 2026-09-21

Every source the app talks to, graded on what it actually does today; the
credibility hierarchy the sources already carry and where it is invisible; and
the shortest list of additions that would let the discovery kit be called
saturated for an MVP. Read from `main` at `71a7983`, the dev database
`devils_dictionary_v2`, and the dev server on port 4007.

**Overall grade for the discovery kit: B+.** The machinery is an A: one shelf
per content type, sources credited once, every item carrying a one-sentence
reason, licence credits under every stock photo, an honest empty on every
identity and attestation shelf, a ledger row for every request, 436 tests
green. What holds it at B+ is not the kit but what flows through it: the three
`:query` image providers are noise on any word that is not a concrete noun, the
attestation providers pass proper nouns, the tier that every source row
carries is invisible on the culture shelves, and no discovery source sits in
the aristocracy at all.

---

## 1. What was measured

| Evidence | What it says |
|---|---|
| `discovery_runs` joined to `sources`, 2026-09-21 16:00 | 173 runs across 9 live providers; **2 failed** (both Open Library: one timeout, one malformed response); 43 honest empties; 1,258 results over 62 distinct words |
| `discovery_results.match_details` | Every result carries a `kind`: `keyword` (CineGraph), `tag` (Met), `depiction` (Commons), `attestation` (PoetryDB, Open Library, Bing), `query` (Openverse, Unsplash, Pexels). No result without one |
| `/define/war`, `/define/love`, `/define/logomachy`, `/define/rizz` in the browser | Shelves render, credits render, empties say *No matching film for this term yet*, the 📱 Urban Dictionary card fetches in the browser |
| `mix test` on the discovery, corpus-conformance and sources suites (partition `audit`) | **436 tests, 0 failures**, 26 s |
| Six one-shot probes of candidate endpoints (this session, identifying User-Agent) | Openverse audio `q=war`: 240; MusicBrainz `tag:war` recordings: 809; Wikiquote *War* and *Love* exist, *Logomachy* is missing; Imgflip `get_memes`: 100 templates; Wikidata SPARQL answered **429 on the first request** |

---

## 2. Source by source

Grades weigh four things: does it run through the kit without failing, is what
it returns actually about the word, is its licence posture settled, and would
a reader want it. The tier column is the `sources.tier` value in the database
today.

### Definition sources (absorbed, `Sources.Catalog`)

| Source | Tier | Grade | Why |
|---|---|---|---|
| Samuel Johnson 1755 (LEME) | 👑 | **A** | 42,726 entries, CC BY transcription, on every page it covers, first in the descent |
| Ambrose Bierce 1911 | 👑 | **A** | Public domain, the house voice, honest about its 1,000-word range |
| Open English WordNet 2025 | 📚 | **A** | The sense spine; broader/narrower graph renders |
| Wiktionary via Kaikki | 📚 | **A** | The only source that has *rizz*; forms, origins, 13 senses of *war* |
| Wikidata | 📚 | **A−** | The identity spine every identity provider hangs off. The weakness is coverage: only *war* of the four probe pages has a sense that `refers_to` a QID, so the Met and Commons decline on about 99% of pages |
| Wikipedia | 📚 | **B+** | The thing panel. Wrong layer for currency by its own measurement (#134: the *Bestiality* article never mentioned the hearing) |

### On-demand definition source (`Sources.OnDemand`)

| Source | Tier | Grade | Why |
|---|---|---|---|
| Urban Dictionary | 📱 | **B** | Renders on *war*, *love*, *rizz*; fuzzy-match trap handled; nothing stored. Permission email still `pending` on the source row, so it is a stopgap by the project's own rule, and the mature-content gate is an open design question |

### Discovery providers (`:discovery_providers`)

| Source | Tier | Content type | Grade | Evidence |
|---|---|---|---|---|
| Wikimedia Commons | 📚 | `:image` | **A−** | 7 runs, 74 results, 0 failures, identity by `P180` depicts-QID, per-file licence gate. Declines cleanly where the page has no QID |
| PoetryDB | 📚 | `:text` | **B+** | 26 runs, 77 results, line-numbered attestation (*Intestine war no more our passions wage*, line 35). 14 empties out of 26 is the corpus's size (2,903 poems), not a fault |
| The Met | 📚 | `:artwork` | **B** | Identity by tag QID with a bounded broader walk; 60 results over 5 words. Cost is the note: 130 requests for 60 results, because each object is hydrated one request at a time |
| Open Library | 📚 | `:text` | **B** | 21 runs, 184 results, snippet-verified attestation with an OLID. The only two failures in the ledger are its (timeout, malformed response). Passes proper nouns: *rizz* returns *Rizz* the character and *Rizz.* the medal-catalogue abbreviation |
| CineGraph | 📚 | `:film` | **B−** | 48 runs, 0 failures, identity by TMDb keyword id. Relevance is the issue: the *war* shelf opens on *Street Fighter 8 (Finish Him)*, *My Mother*, *Leçon de français* — obscure 2026–27 titles that carry the keyword, in what looks like release-date order. The match is honest; the ranking is not what a reader wants first |
| Bing News | 📱 | `:news` | **C+** | 6 runs, 19 results, dated locator works, 30-day gate works. Two problems: the feed's own `<copyright>` forbids the use (owner accepted the risk in #141), and headline attestation passes names — three of five *love* items are *Jeremiyah Love* and *Darlene Love* |
| Openverse | 📱 | `:image` | **C+** | 22 runs, 201 results, licence-clean by construction. Substring noise on rare words: *rizz* → *Casa Rizz di Barletta*, *RISD (RIZZ-dee)*; *bestiality* → *Restaurante Bestial* (#134) |
| Unsplash | 📱 | `:image` | **C** | 17 runs, 164 results, credit and UTM right. Search-only; relevance is the provider's |
| Pexels | 📱 | `:image` | **C−** | 16 runs, 190 results, **never empty**. `/define/logomachy` shows eleven Pexels photographs including the Auschwitz gate. This is the D2 case the README already names |
| GIPHY | 📱 | `:gif` | **C** | Works in the browser and reads well on *love* and *rizz*. Outside the pipeline by K10: no ledger, no dedup, no reason, its own component. Promise 6 (*nothing is spent without a ledger*) is not true of it |
| Artsy | 📚 | `:artwork` | **D** | Registered, `background: false`, 0 runs ever; the client was retired in #109. Its 43 artworks reach pages through the catalog. It is a corpus wearing a provider's registration |

### Corpora (`priv/artworks/manifests/`)

| Corpus | Grade | Why |
|---|---|---|
| `met-highlights-v1` (1,644), `wikidata-famous-v1` (1,575) | **B+** | Identity-only, checksummed, honest. *war* gets Rubens's *Consequences of War* and Barnard's Sherman photographs from the catalog; *love* gets Bouguereau and Gérard. These are the most aristocratic items on any shelf and they sort **after** every live result and carry a 📚 tier |
| `poetrydb-v1` (2,903), `open-library-v1` | **B** | Identity only by decision; neither reaches a page as evidence. Correct per D14, and it means the Texts shelf is live-only |

### In flight

| Source | State |
|---|---|
| The Guardian (#142) | Specified in full, key held, branch `codex/142-guardian` exists with **no commits ahead of main**. Not started |
| Wikipedia pageviews trending (#134 Phase 0) | Not started; no `dd.trending` task exists |
| GDELT (#134 Phase 2) | Not started; blocked on a GDELT-shaped backoff |

---

## 3. Is the infrastructure working across all of these?

Yes, mechanically, and the proof is specific:

- **One shelf per type, many sources.** *war* shows one Images shelf bylined *Wikimedia Commons · Openverse · Pexels · Unsplash*, 88 items, taking turns by tier then slug; one Artworks shelf bylined *The Met · Saved catalog*.
- **Every item says why.** 1,258 rows, every one with a `kind`; the reason renders as a sentence (*Uses "war" at line 35*, *a headline, UPI on MSN, 19 September 2026*).
- **Honest empties where the evidence class allows one.** *logomachy*: no film, no news, no GIFs, and the ledger records `no_results` rather than a retry.
- **The ledger is complete.** 96 distinct `(source, stage)` pairs, down to the individual Met object and the individual PoetryDB poet.
- **Nothing failed that should not have.** 2 failures in 173 runs, both from one provider's upstream.

What is not working, in order of how much a reader notices:

1. **`:query` shelves on words that are not concrete nouns.** *logomachy* has no honest empty on Images because Pexels never declines. The README's D2 lever (hide a shelf whose every state is `:query`-only) has been named twice and not pulled. On the evidence of *logomachy* and *bestiality* it should be, or the plebs band should collapse by default (§4 makes these the same change).
2. **Proper nouns pass the attestation gate.** *Jeremiyah Love*, *Rizz* the character, *Rizz.* the abbreviation. The whole-word gate is doing its job; what is missing is a capitalisation heuristic: a lowercase headword whose only hits are mid-sentence capitals is a name, not a use. It is cheap, it lives in the two providers' gates, and it does not need #101.
3. **CineGraph's ordering.** The keyword match is identity and stays. Whatever order CineGraph returns keyword matches in, the first twelve should not be the twelve most recent obscure titles. Worth one question upstream: can the query sort by TMDb popularity or vote count.
4. **The tier is invisible on the culture shelves.** Every source row has one; `Shelf.interleave` sorts by it; the reader cannot see it. §4.
5. **GIPHY is outside the kit.** K10 was a caching decision; the effect is that promise 5 and promise 6 are false for one provider. Either fold it in as `transport: :browser, persistence: :transient` through `Culture.section` or state that the GIF shelf is exempt.
6. **Artsy's registration is a fiction.** A provider with no `retrieve/4` that will never run should be a corpus manifest, not a `:discovery_providers` entry.

---

## 4. The hierarchy

### It already exists, in one place

`sources.tier ∈ {aristocracy, middle, plebs}` is on every row. The definitions
block on every page already descends 👑 → 📚 → 📱 (Johnson and Bierce, then
WordNet and Wiktionary, then Urban Dictionary), tinted and glyphed by
`Kit.tier_class/1` and `tier_glyph/1`. That is the descent #46 and #66 asked
for, and it works.

### Where it does not exist: the culture shelves

*Out in the world* is ordered by **content type** (film · artwork · image ·
text · news · gif, the order of `ContentTypes.known/0`), and within a shelf by
archetype, tier, slug. So a Rubens from the aristocracy of the dead sorts after
a 2027 keyword-matched short, and a public-domain Barnard photograph of
Sherman's campaign sits in the same rail as a Pexels reenactment. The tier
decides the interleave and nothing the reader can see.

### The tiers as the sources carry them today, and two disagreements

| Tier | Today | Disagreement |
|---|---|---|
| 👑 aristocracy | Johnson, Bierce | **No discovery source at all.** #100 placed PoetryDB, Chronicling America, Gutenberg and Wikisource here; PoetryDB was seeded 📚. The famous-paintings corpus is Rubens, Delacroix, David, Bouguereau — the dead — under a 📚 row |
| 📚 middle | WordNet, Wiktionary, Wikidata, Wikipedia, Met, Commons, Open Library, PoetryDB, CineGraph, Artsy | — |
| 📱 plebs | Urban Dictionary, GIPHY, Bing News, Openverse, Unsplash, Pexels; the Guardian is specified 📱 in #142 | #66 defines the middle as *living institutions* (Merriam-Webster, Britannica) and the plebs as *the crowd* (Urban Dictionary, Reddit, X). A masthead is a living institution. The Guardian and NYT belong in 📚; an aggregator of whatever MSN syndicates can stay 📱 |

### Proposed tiers

| Tier | Sources |
|---|---|
| 👑 The dead | Johnson, Bierce, **PoetryDB** (129 poets, all public domain), **the two painting corpora** (the row is the Met's and Wikidata's, so this needs an item-level rule: a corpus item whose creator died before some year sorts 👑 — or two corpus source rows of their own), Wikiquote, Chronicling America, Gutenberg, Wikisource when added |
| 📚 The institutions | WordNet, Wiktionary, Wikidata, Wikipedia, the Met live, Commons, Open Library, CineGraph, MusicBrainz, the Guardian, IGDB, iNaturalist |
| 📱 The crowd | Urban Dictionary, GIPHY, Bing News, Openverse, Unsplash, Pexels, Hacker News, Mastodon, Bluesky, Imgflip |

Re-tiering is a data change on the `sources` row (providers seed with
`on_conflict: :nothing`, so `source_attrs` alone will not move an existing
row) plus the provider's `source_attrs` so a fresh seed agrees.

### Making the descent visible, and why it also fixes finding 1

Two changes, both in `DevilsDictionaryWeb.Culture`, no provider touched:

1. **Band the shelves by tier.** *Out in the world* becomes three bands, 👑 → 📚 → 📱, each holding the content-type shelves that tier's sources contribute to. A shelf stays one per content type inside a band (K2 holds), so *war* shows a 👑 band (poems, the famous paintings), a 📚 band (films, Met artworks, Commons images, Open Library texts, Guardian news) and a 📱 band (stock images, Bing, GIFs, Urban Dictionary). The page then descends the classes once for definitions and once for the world, which is the #66 wireframe.
2. **Collapse the 📱 band by default**, opened by the reader (*show me the plebs*). Every `:query` provider is 📱, so the shelf of Auschwitz gates on *logomachy* is behind a click and the D2 lever is pulled without a new rule. A word with nothing above the plebs band shows the band open, because an honest page with only a crowd is still a page.

The `state.tier` and `item.source_tier` fields the band needs are already on
every shelf state (`culture.ex:151`); this is a group key, not a migration.

---

## 5. Saturation: what a maximally diverse MVP still lacks

Six content types are live (`:film :artwork :image :text :news :gif`) plus
three definition tiers. The modalities with no row at all: **music/sound,
quotes, video, games, discussion, and the natural world**. Memes are a special
case (below). The list is ordered by diversity gained per unit of cost, and
each item names its gate.

### Wave A — no key, licence-clean, and it fills the empty 👑 tier

| # | Add | Row | Tier | Gate, measured | Why first |
|---|---|---|---|---|---|
| 1 | **Wikidata "works about this thing"** (`P921` main subject, `P138` named after) | joins every existing shelf (a book, a film, a song, a painting whose subject is the QID) | 📚 | The SPARQL endpoint answered **429** on this session's first request; use CirrusSearch `haswbstatement:P921=Q198` through the existing `wbgetentities` client and its 200 ms pacing instead | #100's provider #3 and still not built. The only **sense-level** identity source, and the crosswalk hub every later provider resolves through |
| ~~2~~ | ~~**Wikiquote** via the concept's sitelink~~ — **rejected by the owner, 2026-09-21: the quality is not good enough to be the quotes source.** A `:quote` row still wants a 👑 source; Gutenberg extraction or Wikisource are the remaining candidates (#65) | **`:quote`** (new row; heading *Quotations*, no image slot, evidence identity `(author_id, body hash)`) | 👑 | *War* and *Love* pages exist; *Logomachy* does not (an honest empty, measured today). Wikitext bullets: top-level `*` is the quotation, `**` the citation; Misattributed and Disputed sections become provenance notes | The first discovery source whose items are the dead speaking, and #65's first adapter |
| 3 | **Openverse audio** | **`:sound`** (new row; square cover, a play control, attribution `:required`) | 📱 | `q=war`: 240 results today, Jamendo CC BY-SA and CC BY-NC-SA, Freesound for onomatopoeia. Same client, same licence gate, same attribution string as the image provider | The cheapest new modality in the codebase: a second `content_types` entry on a provider that already runs |

### Wave B — keys held or trivially obtained, new modalities

| # | Add | Row | Tier | Gate | Notes |
|---|---|---|---|---|---|
| 4 | **Music: Spotify search, linked out** | **`:music`** (sketched in the README) | 📚 | Read from Spotify's own pages on 2026-09-21: the development-mode cap is **5 *authenticated* users** (OAuth sign-ins), which a server-side Client Credentials search never touches; the owner must hold Premium (held); the policy requires the Spotify marks and **a link back for every piece of metadata or cover art**, and forbids offering the metadata as a standalone product. The 2024-11-27 change removed Recommendations, Related Artists, Audio Features and Audio Analysis for dev-mode apps; search, track, artist and album metadata and cover art remain | **Correction to the first draft of this audit**, which called Spotify "a no as a provider" by repeating #100 and the README. The README's "single-source shelf" reading came from a clause ("integrated with streams or content from another service") that sits among the *streaming* restrictions, next to "plays content from a single source to several listeners" and "synchronize sound recordings with visual media"; it is about playback, not about a track card beside a painting. So: Spotify search → a `:music` shelf, labelled `:query`, cover art hotlinked, Spotify mark plus link back on every card, `SPOTIFY_CLIENT_ID`/`SECRET` already held. Identity where Wikidata carries `P2207` on a song whose `P921` is the page's QID. The one open point, the owner's call as with Bing: development mode is described as for apps "under construction", and extended quota is closed to individuals, so running it on a public site is a terms question, not a technical one. MusicBrainz (809 recordings `tag:war` today, CC0) can join the same shelf as a second source |
| 5 | **The Guardian** (#142) | joins `:news` | 📚 (see §4) | Specified; 500/day; 24-hour retention needs `retention_seconds` in cleanup | The branch is empty. This is the next PR |
| 6 | **Wikipedia pageviews trending** (#134 Phase 0) | not a shelf; a daily signal | — | One keyless request a day; *Bestiality* was rank 354 on 2026-09-16 | The thing that makes a News shelf refresh when it matters and sleep when it does not |
| 7 | **iNaturalist** via taxon QID (`P3151`) | joins `:image` with **identity** | 📚 | 60 req/min; per-photo licence, CC BY-NC default, skip all-rights-reserved | *ox*, *oyster*, *hedge warbler* are already in the probe set and today get only stock photos. This is the second identity path on Images the README asked for |
| 8 | **IGDB** keyword discovery | **`:game`** (sketched) | 📚 | Twitch client credentials; non-commercial; `P5794` crosswalk | The non-commercial posture on a per-item licence, which the row was sketched to test |

### Wave C — the crowd, so the 📱 band is not only stock photography

| # | Add | Row | Gate | Notes |
|---|---|---|---|---|
| 9 | **Hacker News** (Algolia) | **`:discussion`** (new; text-first, a title, a score, a date locator) | Keyless, open; *nepotism*: 62 stories in #100's probe | The plebs echo of a news story, with votes — the first shelf whose items carry a crowd's ranking honestly |
| 10 | **Mastodon** hashtag timelines | joins `:discussion` | Per instance; user content; keyless on mastodon.social | Evidence-wall material that can also be a labelled `:query` shelf |
| 11 | **Bluesky** `searchPosts` | joins `:discussion` | App password; 403 unauthenticated from datacenters | Same shape |

### Memes: there is no source, and the audit should say so

Know Your Meme has no API. Tenor closed to new clients in January 2026.
Imgflip's `get_memes` answers 100 **templates** (*Drake Hotline Bling*, *Two
Buttons*), keyless, title-substring only, no per-word coverage: it is a picker
for a meme *generator*, not a search. Reddit needs a manual approval ticket and
48-hour deletion. So the meme layer is what #67 already says: paste-a-link
evidence, nominated and voted, with GIPHY as the automatic reaction-GIF
register beside it. Building a meme *shelf* from an API would mean either
scraping or a generator's template list, and neither is a source.

### Not recommended, and the keys to remove

| Candidate | Why not |
|---|---|
| Tenor | closed to new clients |
| X | pay-per-read since April 2026 |
| Reddit | approval ticket plus 48-hour deletion, incompatible with a 30-day cache |
| TikTok, Instagram | no third-party search; oEmbed of a known link only (#67) |
| YouTube Data API | 100 searches/day and a 30-day storage rule; curated embeds only |
| **Pixabay** (`PIXABAY_API_KEY` is in `.env`) | its terms require download and forbid permanent hotlinking, the opposite of D14 |
| **Freepik** (`FREEPIK_API_KEY` is in `.env`) | not CC; a stock licence with attribution and download terms; nothing it adds that Openverse, Unsplash and Pexels do not |
| Deezer | no new tokens issued |

The two unused keys in `.env` should go, or be commented as *evaluated, not
used*, so the next session does not re-evaluate them.

---

## 6. What to do, in order

1. **Pull the tier onto the page** (§4): band *Out in the world* by tier, collapse 📱 by default, re-tier PoetryDB to 👑 and the Guardian spec to 📚. One component, one data change. This is the visual thesis of the project and it also retires the D2 question.
2. **Two cheap gates**: the proper-noun heuristic in Bing's and Open Library's attestation, and a question to CineGraph about sort order.
3. **Wave A**: Wikidata works-about (sense-level identity, every shelf), Openverse audio (`:sound`, the cheapest new modality). Wikiquote is out (owner, 2026-09-21); the 👑 discovery tier waits for a better quotes source.
4. **The Guardian** as specified, then the trending signal.
5. **Music from Spotify search, linked out with the Spotify mark; MusicBrainz as the second source.** iNaturalist and IGDB after.
6. **Hacker News** for a crowd that is not stock photography.
7. Fold GIPHY into the kit or exempt it in writing; demote Artsy to a corpus manifest; drop the Pixabay and Freepik keys.

After 1–6 the page for *war* would descend: Johnson and Bierce, a Rubens, a
Byron line, a Wikiquote epigram; then WordNet, Wiktionary, the Met, Commons,
a Guardian headline, a Spotify track, an Open Library snippet; then,
behind a fold, Urban Dictionary, Hacker News, the stock photographs and the
GIFs. That is eleven content types across three visible classes, and it is
what "saturation of an MVP" should mean here: every modality a reader expects
has one honest source, and the class of each source is on the page.

---

## Part two: the kit itself

The same day's audit of the pipeline rather than the sources — contract enforcement, copied helpers, freshness versus retention, the first generation's drift and Artsy's status — is issue #144, phased. Its one-line finding: refresh is per-provider and automatic; retention is neither.

---

## Probe ledger

Six API requests this session, one per endpoint, User-Agent
`wordhoard-audit/0.1`: Wikidata SPARQL (429 twice, nothing measured),
Openverse audio (200), MusicBrainz recording search (200), Wikiquote page info
(200), Imgflip `get_memes` (200); plus four reads of Spotify's public
developer pages (quota modes, policy, the 2024-11-27 change, rate limits) to
correct the music row. No Spotify API call was made. Four page loads on the dev server, which
created new runs in `devils_dictionary_v2` for *war*, *love* and *rizz*
(visible in the ledger totals above). No fixture committed, no key used, no
provider called with a credential.
