# PoetryDB

Probed 2026-09-18 for #109 Phase 2. Scaffolded by `mix dd.provider.new poetrydb
--archetype both --content-type text --transport get --pagination offset`.

## Posture

| | |
|---|---|
| Slug | `poetrydb` |
| Archetype | both — a discovery provider over `/lines`, and the `poetrydb-v1` corpus |
| Base | `https://poetrydb.org` |
| Licence | the poems are public domain; the API is MIT ([LICENSE](https://github.com/thundercomb/poetrydb/blob/master/LICENSE)). Both metadata and full text may be stored. |
| Key required | none. This is the second provider after the Met that a fresh worktree with no `.env` can actually drive. |
| Published rate limit | none published |
| Measured sustainable rate | 300 ms spacing held for 127 consecutive requests with no throttle of any kind — no `429`, no `Retry-After`, no rising latency. Shipped at **1,000 ms** anyway; see *Pacing* below. |
| Images | none. A poem has no image, and `:text` has no image slot. |

## Probe

Ceiling: **200 requests** for the Phase 2 probe, spent **172**; #109 Phase 1c
was given a second ceiling of **40** for the Byron/Shelley recovery and spent
**40**. Written as each run went, never totalled at the end.

| # | requests | what was asked | what came back | running total |
|---|---|---|---|---|
| P1 | 1 | `/author` | 200, 2.3 s — 129 poets | **1 / 200** |
| P2 | 3 | `/lines/war`, twice with `title,author,linecount,lines` and once bare | **503** all three, after 15.7–17.1 s | **4 / 200** |
| P3 | 1 | `/title/Sonnet 1` with a literal space | never left the process: `Req.HTTPError invalid_request_target`. Counted anyway — a request budgeted is a request spent. | **5 / 200** |
| P4 | 4 | `/lines/thunderbolt` (25 hits), `/lines/war/title,author`, `/title/Sonnet%201`, `/author/Ambrose%20Bierce/title` | `thunderbolt` **503** at 17.2 s with only 25 results; the other three 200 in 0.2–2.1 s | **9 / 200** |
| P5 | 5 | field-set bisection on `/lines` | `title,author` 200 · `title,author,linecount` 200 · `lines` alone **503** · `title,author,linecount,lines` **503** · `/lines/zzzzqqqx/title,author` → **200** carrying `{"status":404}` | **14 / 200** |
| P6 | 3 | `/lines,author/war;Alan%20Seeger/…,lines`, `/title/…:abs/…,lines`, `/author/Alan%20Seeger/…,lines` | all 200, 0.2–1.6 s — **narrowing rescues the `lines` field** | **17 / 200** |
| P7 | 129 | `/author/<poet>/title,author,linecount,lines`, one per poet, 300 ms apart | 127 × 200 (mean 1.35 s, max 14.4 s), **2 × 503**: Byron and Shelley | **146 / 200** |
| P8 | 2 | `/author/<poet>/title,linecount` for those two | 200 — Byron holds *Don Juan* at 16,092 lines; Shelley 312 poems / 37,898 lines | **148 / 200** |
| P9 | 2 | `query.wikidata.org/sparql`, POST, 127 poet labels in one `VALUES` block, then again with sitelinks | 200 in 1.0 s and 2.0 s — 324 candidate bindings | **150 / 200** |
| P10 | 6 | fixture capture: `/lines/war/…`, `/lines/love/…`, two poet hydrations, a colon-titled poet, and a miss | all 200 | **156 / 200** |
| P11 | 1 | `/lines/zzzzqqqx/title,author,linecount` | 200 with the in-body 404 | **157 / 200** |
| B1 | 5 | the browser proof: `/define/war`, one run | 200 — 12 candidates, 4 poets, **3 kept** by the gate | **162 / 200** |
| B2 | 4 | `/define/love`, one run | 200 — 12 candidates, 3 poets, **10 kept** | **166 / 200** |
| B3 | 1 | `/define/zyzzyva`, one run | 200 with the in-body 404 → `no_results`, refresh in 24 h | **167 / 200** |
| V1 | 2 | answering a review: `/lines,author/war;<Byron>` and `;<Shelley>` | **503** both, ~16 s — narrowing by poet alone does not rescue them | **169 / 200** |
| V2 | 3 | the same two poets narrowed by line count as well | 200 in 246–785 ms, **one poem each** | **172 / 200** |

#109 Phase 1c, 2026-09-18 — its own ceiling of **40**, spent **40**:

| # | requests | what was asked | what came back | running total |
|---|---|---|---|---|
| C1 | 2 | `/author/<poet>/title,linecount` for Byron and Shelley | never left the process — `Req.Finch` was not started in the script. Counted anyway, the way P3 was: a request budgeted is a request spent | **2 / 40** |
| C2 | 2 | the same two, with `:req` started | 200 in 0.98–1.23 s — Byron **325** poems / 69,650 lines, Shelley **312** / 37,898 | **4 / 40** |
| C3 | 1 | `/author,linecount/Percy%20Bysshe%20Shelley;4/title,linecount` | 200 in 736 ms, **18 rows, all `linecount` 4** — so `linecount` matches exactly and a bucket is a partition, not a filter | **5 / 40** |
| C4 | 1 | `query.wikidata.org/sparql`, POST, both poet names in one `VALUES` block with `wikibase:sitelinks` | 200 in 6.9 s — Shelley one candidate (**Q93343**, 142 sitelinks); *George Gordon, Lord Byron* **no candidate at all** | **6 / 40** |
| C5 | 34 | `/author,linecount/<poet>;<n>/title,author,linecount,lines`, the 34 largest buckets, 1 s apart | **34 × 200**, 232 ms–923 ms, no `503` of any kind. **380 poems**: Byron 198 of 325, Shelley 182 of 312 | **40 / 40** |

Every C5 row returned exactly the number of poems C2's title list predicted for
that bucket — 34 of 34 — which is the check that the bucket route sees the same
corpus the author route does.

B1–B3 were spent by the running application rather than by a script, and they
are the rows of `discovery_request_attempts` for this source — which is the
record of what was actually spent, per the checklist.

Requests 149 and 150 are the two SPARQL calls; they are on this ledger rather than
a separate one because the ceiling is a ceiling on the probe, not on one host.
No image bytes were fetched at any point — there are none to fetch.

## What identity a result carries

**None, and that is the point.** PoetryDB is the text provider the README's
*one rule* names as its own exception. A poem publishes no claim about what a
word means, so the evidence is **attestation**: this work *uses* this word, at
this line. It renders as *Uses “war” at line 16* and never as *about war*.

- Source identifier: none published. `poem_id` is derived — `sha256(author ␀
  title ␀ lines)`, truncated to 32 hex. Poet and title alone are not an
  identity: 18 pairs in the 2,526 poems fetched are used twice.
- Encyclopedia identifier: none is required. `covers?/1` is the default `true`.
- Crosswalk: the **author's** Wikidata QID, in the corpus manifest only, and
  never on the poem's `external_identifiers` — a poem is not the person who
  wrote it, and registering `wikidata: Q82083` on a Keats poem would collide
  with the entity that actually is Keats.

The author crosswalk is a stated rule, not a judgement: the most-linked
Wikidata human whose label or alias is exactly the poet's name, with `P31`
human and `P106` poet / writer / author / lyricist, at least 5 sitelinks and at
least 3× the runner-up. **116 of 129 poets** clear it and 2,499 of the 2,903
rows carry a QID. The other thirteen carry none — three are namesakes nothing
separates (*James Thomson* is two poets, 38 sitelinks against 19), and ten are
names PoetryDB spells its own way: *Lord Alfred Tennyson*, *Samuel Coleridge*,
*Sir Walter Scott*, *Henry Wadsworth Longfellow*, *James Henry Leigh Hunt*,
*John Wilmot*, *Anne Kingsmill Finch*, *Major Henry Livingston, Jr.*,
*Robinson*, and — since Phase 1c — *George Gordon, Lord Byron*, which is
neither a Wikidata label nor an alias of anything. Shelley clears it as the
sole candidate for his own name (Q93343, 142 sitelinks). A guess would be worse
than a gap.

## Measured facts

Things nobody should have to measure twice.

1. **`lines` is unaskable on a `/lines` search.** `/lines/<word>` with the
   `lines` output field returns `503` after ~16 s, **every time**. It is not a
   volume limit: `thunderbolt` matches 25 poems and fails exactly as `war`'s
   1,026 do. Any field set without `lines` answers 200 in under 2.5 s.
2. **Narrowing rescues it.** `/lines,author/<word>;<poet>/…,lines` returns the
   lines fine. That is why the provider is two-stage — candidates from
   `/lines/<word>/title,author,linecount`, then one hydration per distinct poet
   in the page's window.
3. **Narrow by poet, never by title.** `:` `;` and `/` are PoetryDB's own
   operators. **434 of the 2,526 titles contain one** (*The Rape of the Lock:
   An Heroi-Comical Poem*, *Monday Night May 11th 1846 / Domestic Peace*), and
   **no** poet's name does. A title-keyed hydration is broken for one poem in
   six; `:abs` title matching works and is unusable for the same reason.
4. **The search is a substring search.** `/lines/war` answers 1,026 poems;
   only **201** of them contain *war* as a word. The rest are *warm*, *toward*,
   *wary* — and the very first candidate PoetryDB returns for `war`, Gordon's
   *An Exile's Farewell*, is one of them. The provider re-checks every
   hydrated poem at a word boundary and drops what fails; the fixture keeps
   that candidate so a provider that stopped checking fails the suite.
5. **A miss is a 200 carrying a 404.** `/lines/zzzzqqqx/…` answers HTTP 200
   with `{"status": 404, "reason": "Not found"}`. Reading the status line would
   turn every unattested word into a provider failure and a backoff; it is a
   negative cache.
6. **`linecount` is not `length(lines)`.** The field counts non-blank lines;
   the array includes the blank lines between stanzas. They disagree for
   **1,694 of 2,526** poems. A line number a reader can count to is an index
   into the array, so that is what `line_count` and the match reason use, and
   PoetryDB's own figure is kept beside it as `source_line_count`.
7. **Two poets cannot be fetched in bulk, by any route that names only them.**
   `/author/George Gordon, Lord Byron` and `/author/Percy Bysshe Shelley` both
   `503` after ~16 s, and so — measured while answering a review on #115 — does
   the narrower `/lines,author/war;<poet>`. Their collected works are too large
   to serialize in one response: *Don Juan* alone is 16,092 lines, and
   Shelley's 312 poems total 37,898. **A third axis reaches them in bulk:**
   `/author,linecount/<poet>;<n>` returns the `lines` field for these two where
   `/author/<poet>` will not, in 232–923 ms, because a bucket is a fraction of
   the payload. `linecount` matches **exactly** — `Shelley;4` answers with the
   eighteen four-line poems and nothing else — so the buckets partition a
   poet's poems rather than filtering them, and full coverage is one request
   per distinct linecount: 111 for Byron, 108 for Shelley, **219** in all. #109
   Phase 1c had a ceiling of 40 and took the 34 largest buckets, so the corpus
   now holds **129 of 129 poets** and **380 of those two poets' 637 poems**.
   The manifest's `selection.recovery` block lists every bucket taken, so what
   is absent is derivable rather than merely admitted: 257 poems, *Don Juan*
   among them.
9. **A third axis reaches them.** `/lines,author,linecount/war;<poet>;<n>`
   answers with **one poem**, in 246–785 ms, for the same poet whose two-axis
   query times out. The candidate list already carries `linecount`, so this
   costs no extra lookup — it is why the provider has a straggler pass and why
   a result's `source_url` is the three-axis query. It is not the normal
   hydration route because candidates arrive clustered by poet: a
   twelve-candidate window of `war` is four poets, so one request per poet is
   five requests where one per candidate would be thirteen.
8. **Duplicates exist.** 18 (poet, title) pairs occur twice; for 3 of them the
   text is identical too, so the P7 fetch's 2,526 rows deduplicate to **2,523**.
   The 380 rows Phase 1c added deduplicate to 380 — `Manifest.new/3` is
   idempotent on `poem_id`, and none of them collided.

### Pacing

`request_interval_ms: 1_000`, `min_retry_interval_ms: 5_000`.

Neither is a throttle this provider was forced to — 127 requests at 300 ms
drew no backpressure at all. 1 s is what a free single-dyno public service is
owed by something that visits it on every word page. The 5 s retry gap is
measured: a `503` here arrives after ~16 s with no `Retry-After`, so retrying
straight back buys another 16 s timeout.

## The corpus

`priv/artworks/manifests/poetrydb-v1.json` — **2,903 poems, 129 poets, 2,499
with an author QID**, checksum `9fa17133…`. Built from the P7 fetch and
extended once by Phase 1c's C5 buckets, then committed;
`DevilsDictionary.Artworks.Corpus.Poetrydb` is the builder. Seeded as
`work_kind: "poem"` under the `poetrydb_poem` identity namespace, which is the
same namespace and the same `poem_id` a live result resolves to — a poem found
on a page and the same poem held here are one identity, not two.

## Browser proof

Port 4017, one node on `devils_dictionary_v2`, `mix compile` to completion
first. Screenshots at 1280 and 375 CSS px, driven over CDP with
`Emulation.setDeviceMetricsOverride` rather than `--window-size`:

    docs/discovery/issue-109-phase2-war-1280-2026-09-18.jpg
    docs/discovery/issue-109-phase2-war-375-2026-09-18.jpg
    docs/discovery/issue-109-phase2-love-1280-2026-09-18.jpg
    docs/discovery/issue-109-phase2-love-375-2026-09-18.jpg

`document.documentElement.scrollWidth === 375` at 375 on both pages, and
`=== 1280` at 1280: no horizontal page scroll at either width.

The shelf is *Texts*, bylined **PoetryDB · attested lines**, with no image
slot. Every item names a line: *Uses “war” at line 16*, *at line 118*, *at line
35*; *Uses “love” at line 19*, *at line 14*, *at line 28*, and so on for ten.

The live results resolved to `poetrydb_poem` identities whose ids are the ones
in the committed manifest — `69b7e022…` is *Ode in Memory of the American
Volunteers Fallen for France* in both — so a poem found on a page and the same
poem held in the corpus are one entity with `work_kind: "poem"`, not two.

## Conformance

    mix test test/devils_dictionary/discovery/conformance/poetrydb_conformance_test.exs
    mix test test/devils_dictionary/artworks/corpus/conformance/poetrydb_corpus_conformance_test.exs
