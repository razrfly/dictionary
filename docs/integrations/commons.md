# Wikimedia Commons

Probed 2026-09-18 for #109 Phase 3a. Scaffolded by `mix dd.provider.new commons
--archetype discovery --content-type artwork --transport get --pagination cursor
--name "Wikimedia Commons"`, then moved to the `:image` content type the probe
showed it needed (see *Measured facts*, 9).

## Posture

| | |
|---|---|
| Slug | `commons` |
| Archetype | discovery only |
| Content type | `:image` — a fifth row in `DevilsDictionary.Discovery.ContentTypes`, added in this phase |
| Base | `https://commons.wikimedia.org/w/api.php` |
| Transport, pagination | GET; MediaWiki `continue` cursor (`{"continue":"gsroffset\|\|","gsroffset":12}`, JSON-encoded as the cursor and handed back as the parameters it names) |
| Licence | per **file**, read from the hydrated file's `extmetadata`. Only `pd`, `cc0`, `cc-by-*` and `cc-by-sa-*` codes (or, when the code is absent, the short names *Public domain*, *CC0*, *CC BY x*, *CC BY-SA x*) are shown. Everything else — Commons's own `Attribution` template, GFDL, every `NC`/`ND` variant — is dropped. What is stored is a thumbnail URL, the author and the licence; nothing else may be, and nothing else is. |
| Key required | none. The third keyless provider after the Met and PoetryDB. |
| Published rate limit | none for reads; the [API etiquette](https://www.mediawiki.org/wiki/API:Etiquette) asks for a contact `User-Agent`, requests in series, and `maxlag` |
| Measured sustainable rate | 30 request pairs at **250 ms** and 30 at 1 s drew no `429`, no `maxlag` refusal and no `Retry-After`; latency 284–2,449 ms, mean about 500 ms. Shipped at **1,000 ms** anyway, with `maxlag=5` on every request — see *Pacing*. |
| Images | thumbnail URLs (`iiurlwidth=640`) only; bytes are never downloaded |
| A page costs | exactly **2** requests: one `generator=search` carrying `prop=imageinfo`, one `wbgetentities` for the window's `M`-ids |

## Probe

Ceiling: **300 requests** (#109 Phase 3's ceiling; the generator's template says 200). Stop at it. Spent: **81**.

One row per batch, written when the batch finishes rather than when the
probe does. The last column is the running total against the ceiling, so a
probe that is killed leaves the number it had reached and not a blank.

| # | requests | what was asked | what came back | running total |
|---|---|---|---|---|
| A1 | 1 | `list=search haswbstatement:P180=Q4991371`, ns 6, limit 5 | 200 in 590 ms — 8852 total hits; `continue` = `{"continue":"-||","sroffset":5}` | **1 / 300** |
| A2 | 1 | the same search as `generator=search` with `prop=imageinfo` (`url`, `extmetadata`, `iiurlwidth=640`) | 200 in 476 ms — 5 pages with thumbnail URL and `extmetadata` licence in one answer; `continue` = `{"continue":"gsroffset||","gsroffset":5}` | **2 / 300** |
| A3 | 1 | `wbgetentities ids=M6659002|M7887852|M8841536|M17040973|M23538787` (`props=claims`) | 200 in 369 ms — every entity carries `statements.P180` with `mainsnak.datavalue.value.id` QIDs | **3 / 300** |
| A4 | 3 | `haswbstatement:P180=Q144|P180=Q25324`, then `Q144` alone, then `Q25324` alone | 200/200/200 in 212/537/206 ms — 26220 hits for the OR, 26131 for dog, 115 for Canidae | **6 / 300** |
| A5 | 1 | `haswbstatement:P180=Q4991371 filetype:bitmap` | 200 in 487 ms — 8840 hits (A1 had 8852 without the filter) | **7 / 300** |
| A6 | 1 | the same search with `maxlag=-1`, to see the lag refusal | 200 in 237 ms — body `{"error":{"code":"maxlag","docref":"See https://commons.wikimedia.org/w/api.php for API usage. Subscribe to the mediawiki-api-announce mailing list at &lt;https://lists.wikimedia.org/postorius/lists/mediawiki-api-announce.lists.wikimedia.org/&gt; for notice of API deprecations and breaking changes.","host":"10.64.16.149","info":"Waiting for 10.64.16.149: 0.445356 seconds lagged.","lag":0.445356,"type":"db"},"servedby":"mw-api-ext.eqiad.main-77d9d4c448-9vthq"}`; `Retry-After: ["5"]` | **8 / 300** |
| A7 | 1 | page 2 of A2 by handing back its `continue` (`gsroffset=5`, `continue=gsroffset||`) | 200 in 404 ms — 5 new pages, none from page 1; `continue` = `{"continue":"gsroffset||","gsroffset":10}` | **9 / 300** |
| A8 | 1 | `haswbstatement:P180=Q262026` (andiron), the empty case | 200 in 411 ms — body `{"batchcomplete":true,"continue":{"continue":"gsroffset||","gsroffset":5},"query":{"pages":[{"imageinfo":[{"descriptions` | **10 / 300** |
| B1 | 2 | `haswbstatement:P180=Q4115189` (the Wikidata sandbox item) as `generator=search` and as `list=search` | 200/200 in 480/244 ms — **not** the empty case: five test uploads depict the sandbox item (a keyboard, a logo, a roundabout, a `video/webm`, a park), so the window has to gate on `mime` as well as on licence. Written wrongly at first as "no `query` key"; corrected after reading the body | **12 / 300** |
| B2 | 1 | `wbgetentities ids=M116369|M1|M999999999999`: a real file, a very early page id, an id that cannot exist | 200 in 220 ms — []; error `"no-such-entity"` | **13 / 300** |
| B3 | 30 | 15 pages of soldier, each a `generator=search` (limit 10) then a `wbgetentities` of its ten M-ids, **1 s** apart | 15 of 15 pairs clean; latency 308–2449 ms, mean 615 ms; statuses [200]; errors [nil]; Retry-After [nil] | **43 / 300** |
| B4 | 30 | 15 more pages the same way, **250 ms** apart | 15 of 15 pairs clean; latency 284–1746 ms, mean 495 ms; statuses [200]; errors [nil]; Retry-After [nil] | **73 / 300** |
| C1 | 2 | `haswbstatement:P180=Q999999999999 filetype:bitmap` as generator and as list | 200/200 in 492/312 ms — generator body `{"batchcomplete":true}`; list body `{"batchcomplete":true,"query":{"search":[],"searchinfo":{"totalhits":0}}}` | **75 / 300** |
| C2 | 1 | soldier, `gsrlimit=12`, `gsrsort=incoming_links_desc` | 200 in 542 ms — 12 files: File:Cheshire Regiment trench Somme 1916.jpg, File:David - Napoleon crossing the Alps - Malmaison1.jpg, File:Ulysses S. Grant from West Point to Appomattox.jpg, File:Steeplechase2.jpg, File:After the war a medal and maybe a job2.jpg, File:Polish Army Kołobrzeg 077.JPG, File:Into the Jaws of Death 23-0455M edit.jpg, File:Thure de Thulstrup - L. Prang and Co. - Battle of Gettysburg - Restoration by Adam Cuerden.jpg, File:ANA soldier with RPG-7 in 2013-cropped.jpg, File:Escolta presidencial, Plaza de Armas, Lima, Perú, 2015-07-28, DD 40.JPG, File:Yevgene Petrakov's film roll, 1960 04.jpg, File:Stamp of Ukraine s1985.jpg; licences %{"Attribution" => 1, "CC BY-SA 4.0" => 2, "Public domain" => 9} | **76 / 300** |
| C3 | 2 | soldier, `gsrlimit=12`, default sort, then `wbgetentities` for the twelve | 200/200 in 618/363 ms — 12 files, **12 of 12** carry `P180=Q4991371` in their statements; licences %{"Attribution" => 2, "CC BY-SA 3.0" => 1, "CC BY-SA 4.0" => 1, "Public domain" => 8} | **78 / 300** |
| C4 | 2 | dog: the five QIDs `/define/dog` refers to OR'd in one `haswbstatement`, `gsrlimit=12`, links-desc, then `wbgetentities` | 200/200 in 747/468 ms — 12 files, **12 of 12** carry one of the five QIDs; licences %{"CC BY 2.0" => 1, "CC BY-SA 2.5" => 1, "CC BY-SA 3.0" => 4, "CC0" => 1, "Public domain" => 5} | **80 / 300** |
| C5 | 1 | `wbgetentities ids=M116369` alone | 200 in 183 ms — [{"M116369", ["statements"], ["P1163", "P180", "P2048", "P2049", "P3575", "P4092", "P571", "P6216", "P6731"]}] | **81 / 300** |
<!-- ledger -->

Browser-proof requests belong on this ledger too: they are the rows of
`discovery_request_attempts` for this source, which is the record of what
was actually spent.

## What identity a result carries

Association is identity, not text. The search is asked
`haswbstatement:P180=<QID>|P180=<QID>… filetype:bitmap` for the QIDs the
page's senses already `refers_to` — `DevilsDictionary.Discovery.PageEvidence`,
the same read the Met uses, extracted from the Met in this phase so the two
providers cannot drift — and the search only proposes. Every file in the window
is then hydrated with one `wbgetentities` call and kept **only** when its own
`statements.P180` names one of those QIDs. No broader walk: equal QID or
nothing.

- Source identifier: the file's **page id** (the `M` id without the letter),
  namespace `commons_file`. A file's own `P180` / `P6243` values are metadata,
  never its identity.
- Encyclopedia identifier: a Wikidata QID on an active, verified `refers_to`
  claim of a sense on the page. A page with none is declined by `covers?/1`
  before any run exists.
- Crosswalk: the file's `P180` statement value **equals** the sense's QID. The
  reason renders as *Direct depiction of “soldier” (Q4991371).* — a new
  `"depicts"` reading in `MatchReason.from_result/2`, ending as the same
  `:depiction` struct a corpus row's `depicted_qid` already did.

## Measured facts

Things nobody should have to measure twice.

1. **`generator=search` + `prop=imageinfo` answers search and licence in one
   request.** `iiprop=url|mime|extmetadata` with `iiurlwidth=640` returns the
   thumbnail URL, the mime type and the licence fields for every hit, so the
   licence gate costs no request of its own. The whole page is two requests.
2. **The empty answer has no `query` key.** A `generator=search` that proposes
   nothing answers `{"batchcomplete": true}` and nothing else (C1). The
   provider treats that as an ordinary empty page — a negative cache, not a
   malformed body. `list=search` for the same query answers `totalhits: 0`
   with an empty `search` array.
3. **A lag refusal is HTTP 200.** With `maxlag=-1` the API answered `200` and
   `{"error":{"code":"maxlag","lag":0.445,…}}` with `Retry-After: 5` (A6). The
   shared transport reads `Retry-After` only on a non-200, so it never sees
   this; the provider reads the body and returns `{:deferred, "maxlag", 5+}`
   itself. `maxlag=5` rides on every request.
4. **`haswbstatement` OR's with `|`.** `P180=Q144|P180=Q25324` returned 26,220
   hits against 26,131 for dog and 115 for Canidae alone (A4): a union, so the
   page's whole QID set is one query.
5. **`Attribution` is not CC.** Two of the first twelve soldier files carry
   `LicenseShortName: "Attribution"` and no `License` code (C3) — Commons's
   copyrighted-free-use-with-attribution template. It is outside the brief's
   four licences and is dropped. `License` codes seen: `pd`, `cc0`,
   `cc-by-2.0`, `cc-by-sa-2.5`, `cc-by-sa-3.0`, `cc-by-sa-4.0`.
6. **A video can depict a soldier.** The Wikidata sandbox item is depicted by
   five test uploads including a `video/webm` (B1), so the search carries
   `filetype:bitmap` and every kept file's `mime` must start with `image/`.
7. **The proposal is nearly the disposal.** All 12 of 12 soldier files (C3) and
   12 of 12 dog files (C4) the search proposed carried the QID in their
   statements — as they should, since `haswbstatement` is an index of those
   statements. The gate still runs on the hydrated file: an index can lag its
   source, and the rule is that the statements dispose.
8. **`wbgetentities` fails the whole batch on one bad id.** `M116369|M1|
   M999999999999` answered `no-such-entity` and **no** entities at all (B2).
   Our ids come from the search, so they exist; the provider still treats a
   missing entity, an entity without `statements`, and a `somevalue` snak as
   naming nothing rather than as a failure.
9. **`extmetadata` values are HTML**, including `ObjectName` (`<div
   class="fn">…</div>`), `Artist` (a user link, a museum credit block) and
   `DateTimeOriginal` (`1887<div style="display: none;">date QS:P571,…</div>`).
   Tags are stripped, entities decoded, whitespace folded; the year is the
   first four-digit run.
10. **What the search returns for a soldier is mostly photographs**: a Javelin
    launch, D-Day landings, a Polish Army parade, a Confederate infantryman —
    with a Prang chromolithograph and *Napoleon crossing the Alps* among them.
    A shelf headed *Artworks* with an *Artwork* badge under a US Army
    photograph misnames what it shows, so `:image` is the fifth content type:
    heading *Images*, badge *Image*, square slot, ordered after artworks. The
    identity is `work_kind: "image"`. This is the decision #109 3a asked to be
    made during the session.
11. **`gsrsort=incoming_links_desc`** puts the widely used files first — for
    soldier, the Somme trench photograph and David's Napoleon (C2) — where the
    default relevance sort of a pure filter query is effectively arbitrary.
    That is the one quality signal the search offers, and the provider uses it.

### Pacing

`request_interval_ms: 1_000`, `min_retry_interval_ms: 5_000`, `maxlag=5`.

Neither interval is a throttle this provider was forced to — 60 requests at
250 ms drew no backpressure at all. 1 s is what a public API is owed by
something that visits it on every word page; 5 s after a failure is
MediaWiki's own `Retry-After` for a lag refusal. Both are overridable in
`config :devils_dictionary, :commons`.

## Browser proof

See the *Browser proof* rows of the ledger above and the screenshots named in
the #109 report:

    docs/discovery/issue-109-phase3a-soldier-1280-2026-09-18.jpg
    docs/discovery/issue-109-phase3a-soldier-375-2026-09-18.jpg
    docs/discovery/issue-109-phase3a-dog-1280-2026-09-18.jpg
    docs/discovery/issue-109-phase3a-dog-375-2026-09-18.jpg

## Conformance

    mix test test/devils_dictionary/discovery/conformance/commons_conformance_test.exs
    mix test test/devils_dictionary/discovery/providers/commons_test.exs
