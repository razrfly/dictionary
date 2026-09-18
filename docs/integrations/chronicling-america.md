# Chronicling America (Library of Congress)

**Status: blocked, not implemented.** #109 Phase 3b, 2026-09-18. No provider was
written, nothing was registered, and no fixture was invented. This page is the
probe's ledger and the reason the phase stopped.

The two shared changes Phase 3b also owns — the `WordPage` ranking fix and the
`:text` card at 375 px — landed and are unrelated to this blocker.

---

## What 3b asked for

| Decision | Value |
|---|---|
| archetype | discovery only |
| content type | `:text` |
| transport | GET |
| pagination | offset (`page=`) |
| identity | `loc_page` = `lccn/date/edition/sequence` |
| match | attestation (K11): `search/pages/results?andtext=<word>` proposes, the hydrated page's OCR disposes at a word boundary |
| reason | *uses “war” — \<paper\>, \<date\>, page N*, with the OCR line as the note |
| pacing | measure the real rate; start at 1 s |
| ceiling | 300 requests |

---

## The ledger

Running totals, as the guide's §1 requires. Every request used `Req`, a
contact `User-Agent`, and a 2 s gap.

| # | Request | Result |
|---|---|---|
| 1 | `chroniclingamerica.loc.gov/search/pages/results/?andtext=war&format=json` | **308** → `www.loc.gov/chroniclingamerica/...` |
| 2 | `www.loc.gov/chroniclingamerica/search/pages/results/` (the redirect target) | **403**, Cloudflare interstitial |
| 3 | `www.loc.gov/collections/chronicling-america/?q=war&fo=json` | **403**, Cloudflare interstitial |
| 4 | `www.loc.gov/search/?q=war&fo=json` | **403**, Cloudflare interstitial |
| 5 | legacy search again, following redirects | **403** at the target |
| 6 | `chroniclingamerica.loc.gov/lccn/sn83045462/1918-11-11/ed-1/seq-1/ocr.txt` | **403** after redirect — *this is the hydration path attestation needs* |
| 7 | `chroniclingamerica.loc.gov/lccn/.../seq-1.json` | **403** after redirect |
| 8 | `www.loc.gov/item/sn83045462/?fo=json` | **403** |
| 9 | `www.loc.gov/apis/` — the LoC's own API documentation | **403** |
| 10 | `chroniclingamerica.loc.gov/data/ocr/` | **200**, a 418 KB directory index of bulk OCR tarballs |
| 11 | `chroniclingamerica.loc.gov/newspapers.json` | **403** after redirect |
| 12 | `tile.loc.gov/storage-services/...` | **403** |
| 13 | search endpoint, retested to rule out a transient incident | **403** |
| 14 | `www.loc.gov/` — the site root | **403** |

**Total: 14 of 300.** No page images were fetched; nothing was stored.

---

## What blocks it

`www.loc.gov` — which every Chronicling America path now redirects to — answers
a scripted client with a **Cloudflare “Just a moment…” bot-verification
interstitial** carrying HTTP 403. This is not a rate limit: it was the *first*
request on a cold connection, it applies to the LoC's own `/apis/`
documentation page, and it did not clear on retest.

It is also not specific to `Req`. The same URL loaded in a real browser (the
Claude desktop browser pane, a genuine Chromium with a normal user agent) sat on
*“Performing security verification”* and had still not cleared after ten
seconds.

The only endpoint that answered was `chroniclingamerica.loc.gov/data/ocr/`, a
static directory index of multi-gigabyte bulk OCR tarballs. That is not an API:
it cannot answer `andtext=<word>` for a page, and a live discovery provider
cannot be built on it.

**Getting past the interstitial would mean defeating bot detection** — spoofing a
browser fingerprint, solving the JS challenge, or driving a real browser to
harvest a clearance cookie for a scripted client. That was not done and should
not be.

## Why that ends the phase rather than delays it

Attestation is the whole of 3b's match rule: the search only *proposes*, and the
hydrated page's OCR *disposes* at a word boundary. Requests 2 and 6 are exactly
the two halves of that, and both are gated. Without them there is no way to:

- measure the real rate the brief asked for before assuming the published one;
- capture a real response for the fixture's `respond/1`, which §4 of the guide
  requires to be "from a real captured response";
- produce a single honest reason naming a paper, a date and a page.

A scaffolded provider *would* have passed conformance — §4 says so plainly: it
"passes conformance as generated, which proves the wiring and nothing about the
source." Registering one here would have put a green suite and a provider row
behind a source this session never once reached. That is the failure mode the
guide's §8 names: a skipped step described as done.

## What to do when it is reachable again

Nothing here is wasted. The four decisions above stand, the identity scheme
stands, and the shared changes 3b owed are already in. A later session should
re-run requests 2 and 6 first: if they answer JSON and OCR text, the phase
resumes at the guide's §2 with roughly 286 requests of its ceiling unspent.

If the gate is permanent, the alternatives are a registered LoC API key if one
is ever offered, or the bulk OCR tarballs as a **corpus** — a different
archetype, a different brief, and a decision for #109 rather than for this
session.
