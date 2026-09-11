# Reader milestone close-out and remaining MVP — 11 September 2026

The owner has authorized pushing the remaining changes, merging [PR #83](https://github.com/razrfly/dictionary/pull/83) into main, and closing [#82](https://github.com/razrfly/dictionary/issues/82). This report accompanies that delivery. The linked PR and issue are the authoritative merge/closure records.

**The reader milestone is usable; the original participatory encyclopedia MVP is not complete.** Closing #82 is a bounded delivery decision, not an A+ certification of all architecture and not closure of #73/#74/#78. The person-only scope exception identified in the previous audit remains; the owner-requested merge carries it forward explicitly into the foundation backlog.

## Verification for this delivery

The final local review fixes were initially uncommitted. They batch connection endpoint queries before rendering, avoid retaining the full Wiktionary lemma set in BEAM memory, preserve identifier links with nullable source-record provenance, and correct coverage/hub measurement queries and test totals. The five posted CodeRabbit findings were checked against these changes; the final code addresses their causes.

- Fresh `mix precommit`: **774 tests, zero failures**.
- Fresh coverage, now also excluding retired senses: **1,533,898 / 1,541,668 = 99.50%**; unchanged. The remaining **7,770** indexed lexemes do not have qualifying sense content.
- Fresh warm-cache page p95, after the test suite finished: cat **36.384 ms**, run **65.668 ms**, set **59.946 ms**, highest visible-degree entity **72.653 ms**; all below 150 ms. The first run overlapped the full suite and exceeded the budget on three probes; both logs are retained rather than hiding the failed measurement. This is isolated warm-cache evidence, not a guarantee under load.
- The immediately preceding independent full scorecards at `44f9c3b` passed animals **44/44**, emotions **43/43**, culture **42/42**, X3 **4/4** throughout. Those are reused dated evidence, not falsely described as a full re-score of the final review patch. The changed endpoint composition and measurement filters were freshly benchmarked; the full importer was tested on bounded fixtures, not rerun over the entire corpus.
- Prior independent browser audit verified word → person → work → edition and the reverse author/work links, 997 definitions across 42 pages, mobile height 6,383 px and no horizontal overflow at 375/1280 px. Final endpoint batching is additionally covered by the passing LiveView suite; that earlier browser evidence is reused.
- Fresh old #73 audit: **7 tests, 5 failures**. These remain outside the ordinary passing suite and must become permanent regression tests in the correctness release.

No baseline database reset, legacy migration, or broad re-import was performed for this close-out.

## What the product does now

1. Search a broad English lexicon and read attributed source definitions. Inflections and punctuation-safe canonical word URLs have tested handling; index-only entries have recovery states.
2. Keep lexical identities and senses separate from encyclopedia entities. A name entry and its person can coexist and be linked with source identifiers rather than merged by spelling.
3. Browse people, their biographies, works, editions and authored definitions through bounded role sections and canonical links.
4. Inspect source provenance and assertion details/history. Register and log in; contribution composition remains restricted to the internal account/reviewers.
5. Import/replay six registered sources: WordNet, Wiktionary, Wikidata, Wikipedia, Bierce and Johnson. This is six implemented adapters, **not all information from all six sources**, and not an implemented Artsy/ConceptNet/media platform.

The actual entity population is still **75,849 concepts, 17,097 taxa, 2 people, 2 works and 2 editions**. Broad lexical coverage should not be confused with broad typed encyclopedia coverage.

## Recommended execution order

### 1. Correctness and source-independent selection — #78 P1/P2, coordinated with #72

Start here, using the existing issues rather than another general architecture plan.

The five reproduced failures are: stale acceptance after endpoint changes; merged input pages still showing the old identity; split-context references failing to open reconciliation; rejected `defines` relationships leaking through authored-definition summaries; and `Registry.resolve/1` using `:merged` where the operation enum is `:merge`.

Also remove the new linker exception at `lib/devils_dictionary/absorb/linker.ex` (`sl.lexeme_id IS NOT NULL OR e.entity_kind = 'person'`). A scoped run should honor its selected population for every kind. Provide an explicit bounded record-selection path for evidenced records outside the scope; prove the same rule for a person and a work/non-person. Preserve real Bierce links, evidence, run ownership and idempotency. Do not weaken Animals scorecard thresholds to justify a global pass.

Complete the surrounding contract, not merely the five narrow assertions: visibility before counts/pagination; identity chains, compatible merge/split operations and old URLs; exact reviewed/evidence revisions; authorized reconciliation actions; and import → resolve/link → reconcile ownership. Optional source-record provenance is now preserved as optional; it is not evidence that every output has complete lineage.

**Exit:** the five old cases and adjacent negative tests pass in the ordinary suite, a source refresh leaves attached meanings and review history correct, and no unexplained output ownership is lost. Keep public contributions gated until this holds.

### 2. One complete cultural-example flow — #78 P3 + #67 + #66

The core distinction from an ordinary dictionary is still missing as a usable public flow:

Register → choose a precise meaning → create/select a URL, text or media-reference artifact → explain why it illustrates that meaning → attach inspectable evidence → submit for review → display in a mixed wall → filter by type → vote on relevance → challenge/correct.

The code already has typed claims, evidence, reviews and a voting API. That is useful infrastructure, but it is not the full submission, media-card, voting and correction UI. `ConnectionLive` is an existing-object claim composer; it does not supply the complete artifact-creation workflow. Public users must not edit source definitions or editorial interpretation. Keep original claimant, submitter and author distinct.

Start with reliable text/link/reference cards, empty/populated/mobile states, and real persisted data. Platform-specific unfurling, every embed provider, native social metrics and elaborate ranking are later enhancements. One artifact must support different meanings through separate contextual claims without duplicate artifact identity.

### 3. Representative general entities — #78 P2, #79 E0–E3, #72

The Wikidata adapter still retains a taxonomy-oriented property subset and projects `taxon` versus `concept`. It is not a general people/work/organization/event importer. Its trim retains mainsnaks, rank and type but omits statement references and qualifiers. Those limits need explicit source-policy decisions and tests; do not claim all Wikidata evidence is retained.

Demonstrate a bounded set of non-seeded people, a work, organization, place and event. Separate what source facts are retained, what becomes a typed projection, and which related entities are fetched. Use explicit budgets/resume behavior, preserve identities when classification improves, and retain unresolved references honestly. No whole-Wikidata crawl is needed to launch.

This is also the right place to prove that scope selection is operational and entity-kind-independent. The source-selection cleanup in step 1 is small; broader acquisition/projection follows here.

### 4. Public deployment readiness — #72

Before an internet-facing release, guard operational routes and their events. `/ops/imports` currently uses only the browser pipeline and can queue an absorb; changing the URL prefix was not authorization enforcement. Decide which health information can remain public separately from import controls.

Establish automated application CI, deployment configuration/runbook, secret handling and a tested backup/restore procedure. No `.github` workflow directory or repository-root deployment manifest was found during this inspection; successful GitGuardian/CodeRabbit checks do not constitute application CI. Reuse existing rebuild evidence where valid, but prove the actual deployment/recovery path. This is not required to merge a local reader milestone; it is required before calling it a public release.

## Open issue disposition

All 23 open issue bodies were inventoried at the start, with the current execution comments in #78/#79 and the owner clarification in #82 checked against the code. The older broad roadmaps were classified as product/specification history, not each retested as a separate current acceptance suite. After closing #82, 22 of this inventory remain open unless another actor changes them.

| Issue | Assessment and recommended disposition |
|---|---|
| [#82 Reader milestone](https://github.com/razrfly/dictionary/issues/82) | Close with this delivery and an explicit carry-forward note. Reader scope delivered; no claim of full MVP completion. |
| [#79 MVP-1 execution tracker](https://github.com/razrfly/dictionary/issues/79) | Its latest comment already says the session plan is superseded by #82. W1–W3/N1–N3 are delivered. E0–E3 and C1–C3 remain represented in #78/#72. Recommend archival closure as superseded **after** links are reconciled; not “everything in its old checklist completed.” |
| [#78 Remaining foundation and connected experience](https://github.com/razrfly/dictionary/issues/78) | Keep open; primary next implementation contract. P1 correctness, general selection/projection, P3 contribution workflow and unseen-extension proof remain. Pagination and much of reader discovery are now done. |
| [#74 Encyclopedia implementation](https://github.com/razrfly/dictionary/issues/74) | Schema/re-import/reader work largely delivered. Its opening audit is historical and stale. Keep open until #78 maps remaining guarantees and accepted boundaries; do not treat PR #83 as proof all durability requirements passed. |
| [#73 Identity/connection specification](https://github.com/razrfly/dictionary/issues/73) | Keep as parent contract until identity continuity, contextual evidence/review and contribution requirements are proven. No legacy migration is required. |
| [#72 Backbone/source correctness](https://github.com/razrfly/dictionary/issues/72) | Partially satisfied by identity, source revision and rebuild work. Still owns source semantics, retained qualifiers/evidence, bounded ConceptNet evaluation and public-operation readiness. Keep open; reconcile old names with the current registry model. |
| [#68 Old state/build order](https://github.com/razrfly/dictionary/issues/68) | Stale snapshot: old importer names/schema/auth decisions conflict with delivered work. Recommend archive as superseded by the current report/#78/#82, not another execution plan. |
| [#67 Evidence Wall](https://github.com/razrfly/dictionary/issues/67) | Keep open; central remaining reader/contributor product feature. Demo layouts and model APIs do not satisfy persisted submission/filter/voting behavior. |
| [#66 Layered definition-page design](https://github.com/razrfly/dictionary/issues/66) | Partial: source reader and related navigation exist; complete cultural layer, contribution states and separation of layers need implementation. Reuse design work rather than restart mockups. |
| [#65 Quote provenance](https://github.com/razrfly/dictionary/issues/65) | Not complete. No registered Wikiquote ingestion or full misattribution/provenance UI was found. Re-express the old dedicated-table proposal through the current content/assertion model; do not blindly create parallel quote identities. Full quote-source scoring can follow the minimum example flow. |
| [#64 Layered vision/MVP](https://github.com/razrfly/dictionary/issues/64) | Keep as product umbrella: editorial entries plus participatory annotations. The public examples/relevance-vote criteria remain unmet. This, not the older giant rebuild plans, defines the minimum product. |
| [#63 Guardian dating terms](https://github.com/razrfly/dictionary/issues/63) | Source expansion not implemented in the registered adapters. Useful later fixture/source work, not a prerequisite for fixing identity or building the first generic example flow. Validate the proposed source before implementation; no claim here that its content was fetched or verified. |
| [#75 Dead Editors’ Society](https://github.com/razrfly/dictionary/issues/75) | Deferred. Build human submission/review/evidence first, then a bounded labelled curator pilot. |
| [#17 Curator Bots](https://github.com/razrfly/dictionary/issues/17) | Deferred parent bot capability. Do not implement old weighted-vote/schema proposals as current MVP requirements. |
| [#61 Master rebuild plan](https://github.com/razrfly/dictionary/issues/61) | Historical umbrella that already consolidated several older issues. Clerk/Topic-era schema and broad integrations are not the current implementation contract. Recommend archival supersession, preserving useful ideas in current issues. |
| [#60 Relationships/forms/disambiguation](https://github.com/razrfly/dictionary/issues/60) | Forms and safe canonical addresses substantially implemented; broad semantics/ambiguity overlap #72/#73. Recommend map residuals there, then archive the old schema plan. |
| [#59 UI/UX system and wireframes](https://github.com/razrfly/dictionary/issues/59) | Partial design reference; Kit/Oatmeal and reader exist. Remaining product flows belong to #66/#67/#78. Avoid treating every historical mockup as an additional launch requirement. |
| [#48 Old hierarchical-platform MVP](https://github.com/razrfly/dictionary/issues/48) | Old scope/schema/auth assumptions superseded. Map any unique remaining feature into #64/#78, then archive as superseded. |
| [#47 Layered content design](https://github.com/razrfly/dictionary/issues/47) | Design reference; overlaps #66/#67. Retain useful visual principles, consolidate remaining execution there. |
| [#46 Aristocracy of Truth vision](https://github.com/razrfly/dictionary/issues/46) | Philosophical/brand reference, not a separate implementation gate. Recommend archival/reference treatment. |
| [#45 Construction of Truth brainstorm](https://github.com/razrfly/dictionary/issues/45) | Historical brainstorm; #64 is the narrower current MVP. Recommend archival/reference treatment. |
| [#44 Complete layered rebuild](https://github.com/razrfly/dictionary/issues/44) | Superseded historical roadmap, even by #61. Do not rebuild its old tables or implement all listed APIs to call the present MVP done. |
| [#16 Overview full-start](https://github.com/razrfly/dictionary/issues/16) | Historical wish list, including Rails-era checked integrations. Those checkmarks do not establish current Phoenix implementation. Archive/reference, not launch checklist. |

[#77](https://github.com/razrfly/dictionary/issues/77) is already closed. The removal of Animals navigation/defaults is real, but that closed state is not evidence that general entity ingestion or the newer linker exception is solved.

Only #82 is being closed in this delivery. The other dispositions above are recommendations; this audit does not silently close parent specifications or discard unfinished work.

## The smallest honest MVP completion gate

Use one connected acceptance walk instead of another broad roadmap:

- A reader finds “nepotism” or “situationship” and can distinguish source definitions from attributed editorial interpretation.
- A normal registered user chooses a specific meaning and submits a real text/link/media-reference example with rationale and evidence.
- A reviewer accepts or disputes the claim; a reader sees the correct status, source and separate subject identity.
- Another user votes on relevance or challenges the interpretation without editing the source definition.
- A source refresh, rejected edge, merged identity or split meaning cannot silently move the example or preserve misleading approval.
- Repeat across a word, person, work and non-person entity; verify mobile reading and public-operation controls.

When this passes on representative actual data, with the negative cases in CI, the original layered MVP is ready. Until then we have a useful reader and a substantial foundation, not the finished participatory product.
