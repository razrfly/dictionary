# Issue #86 independent-audit repair

Date: 2026-09-12

Branch: `codex/issue-86-artsy-catalog`

Pull request: [#98](https://github.com/razrfly/dictionary/pull/98)

This is the completion ledger for the findings in the independent C+ audit. It
distinguishes verified behavior from unsupported coverage and should be used for the
next independent review.

## Audit finding disposition

| Finding | Repair | Evidence |
| --- | --- | --- |
| Preserve current Wikidata evidence | The seeder loads/materializes an existing full source record and never replaces it with manifest-shaped data. Missing records are either hydrated by the shared adapter or represented as explicit manifest evidence without synthesizing a Wikidata observation. | Regression retains byte-for-byte P18/claims via `Sources.raw/1`. The old external audit assertion reads a `load_in_query: false` field directly and must use that accessor. |
| Honor creator review decisions | Cards and creator search use `Claims.visible(:public)`, require `authored_by`, and deduplicate creator identities. | Rejected creator and unrelated-predicate search regressions. |
| Stop access on withdrawal | One configuration/source/coordinator gate is checked at every client attempt and at importer/UI entry points. Provider writes lock the same source row as withdrawal; generation invalidation discards an in-flight response. | Post-withdrawal import reports zero calls, zero processed records, and no new source records. |
| Keep partial imports resumable | Manifest schema v2 checkpoints Wikidata, artwork, artists, genes, identity, and creators. Artist/gene pages persist their cursor after every page. Temporary/request/quota failures remain partial. | A two-attempt run checkpoints after artwork, resume finishes collections, and a second resume uses zero calls without duplicate IDs. |
| Preserve independent creators | P170 is materialized as `authored_by`; local and remote candidate pages merge creator QIDs/slugs; creator identities/links are created before optional Artsy hydration. | Missing-Artsy and multi-page/multi-creator regressions; live Q122978100 page links Ferdinand Hodler after Artsy 404. |
| Shared limits/freshness | A supervised application-wide coordinator paces all actual attempts, shares full Retry-After deadlines, counts auth/retry/redirect attempts, and invalidates withdrawal generations. Source caches carry 24-hour freshness metadata and completed stale records are refreshable. | Negative monotonic epoch, concurrent-client pacing, long Retry-After, retry, 401 and bounded-budget tests. |
| Exact mappings | Registry v2 pins exact WordNet source keys and opaque Artsy gene IDs with version, relation type, note, and probe evidence. | Four mappings enabled; six failed gene-resource probes remain disabled. Same-name/wrong-ID assignment produces no suggestion. |
| Complete reader/catalog flow | Local title/creator/retained-tag search is network-free and paginated; cards/pages use independent images first, Artsy references only while active, show rights/freshness/source data, and link creators. Candidate links preselect exact endpoints, predicate, revision, locator and rationale in the existing composer. | Pagination, tag search, rejected visibility, rich-page, creator-link, and composer regressions plus desktop/mobile browser checks. |

## Live bounded evidence

The complete feasibility campaign is bounded at **no more than 189 Artsy attempts**,
below the issue's 200-request ceiling. No image bytes were downloaded and no secret or
token was printed, saved, or committed.

| Run | Wikidata requests | Artsy attempts | Result |
| --- | ---: | ---: | --- |
| Readiness + original implementation evidence | documented separately | 160 | 20-query readiness, five-record pilot/rerun, browser lookup |
| Stable gene-ID repair probes | 0 | 16 | Conflict, Family and Love resolved; six candidate slugs returned 404 |
| Interrupted legacy-cache repair | 0 | at most 3 | Exposed/fixed resume and monotonic-coordinator paths; no claimed import outcome |
| Two-record repair pilot | 1 | 7 | matched 2; existing Artsy-rich entry reused 1; existing Wikidata entry newly Artsy-hydrated 1; creator links 1; conflicts/reproductions/quota 0 |
| Same two-record manifest resume | skipped | 0 | processed 0; duplicates 0 |
| New-entry proof Q122978100 | 1 | 3 | Wikidata created the absent artwork + creator; exact Artsy endpoint unavailable; no provider data invented |
| Same new-entry manifest resume | skipped | 0 | processed 0; duplicates 0 |

The two-record pilot's Artsy summary was `matched: 2, created: 0, unavailable: 0`.
The new-entry proof's Artsy summary was `matched: 0, created: 0, unavailable: 1`.
Creation of *Les Âmes Déçues* and Ferdinand Hodler happened in the explicitly reported
Wikidata hydration stage. This avoids misreporting “a newly useful local entry” as an
Artsy-created record.

## Browser acceptance

Development Chrome was checked at desktop and a narrow mobile width against real
retained pilot data:

- `/artworks` showed seven reusable works after the final proof, independently licensed
  thumbnails where present, honest image fallbacks elsewhere, creator/source links,
  and responsive layout.
- Local search reduced the catalog to the one requested Ranuccio record without a
  provider call.
- *Portrait of Ranuccio Farnese* showed the permitted image, creator, date, medium,
  collection, image credit, Wikidata/Wikipedia/Artsy links, and cache notice.
- *Les Âmes Déçues*, created during the final proof, showed the retained Wikidata
  description, Ferdinand Hodler link and Wikidata source; the unavailable Artsy image
  remained an honest fallback. Creator navigation returned to the work.
- An authenticated internal contributor opened the composer with exact Cupid and
  WordNet `war` identities, `illustrates`, the immutable Artsy revision, opaque Conflict
  gene locator, and explanatory rationale preselected. No claim was submitted.

## Product and retention decision

Artsy remains **optional, freshness-limited discovery/enrichment**, not the durable
collection authority. Wikidata provides exact cross-source identity; museum/open
sources provide durable metadata/images where their record permits it. The 20-query
Met comparison hydrated 48/48 requested records and found 30 public-domain image
references, versus 3/59 hydrated Artsy search hits and no blanket permanent Artsy
retention basis. Provider withdrawal removes provider payloads, genes, opaque IDs,
URLs and source-owned claims while preserving independently supported identities,
creator relations, open fields, and editorial work.

## Acceptance status

- [x] Full P0 capability/rights/coverage report and explicit GO-for-optional-enrichment decision.
- [x] Versioned selected corpus plus bounded Wikidata P11005/P2042 discovery and import task.
- [x] Dry-run, limits, atomic manifest checkpoints, resume and duplicate-free reruns.
- [x] Exact identifiers, conflicts, reproductions, missing endpoints, retries, 401, 429/local quota, pagination and provider withdrawal covered.
- [x] Rich reusable catalog, local pagination/search, artwork/creator navigation and honest image fallback.
- [x] Exact meaning candidates remain distinct from artwork identity and require normal evidence/review.
- [x] Desktop/mobile local search, artwork pages, creator links and select/review composer verified.
- [x] Open museum comparison, field-level retention matrix and provider-disappearance operation documented.
- [ ] Reviewed/featured art examples gained: **0**. Four exact mappings can produce candidates where a retained direct assignment exists, but no human review was performed or implied by this issue implementation.
- [ ] Permanent Artsy retention rights: **not established**. The supported fallback is deliberately implemented; Artsy-only material remains removable.

The last two unchecked statements are reported product facts, not silently omitted
engineering work. They must not be converted to claims of reviewed coverage or durable
Artsy ownership without separate evidence/authorization.

## Verification commands

- Focused repository regressions: **72 tests, 0 failures** across every test file
  changed for issue #86, including the Artsy client,
  seeder, Wikidata adapter and artwork LiveViews.
- Original external audit file: **4 of 5 expectations pass**. Its remaining line reads
  `SourceRecordRevision.payload` directly even though issue #93 intentionally declares
  that 660 MB aggregate field `load_in_query: false`. The equivalent repository
  regression uses `Sources.raw/1`, verifies exact payload equality (including P18), and
  passes. Re-enabling payloads on every ordinary revision query would regress the shared
  identity foundation's memory-safety fix.
- Full suite through the required `mix precommit`: **944 tests, 0 failures**. The two
  ignored corpus archives were temporarily linked read-only from the original
  Dictionary checkout so the real source-manifest digests were verified; the links
  were removed immediately afterward and are not branch artifacts.
- `mix format --check-formatted`, `mix compile --warnings-as-errors`, and
  `git diff --check`: pass.
