# Spotify

The Music shelf's first provider (#143, from the correction in
[`docs/audits/2026-09-21-api-saturation-audit.md`](../audits/2026-09-21-api-saturation-audit.md)
§5). Keyed and server-side: `POST https://accounts.spotify.com/api/token` with
the app's id and secret mints a bearer token, and `GET
https://api.spotify.com/v1/search?q=<term>&type=track&market=US` answers tracks
with cover art, an artist, an album year, an ISRC and a link back to
`open.spotify.com`.

## Read this first: what the Developer Terms say about caching

The issue asked for the caching clause to be read and quoted, because it
decides retention. Spotify Developer Terms, **Version 10, effective 15 May
2025**, Section IV, *Storing Spotify Content*, read in full on 2026-09-21:

> **Storing and displaying content.** Except as otherwise set out in these
> Developer Terms, you may not store, aggregate or create compilations or
> databases of Spotify Content, other than as strictly necessary to operate
> your SDA. You must use reasonable efforts to ensure that any data you display
> to users is the most up to date data available through the Spotify Platform,
> and to delete older data. Do not store Spotify Content indefinitely.
>
> **Local caching.** Do not locally cache any Spotify Content, except as
> strictly necessary to enhance the performance of your SDA and its
> functionality, and limited to the temporary caching of:
>
> - metadata and cover art; or
> - Conditional Downloads of sound recordings. […]

**There is no number in it.** The clause caps retention with a duty rather than
a duration — *strictly necessary*, *most up to date*, *delete older data*, *not
indefinitely*. The number is therefore this shelf's to choose, and it chooses
seven days through the mechanism #142 added for the Guardian: a
`retention_seconds` in `source_policies`, which `Discovery.cleanup/0` sweeps
**without** the shared sweep's exemption for each word's current run. That
exemption is what would otherwise make the storage indefinite — a word nobody
returned to would keep its last twelve tracks' metadata for good.

What is done, and why it is a fair reading of the duty:

| The clause says | What this shelf does |
|---|---|
| limited to *metadata and cover art* | exactly that, and nothing else: no audio, no bytes. Cover art is hotlinked from `i.scdn.co` at 300 px and 64 px |
| *reasonable efforts … most up to date* | `positive_refresh_seconds: 86_400` — a day, against the shipped thirty |
| *delete older data* | `retention_seconds: 7 * 24 * 60 * 60` in this source's own policy: every Spotify run older than seven days is deleted with its results and attempts, current or not, and the `source_records` nothing references any more go with it |
| *do not store indefinitely* | a result older than the refresh is refetched on the next visit to its word; one older than the retention is deleted whether or not anyone visits. A page opened after the sweep shows nothing on this shelf until its own run comes back, which is the honest state of a cache that has expired |

## Posture

| | |
|---|---|
| Slug | `spotify` |
| Archetype | discovery |
| Shipped state | **Enabled**, by the owner's decision of 2026-09-21 — see *The one decision that is a posture* below. `SPOTIFY_ENABLED=false` (shell or `.env`) turns it off without a deploy, as `BING_NEWS_ENABLED` does |
| Licence | Spotify Developer Terms v10 and the Developer Policy. Metadata and cover art only, displayed with the Spotify mark and a link back |
| Key required | **Yes**, both halves: `SPOTIFY_CLIENT_ID` and `SPOTIFY_CLIENT_SECRET`. Server-only. Without both, `enabled?/0` is false and the provider is registered and never runs |
| Auth | Client Credentials. One token per hour, cached in `Spotify.Token`, minted through the shared transport so it is a ledger row (`stage: "token"`) and a budgeted request |
| User-Agent | The project's own string. Accepted by both hosts with no browser impersonation |
| Published rate limit | A rolling 30-second window whose size Spotify **does not publish**, lower in development mode. A refusal carries `Retry-After` in seconds |
| Measured sustainable rate | 20 distinct words at 1 req/s: **20/20 `200`**, no `429`, no `Retry-After`, latency 477/563/748 ms min/median/max. Ten issued **at once** — 10.8 req/s — also 10/10 `200`. No refusal was drawn at any rate this probe reached |
| Images | references only; bytes are never downloaded. 300 px into `image_url`, 64 px into `thumbnail_url`, both on `i.scdn.co` |
| Previews | **`preview_url` is `null`.** On all 253 tracks captured, across twelve searches. The 2024-11-27 change removed it for an app registered after it, and nothing on the card pretends otherwise |

## Probe

Ceiling: **100 requests** (the issue's number, not the checklist's 200).
Spent: **52**.

| # | requests | what was asked | what came back | running total |
|---|---|---|---|---|
| P1 | 1 | `POST /api/token`, `grant_type=client_credentials`, HTTP Basic | `200` in 302 ms. `access_token` (140 chars), `token_type: Bearer`, `expires_in: 3600`. Exactly the three documented keys | **1 / 100** |
| P2 | 12 | the four query shapes × *war*, *love*, *logomachy*, `type=track&market=US&limit=12` | `200` throughout. The shapes differ, and the two `track:` ones answer **six rows whatever `limit` says** — see the table below | **13 / 100** |
| P2b | 3 | the chosen bare shape at `limit=50`, same three words | `200`. 50 rows each; the gate kept 21 (*war*), 38 (*love*), 6 (*logomachy*) | **16 / 100** |
| P3 | 3 | the bare shape at `limit=12&offset=12`, same three words | `200`. Paging works and `total` does not: *war* reported `total: 18` here against `total: 62` for the same word at `limit=50`, and `next` was `null` for *war* and *love* but a URL for *logomachy* | **19 / 100** |
| P5 | 2 | `q=war` at `market=US` and at `market=GB` | `200` both. US kept **6** of 12, GB kept **2**. Three of the six US tracks are simply not in the GB catalogue | **21 / 100** |
| P5b | 1 | `q=war&type=track` with **no `market` at all** | `200`, twelve tracks. The documented requirement is not enforced — see *What the issue got wrong* | **22 / 100** |
| P4 | 20 | twenty distinct words at 1 req/s, `limit=50` | **20/20 `200`**, no `429`, no `Retry-After`. 477/563/748 ms min/median/max | **42 / 100** |
| P4b | 10 | ten words issued **at once**, unpaced — 10.8 req/s | **10/10 `200`**, no `429`. The throttle was not reachable with one token from one desk | **52 / 100** |
| B1–B3 | 0 | the browser proof | Spent from `discovery_request_attempts` — see *The browser proof* | **52 / 100** |

The counter in the probe script is a read-modify-write on a file and P4b's ten
requests raced it, so the printed numbers jump; **52** is the sum of the
batches, which is the number the rows above are added from.

## The query shape, measured

`q=war`, `q="war"`, `q=track:war` and `q=track:"war"` are four different
searches. Measured 2026-09-21 at `limit=12`, `market=US`, with the whole-word
gate applied to `name`:

| shape | *war* | *love* | *logomachy* | rows offered | rows kept |
|---|---|---|---|---|---|
| **bare** `q=war` | 6 / 12 | 9 / 12 | 4 / 12 | 36 | **19** |
| quoted `q="war"` | 2 / 7 | 10 / 12 | 4 / 12 | 31 | 16 |
| field `q=track:war` | 1 / 6 | 3 / 6 | 6 / 6 | 18 | 10 |
| field+quoted `q=track:"war"` | 1 / 6 | 3 / 6 | 6 / 6 | 18 | 10 |

**Bare wins**, and the reason is in the *rows offered* column rather than the
ratio: the two `track:` shapes have the best hit rate and the worst yield,
because Spotify answered them with **six rows for every request regardless of
`limit`**, so they hand the gate a third of the candidates to choose from. The
gate is what makes a wide candidate set honest; a narrow one just makes the
shelf short.

`limit=50` on the bare shape is what the provider actually ships, for the same
reason: one request, fifty candidates, twelve cards.

## The market

`market=US`. **Not** because it is required — it is not, see below — but
because it chooses the catalogue:

| | kept for *war* | what is there |
|---|---|---|
| `market=US` | 6 | *War* (Chief Keef), *War* (Edwin Starr), *War Pigs*, *War with Us*, *War Pigs / Luke's Wall*, *War Ready* |
| `market=GB` | 2 | *War* (Edwin Starr), *War Pigs - 2009 Remaster* |

Three of the six are not in the GB catalogue at all. `US` is the larger answer
and the one that makes a captured fixture reproducible from another desk.

## The four decisions

| Decision | Value | Why |
|---|---|---|
| **archetype** | `discovery` | live answers to a page; nothing to seed |
| **content type** | **`music`** — a new row in `DevilsDictionary.Discovery.ContentTypes`, placed after `:news` and before `:gif` | a track is neither a *Text* nor an *Image*: square cover art like an image, a two-line title and an artist like neither |
| **transport** | `get`, JSON, bearer token | the search is a GET; the token is a POST through the same transport |
| **pagination** | `offset` | the offset is an offset into the **gated** list, as PoetryDB's and Bing's are. One request per page whichever page it is |

## What identity a result carries

- **Source identifier**: `spotify_track` = the track `id` (Wikidata `P2207`),
  and `isrc` = `external_ids.isrc` (Wikidata `P1243`) — present on **253 of
  253** captured tracks.
- **Encyclopedia identifier**: none yet. A search result proposes no
  encyclopedia identity, so there is no `identity_record/1` and every result
  persists as `:insufficient_evidence`.
- **Crosswalk**: the ISRC is the join MusicBrainz will fold on when it becomes
  the shelf's second source (#116) — a recording carrying the same ISRC becomes
  the same card through `Shelf.dedup/2` without either provider knowing about
  the other. The identity path (`P921` works-about, `P2207` on the song) is the
  audit's Wave A item 1 and lands on this row's `:identity` evidence class.

## Measured facts

Things nobody should have to measure twice.

- **`market` is not required with Client Credentials.** The documentation says
  it is; `q=war&type=track` with no `market` answered `200` with twelve tracks.
  It is pinned anyway, for the catalogue it chooses.
- **`limit` is ignored for a `track:` field filter.** Six rows came back for
  every such request, at `limit=12` and at `limit=50`.
- **`total` is not a count you can page against.** *war* reported `total: 62`
  at `limit=50&offset=0`, `total: 18` at `limit=12&offset=12` and `total: 14`
  at `limit=12&offset=0` — three numbers for one query within four minutes.
  `q=logomachy&type=track:logomachy` reported `total: 0` while returning six
  items. The provider does not read `total` and pages off its own gated list.
- **`preview_url` was `null` on 253 of 253 tracks.** Not a sample: every track
  of every captured response.
- **`external_ids.isrc` and all three cover-art rungs (640/300/64) were present
  on 253 of 253 tracks.** The branches for a track missing either are tested in
  `test/devils_dictionary/discovery/providers/spotify_test.exs`, because the
  capture cannot test them.
- **The gate does about half the work, and its yield varies enormously by
  word.** At `limit=50` over 23 words: median 29 of 50 kept, *pride* 45, *folly*
  **1**, *logomachy* 6, *greed* 8.
- **No `429` was reachable.** Neither at 1 req/s for twenty requests nor at
  10.8 req/s for ten. `request_interval_ms: 250` is therefore the issue's
  courtesy figure rather than a measured floor, and `min_retry_interval_ms:
  30_000` is a posture against a window Spotify does not publish.

## What the issue got wrong

Recorded because the checklist asks for it and because each one changed the
code.

1. **"`market` is *required* with Client Credentials."** It is not. Measured
   P5b. Pinned for a different reason.
2. **"twelve tracks whose name contains the word as a whole word"** on
   `/define/war`. Not from a twelve-row request: the gate keeps 6 of 12 for
   *war*. The provider asks for fifty and shows the twelve that pass, which is
   the only way the issue's own sentence comes true.
3. **"On `/define/logomachy` the run records `no_results` and no shelf
   renders."** Spotify has **six** tracks actually called *Logomachy*. The word
   the issue chose for the negative path is one of this provider's better
   answers. The negative proof is taken on a word that really has nothing —
   see *The browser proof*.
4. **"*Open on Spotify*"** as the link text. The Branding Guidelines permit
   three strings for a platform where the Spotify app exists — *OPEN SPOTIFY*,
   *PLAY ON SPOTIFY*, *LISTEN ON SPOTIFY* — and that is not one of them. The
   card says **Listen on Spotify**.
5. **"`retention_seconds` in `source_policies` … if it caps retention."** The
   clause caps retention with a duty and no number, and `Policy`'s `@keys` does
   not admit `retention_seconds` anyway. See the top of this file.

## The mark, and where its numbers come from

Spotify's Design & Branding Guidelines, read 2026-09-21:

- *In partner integrations, you should always use our full logo (icon +
  wordmark).* → the full logo, not the icon.
- *The Spotify logo should never be smaller than 70px in digital.* → `width:
  70px`.
- *The exclusion zone is equal to half the height of the icon.* → the icon is
  the logo's full height, which at 70 px wide is 19 px, so **10 px** on every
  side.
- *The Spotify green logo should only be used on a black or white background,
  for any other background you should use a monochrome logo.* → the black logo
  in the light theme and the white one in the dark, as two files. Not a CSS
  filter on one file.
- *Artwork corners must be rounded … 4px corner radius* on small and medium
  devices → the card's existing `rounded-sm`, which is 4 px.
- *Don't place your brand or logo on top of album artwork.* → the mark is in
  the card's credit block, never over the cover.

Since the #144 followups the mark is `Spotify.attribution_mark/0` — the same
callback the Guardian's shelf mark uses, with `placement: :card` and the link
wording under `:link_text`. It was `preview_metadata["brand_mark"]` on every
item until then: one obligation, rewritten on every row the provider ever
returned, where the Guardian wrote the same obligation once.

The assets are Spotify's own, from
`https://developer.spotify.com/images/guidelines/design/2024-spotify-full-logo.zip`,
unmodified, checked in as `priv/static/images/spotify-full-logo-black.svg` and
`spotify-full-logo-white.svg`.

**The mark is under the credit rather than literally beside it**, which is a
departure from the issue's wording and is a measurement: 70 px of logo plus its
two 10 px exclusion zones is 90 px of a 144 px column, and *YoungBoy Never
Broke Again* does not fit in the 54 px that would be left. It is the same
credit block either way — the credit names who made the track, the mark names
who supplied it.

## The one decision that is a posture

Spotify describes development mode as for apps *under construction*, and
extended quota mode has been organisations-only since 2025-05-15. Running a
development-mode app behind a public page is a terms question of the same kind
as Bing's `<copyright>` (#141), and it is not one this document can settle.
**The owner's decision, 2026-09-21: proceed.** `SPOTIFY_ENABLED=false` turns it
off without a deploy.

The two readings that said no, and why neither binds, are in #143's own table.
The short version: the five-user cap counts **authenticated** users and a
Client Credentials search has none, and the single-source sentence sits in the
Developer Policy's **streaming** restrictions, between two rules about
playback.

## The browser proof

At 1280 and 375 CSS pixels, 2026-09-21. Screenshots in
[`docs/discovery/`](../discovery/).

See [`issue-143-spotify-2026-09-21.md`](../discovery/issue-143-spotify-2026-09-21.md)
for what each one shows and the ledger rows each page spent.

## Conformance

    MIX_TEST_PARTITION=spotify mix test test/devils_dictionary/discovery/conformance/spotify_conformance_test.exs
    MIX_TEST_PARTITION=spotify mix test test/devils_dictionary/discovery/providers/spotify_test.exs
