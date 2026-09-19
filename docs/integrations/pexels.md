# Pexels

Scaffolded by `mix dd.provider.new pexels` for #116 Phase 3, and filled from
the probe of 2026-09-19 (`photos-probe-unsplash-pexels-2026-09-19.md`, which
has the per-word tables and the raw fields).

## Posture

| | |
|---|---|
| Slug | `pexels` |
| Archetype | discovery |
| Content type | `:image` — the fourth source on the Images shelf |
| Tier | `:plebs` (D1) |
| Licence | **Pexels License**: free to use, commercially, no attribution required but crediting the photographer is asked for, and so is linking back to Pexels. We do both. URLs and metadata only, never bytes (D14). |
| Key required | **yes** — `PEXELS_API_KEY`, read in `config/runtime.exs` from the environment. Without it `enabled?/0` is false and the provider never runs. |
| Published rate limit | 200/hour and 20,000/month |
| Measured sustainable rate | **`x-ratelimit-limit: 25000`** with `x-ratelimit-reset: 1791405831` — 2026-10-07, about a month out. So the window this key is graded on is the **month**, not the hour, and the published 200/hour is not what binds. `request_interval_ms` is 3,000 ms, the same courtesy the other three keep. |
| Images | references only; bytes are never downloaded, by this provider or by the probe |

## Probe

Ceiling for the session: **300**, of which this slice was allowed **60**.
Spent here: **8**.

| # | requests | what was asked | what came back | running total |
|---|---|---|---|---|
| P1 | 6 | `GET /v1/search?query=<word>&per_page=20&page=1` for `war`, `love`, `grief`, `soldier`, `allegory`, `nepotism` | `200` × 6, 20 photos each; `total_results` 7,737 / 8,000 / 5,925 / 6,655 / 4,297 / **4,125** | **6 / 60** |
| P2 | 1 | `query=war&page=2` | `200`, **19** photos for `per_page=20`, **0** ids shared with page 1 | **7 / 60** |
| P3 | 1 | the same query with a deliberately invalid key | `401` with `{"code":"Unauthorized","message":"Invalid API key","status":401}` and **no** `x-ratelimit-*` headers | **8 / 60** |

The site's own requests are in `discovery_request_attempts` under source
`pexels` and are counted in the Phase 3 report, not here: **4** (one each for
`/define/war`, `/define/soldier`, `/define/nepotism` and `/define/logomachy`).

## What identity a result carries

**None.** The same posture as Unsplash, and for the same reason (M6).

- Source identifier: the numeric photo id (`32230027`), registered in the
  `pexels_photo` namespace.
- Encyclopedia identifier: **none.** No `identity_record/1`; every result
  persists as `:insufficient_evidence`.
- Crosswalk: none. The reason is `%{"kind" => "query"}` and is rendered as a
  search result.

## What the licence asks for, and where each part of it is

| Requirement | Where it is |
|---|---|
| Credit the photographer where possible | `preview_metadata["attribution"]` — *Photo by {name} on Pexels* — beneath the thumbnail, always visible |
| Link back to Pexels | `creator_url` (the photographer's Pexels page) and `license_url` (the licence), both rendered as links inside that line (D3); `source_url` is the photo's own page |
| No UTM | Pexels asks for none, so none is added. Inventing parameters a provider did not ask for is not a courtesy. |
| Do not re-host | D14: `<img>` against `images.pexels.com`, no proxy, no bytes |

## Measured facts

- **Pexels has no empty.** All six words answered thousands of results.
  `nepotism` — the word #100 chose *because* it should be empty — answered
  **4,125**, led by stock illustrations of a handshake, a rejected helping
  hand and a man being pointed at. The search falls back to something
  semantic rather than returning nothing, so `total_results` is not a measure
  of relevance and there is no count at which this provider declines. Served
  live on 2026-09-19, **`/define/logomachy`** — the word Phase 2 measured at
  zero on Openverse and used to prove the honest empty — drew 11 Pexels
  photographs of sewing machines, neon letterpress and a *PITCH* sign, while
  Openverse and Unsplash both recorded `no_results` in one request each.
  There is no word left without an Images shelf. The shelf's honesty is the
  labelled reason and nothing else.
- **There is no title and no date.** `alt` is one generated sentence and the
  only text Pexels publishes about a photo; it was present on **all 120**
  results measured, and it is the card's title. No `created_at`, no `taken_at`,
  nothing — so the card says *Year unknown*, which is the truth.
- **The thumbnail ladder is eight rungs and it does not change the row.**
  `src` carries `tiny`, `small` (h=130), `medium` (h=350), `large` (w=940),
  `large2x`, `portrait`, `landscape` and `original`, all on
  `images.pexels.com` and all the same file with different query strings. The
  provider maps `medium` → `thumbnail_url` and `original` → `image_url`,
  which is the two-rung `thumbnail_keys` the `:image` row already reads.
  Because every rung is one path with a different query, `Shelf`'s canonical
  media URL (host and path, no query) already treats them as one picture.
- **`next_page` is malformed.** Pexels answers
  `https://api.pexels.com/v1/v1/search?page=2&per_page=20&query=war` — the
  path segment doubled — which 404s. It is not followed; the cursor is the
  offset.
- **A short page is not the last page.** `page=2&per_page=20` returned
  **19** photos against a `total_results` of 7,737. "Short means last", which
  is what every other provider here assumes, would have ended the walk on the
  second *Load more*. The rule for this provider is: end on an empty page, or
  where `total_results` says.
- **`alt` is unique per photo**, so the `{creator, title}` upload fold that
  Openverse and Unsplash both need never fires here — although one
  photographer often has several photos on a page (8 of 20 slots on
  `nepotism`). The rule stays in the provider because it belongs to the
  shelf's promise, not to whichever provider happens to need it.
- **Quota headers.** `x-ratelimit-limit`, `x-ratelimit-remaining` and
  `x-ratelimit-reset` on every `200`; none on the `401`. **No `429` was
  drawn**, so `min_retry_interval_ms` (60,000 ms) is a floor rather than a
  measurement.
- **The response is not cacheable** (`cache-control: max-age=0, private,
  must-revalidate`), so unlike Unsplash and Openverse every request reaches
  the origin and moves the counter. The 30-day positive cache is ours alone —
  and it is why this is the one of the three search providers whose **URL
  stability could actually be measured**: the same `query=war` 62 minutes
  later moved `x-ratelimit-remaining` 24,971 → 24,959 and returned the same
  twenty photos with byte-identical `src` maps. No signature, no token, no
  expiry; every rung is a pure function of the photo id.

## Conformance

    mix test test/devils_dictionary/discovery/conformance/pexels_conformance_test.exs
    mix test test/devils_dictionary/discovery/providers/pexels_test.exs
