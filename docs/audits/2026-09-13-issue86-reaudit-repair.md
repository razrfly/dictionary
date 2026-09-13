# Issue #86 second independent re-audit repair

Repairs every unchecked item in the independent re-audit at
<https://github.com/razrfly/dictionary/issues/86#issuecomment-5648331311>, which
graded the integration **B — not ready to close** and held PR #98.

This document records what changed, how each item was verified, and what remains
unproven. It is not an independent re-audit. Nothing here was merged, deployed,
or closed.

## Provider request accounting

**This round spent zero Artsy HTTP attempts.** Every repair and every proof below
used retained provider data, local fixtures, the shared Wikidata adapter, or the
browser. The cumulative feasibility campaign therefore remains bounded at **no
more than 194 attempts** (189 documented in the 2026-09-12 repair, plus at most 5
in the interrupted image-fallback pilot that produced *Rebus* and *Canyon*),
below the issue's 200-request ceiling. No image bytes were downloaded. No
credential or token was printed, logged, or committed; `.env` stays git-ignored.

## Audit item disposition

| Audit item | Fix | Verification |
| --- | --- | --- |
| Discovery silently dropping artworks as the catalog grows | `Artworks.suggestions/1` now queries the *relevant* Artsy gene assignments first, paginated by `output_object_id` in 500-row pages with no global cutoff, then loads exactly those identities. The unrelated 100-title catalog clamp is gone. | Deterministic fixture regression with 501 artworks and 501 assignments where only the last matches; it is found. |
| Interactive request allowance never renewing | `RequestCoordinator` tracks a per-scope window start and resets a scope's usage once `window_ms` elapses. `ArtworkLive` reads `interactive_request_limit` / `interactive_request_window_ms` from config (30 per 60s). Per-import finite ceilings are unchanged and separate. | Shared-accounting, exhaustion and recovery test driven by an injected clock. |
| Queued HTTP requests sent after provider disable/withdrawal | After the paced sleep the client revalidates the reservation through `RequestCoordinator.revalidate/2` and rechecks availability and generation immediately before transmission. Provider-wide `Retry-After` deferrals are re-waited by already-queued callers. The existing in-flight response invalidation is preserved. | Mocked regression disabling the provider while a request is queued observes zero transmissions; a second test asserts a queued caller respects a later `Retry-After`. |
| Duplicate visible creator/work relationships | Encyclopedia sections group identical semantic relationships (subject, predicate, object, context, jurisdiction, language, validity) and count the grouped rows, keeping one representative per group. The seeder attaches Artsy evidence to an existing `authored_by` claim instead of creating a parallel one. No assertion or evidence row is deleted. | Browser: Ranuccio shows **1** creator link (was 3); Titian lists **3** works, each once, with a matching count of 3 (was the same two paintings listed six times). Database: 14 active `authored_by` assertions over 9 distinct work/creator pairs, displayed as exactly 9 visible links. |
| Backfill existing sparse records safely | `mix dd.artworks.seed --wikidata-only --refresh-wikidata` hydrates only artwork identities that already exist locally, plus their linked creator QIDs, through the existing bounded Wikidata adapter. It never creates catalog entries and spends no Artsy requests. | Ran twice over the 43-candidate manifest; see the bounded-pilot table below. |
| Verify imagery end to end | An `ArtworkImage` hook marks each card `loading` / `loaded` / `error` / `empty` from the real `load` and `error` events and swaps in the placeholder when decoding fails. Image URL and credit are now resolved **as a pair**, so a retained Artsy thumbnail can never be displayed under an independent Wikimedia credit. | Browser measurements of decoded pixels, below. |
| Prove larger, repeatable seeding | The seed task reports candidates, local identities, images, Commons images, Artsy-thumbnail fallbacks, visible creator links and unavailable records separately. | Bounded pilot and rerun, below; scale proven by fixtures rather than live quota. |
| Prove the word-page flow | A definition page's artwork candidate now carries an internal contributor into the review composer with the exact sense, `illustrates`, the immutable Artsy source-record revision, the opaque gene locator and the rationale preselected. `WordLive` mounts the current scope read-only; `/connect` remains gated server-side. | Full browser walkthrough ending in a submitted claim held at `needs_review`. |

## Two defects found and fixed during this round's browser verification

Both were found only because the audit insisted on looking at real rendered
pages rather than at populated fields, and both now carry regression tests that
fail without the fix.

1. **Misattributed image credit.** `image_url` and `image_attribution` each fell
   back to Artsy independently. An entity whose independent image was withheld
   but whose credit string survived displayed the **Artsy** thumbnail under a
   **Wikimedia Commons** credit. They are now resolved together.
2. **The preselected composer was unreachable.** The rich composer path existed
   and was unit-tested, but no page ever rendered a candidate card with the
   contributor flag, so the reviewed connection flow could not be entered from a
   definition page at all. `WordLive` now passes it.

## Meaning mappings

Three mappings were added, raising the enabled set from four to seven. Their
opaque Artsy gene IDs were **verified by direct observation on retained Artsy
artwork records in this repository**, not by new provider probes, so they cost
zero requests:

| Gene | Gene ID | Exact sense | Relation |
| --- | --- | --- | --- |
| Allegory | `528646d2139b214bd9000687` | `oewn-06893714-n#allegory` — "a visible symbol representing an abstract idea" | related |
| Classical Mythology | `507479c1cd92460002001828` | `oewn-07994846-n#mythology` | related |
| Portrait | `4d90d193dcdd5f44a500007e` | `oewn-03993437-n#portrait` — "any likeness of a person, in any medium" | related |

Each remains `approved_for_candidate_generation_only` and carries a note saying
what the gene does *not* establish. The six unresolved gene slugs stay disabled.
Before this change no retained artwork carried any enabled gene, so the catalog
produced zero candidates and the word-page flow could not be demonstrated at all.

## Bounded pilot and duplicate-free rerun

`mix dd.artworks.seed --manifest priv/artworks/manifests/pilot-v1.json
--wikidata-only --refresh-wikidata --wikidata-request-limit 2`, run twice.

| Count | Pass 1 | Pass 2 |
| --- | ---: | ---: |
| Manifest candidates | 43 | 43 |
| Candidates with an existing local identity (selected) | 9 | 9 |
| Wikidata HTTP requests | 1 | 1 |
| **Artsy HTTP attempts** | **0** | **0** |
| Wikidata entity records hydrated | 15 | 15 |
| New local identities created | 0 | 0 |
| Unavailable records | 0 | 0 |
| Images | 6 | 6 |
| Commons images | 6 | 6 |
| Artsy-thumbnail fallbacks | 0 | 0 |
| Records with no image | 3 | 3 |
| Visible creator links | 9 | 9 |
| Active `authored_by` assertions | 14 | 14 |
| Distinct work/creator pairs | 9 | 9 |

Catalog identities, assertion totals and creator links were byte-identical
before, between and after the two passes: the rerun created no duplicate
identity, claim or visible link.

## Browser acceptance

Development Chrome against the real development catalog. Decoded pixel
dimensions are reported because a populated URL is not evidence that anything
rendered. Catalog cards are `loading="lazy"`; automated scrolling does not
reliably trigger intersection, so each card's image was forced to fetch and then
measured.

| Page | Result |
| --- | --- |
| `/artworks` | 9 cards. **6 decode real Commons images** (500×452, 500×604, 500×639, 500×679, 500×607, 500×651); 3 render honest placeholders and are the 3 records with no image. 0 errors. |
| `/define/allegory` | Artwork candidate *Cupid with the Wheel of Time* by Titian, image decoded 500×604, labelled `Related Artsy gene "Allegory" · not yet reviewed` with its caution note, plus links to the work and to Titian. |
| `/entities/.../cupid-with-the-wheel-of-time` | Image decoded 500×604 from Commons, exactly **1** creator link, date, medium, collection, credit and source links. |
| `/entities/.../portrait-of-ranuccio-farnese` | Image decoded 500×607, exactly **1** creator link. |
| `/entities/.../titian` | 3 works, each listed once, count 3. |
| Artsy-thumbnail fallback | Image served from `d32dm0rphc51dk.cloudfront.net`, **decoded 215×260**, credit `Courtesy National Gallery of Art, Washington`, with no Wikimedia credit anywhere on the page. |
| Broken image | State goes `loaded` → `error`, the `<img>` is hidden and the placeholder icon is shown. No broken-image glyph. |
| Provider withdrawal | Commons image still decodes 500×604 and the creator link survives; Artsy-only medium and collection disappear; the definition page drops to **0** artwork candidates. |
| Review composer | Preselected with subject *Cupid with the Wheel of Time*, `illustrates`, sense #308977 `allegory`, source-record revision 6984046 and the gene locator. Submitting produced claim #3856927 at revision 1, review state **`needs_review`**, evidence attached, attributed to the submitting account. |

### How the two non-default browser states were produced

Both are reversible development-database demonstrations of real code paths using
real retained provider data. Neither invents provider data.

- **Artsy-thumbnail fallback**: the independent image projection was removed from
  one entity's metadata so the retained Artsy thumbnail became the displayed
  image, then restored byte-for-byte from a backup. No live record has an Artsy
  thumbnail as its displayed image today, because every Artsy-enriched record in
  the catalog also has a Wikidata P18 image, which correctly wins.
- **Provider withdrawal**: `display_allowed` was set to `false` on the three
  Artsy source records — the same flag `Artworks.withdraw_artsy/1` sets — then
  restored. A destructive withdrawal was deliberately **not** run, because it
  permanently deletes retained payloads that cannot be rebuilt without spending
  provider requests this campaign no longer has. The destructive path stays
  covered by the existing automated withdrawal test.

## Honest remaining limitations

- **No live Artsy-thumbnail-only record exists in the catalog.** The fallback is
  proven to render and decode a real Artsy CDN image with the correct credit, but
  the record used had its independent image temporarily withheld. Two genuine
  exact-linked paintings without Wikidata P18 (*Rebus*, *Canyon*) were attempted
  in the previous session and both returned unavailable from Artsy. Finding a
  retrievable one needs provider requests the 200-request ceiling no longer
  comfortably allows.
- **Scale beyond 100 artworks and 500 assignments is proven by fixtures**, not by
  a live bulk import. This is deliberate: the audit asked for exactly that, to
  avoid spending live quota to prove scale.
- **Reviewed and featured examples remain editorial.** One demonstration claim was
  submitted in the development database and left at `needs_review`. Nothing was
  approved, and no interpretation was invented.
- **Permanent Artsy retention rights are still not established.** Artsy remains
  optional, removable enrichment; independent sources are the durable catalog.
- **The three added mappings are candidate generators, not accepted meanings.**
  They widen what a reviewer may consider; they assert nothing.

## Verification commands

```sh
mix test test/devils_dictionary/artsy/client_test.exs \
         test/devils_dictionary/artworks \
         test/devils_dictionary_web/live/artwork_live_test.exs
mix precommit
mix dd.artworks.seed --manifest priv/artworks/manifests/pilot-v1.json \
  --wikidata-only --refresh-wikidata --wikidata-request-limit 2
```
