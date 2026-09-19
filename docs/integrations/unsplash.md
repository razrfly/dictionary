# Unsplash

Scaffolded by `mix dd.provider.new unsplash` for #116 Phase 3, and filled from
the probe of 2026-09-19 (`photos-probe-unsplash-pexels-2026-09-19.md`, which
has the per-word tables and the raw fields).

## Posture

| | |
|---|---|
| Slug | `unsplash` |
| Archetype | discovery |
| Content type | `:image` — the third source on the Images shelf, after Wikimedia Commons and Openverse |
| Tier | `:plebs` (D1) — a text search does not lead a rail an identity source is on |
| Licence | **Unsplash License**: free to use, commercially, without permission; a credit is required, and the API Guidelines make it a *linked* credit. We store URLs and metadata only, never bytes (D14), and Unsplash **requires** hotlinking, so the posture fits. |
| Key required | **yes** — `UNSPLASH_ACCESS_KEY`, read in `config/runtime.exs` from the environment. Without it `enabled?/0` is false and the provider never runs. |
| Published rate limit | 50/hour for a demo application, 5,000/hour once production access is approved |
| Measured sustainable rate | **`x-ratelimit-limit: 5000`** on this project's key, on every one of 7 responses — this is a production key, not a demo one. `request_interval_ms` is 3,000 ms anyway; the pace is a courtesy, and behind the 30-day positive cache a reader-driven site never approaches 5,000/hour. |
| Images | references only; bytes are never downloaded, by this provider or by the probe |

## Probe

Ceiling for the session: **300**, of which this slice was allowed **60**.
Spent here: **8**.

| # | requests | what was asked | what came back | running total |
|---|---|---|---|---|
| U1 | 6 | `GET /search/photos?query=<word>&per_page=20&page=1` for `war`, `love`, `grief`, `soldier`, `allegory`, `nepotism` | `200` × 6, 20 results each; `total` 6,214 / 10,000 / 744 / 3,484 / 361 / **69** | **6 / 60** |
| U2 | 1 | `query=war&page=2` | `200`, 20 results, **0** ids shared with page 1 | **7 / 60** |
| U3 | 1 | the same query with a deliberately invalid `Client-ID` | `401` with `{"errors":["OAuth error: The access token is invalid"]}` and **no** `x-ratelimit-*` headers | **8 / 60** |

The site's own requests are in `discovery_request_attempts` under source
`unsplash` and are counted in the Phase 3 report, not here: **4** (one each for
`/define/war`, `/define/soldier`, `/define/nepotism` and `/define/logomachy`;
every reload was served from the cache, positive or negative).

## What identity a result carries

**None, and that is the point.** Association is identity, not text — and this
source has no identity path at all, so M6 of #116 is what lets it onto a
shelf:

- Source identifier: the photo id (`LheHIV3XpGM`), registered in the
  `unsplash_photo` namespace so two copies of one photo fold.
- Encyclopedia identifier: **none.** There is no `identity_record/1`; every
  result persists as `:insufficient_evidence`.
- Crosswalk: none. The reason is `%{"kind" => "query"}`, the `:image` row is
  the only one whose `evidence` admits that class, and the renderer describes
  it as *Search result for “war”, ranked by the provider and not matched on
  an identifier.*

## What the licence asks for, and where each part of it is

| Requirement | Where it is |
|---|---|
| Credit the photographer and name Unsplash | `preview_metadata["attribution"]` — *Photo by {name} on Unsplash* — shown beneath the thumbnail, always visible, never on hover (M4) |
| Both names are links | `creator_url` (the photographer's profile) and `license_url` (Unsplash's licence page); the renderer turns those two runs of the line into links (D3) |
| `?utm_source=<app>&utm_medium=referral` on every link back | `utm/1` puts them on `creator_url`, `license_url` and `source_url`; `utm_source` is `devils_dictionary` |
| Trigger the download endpoint when the photo is *carried* somewhere, and not when it is displayed | `download_location` is persisted on the item; `track_download/2` is the only caller, guarded to `https://api.unsplash.com/photos/`. **Nothing fires it**, which is correct: showing a search result is not a download, and no reader path carries an Unsplash photo yet (see below) |
| Do not re-host | D14: `<img>` against `images.unsplash.com` with `referrerpolicy="no-referrer"`; no proxy, no bytes |

**The download trigger has no caller, and that is a gap in the reader and not
in this module.** `DevilsDictionaryWeb.Culture.connect_path/1` — the one place
a reader carries a discovery item anywhere — requires a resolved `object_id`
*and* a `sense_id`, which a search-only provider never has. The mechanism is
built, guarded and tested (`unsplash_test.exs`); the phase that gives a
search result a way of being carried has to call it.

## Measured facts

Things nobody should have to measure twice.

- **There is no title.** `description` is the photographer's own and is
  absent on 3 to 10 of every 20 results (`love`: 10 of 20, `nepotism`: 8 of
  20). `alt_description` is generated for accessibility and reads like it
  (*man in brown and black camouflage uniform holding rifle*), but it is
  always there: over **120 results across six words, no item had neither**.
  `title/1` prefers the human one.
- **The thumbnail ladder is five rungs and it does not change the row.**
  `urls` carries `thumb` (w=200), `small` (w=400), `regular` (w=1080), `full`
  and `raw`, all on `images.unsplash.com` except `small_s3`, which is a
  different host. The provider maps `small` → `thumbnail_url` and `full` →
  `image_url`, which is exactly the two-rung `thumbnail_keys: ~w(thumbnail_url
  image_url)` the `:image` row already reads. A row key per rung would only
  earn its place if the card emitted a `srcset`, and it does not.
- **A photographer's set arrives as several items.** `soldier` returned
  `ExxuYNsViC4` and `0q90Mumo-xE`, both by HIZIR KAYA, under one identical
  `description` (trailing tab included). `Shelf.dedup/2` cannot fold them —
  different files — so the provider keeps one card per `{creator, title}`.
  Same-photographer repeats appeared on 4 of the 6 words.
- **The search degrades; it does not empty.** `nepotism` answers **69**
  results whose top three are a purple gradient, a close-up of the letter *n*
  and a Notion icon. There is no query for which this provider says nothing,
  so a low `total` is the only signal there is. It does reach zero on a rare
  enough word: `/define/logomachy`, served live the same day, recorded
  `no_results` in **one** request, and reloading the page spent none.
- **`total_pages` is honest and the walk is clean.** `war` reports 311 pages;
  page 2 shared **zero** ids with page 1.
- **Quota headers.** `x-ratelimit-limit` and `x-ratelimit-remaining` on every
  `200`; **no** `x-ratelimit-reset`, so the window's end is not published. The
  `401` carries neither header. **No `403 Rate Limit Exceeded` was drawn**, so
  `min_retry_interval_ms` (60,000 ms) is a floor rather than a measurement;
  the first real refusal should replace it.
- **CloudFront fronts the API** with `cache-control: public, max-age=86400`,
  so a repeated identical query may be answered at the edge and never move
  the counter. Measure quota against `x-ratelimit-remaining`, not against the
  number of requests sent.
- **`asset_type` was `"photo"` on all 120 results** and `sponsorship` was
  `null` on all 120. Neither is gated on, and the first sponsored photo is
  worth a second look: a sponsor's credit is an additional requirement.

## Conformance

    mix test test/devils_dictionary/discovery/conformance/unsplash_conformance_test.exs
    mix test test/devils_dictionary/discovery/providers/unsplash_test.exs
