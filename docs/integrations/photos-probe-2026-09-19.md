# Photos probe — Openverse slice, 2026-09-19

Phase 0 of #116 asked for six words through every candidate in one session.
This is the **Openverse slice only**, run inside Phase 2 because Openverse is
the source whose thumbnail ladder the row's shape was waiting on (#116 Phase 1
audit, 2026-09-19). Unsplash and Pexels move to Phase 3; Wikimedia Commons was
probed separately and is already a provider (`commons.md`).

The Unsplash and Pexels slices ran inside Phase 3 on the same day and are in
[`photos-probe-unsplash-pexels-2026-09-19.md`](photos-probe-unsplash-pexels-2026-09-19.md),
which completes Phase 0. Read the two together for the cross-source overlap
question (M3): §7 there measures all four sources at once.

The six words are the project's usual four plus #100's honest-empty pair:
`war`, `love`, `grief`, `soldier`, `allegory`, `nepotism`.

Every request went through `Req`, anonymously, with this project's
`:user_agent`. No image bytes were fetched.

## Ledger

Ceiling for the session: **200**, of which the probe slice is at most **100**.
Spent here: **80**.

Running totals, written per batch.

| # | requests | what was asked | what came back | running |
|---|---|---|---|---|
| P1 | 1 | `GET /v1/rate_limit/` | `401` — the endpoint that reports your quota needs a key | **1 / 100** |
| P2 | 6 | the six words, bare `q`, no filter | `200` each, 20 results each, `result_count` **240** for all six | **7 / 100** |
| P3 | 6 | the six words, `license=cc0,pdm,by,by-sa` | `200` each, 20 results each, still `result_count` 240 | **13 / 100** |
| P4 | 2 | `q="nepotism"` and `q="war"` quoted, same licence filter | `200`; `"nepotism"` drops to `result_count` **66** and the results change entirely | **15 / 100** |
| P5 | 30 | the same query 30 times as fast as Req would send it | `200` × 30, **no 429**; 29 were Cloudflare `HIT`s and never reached the origin | **45 / 100** |
| P6 | 24 | 24 *distinct* queries, back to back, all `MISS` | `200` × 24, **no 429**, and the quota headers never moved | **69 / 100** |
| P7 | 1 | `q="war"&source=wikimedia` | 20 Commons files, `foreign_landing_url` = `…/w/index.php?curid=<pageid>` | **70 / 100** |
| P8 | 4 | four rare dictionary words, quoted, licence-filtered | `abderian` 0, `logomachy` 0, `eructation` 1, `quodlibet` 149 | **74 / 100** |
| P9 | 6 | the six words again, 43 minutes later, for URL stability | `200` × 6 in 20–24 ms, all `cf-cache-status: HIT` — the edge answered, so this measured nothing; see §2 | **80 / 100** |

The browser proof's requests are on this project's own ledger
(`discovery_request_attempts`, source `openverse`) and are counted in the Phase
2 report, not here.

## 1. What comes back, and for which words

| word | bare `q` | `license=cc0,pdm,by,by-sa` | top three, licence-filtered |
|---|---|---|---|
| war | 20 of “240” | 20 of “240” | *Star Wars Episode 1* × 3 |
| love | 20 of “240” | 20 of “240” | *Love!* · *Love* · *Love* |
| grief | 20 of “240” | 20 of “240” | *grief and beyond* · *grief* · *Grief-2.jpg* |
| soldier | 20 of “240” | 20 of “240” | *North Korea - Woman soldier* · *Young soldier boy, probably Spanish ca 1900* · *North Korea - Woman soldiers* |
| allegory | 20 of “240” | 20 of “240” | *Allegory of Justice, Lausanne* · *Germany-00494 - Allegory of Science* · *An Illustration of The Allegory of the Cave* |
| nepotism | 20 of “240” | 20 of “240” | *Tesoretto di sovana … solido di giulio nepote* · *Mónica Nepote* · *Indigo Bunting: Negri Nepote* |

**`result_count` is not a count.** Every one of the six words answers exactly
`240` with `page_count: 12`, which is the anonymous walk's ceiling and not a
measurement of anything. A word with genuinely few matches reports the truth
(`"nepotism"` quoted: 66; `quodlibet`: 149; `logomachy`: 0), so the number is
usable only below the cap. The provider treats 240 as the end of the walk.

**The bare `q` is not a search for the word.** `fields_matched` on a bare query
names `description`, `title` and `tags.name`, and the analyzer stems: `war`
answers twenty copies of *Star Wars Episode 1*, and `nepotism` answers
photographs of *Negri Nepote*, a grassland in New Jersey. Quoting the term
makes it an exact phrase: `q="war"` answers pictures titled *war*, and
`q="nepotism"` answers a Wellcome cartoon about Benjamin Harrison. **The
provider quotes.** This is the single largest quality decision in the module.

One raw item, trimmed to the fields the provider reads:

```json
{
  "id": "fea16c2e-31c0-43dc-9672-fff81a3f4346",
  "title": "An Illustration of The Allegory of the Cave, from Plato’s Republic",
  "creator": "4edges",
  "creator_url": "https://commons.wikimedia.org/wiki/User:4edges",
  "source": "wikimedia",
  "provider": "wikimedia",
  "license": "by-sa",
  "license_version": "4.0",
  "license_url": "https://creativecommons.org/licenses/by-sa/4.0/",
  "attribution": "\"An Illustration of The Allegory of the Cave, from Plato’s Republic\" by 4edges is licensed under CC BY-SA 4.0. To view a copy of this license, visit https://creativecommons.org/licenses/by-sa/4.0/.",
  "foreign_landing_url": "https://commons.wikimedia.org/w/index.php?curid=73850232",
  "url": "https://upload.wikimedia.org/wikipedia/commons/8/8d/An_Illustration_of_The_Allegory_of_the_Cave%2C_from_Plato%E2%80%99s_Republic.jpg",
  "thumbnail": "https://api.openverse.org/v1/images/fea16c2e-31c0-43dc-9672-fff81a3f4346/thumb/",
  "fields_matched": ["title"],
  "width": 2400, "height": 1011, "filesize": 842601, "filetype": "jpg"
}
```

## 2. Licence, attribution, creator, and whether the URLs hold

**The licence travels on the item, split in two**: `license` is Openverse's
slug without a `cc-` prefix (`by`, `by-sa`, `cc0`, `pdm`, and the `nc`/`nd`
variants) and `license_version` is separate. `CC-BY-SA-4.0` is `by` + `sa` +
`4.0` reassembled, which is what M4's short form asks for.

**A licence filter on the query is not a licence gate.** Measured spread on the
bare queries — `war`: `by-sa` 10, `by-nc` 6, `by-nc-sa` 3, `by` 1; `soldier`:
`by` 6, `by-nc-nd` 4, `by-nc` 3, `by-nc-sa` 3, `by-sa` 3, `pdm` 1 — so more
than half of what a naive integration would show is `NC` or `ND`, which this
project does not show. The provider passes `license=cc0,pdm,by,by-sa` **and**
re-checks each item's own `license`, the same posture Commons takes and for the
same reason: the gate belongs on the object.

**`attribution` is a ready-made line**, present on every item observed:
`"Title" by Creator is licensed under CC BY-SA 2.0. To view a copy of this
license, visit https://…`. It is what M4 means by a line shown verbatim, and
it is what the card shows.

**`creator` and `creator_url` are plain** — no HTML, unlike Commons's `Artist`.
One exception matters: for a `source: "wikimedia"` item Openverse passes
Commons's `ObjectName` through as the **title**, markup and all. Measured on
`/define/allegory`: *Allegory of Europe* arrived as
`<div class='fn'> <p>Allegory of Europe </p> <div style='display: none;'>label
QS:Lsl,…`. The provider strips it.

**URL stability**, which Phase 0 asks about, could not be measured the obvious
way: repeating the six queries 43 minutes later came back in 20–24 ms with
`cf-cache-status: HIT`, so Cloudflare answered and the origin was never asked.
What *was* measured is better than a repeat anyway — the same items seen
through **two different queries**, and so two different cache keys, 26 minutes
apart: the probe's `q="war"&page_size=20` at 07:36Z and the running site's
`q="war"&page_size=12&mature=false&filter_dead=true` at 08:02Z. All **six**
items present in both carry byte-identical `url` and `thumbnail`. Neither URL
carries a signature, a token or an expiry parameter, and `thumbnail` is a pure
function of the item's UUID, so there is nothing in either that *could* rotate.
Treat them as stable; the failure mode to watch is an upstream file being
deleted, which is what `filter_dead=true` exists for.

## 3. The thumbnail ladder — and why the row does not change

Two URLs per item, and only two:

| key | what | host |
|---|---|---|
| `thumbnail` | Openverse's own proxy, one size, no ladder | `api.openverse.org/v1/images/<uuid>/thumb/` |
| `url` | the upstream file at full size | `live.staticflickr.com`, `upload.wikimedia.org`, `iiif.wellcomecollection.org`, … |

There is **no ladder**: no `small`/`medium`/`large` variants, no width
parameter that the anonymous API honours. So the `:image` row's
`thumbnail_keys` stay **`thumbnail_url, image_url`** and its aspect stays
**square**, both unchanged from #109 Phase 3a.

**Verdict on the row: no change.** The measurement that was supposed to decide
it says there is nothing to decide — one thumbnail and one original is exactly
the two-rung ladder the row already reads. Square also remains the right frame:
of twenty licence-filtered results for *soldier*, **15 are landscape, 5 are
portrait and none is square**, so any fixed aspect crops something; a square
crops a portrait less than a 4:3 frame would, which is the argument Phase 1
recorded and this measurement supports.

One consequence worth naming: `thumbnail` is a **proxy on Openverse's own
servers**, so every card rendered is a request to `api.openverse.org`
(throttled separately as `anon_thumbnail`, advertised at 150/min). That is
hotlinking, which D14 permits, but it spends Openverse's bandwidth rather than
the upstream CDN's. The full-size `url` goes to `image_url`, which is where the
shelf's media join key is read from and is never the thumbnail.

## 4. Rate limits: what is advertised, what is enforced

Openverse's own settings file publishes the anonymous defaults as
`THROTTLE_ANON_BURST = 5/hour` and `THROTTLE_ANON_SUSTAINED = 100/day`
(`api/conf/settings/rest_framework.py`). **The deployment says otherwise**, in
a header on every response:

```
x-ratelimit-limit-anon_burst: 20/min
x-ratelimit-limit-anon_sustained: 200/day
x-ratelimit-available-anon_burst: 19
x-ratelimit-available-anon_sustained: 199
```

Neither number was reachable:

* **30 identical requests** as fast as they would send: `200` every time. 29
  came back `cf-cache-status: HIT` with `age: 0` and never reached the origin,
  so an integration that repeats one query is not spending quota at all.
* **24 distinct requests**, every one `cf-cache-status: MISS`, back to back
  inside a minute — well past an advertised 20/min: `200` every time, **no
  `429`, no `Retry-After`**, and `x-ratelimit-available-anon_burst` stayed at
  `19` and `-anon_sustained` at `199` through all 24. The same settings file
  defaults `DISABLE_GLOBAL_THROTTLING` to true, which sets every rate to
  `None` and removes the throttle classes; the headers are advertised by
  middleware that the throttle itself is not behind.

**No `429` was observed in 54 requests, so its shape is unmeasured.** The
provider sizes `request_interval_ms` to the **advertised** burst anyway —
3,000 ms for 20/min — because the number a public service publishes is the
number it is owed, and because an unenforced limit is a limit that can be
switched on without telling us. `min_retry_interval_ms` is 60,000, the length
of the advertised burst window; it is a floor, not a measurement, and the first
real `429` should replace it. `retryable_status?/1` is the shared default
(`429` and `5xx`), which is right for a DRF service.

**The advertised 200/day is the number this project binds itself to.** Nothing
measured here shows Openverse enforcing it — no `429`, counters that never
moved, `DISABLE_GLOBAL_THROTTLING` defaulting on — so honouring it is a policy
of ours, not an observed ceiling. One word page is one Openverse request; 200
cache misses a day is a small site. M8's answer stands —
the 30-day positive cache and the 24-hour empty cache are the mechanism, and
they were measured working (§6). A registered key raises it to 10,000/day and
100/min and is the owner's action to take; this session holds no key and
registered none.

## 5. Overlap with Wikimedia Commons — the M3 question

Openverse aggregates Commons, and it names the file it aggregated:
`foreign_landing_url` is `https://commons.wikimedia.org/w/index.php?curid=<pageid>`,
where `<pageid>` is **exactly** the `commons_file` external id this project's
Commons provider registers. The crosswalk is free and exact, and the provider
proposes it as a second identifier so `Shelf.dedup/2` folds the copies.

How often the two actually collide on one page is a different question, and the
answer is: **not once, in anything measured.**

* For `war`, restricted to `source=wikimedia`, Openverse's twenty files are
  medal ribbons, war flags and conflict map SVGs — *War Ensign of Prussia
  (1816)*, *Ribbon - War Medal*, *Syrian Civil War map*, *Libyan Civil War*.
  Commons's twelve for the same page, found by `P180 depicts Q198`, are
  photographs and paintings **of** war — *UH-1D helicopters in Vietnam 1966*,
  *My Lai massacre*, *Liberty Leading the People*, *Battle of Gettysburg*.
  **Zero pageids in common.**
* Across six word pages served live (`war`, `soldier`, `allegory`, `dog`,
  `telephone`, `ox`), **12** Openverse items named a Commons file and **0** of
  them was a file Commons had also returned on that page.

That is not a defect in the fold; it is what selecting by *depicts a QID* and
selecting by *has the word in its title* does to two subsets of the same
archive. The fold is asserted on fixtures
(`openverse_commons_fold_test.exs`), it is correct, and on these two providers
it will fire rarely. It will matter more when a third source aggregates the
same files.

## 6. Cache behaviour, measured on the live site

From `discovery_runs` after the browser proof, one row per word:

| completion | words | `refresh_after` | requests spent |
|---|---|---|---|
| `results` | war, soldier, allegory, dog, telephone, ox, nepotism | +30 days | 1 each |
| `no_results` | logomachy | +24 hours | 1 |

Reloading `/define/logomachy` after the empty answer spent **0** requests: the
negative cache answered. One page is one request, never two.

## 7. The honest empty is not `nepotism`

#100 picked `nepotism` as an honest-empty word, and it is one for an
identity-bearing source: no sense on that page refers to a QID, so Commons
declines before spending anything. A keyword provider declines nothing (M6),
and Openverse answers `nepotism` with sixty-six results. `/define/nepotism`
therefore shows an Images shelf credited to Openverse alone.

Words Openverse genuinely has nothing for, licence-filtered and quoted:
**`abderian` (0)** and **`logomachy` (0)**. `eructation` returns 1 and
`quodlibet` 149. `logomachy` is the word the browser proof uses for the empty.

## Verdict

**In.** Keyless, CC-only by construction, one request per page, a ready-made
attribution line per item, and an exact crosswalk to the Commons files it
aggregates. Against it: the match is text and can only ever be a labelled
search (M6); the daily ceiling is 200 without a key; and `result_count` lies
above 240.

Nothing in the `:image` row changes.
