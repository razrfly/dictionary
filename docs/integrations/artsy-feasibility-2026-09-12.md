# Artsy feasibility and open-source comparison — issue #86

Research and live-probe date: 2026-09-12. The issue's earlier readiness audit is the
baseline. This report completes the remaining bounded evidence before implementation.
It is a measurement of current API behavior, not a promise of future access or a
license opinion.

## Exit decision

**GO for Artsy as optional, disposable discovery and exact-identifier enrichment.
Do not use Artsy as the durable primary collection.** Wikidata supplies cross-source
identity. Independently licensed museum metadata and images, starting with the Met,
are preferred for durable display. Artsy descriptions, gene assignments, image URLs,
and cached responses must remain source-specific and removable.

The first pilot stays capped at 500 manifest candidates and 500 created/matched
records, with smaller operator-configured request and batch limits. Given the live
search hydration rate, start with Wikidata P11005-linked records rather than broad
title search. Widen only after the pilot reports its actual coverage.

## Probe bounds and declared sample

- Earlier issue audit: 39 Artsy requests.
- Completion probe: 93 Artsy requests, including 2 token exchanges; no retries and no
  429 responses. Combined issue evidence: **132 Artsy requests**, below the 200-request
  initial-probe ceiling.
- The implementation-validation runs added at most 57 requests: 28 for the original
  five-record import/rerun/browser check, 16 bounded gene-resource probes, at most 3
  in an interrupted legacy-cache repair run, 7 in the two-record repair pilot, and 3
  in the one-record new-entry proof. The cumulative ceiling is therefore **189 Artsy
  requests**, still below 200. Both final manifest resumes made zero provider requests.
- Open-source comparison: 68 Met requests against the current paginated
  `/public/collection/v1.1/search` endpoint and object hydration endpoint.
- No image bytes were requested or downloaded.
- Every request used an identifying User-Agent. Secrets and XAPP tokens were held only
  in process memory and never printed or written.
- Known-work queries: Mona Lisa; The Starry Night; The Kiss; The Third of May;
  Guernica; The Scream; Water Lilies; The Birth of Venus; American Gothic; The Great
  Wave.
- Meaning queries: nepotism; war; grief; love; power; family; solitude; justice; bank;
  Pop Art.

## Measured Artsy behavior

| Capability | Documented | Live result | Implementation consequence |
| --- | --- | --- | --- |
| XAPP authentication | Yes | 2/2 token exchanges returned 201 | Server only; redact credentials/token; refresh once on 401. |
| Artwork-only search | Search is mixed; audit found `type=artwork` behavior | 20/20 declared searches returned 200 and sampled only artwork types | Revalidate response types; the parameter is not trusted as an identity or relevance filter. |
| Search hydration | Search self links may be unavailable | 59 artwork hits; **3 hydrated, 56 returned 404** | A hit is only a candidate. Hydration status is explicit and 404 is useful output, not a crash. |
| Known-work coverage | Not guaranteed | Goya's *The Third of May* hydrated as the expected painting. *The Birth of Venus* was Marcantonio Raimondi's print, not Botticelli's painting. The other canonical title queries produced unavailable or unrelated works. | Never merge or select by title/rank. Preserve reproductions, prints, editions, and originals separately. |
| Usable media references | Artwork resources expose image links and rights strings | 3/3 hydrated search records had thumbnail references and rights strings; image bytes were not tested | Store a source-specific reference and rights statement separately. No file download or permanent-retention assumption. |
| Pagination | Follow `_links.next` | `war` page 1 returned only artworks, but its next link again omitted `type=artwork`; explicitly restoring the filter kept page 2 artwork-only | Parse only allowlisted Artsy URLs, reapply validated immutable filters, and validate every returned type. |
| P11005 exact crosswalk | Wikidata P11005 is an artwork slug | The P11005 example redirected, then returned 200 with slug `rembrandt-van-rijn-the-anatomy-lesson-of-dr-nicolaes-tulp` and opaque ID `4eb063a5b1976400010071f0` | Store `artsy_artwork_slug` and `artsy_artwork_id` in distinct namespaces. Follow only validated redirects. |
| P2042 artist crosswalk | Wikidata P2042 is an artist slug | `vincent-van-gogh` redirected, then returned opaque ID `4d8b92944eb68a1b2c000264` | Resolve creators through exact slug/ID evidence, never through a name string. |
| Direct gene assignments | Artwork links expose assigned genes | Goya returned 5 assignments: 19th Century, Chiaroscuro, Collective History, Conflict, Cultural Commentary | Preserve as attributed Artsy vocabulary. No string-to-meaning equivalence. |
| Gene-filtered acquisition | Gene resources link to artworks | The first 10 `gene_id=19th Century` artwork IDs were identical to the unfiltered first 10 | **Unverified/unsafe.** Do not seed through gene traversal. A direct per-work assignment may label a review candidate only. |
| Retry/quota signal | 5 requests/sec documented | Probe throttled below 3/sec; 0 retries, 0 quota responses | One application-wide coordinator paces all callers. It honors the full `Retry-After`, bounds retries and total attempts, and reports local request exhaustion separately from provider quota exhaustion. |

## Repair feasibility findings

The independent audit correctly identified that human-readable gene names were not
stable identifiers. A final bounded resource probe resolved four mappings to exact
opaque Artsy gene IDs:

| Mapping | Exact Artsy gene ID | Exact Dictionary meaning | Status |
| --- | --- | --- | --- |
| Conflict | `4db9b645db68d133c600123e` | `oewn-00975181-n#war` | enabled, related |
| Family | `50b99005c2f9a4a28b00015a` | `oewn-07986853-n#family` | enabled, related |
| Family | `50b99005c2f9a4a28b00015a` | `oewn-01157387-n#nepotism` | enabled, broader association with an explicit review note |
| Love | `4de292fcef72520001005fe5` | `oewn-07558676-n#love` | enabled, related |

The same probe returned 404 for the candidate slugs `grief`, `solitude`, `justice`,
`power`, `death`, and `freedom`. Those six definitions remain in the versioned
registry as disabled evidence records; the product does not pretend that their names
are IDs. Consequently the supported mapping set is four exact mappings, not ten.

The final repair pilot used one bounded Wikidata request and seven Artsy attempts for
two manifest records. Both exact identities matched. One previously enriched record
was reused and one existing Wikidata artwork was newly hydrated with Artsy metadata;
no local identity was created, no conflict/reproduction/quota event occurred, and one
creator link was added. A resume of the saved manifest processed zero records, made
zero Artsy requests, and created no duplicates.

A final one-candidate proof started from Q122978100, which was absent from the local
catalog. One bounded Wikidata request materialized *Les Âmes Déçues* and its creator,
Ferdinand Hodler, as reusable local identities with an `authored_by` route and source
link. The exact Artsy endpoint was unavailable after three attempts, so no Artsy
fields or image were invented. Its saved manifest records `unavailable`; resuming it
made zero requests and no duplicates. This deliberately separates “new local identity
created from independent Wikidata evidence” from the Artsy import summary's honest
`created: 0, unavailable: 1`.

The pilot also exposed and fixed a coordinator initialization bug: monotonic clocks
may start at a negative value, so an absolute zero deadline could sleep indefinitely.
The coordinator now initializes from the injected/current monotonic time, with a
negative-epoch regression test.

### Live-audit findings and enforced behavior

1. Search hits whose artwork endpoint returns 404 are retained only as an explicit
   unavailable discovery result. They never become an identity or claim.
2. Search and collection pagination never follows a provider URL verbatim. The client
   validates scheme/host/path and reconstructs the next request with the immutable
   `type=artwork` or `artwork_id` filter.
3. Gene traversal remains disabled. Only direct assignments returned by an exact,
   hydrated artwork can meet a versioned opaque-ID mapping.
4. Every import validates category and exact Wikidata P11005/P2042 crosswalks.
   Prints/reproductions and conflicting slugs are skipped or opened for reconciliation;
   titles never merge records.
5. API access is treated as freshness-limited cache permission, not permanent rights.
   Provider payloads, URLs, genes, opaque IDs, and provider-only claims can be removed
   while independently supported Wikidata/Wikipedia identity and open imagery remain.

The three hydrated search records were:

1. Goya, *The Third of May* — painting, opaque ID
   `4d8b92ee4eb68a1b2c0009ab`, expected known work.
2. Marcantonio Raimondi, *The Birth of Venus* — print, opaque ID
   `515bb06394714c2e38001285`, a different work from the famous Botticelli title.
3. Alphonse Legros, *Solitude (Solitude (Paysage))* — print, opaque ID
   `515d45217b70570a13003fc1`, meaning-search candidate only.

No meaning query produced an automatically acceptable semantic connection. The probe
therefore gained **zero reviewed art examples**. `family`, `war`, `grief`, and other
queries may support future human-reviewed candidates; `bank` and title-like queries
demonstrate wrong-sense/creator/reproduction risk.

## Met comparison over the same 20 queries

The Met v1.1 highlight-and-image searches returned 48 sampled object records. Of those,
30 exposed a public-domain image reference and 33 had subject tags. Four queries had
no highlight result: Mona Lisa, Guernica, nepotism, and solitude.

The Met covered a recognizable *Great Wave* object (ID 39799) and supplied strong
open candidates for grief, family, and justice, but it also returned broad or unrelated
matches. For example, `American Gothic` returned a cabinet, *Jubal and Miriam*, and a
pitcher. Open licensing solves durability, not semantic relevance or identity.

| Dimension | Artsy sample | Met sample |
| --- | ---: | ---: |
| Search/query pages | 20 | 20 |
| Candidate hits hydrated | 3 / 59 | 48 / 48 requested |
| Explicitly usable/open image references | 0 established for permanent use | 30 public-domain image references |
| Subject/classification data | 5 direct genes on the sampled Goya work; traversal unsafe | 33/48 sampled objects had tags |
| Canonical known-work exact-title evidence | 1 expected painting; 1 same-title different print | 1 recognizable Great Wave result; title search remained noisy |
| Permanent retention basis | No; API terms require removable cache/content | Met Open Access/public-domain fields support durable use where the object says so |

## Retention matrix

| Field/material | Discovery/cache mode | Durable collection mode | Withdrawal action |
| --- | --- | --- | --- |
| Artsy opaque ID and confirmed slug | Keep as source identifiers while access/terms permit | Keep only if an independent identity source or separate permission supports it | Disable Artsy discovery; remove disallowed projections/aliases as policy requires. |
| Artsy title/date/medium/institution | Short-lived normalized cache | Persist only with independent field-level support or separate permission | Remove Artsy-only field support and recompute display. |
| Artsy description/blurb | Short-lived cache only | No default durable retention | Delete Artsy copies. |
| Artsy genes/assignments | Short-lived attributed cache/candidate evidence | No default durable retention | Delete assignments/mappings and stale any review relying on them. |
| Artsy image URL/rights string | Reference only; no image download | Only when a separately verified license supports the image | Remove Artsy-only reference/copies; fall back to text card or open source. |
| Wikidata QID and P11005/P2042 statements | Versioned source record | Durable under Wikidata licensing/attribution policy | Preserve independently supported identity. |
| Met object metadata | Versioned source record | Durable where the field's Open Access terms apply | Preserve independently supported fields. |
| Met image | Reference or download only when object says public domain | Durable for `isPublicDomain=true`, retaining source/credit metadata | Preserve independently licensed image. |
| Editorial rationale/review | Local first-party content | Durable | Preserve; mark for re-review if cited provider evidence disappears. |

Artsy's terms permit reasonable freshness-oriented caching, require changes/removal
after notice, and require API content/copies to be removed after termination. API
availability or a public-domain underlying painting does not license Artsy's text,
classification, or image rendition.

## Meaning and acquisition policy

- Broad searches such as `family`, `power`, or `patronage` are exploratory and are not
  synonyms or evidence for `nepotism`.
- A direct work-gene assignment may generate a clearly labeled candidate for one exact
  meaning only through a versioned reviewed mapping. A search hit records the exact
  query and is weaker.
- Neither path creates an accepted `illustrates` claim. Existing evidence/review rules
  remain authoritative.
- Gene-filter traversal is disabled until a future control query proves it changes the
  returned population as documented.

## Sources

- [Artsy authentication](https://developers.artsy.net/v2/docs/authentication)
- [Artsy search behavior and unavailable hits](https://developers.artsy.net/v2/docs/search)
- [Artsy artwork links and fields](https://developers.artsy.net/v2/docs/artworks)
- [Artsy API terms](https://developers.artsy.net/v2/terms)
- [Met Collection API, including v1.1 search](https://metmuseum.github.io/)
