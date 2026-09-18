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

Ceiling: **200 requests**. Spent: **157**. Written as the probe ran.

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

B1–B3 were spent by the running application rather than by a script, and they
are the rows of `discovery_request_attempts` for this source — which is the
record of what was actually spent, per the checklist.

Requests 9 and 10 are the two SPARQL calls; they are on this ledger rather than
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
least 3× the runner-up. **115 of 127 poets** clear it and 2,317 of the 2,523
rows carry a QID. The other twelve carry none — three are namesakes nothing
separates (*James Thomson* is two poets, 38 sitelinks against 19), and nine are
names PoetryDB spells its own way: *Lord Alfred Tennyson*, *Samuel Coleridge*,
*Sir Walter Scott*, *Henry Wadsworth Longfellow*, *James Henry Leigh Hunt*,
*John Wilmot*, *Anne Kingsmill Finch*, *Major Henry Livingston, Jr.*,
*Robinson*. A guess would be worse than a gap.

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
7. **Two poets are unreachable by author.** `/author/George Gordon, Lord Byron`
   and `/author/Percy Bysshe Shelley` both `503` after ~16 s. Their collected
   works are simply too large to serialize in one response — *Don Juan* alone
   is 16,092 lines, and Shelley's 312 poems total 37,898. The corpus holds 127
   of 129 poets and names the two it does not.
8. **Duplicates exist.** 18 (poet, title) pairs occur twice; for 3 of them the
   text is identical too, so the manifest's 2,526 fetched rows deduplicate to
   **2,523**.

### Pacing

`request_interval_ms: 1_000`, `min_retry_interval_ms: 5_000`.

Neither is a throttle this provider was forced to — 127 requests at 300 ms
drew no backpressure at all. 1 s is what a free single-dyno public service is
owed by something that visits it on every word page. The 5 s retry gap is
measured: a `503` here arrives after ~16 s with no `Retry-After`, so retrying
straight back buys another 16 s timeout.

## The corpus

`priv/artworks/manifests/poetrydb-v1.json` — 2,523 poems, 127 poets, 2,317
with an author QID. Built once from the P7 fetch and committed;
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
