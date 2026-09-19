# Photos probe — Unsplash and Pexels slices, 2026-09-19

Phase 0 of #116 asked for six words through every candidate. This is the
**Unsplash and Pexels slices**, run inside Phase 3, and it completes Phase 0:
Openverse is in `photos-probe-2026-09-19.md`, Wikimedia Commons in
`commons.md`, and Pixabay and Freepik are out by M5 — their keys were not
read.

The six words are the project's usual four plus #100's honest-empty pair:
`war`, `love`, `grief`, `soldier`, `allegory`, `nepotism`.

Every request went through `Req` with this project's `:user_agent` and the
key from the environment. No image bytes were fetched. The per-provider
posture, licence obligations and conclusions are in `unsplash.md` and
`pexels.md`; this document is the measurement.

## Ledger

Ceiling for the session: **300**, of which each probe slice was allowed
**60**. Spent here: **18** — 8 Unsplash, 8 Pexels, 2 for the stability
re-read. Running totals, written per batch.

| # | requests | what was asked | what came back | running |
|---|---|---|---|---|
| U1 | 6 | Unsplash, the six words, `per_page=20&page=1` | `200` × 6, 20 results each | **6 / 60 unsplash** |
| P1 | 6 | Pexels, the six words, `per_page=20&page=1` | `200` × 6, 20 photos each | **6 / 60 pexels** |
| U2 | 1 | Unsplash `query=war&page=2` | `200`, 20 results, **0** ids shared with page 1 | **7 / 60 unsplash** |
| U3 | 1 | Unsplash with a deliberately invalid `Client-ID` | `401`, `{"errors":["OAuth error: The access token is invalid"]}`, no quota headers | **8 / 60 unsplash** |
| P2 | 1 | Pexels `query=war&page=2` | `200`, **19** photos for `per_page=20`, 0 ids shared with page 1 | **7 / 60 pexels** |
| P3 | 1 | Pexels with a deliberately invalid key | `401`, `{"code":"Unauthorized","message":"Invalid API key","status":401}`, no quota headers | **8 / 60 pexels** |
| S1 | 2 | `query=war` again, both providers, **62 minutes** after U1/P1, for URL stability | see §5 | **9 / 60 each** |

The site's own requests during the browser proof are on this project's
ledger (`discovery_request_attempts`, sources `unsplash` and `pexels`) and
are counted in the Phase 3 report, not here: **4** each.

## 1. What comes back, and for which words

**Unsplash** — `total` is the whole result set and is not capped.

| word | `total` | `total_pages` | `description` absent | top three, as the card would title them |
|---|---|---|---|---|
| `war` | 6,214 | 311 | 3 / 20 | *Ruined side-street in Shingal (Sinjar) following war with the Islamic State.* · *There is nothing left in this place* · *Massive fire explosion close up in military combat and war…* |
| `love` | 10,000 | 500 | 10 / 20 | *Love under setting sun* · *Single red rose on pages* · *close-up photography of heart shaped fairy lite on brown sand* |
| `grief` | 744 | 38 | 7 / 20 | *Loss - A sculpture by Jane Mortimer* · *brown wooden bench on green grass field during daytime* · *A pebble painted with the words, For all those we have loved and lost.* |
| `soldier` | 3,484 | 175 | 6 / 20 | *"Afghan War Veteran" Alexander Jawfox* · *man in brown and black camouflage uniform holding rifle* · *Soldiers dressed in army camouflage march in formation.* |
| `allegory` | 361 | 19 | 7 / 20 | *There's always a light up there* · *Artist Pompeo Girolamo Batoni Title Time Unveiling Truth…* (Art Institute of Chicago) · *A cartoon tooth being brushed by a blue toothbrush* |
| `nepotism` | **69** | 4 | 8 / 20 | *a purple background with a blue and green object on top of it* · *a close up of the letter n on a sign* · *Notion icon in 3D…* |

**Pexels** — `total_results`, which is not a measure of relevance.

| word | `total_results` | returned | `alt` absent | top three |
|---|---|---|---|---|
| `war` | 7,737 | 20 | 0 / 20 | *Desolate war-damaged building in Homs, Syria…* · *A glimpse into life amid the ruins of war-torn Damascus…* · *View of destroyed buildings on a deserted street in Homs…* |
| `love` | 8,000 | 20 | 0 / 20 | *A couple shares a tender moment surrounded by vibrant red roses…* · *A red envelope with a love letter on pink background…* · *A loving couple shares an intimate moment outdoors at sunset.* |
| `grief` | 5,925 | 20 | 0 / 20 | *A person stands in a peaceful cemetery holding flowers in remembrance.* · *Young alone black female with Afro braids in casual wear crying…* · *A couple embracing in comfort during a moment of grief…* |
| `soldier` | 6,655 | 20 | 0 / 20 | *Soldiers in uniform during a ceremonial march…* · *A soldier in uniform marches in a parade in Guayaquil, Ecuador…* · *Three soldiers in camouflage uniforms discussing with weapons outdoors.* |
| `allegory` | 4,297 | 20 | 0 / 20 | *Intricate Baroque ceiling mural depicting religious themes…* · *Intricate Renaissance mural on a historic ceiling…* · *A classical marble statue depicting figures in a lush garden…* |
| `nepotism` | **4,125** | 20 | 0 / 20 | *Illustration of entrepreneurs wearing formal clothes shaking hands…* · *Cutout paper composition representing male showing rejection…* · *A man in a suit holding a red notebook with hands pointing at him…* |

**The two providers fail differently, and only one of them fails visibly.**
Unsplash's count collapses on a word it does not have — 69 for `nepotism`
against 6,214 for `war` — even though the 69 are a purple gradient and a
Notion icon. Pexels answers **4,125** for the same word with generic
handshake stock, and 4,297 for `allegory`: its floor is not zero and its
count says nothing. Neither provider has an empty at all (M6 is what admits
them), so on both the honesty is entirely in the labelled reason. Openverse,
for comparison, does have real zeroes once the query is quoted
(`logomachy`: 0) — and so does Unsplash, measured on the live site the same
day: `/define/logomachy` recorded `no_results` for Openverse **and** for
Unsplash in one request each, and **11 results for Pexels**. There is no word
left in this dictionary without an Images shelf.

## 2. Fields present on one raw item

**Unsplash**, trimmed to what the provider reads (`?query=war`, first result):

```json
{
  "id": "LheHIV3XpGM",
  "slug": "ruined-street-in-sinjar-LheHIV3XpGM",
  "created_at": "2020-02-05T17:15:19Z",
  "width": 6240, "height": 4160,
  "description": "Ruined side-street in Shingal (Sinjar) following war with the Islamic State.",
  "alt_description": "A narrow street in Sinjar lined with ruined stone buildings and piles of rubble",
  "asset_type": "photo",
  "sponsorship": null,
  "urls": {
    "thumb":   "https://images.unsplash.com/photo-1580922110301-…&q=80&w=200",
    "small":   "https://images.unsplash.com/photo-1580922110301-…&q=80&w=400",
    "regular": "https://images.unsplash.com/photo-1580922110301-…&q=80&w=1080",
    "full":    "https://images.unsplash.com/photo-1580922110301-…&q=85",
    "raw":     "https://images.unsplash.com/photo-1580922110301-…",
    "small_s3":"https://s3.us-west-2.amazonaws.com/images.unsplash.com/small/photo-1580922110301-…"
  },
  "links": {
    "html": "https://unsplash.com/photos/ruined-street-in-sinjar-LheHIV3XpGM",
    "download_location": "https://api.unsplash.com/photos/LheHIV3XpGM/download?ixid=…"
  },
  "user": {
    "name": "Levi Meir Clancy", "username": "levimeirclancy",
    "links": {"html": "https://unsplash.com/@levimeirclancy"},
    "portfolio_url": "http://levi.pictures"
  }
}
```

The full item also carries `blur_hash`, `color`, `likes`, `promoted_at`,
`topic_submissions`, `breadcrumbs`, `alternative_slugs`,
`current_user_collections`, `liked_by_user` and `bookmarked`. **There is no
`title` and no licence field**: the Unsplash License is the same for every
photo, so there is nothing per item to gate on — unlike Commons and
Openverse, where the gate is the whole point.

**Pexels**, the whole item (`?query=war`, first photo) — there is no more
than this:

```json
{
  "id": 32230027,
  "width": 2268, "height": 4032,
  "alt": "Desolate war-damaged building in Homs, Syria, with a truck in foreground.",
  "avg_color": "#68757B",
  "liked": false,
  "photographer": "Waseem Istanbuli",
  "photographer_id": 2149205866,
  "photographer_url": "https://www.pexels.com/@waseem-istanbuli-2149205866",
  "url": "https://www.pexels.com/photo/war-torn-building-in-homs-syria-32230027/",
  "src": {
    "tiny":      "…/pexels-photo-32230027.jpeg?…&dpr=1&fit=crop&h=200&w=280",
    "small":     "…/pexels-photo-32230027.jpeg?…&h=130",
    "medium":    "…/pexels-photo-32230027.jpeg?…&h=350",
    "large":     "…/pexels-photo-32230027.jpeg?…&h=650&w=940",
    "large2x":   "…/pexels-photo-32230027.jpeg?…&dpr=2&h=650&w=940",
    "portrait":  "…/pexels-photo-32230027.jpeg?…&fit=crop&h=1200&w=800",
    "landscape": "…/pexels-photo-32230027.jpeg?…&fit=crop&h=627&w=1200",
    "original":  "https://images.pexels.com/photos/32230027/pexels-photo-32230027.jpeg"
  }
}
```

**No title, no description, no date, no licence field.** `alt` is one
generated sentence and it is every word Pexels publishes about a photo.

## 3. Licence, attribution and creator

| | Unsplash | Pexels |
|---|---|---|
| Licence, per item | none — one Unsplash License for everything | none — one Pexels License for everything |
| Short form written into `license` | `Unsplash` | `Pexels` |
| `license_url` | `https://unsplash.com/license` **plus UTM** | `https://www.pexels.com/license/` |
| `creator` | `user.name`, falling back to `user.username` | `photographer` |
| `creator_url` | `user.links.html` **plus UTM** | `photographer_url` |
| Ready-made attribution line | none published; composed as *Photo by {name} on Unsplash*, which is the wording the API Guidelines give | none published; composed as *Photo by {name} on Pexels* |
| `source_url` | `links.html` **plus UTM** | `url` |
| Must the credit be a link? | **yes** — the photographer's name and the word *Unsplash*, both with `utm_source` and `utm_medium` | not required; done anyway, because D3 made the linked credit the rule for the row |
| A download trigger? | **yes**, `links.download_location`, when the photo is *carried* somewhere and never on display | no |

Neither provider hands back a composed attribution string the way Openverse
does, so both lines are this project's, and both are the wording the provider
itself documents.

## 4. The thumbnail ladder — and why the row does not change

This was the phase's open question: Openverse publishes no ladder at all
(two URLs), and Unsplash and Pexels are the first sources on the row with a
real one. The answer is still **no change to `thumbnail_keys`**.

| | rungs | hosts | what the provider maps |
|---|---|---|---|
| Unsplash | `thumb` 200w · `small` 400w · `regular` 1080w · `full` · `raw` (+ `small_s3` on a different host) | `images.unsplash.com` | `small` → `thumbnail_url`, `full` → `image_url` |
| Pexels | `tiny` · `small` 130h · `medium` 350h · `large` 940w · `large2x` · `portrait` · `landscape` · `original` | `images.pexels.com` | `medium` → `thumbnail_url`, `original` → `image_url` |

`thumbnail_keys: ~w(thumbnail_url image_url)` is a list of **names**, not of
sizes: it says which metadata key the card reads first, and the choice of
rung belongs to the provider that knows its own CDN. A third or fourth key
would only earn its place if the card emitted a `srcset` and let the browser
choose — and the card emits one `<img src>`. **That is a card question for
whoever wants responsive images, not a row question, and the probe does not
earn the change.**

Aspect, for the record: `soldier` was **16 portrait / 4 landscape** on
Unsplash and **18 portrait / 2 landscape** on Pexels — the opposite bias to
Openverse's 15 landscape / 5 portrait for the same word. Four sources with
two opposite biases is the argument for a square frame rather than against
it, which is where Phase 1 left it.

## 5. URL stability across an hour

`query=war` again at 09:44:43Z, **62 minutes** after the first capture, both
providers, same parameters.

| | first 20 ids returned again | URLs byte-identical for those ids | did the request reach the origin? |
|---|---|---|---|
| Unsplash | **20 / 20** | **20 / 20** | **no** |
| Pexels | **20 / 20** | **20 / 20** | **yes** |

**Pexels's row is a measurement. Unsplash's is not, and saying so is the
point of the column on the right.**

Unsplash's re-read came back with `x-cache: Miss from cloudfront, HIT`,
`age: 3733` (exactly the 62 minutes), `x-ratelimit-remaining` **unmoved at
4998**, and the *same* `x-request-id` as the first capture —
`096d84a9-c7b0-…`. It is byte-for-byte the response from an hour earlier,
served out of Fastly, and it says nothing about whether Unsplash's URLs hold.
This is the same trap the Openverse slice recorded at its P9 (`cf-cache-status:
HIT`, "the edge answered, so this measured nothing"), and it is worth a rule:
**on any provider behind a CDN, read `x-ratelimit-remaining` or the request
id before believing a stability result.** Unsplash's `cache-control` is
`public, max-age=86400`, so a repeated identical query is cached for a day and
an honest re-read needs either a different query or a day's wait; neither is
worth 5,000-per-hour quota to learn.

Pexels's re-read moved `x-ratelimit-remaining` from 24,971 to 24,959 and
carries no cache header (`cache-control: max-age=0, private,
must-revalidate`), so it genuinely reached the origin. The same twenty photos
came back in the same order with byte-identical `src` maps, and none of the
eight rungs carries a signature, token or expiry — they are
`images.pexels.com/photos/<id>/pexels-photo-<id>.jpeg` plus sizing query
parameters, a pure function of the id.

**What the shelf actually depends on is weaker than either measurement, and
it holds by construction.** `Shelf.canonical_media_url/1` compares host and
path only, and both providers' paths are a pure function of the photo id
(`photo-1580922110301-a666f6745565`,
`photos/32230027/pexels-photo-32230027.jpeg`). Unsplash's query string
carries an `ixid` token minted per search, so two genuinely separate searches
would very likely hand back the *same file* under a *different* query — which
is exactly the difference the canonical form is there to ignore. A signed or
expiring URL would be the thing that broke D14's hotlinking, and neither
provider uses one.

## 6. Rate limits and refusals

| | Unsplash | Pexels |
|---|---|---|
| Published | 50/hour demo, 5,000/hour production | 200/hour, 20,000/month |
| `x-ratelimit-limit` on this key | **5000** | **25000** |
| `x-ratelimit-remaining` | present, and it moves one per origin-reaching request | present, and it moves one per request |
| `x-ratelimit-reset` | **absent** — the window's end is not published | `1791405831` = **2026-10-07T20:43:51Z**, about a month out, so the window is the month |
| `Retry-After` | not observed | not observed |
| The refusal shape | **unmeasured.** No `403 Rate Limit Exceeded` was drawn in 8 requests, and spending 5,000 to draw one is not a probe | **unmeasured.** No `429` in 8 requests |
| An *auth* refusal, which is cheap to measure | `401` `{"errors":["OAuth error: The access token is invalid"]}`, **no quota headers** | `401` `{"code":"Unauthorized","message":"Invalid API key","status":401}`, **no quota headers** |
| Edge caching | CloudFront, `cache-control: public, max-age=86400` — a repeated identical query may never reach the origin or move the counter | `cache-control: max-age=0, private, must-revalidate` — every request reaches the origin |

Both providers' `min_retry_interval_ms` is therefore a **floor** (60,000 ms)
and not a measurement, and `retryable_status?/1` is the shared default. The
first real refusal should replace both — the same residual Openverse's slice
left.

**Neither key is the key the issue assumed.** M7's table sizes Unsplash to
"demo 50/h" and Pexels to "200/h"; the headers say 5,000/hour and
25,000/month. The pacing is unchanged (3,000 ms each) because the pace is a
courtesy to a free service rather than a budget, and behind a 30-day positive
cache a reader-driven site does not approach either number.

## 7. Overlap across the four sources — the M3 question

Zero, and by construction.

| source | media host |
|---|---|
| Wikimedia Commons | `upload.wikimedia.org` |
| Openverse | the *upstream's* host — `live.staticflickr.com`, `upload.wikimedia.org`, `iiif.wellcomecollection.org` |
| Unsplash | `images.unsplash.com` |
| Pexels | `images.pexels.com` |

Measured over every `:image` result in the development database on
2026-09-19 — five word pages, 46 + 42 + 36 + 24 + 24 items — **no canonical
media URL is shared by two sources**, and every page's item count equals its
distinct-URL count. The only pair that can ever collide is Commons and
Openverse, because Openverse republishes Commons's own `upload.wikimedia.org`
URL; D4 of this phase is what makes that collision visible at all, by putting
the file rather than the 640 px thumbnail in Commons's `image_url`. It is
asserted on the fixture (`openverse_commons_fold_test.exs`) and it has not
fired on a real page yet, for the reason Phase 2 measured: *depicts a QID*
and *has the word in its title* select disjoint subsets of one archive.

A stock-photo library cannot collide with anything here: the same photograph
uploaded to both Unsplash and Pexels is two files on two CDNs under two ids,
and folding those would need perceptual hashing, which M3 rules out until a
ledger shows it is needed.

## Verdict

**Unsplash: in.** A production-rate key, a licence whose conditions are all
data this project already carries, hotlinking required rather than forbidden
(the mirror image of the Pixabay problem), and a clean walk. Its weaknesses
are that it has no title and no honest empty, and both are handled: the card
prints `description` or the generated `alt_description`, and the reason says
*search result*.

**Pexels: in, and it is the weakest of the four.** It publishes less about a
photo than any other source here — one generated sentence, no date, no
per-item licence — and it never says *nothing*, so every word page it touches
gets twelve stock photographs whether or not the word has any. It earns its
place as a fourth voice on a shelf where three others can be empty, not as a
source anyone should rank. If the owner later wants fewer search results on
the row, this is the one to drop, and D2's one-clause rule (*hide a shelf
whose every state is `:query`-only*) is the other lever.

**Pixabay and Freepik: out, unchanged.** Pixabay forbids permanent
hotlinking, which is the mirror image of D14; Freepik is freemium and
commercial. `PIXABAY_API_KEY` and `FREEPIK_API_KEY` were not read.

**Phase 0 is now complete**: Openverse, Wikimedia Commons, Unsplash and
Pexels all probed against the same six words, all four in, and the two that
were out are out on their terms rather than on their data.
