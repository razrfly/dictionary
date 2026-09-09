# Contract audit: issues #73 and #74

Date: 2026-09-09. Audited commit: `b0abb07`, branch `74-encyclopedia-model`, PR #76. This is an audit, not a fixes pass. No application code or development corpus was changed. Reproductions use rollback-only test transactions.

Contracts: https://github.com/razrfly/dictionary/issues/73 and https://github.com/razrfly/dictionary/issues/74. #74 supersedes old-data migration/compatibility requirements and explicitly scales the product acceptance to a narrow authenticated submit/review slice. It defers full media integrations, a comprehensive voting system and polished implementations of every #73 scenario. These are not retroactive #74 requirements.

## Grade and decision

**Overall delivery against the combined intent: C+ (roughly 68/100, qualitative assessment). Architecture direction: B+. Completion of the narrower #74 contract: B−. Full #73 reader/contributor experience: C. Do not close as complete yet.**

The schema is a credible foundation and should be repaired rather than replaced. The failures concern real contractual guarantees: public visibility, identity lifecycle, stale review presentation and source-output bookkeeping. They are not merely cosmetic shortcomings or missing integrations.

## Evidence and limits

- Fresh `mix precommit`: **722 tests, zero failures**, 27.6 seconds. Adjacent `precommit.txt`.
- Seven isolated audit checks: **six failures, one pass**, 0.5 seconds. Adjacent `reproductions.exs` and `reproductions.txt`. They assert desired behavior and intentionally fail on the audited commit. Run with `mix test docs/audits/2026-09-09-issue73/reproductions.exs`. They are outside the default test directory so the review artifact does not silently change the baseline suite.
- Live HTTP inspection of port 4007: Bierce lexical page, person page, and nepotism page; database reads on `devils_dictionary_v2` substantiate identity/coverage findings.
- Reviewed schema, domain APIs, page queries, contribution handlers, adapter policies, durability/extension tests, and original issue contracts.
- Existing saved evidence: exact independent rebuild equivalence, all-six-source semantic replay equality, scope scorecards and warm-cache budgets in `../../rebuild/evidence-2026-09-09/`. These expensive runs were not repeated for this audit. Their success does not demonstrate absent cases below.
- This is not a security penetration test or proof of every possible future use case. The prior full authenticated browser contribution/review walk remains unfinished.

## Contract matrix

| Area | Status | Evidence / remaining limit |
|---|---|---|
| Registry and typed identities | Substantially implemented | Objects, lexemes, senses, entities, content; subtype integrity and database rejection tests. |
| Local identities without QIDs | Implemented through domain API | Namespace-aware external identifiers; local people, works and artifacts are representable. No public minimal-object creation flow. |
| Source-specific meanings | Implemented with meaningful tests | Sense revisions, reorder reconciliation, ambiguous cases, forms and source-native keys. No universal merged-sense shortcut. |
| Person/author unification | Demonstrated for seeded anchors | Bierce biography, definitions and work point at person ID 1. Not demonstrated as general person ingestion. |
| Work/edition/content/credits | Implemented at model level | Typed work and edition details, authored_by/published_in/excerpt_of/translated_by claims. Content lacks a direct endpoint page; richer credits UI remains limited. |
| Typed assertions and evidence | Substantially implemented | Constrained endpoints, revisions, separate actors/evidence/reviews/votes; contextual fields. |
| Public editorial visibility | Failing specialized projections | Common readers hide rejected claims; biography and definition-summary paths bypass that policy. |
| Identity merge/split | Incomplete and broken | Merge resolver crashes; public reads ignore resolution; context-only split attachments missed. |
| Review context after source changes | Stored history works; presentation fails | Historical revision is pinned, but new endpoint text can still display with old acceptance. |
| Contributor/reviewer slice | Implemented and LiveView-tested, browser proof incomplete | Existing-object selection, rationale, one citation/context, authorized accept/dispute/reject. |
| Full #73 contribution workflow | Partial | No new-object UI, claim edit/challenge, counterevidence submission, original-claimant selection, comprehensive voting UI, or complete visible review history. |
| General discovery | Incomplete | Main search is lexical; Bierce name entry lacks a person connection. Surprise me scope restriction fixed in b0abb07; cross-kind discovery still pending. |
| Bounded traversal | API implemented; UI incomplete | Stable cursor readers exist. Entity sections cap at 50 without a next-page control. |
| Six existing adapters | Ported; coverage constrained | Broad WordNet/Wiktionary lexicon, selective Wiki enrichment, biology-oriented Wikidata projection. |
| Refresh/replay | Strong tested progress; remaining bookkeeping defect | Exact semantic checks pass; 117,363 ownership outputs have null last-seen run stamps. |
| Extension proof | Useful representability proof | Translated-poem scenario uses already-supported kinds/predicates; not proof of an unseen type extension. #74 permits this selected scenario. |
| ConceptNet / Artsy production | Deliberately deferred | Not grounds to fail #74. Source contracts and eventual integration remain required downstream. |
| Existing-data migration | Deliberately eliminated | Do not reintroduce a migration project. |

## Prioritized findings

### P1 — rejected relationships leak through specialized person-page sections

Reproduced two cases. Rejecting an article→person `about` claim makes `Claims.incoming` return no claim, but `EntityPage.build(person).biography` still returns the article. Rejecting definition→word `defines` hides the common outgoing relationship, but the author's definition summary still displays the word association.

Locations: `lib/devils_dictionary/encyclopedia.ex:702` (`content_about`); `lib/devils_dictionary/encyclopedia/entity_page.ex:188` (`targets`). Both construct active/current relationship queries without the common editorial visibility filter. Therefore the earlier statement that all person-page sections obey public policy was too broad.

Fix all projections through shared visibility rules, including counts, summaries, linked titles and publication/credit paths. Test each specialized section from both endpoints. The generic connection reader's passing rejection tests do not cover these paths.

### P1 — merged identity resolution crashes and public pages ignore identity events

Reproduced `Registry.resolve(old_id)` after a valid merge: Ecto raises because lifecycle value `:merged` is passed to the identity-event enum, which expects operation `:merge`. Separately, `EntityPage.build(old_id)` still presents the old identity after merging it into a survivor. Public EntityLive/WordLive do not call Registry.resolve.

Locations: `lib/devils_dictionary/registry.ex:524`, `lib/devils_dictionary_web/live/entity_live.ex:40`, entity/word read contexts. There are no committed Registry.merge/split/resolve tests in the audited test tree.

Fix lifecycle/operation mapping, integrate explicit merge/split/retired states into canonical reads, and specify survivor relationship discovery while preserving immutable historical endpoints. Add merge-chain, cycle rejection, compatible-kind, aliases/external-ID conflict, repeated-merge and old-URL tests. Do not simply rewrite historical assertions or redirect into loops.

### P1 — split reconciliation misses identities used as context

Reproduced a claim with `context_object_id` set to the identity subsequently split: no reconciliation case is created. `Registry.open_split_cases` only checks subject/object IDs.

Location: `lib/devils_dictionary/registry.ex:489`. Cover all semantically relevant references (including context and jurisdiction); report ambiguity and provide an explicit resolution workflow. Do not choose a split output implicitly. The stored case model exists, but no public reconciliation workflow was found.

### P1 — stale acceptance can accompany changed endpoint content

Reproduced: create an article→person claim, accept it with its displayed content revision pinned, then append changed article text without editing the assertion. `Connection.build` displays the new text and still reports accepted. The old review record is correctly preserved, but the presentation does not disclose that the acceptance concerned an older version.

Locations: `Claims.review_state` only reads the latest review decision; `Connection.endpoint` selects current content/sense revisions. The existing D4 test changes the endpoint and then manually revises the claim, so it misses the interval where source content changed and the assertion did not.

Preserve the historical decision, but calculate and display context freshness; show the exact reviewed version or require/recommend re-review under an explicit policy. Extend this to evidence selection: the composer currently keeps an object ID and resolves its current revision at submission, rather than persisting/revalidating the precise revision shown when selected. That latter race is code-inspection evidence, not a separate executed reproduction here.

### P1 — output run stamps are erased by a documented resolver path

Current database: **117,363** source-assertion ownership rows have null `last_seen_run_id`: Wiktionary 116,448; Johnson 906; Bierce 9. These remain source-associated rows; this does not mean all provenance is absent.

Code path: `Mix.Tasks.Dd.Resolve` creates `run_row` but calls `Resolver.run` without its run ID. Resolver forwards the optional nil ID to `Materializer.write_assertions`; ownership upserts replace last_seen_run_id with that value. Reconciliation explicitly treats null stamps as unseen. This explains a mechanism consistent with the post-replay diagnostic; the audit did not perform another destructive refresh to measure downstream retirement.

Pass/account for run identity in resolver/linker writes, prevent bookkeeping-only runs from clearing valid ownership, and test re-materialize→resolve→reconcile together. Recompute diagnostics afterward. Semantic equality is not a substitute for bookkeeping invariants.

### P2 — person support is a demonstrated anchor, not broad imported coverage

Database distribution: 75,849 concepts; 17,097 taxa; **2 people, 2 works, 2 editions**. The latter are seeded historical-author records. The Wikidata adapter initially emits taxon or concept and retains a biology-heavy set of properties. Other human subjects can therefore exist as generic concepts rather than typed people.

Bierce specifically: lexical ID 341814 and source sense 342580 are distinct from person ID 1. That separation is correct. The lexical entry has no outgoing refers_to or candidate link to the person, and belongs to no selected scope. Its name page is consequently a lexical dead end relative to his person page. Do not repair this with a name-only merge; establish an attributable mapping and cross-kind discovery. #77 tracks the generalized acquisition/discovery cleanup.

### P2 — public connection navigation and evidence inspection are incomplete

EntityPage uses a cap of 50 for authored records and connections; EntityLive has no cursor/load-more control. The core API supports pagination, but the reader cannot traverse all results. The first 50 authored records are selected before splitting works from definitions, so a work can be crowded out on high-degree people.

Connection content endpoints have `path: nil`; sense endpoints link to the word without a sense-specific anchor. Evidence UI prints revision IDs, locator and attribution but does not open/render the cited historical passage. Reviews are loaded into the connection struct, yet reviewer decisions/reasons are not rendered as a complete audit history.

Implement bounded continuation and navigable exact evidence/revision views. Preserve attribution and distinguish current source text from the text actually cited/reviewed.

### P2 — broader #73 workflows remain API-only or absent

Existing-object proposal and reviewer accept/dispute/reject exist. The composer cannot create a minimal local object, distinguish an external original claimant from the submitting account, submit multiple supporting/contradicting citations, or edit/challenge an existing assertion. Temporal/jurisdiction fields exist in the model but are not fully exposed. Voting API/storage exist; a full voting UI was explicitly excluded from #74.

Schedule these as remaining #73 product work rather than claiming they were completed by the minimal #74 slice. The new-object flow is particularly important for the goal of connecting future local artworks/events without hand-seeding the database.

## What is genuinely solid

Stable typed identity and predicate validation, current revision integrity, source-specific senses, atomic claim revisions, evidence targets, separate source support/editorial review/relevance, multiple role predicates, replay comparison beyond row counts, deterministic import fixes, bounded indexed relationship readers, and actual Bierce definition→author→biography/work navigation. Existing direct-write rejection, source reorder/withdrawal, contextual revision and multi-role tests provide real value.

One audit check also confirmed that a genuinely withdrawn current content revision is filtered from biography rendering. Do not conflate that working lifecycle filter with the failing editorial-rejection filter.

Recorded warm-cache animals budgets: P1 44.191 ms p95, P2 0.418 ms p95, search 69 ms p95. Recorded full rebuilt corpora match exactly, and all six source replays preserve compared semantics. Those results remain valid within their measured scope; they do not certify the public workflows and identity operations above.

## Completion order

1. Fix P1 visibility, lifecycle resolution, context reconciliation, stale-review presentation and run ownership. Convert the audit reproductions into regression tests, add the uncovered boundary cases, and rerun relevant checks.
2. Finish #74's real-browser submission/review and health agreement proof. Include exact cited evidence and rejection checks on every specialized public projection. Refresh only the corpus measurements affected by fixes; no unnecessary full-import repetition.
3. Deliver #77's subject-independent discovery/acquisition cleanup, including safe typed-person enrichment and the name-entry/person bridge. Keep Animals as ordinary content and a test fixture.
4. Finish #73's minimum new-local-object, evidence inspection, edit/challenge/reconciliation and pagination workflows. Explicitly assign genuinely larger social/media features downstream.
5. Update the issue matrix with evidence per requirement. Close #74 only after its narrowed contract holds; close #73 only when remaining product requirements are implemented or explicitly accepted as scoped follow-ups.

No further schema rewrite is justified by these findings. Small justified schema changes may be needed for specific operations, but the main work is correct integration and complete behavior.
