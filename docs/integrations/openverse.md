# Openverse

The second source on the Images shelf (#116 Phase 2), beside Wikimedia
Commons. Commons reaches a page by identity — a `P180 depicts` statement whose
QID a sense already refers to — and Openverse reaches one by text, which M6 of
#116 allows on this shelf and nowhere else, provided the reason says so.

The measurements behind every number here are in
[`photos-probe-2026-09-19.md`](photos-probe-2026-09-19.md), which is this
provider's probe and the Openverse slice of #116's Phase 0.

## Posture

| | |
|---|---|
| Slug | `openverse` |
| Archetype | discovery |
| Transport / pagination | GET / offset (`page` + `page_size`) |
| Content type | `:image` — the Images shelf, `attribution: :required`, `evidence: [:identity, :query]` |
| Tier | `:middle`, so `commons` leads it by slug |
| Licence | per item. Only `cc0`, `pdm`, `by` and `by-sa` are shown; every `NC` and `ND` variant is dropped. Stored: the URL, the creator, the licence and Openverse's own attribution line — never bytes (D14) |
| Key required | no. This session holds none and registered none |
| Published rate limit | advertised in every response: `20/min` burst, `200/day` sustained, anonymous. Openverse's own settings file publishes the *defaults* as `5/hour` and `100/day`; the deployment overrides both |
| Measured sustainable rate | no throttle observed at all — 24 distinct origin-reaching requests inside a minute drew no `429` and never moved the counters. `request_interval_ms` is 3,000 ms anyway, sized to the advertised burst |
| Images | references only; the thumbnail is Openverse's own proxy and `image_url` is the upstream file |

## Probe

Ceiling: **200 requests** for the Phase 2 session, of which the probe slice is
at most **100**. Spent in the probe: **80**. Spent by the browser proof: **12**
(`discovery_request_attempts`, source `openverse`).

The full batch-by-batch ledger is in
[`photos-probe-2026-09-19.md`](photos-probe-2026-09-19.md#ledger); it is not
copied here, because two copies of a ledger is one ledger and one stale table.

| # | requests | what | running |
|---|---|---|---|
| P1–P9 | 80 | the probe: six words bare, six filtered, exact-phrase, two throttle runs, the Commons overlap, four empty candidates, one stability recheck | **80 / 100** |
| B1 | 12 | the browser proof: eight word pages served live, and four runs discarded while iterating on the provider | **92 / 200** |

## What identity a result carries

**None of its own that this encyclopedia holds.** A title search is not an
identity match, so the provider implements no
`DevilsDictionary.SourceIdentity.Adapter` and every result persists as
`:insufficient_evidence`. That is the honest state for a `:query` reason, and
the conformance suite asserts it.

What it *does* carry is two identifiers, for the shelf's dedup rather than for
the registry:

- Source identifier: `openverse_media` + the item's UUID
- Upstream identifier, when the upstream is one this project also holds:
  `commons_file` + the Commons pageid, read out of
  `foreign_landing_url` (`https://commons.wikimedia.org/w/index.php?curid=<pageid>`)
  on any item whose `source` is `wikimedia`
- Crosswalk: that pageid is **exactly** the `commons_file` external id
  `DevilsDictionary.Discovery.Providers.Commons` registers, so
  `Shelf.dedup/2` folds the two copies with neither provider naming the other
  (#116 M3). Asserted in
  `test/devils_dictionary/discovery/conformance/openverse_commons_fold_test.exs`.

Flickr, Wellcome and the other upstreams publish ids too; none is a namespace
this project holds, so none is proposed. When one becomes a source, its
identifier goes here the same way.

## Measured facts

Things nobody should have to measure twice.

- **`q` must be quoted.** A bare `q` is stemmed and matched against
  `description`, `title` and `tags.name`: `q=war` answers twenty copies of
  *Star Wars Episode 1*, and `q=nepotism` answers a grassland in New Jersey
  called *Negri Nepote*. `q="war"` answers pictures titled *war*.
- **`result_count` is capped at 240 for an anonymous client**, and reports
  exactly `240` with `page_count: 12` for anything at or above the cap. It is
  usable only below it. The provider stops the walk at 240.
- **`license` is the slug without its `cc-` prefix and `license_version` is a
  separate field.** `CC-BY-SA-4.0` is the two reassembled.
- **The `license` parameter narrows the search; it does not gate the item.**
  The gate is re-applied to the item's own `license`, as it is for Commons.
- **`attribution` is a ready-made line** on every item observed, and it is what
  the card shows verbatim.
- **A `wikimedia` item's `title` can be Commons `ObjectName` markup**, hidden
  `label QS:…` QuickStatements lines and all. The provider strips it; measured
  on `/define/allegory`.
- **One photographer's set arrives as many items.** Eight of twelve results for
  *war* were `"War Horse" by Eva Rinaldi Celebrity Photographer` — eight ids,
  eight URLs, one evening. `Shelf.dedup/2` cannot fold them, so the provider
  keeps one item per `{creator, title}`.
- **The quota headers are advertised, not enforced.** `x-ratelimit-available-*`
  did not move across 54 requests and no `429` was ever returned, so its shape
  and its `Retry-After` are **unmeasured**; `min_retry_interval_ms` is a floor.
- **Cloudflare fronts the API.** A repeated identical query is served from the
  edge (`cf-cache-status: HIT`) and never reaches the origin, so a naive
  throttle probe measures the CDN.
- **`/v1/rate_limit/` needs a key**, so an anonymous client cannot ask how much
  quota it has left; the per-response headers are the only report.

## What this provider does not do

- **No key.** A registered client gets 10,000/day and 100/min. Registering one
  is the owner's action; when it exists, `request_interval_ms` drops to 600 ms
  and the 200/day ceiling goes away.
- **No relevance ranking, and no claim to any.** The reason is
  `Search result for “war”, ranked by the provider and not matched on an
  identifier.` and is shown only on a shelf whose row admits `:query` (#116 M6).
- **No audio.** `/v1/audio/` exists; the `:image` shelf is what this phase is
  about.

## Conformance

```
mix test test/devils_dictionary/discovery/conformance/openverse_conformance_test.exs \
         test/devils_dictionary/discovery/conformance/openverse_commons_fold_test.exs \
         test/devils_dictionary/discovery/providers/openverse_test.exs
```
