# Proposed additions to issue #194

**Historical draft, now superseded:** the owner accepted these recommendations. Use [ADR 0002](../../adr/0002-public-routing.md) and the [policy validation](policy-readiness.md) for the settled decisions and implementation contract. The unchecked items below preserve the original proposal and are not the current status tracker.

This is a handoff draft supported by the [26 September audit](README.md). It does not publish routes, replace approved product decisions, or claim the mapping is already implemented.

## Goal and scope

Create stable, readable addresses for distinct useful pages. Keep existing object identities, source senses, revisions, licensing and relationships intact. Adopt On for curated treatments and the proposed subject families after resolving the boundaries below. Use a local routing policy informed by external vocabularies; external taxonomy changes must not automatically move published pages.

The audit reproduced 100,723 entities and 1,541,669 lexemes. A deliberately narrow eight-class screen found 7,475 reclassification candidates. Source-page classifications identify 5,917 disambiguation/list/index records. These are development-corpus measurements, not launch-page counts or verified assignments.

## A. Publish the design contract before the route migration

- [ ] Add `docs/adr/0002-public-routing.md` with status, owner, policy version, approved defaults and unresolved decisions. On approval, link it from ADR 0001 §10; on implementation, mark the old route policy superseded.
- [ ] Add a versioned machine-readable namespace registry, suggested location `priv/routing/namespaces.json`, and classification rules, suggested location `priv/routing/classification-rules.json`.
- [ ] Give each family a stable key, prefix, scope, inclusions, exclusions, overlap precedence, examples, reviewed mappings and change history. Prefixes are allowlisted; imported names cannot create new families.
- [ ] Define one result contract: proposed family, rule ID/version, supporting source revisions/classification path, contradictions, and one of `approved`, `needs_review`, `out_of_scope`, or `excluded_source_page`. Keep publication and indexing states separate.
- [ ] Store per-domain authority choices and explicit manual overrides. Define deprecated/withdrawn classifications, source disagreement, missing classes, cycles and traversal limits. A stale or incomplete result must be visible as such.
- [ ] Distinguish page-role evidence, semantic classification, lexical linkage and identity equivalence. Never use `part_of`, `about`, `depicts`, text similarity or a candidate lexical link as type inheritance.
- [ ] Persist enough external classification evidence to reproduce the decision offline: source URI and revision/checksum, selected assertions, mapping relation/direction, version and review rationale. Provider failures leave existing published routes unchanged.

### Recommended boundaries to settle in this contract

| Subject | Recommended public treatment |
|---|---|
| Human biography | People; occupations remain classifications/collections. |
| Institution, company, band, team, government | Organizations; its building/campus may be a distinct Place. |
| Named terrestrial location, river, mountain, country | Places; general landform types are Nature subjects. |
| Celestial body | Nature, following the selected product direction. |
| Taxon, breed, nonhuman organism, substance, general natural phenomenon | Nature; preserve distinctions among individual, group, substance and process. Include synthetic substances as scientific subjects. |
| Particular historical occurrence or named organized event series | Events; occurrences retain their own identity when represented. General processes/practices and cultural observance concepts use Concepts. Record exceptions. |
| Book, film, album, poem, software, authored artwork, recipe | Works; an article about an object does not turn that object into a work. |
| Publication edition | Works as a public grouping, with an explicit edition page role and qualified address; preserve its separate edition identity and parent-work relation. |
| Particular non-art object, device, prepared dish, mythological/fictional being or fictional place | Subjects initially, when identity and scope are known. An artwork or recipe depicting/describing it is a separate Work. |
| Language, programming language, mathematical idea, emotion, practice, discipline, cultural/historical period | Concepts; the lexical term is separate. Software implementations are Works. Geological periods use Nature under a documented exception. |
| Imported disambiguation, list, category or index page | Source-page review; no automatic subject page or curated On creation. Retain source identity and evidence. Useful local collections/choice pages require their own role and policy. |
| Missing/conflicting classification or uncertain identity | Review state; do not silently call it Subjects or Concepts. |

These defaults require explicit adoption in the ADR. An agent must not infer adoption merely because this draft lists them. A new detailed subtype normally changes classifications, templates or collections. A new public family needs a reviewed scope, corpus evidence, overlap rules, useful pages and an address-migration assessment.

## B. Page and URL storage invariants

- [ ] Introduce durable page identity separate from a displayed label. A subject page references its existing object; a lexical page references its lexical identity/group contract; an On page has explicit ordered membership and association roles.
- [ ] Specify On storage without treating one lexeme as an overview. If adding a registry object kind, migrate the registry's constraints, deferred subtype checks and predicate endpoint rules deliberately. A separate page table is another possible design; document the choice.
- [ ] Permit at most one current canonical address per page and locale. A single normalized-path uniqueness domain reserves current paths, redirects and retired paths together.
- [ ] Define normalization explicitly: Unicode normalization, URL case, punctuation, encoding, trailing slash, maximum length, empty labels, reserved segments, encoded slashes and malformed inputs. Apply the same function during allocation and resolution.
- [ ] Recommended launch default: unprefixed English pages, locale recorded in the page record, lowercase readable path segments, punctuation-aware proposals (`c-plus-plus`, `c-plus`) and human-readable qualifiers. Preserve original spelling/case in identity and display. Reserve a documented strategy for future locale prefixes before allocating conflicting top-level paths.
- [ ] Allocate and persist paths transactionally with database uniqueness enforcement and bounded retry. Stable tie-breaking must not grant a bare name to whichever import happens first. Keep two distinct same-name people/works separate.
- [ ] Define the last collision step: review or an approved stable suffix when semantic qualifiers still collide. No empty/dummy slug and no silent merge. Publish nothing until a unique path is resolved.
- [ ] Keep current routes, old-path history, manual overrides, editorial pages and memberships outside disposable import projections. Rebuild/restore must preserve their page/object identities and destinations even if provider order changes.

## C. Lexical coverage and navigation

- [ ] Decide explicitly whether existing lexical paths remain at launch. Recommended scope: retain the identity-addressed lexical layer while introducing subject namespaces and curated On pages. Replacing `/define` or `/words` requires an equally complete lexical address/resolution contract first.
- [ ] Preserve all constituent source senses, content revisions, language/POS distinctions, homographs, inflections and exact evidence URLs. A curated On page is optional; lexical reachability must not depend on editorial coverage.
- [ ] Use a shared route resolver/helper for search results, Enter submission, internal links, provenance drawers, trails, entity sections, collections and identity histories.
- [ ] Exact page/object lookup must never fall back to another identity by its slug. Ambiguous aliases return multiple candidates or a deliberately curated choice page.
- [ ] Document query parameters: UI state, provenance reference, navigation origin, pagination and discovery cursors. Preserve meaningful navigation state while keeping canonical behavior consistent with actual page content.

## D. HTTP, metadata and publication

| Situation | Required behavior |
|---|---|
| Published canonical page | Initial GET/HEAD returns 200 with the intended content, canonical URL, title and indexing policy. |
| Equivalent historical address of a moved page | One permanent server redirect (301 or 308, consistently chosen) to its current 200 canonical. Update internal links and sitemap. |
| Wrong case/encoding/trailing slash | Resolve only according to the documented normalization policy; canonicalize equivalent variants without changing identity. |
| Unknown exact identity/path | 404; no slug-based substitution or empty 200 page. |
| Merged identity | Approved survivor and preserved identity history; redirect only after confirming equivalent page purpose. |
| Split identity | Explain the split and offer successors; never arbitrarily choose one. |
| Retired identity | Preserve a useful history/provenance page where warranted; otherwise documented 410/404 behavior. Reserve the old path. |
| Imported stub, fixture, unresolved classification | No automatic indexing or sitemap entry; retain internal identity and evidence access as required. |
| Distinct overview and subject | Each useful page gets its own canonical; do not canonicalize all subjects to On. |

- [ ] Provide separate WebPage/Article/CollectionPage and subject nodes where appropriate; connect them explicitly. Use evidenced Schema.org types and verified identity links. Nature is a local family, never a fabricated Schema.org type.
- [ ] Use one canonical/metadata producer for server rendering and live navigation. Prevent stale or duplicated head tags after navigation.
- [ ] Define publication readiness using useful distinct reader content, public visibility, source/license eligibility, valid identity and an approved route. Metadata presence or row count alone is insufficient.
- [ ] Make sitemap and robots/noindex behavior match the publication policy. Crawlers must be able to observe a noindex response. Define pagination separately from UI-only query variants.
- [ ] Do not require redirects for unpublished legacy paths. Test them for future published moves and retain any existing provenance destinations the design explicitly preserves.

## E. Full-corpus backfill and acceptance gates

- [ ] Emit an all-record dry-run manifest keyed by object/page identity: existing kind, page role, candidate family/path, evidence, rule version, confidence/review status and reason. Count by family and outcome, including unchanged, reassigned, ambiguous, unmapped, excluded and colliding rows.
- [ ] Account for 100% of the input snapshot. No unknown classification may silently become an approved fallback.
- [ ] Review source-page conflicts, all conflicting rules and every unresolved record in the proposed launch set. Broader corpus review may remain pending and unpublished.
- [ ] Build an independently reviewed fixture matrix spanning all populated kinds, frequent classes, rare boundaries, source disagreements and same-name collisions. Record expected outcomes before running the implementation. Compare a stratified sample to reviewed evidence; report sample size and errors by family, without claiming whole-corpus accuracy.
- [ ] Require zero known wrong identities, duplicate normalized paths, missing launch assignments, unresolved launch conflicts, broken page references or changed evidence targets. Keep all out-of-scope/deferred records explicitly accounted for.
- [ ] Verify idempotency and stable results after changed import order, label changes, vocabulary updates, repeated backfills and interrupted/resumed runs. Batch progress must be resumable; per-page allocations must remain atomic.
- [ ] Save before/after assignments and rollback information. Reversing a published move must still leave aliases pointing directly to the approved canonical without loops or path reuse.

### Regression matrix

Use the audit's real object IDs as discovery references; CI should create stable fixtures rather than depend on a developer's database IDs.

- Mercury planet/element/god and a Mercury album; separate overview; missing identities must not be fabricated.
- Apple album/fruit, Polish language/breed/disambiguation and Polish/polish lexical records.
- Love emotion and multiple same-title works; C++, C+, c, punctuation-only labels, accented/combining Unicode, non-Latin names, same-name people, translated editions.
- Voltaire philosopher absent versus Aurelio Voltaire present; Putin/poutine editorial association; local subjects with no QID.
- University/campus, country/government, river/river type, planet/geographic place, animal/taxon/individual, substance/product, programming language/software, dish/recipe.
- Apollo 11 and a particular earthquake versus repentance/flypast; recurring series and occurrences; historical and geological periods; fictional character versus work.
- Work/edition/copy, two Mona Lisa records requiring identity review, import reorder, external-class updates, conflicting metadata and incomplete/cyclic hierarchy.
- Alias collisions, simultaneous allocation, empty or overlong slugs, reserved paths, merge/split/retirement, repeated rename, redirect cycles, restore and rollback.
- Direct HTTP plus LiveView navigation: correct status, canonical, JSON-LD, title, indexing, sitemap and retained drawer/trail/cursor identity.

Run targeted tests for new behavior, then project-required `mix precommit`. Verify preserved identity, content and membership sets, not just row totals or successful compilation.

## F. README completion requirement

- [ ] Add/update a prominent **Classification and public URLs** section in `README.md` explaining why the chosen hybrid fits this project, what each external vocabulary contributes, and which route boundaries are local editorial policy.
- [ ] Explain identity vs classification vs page role vs address, including optional QIDs and curated On membership.
- [ ] Link the authoritative ADR, exact registry/rule files and version, full-corpus report, reproduction commands and regression matrix.
- [ ] Show the Mercury, Apple, Polish, C++ and work/edition examples; explain reviewed Subjects fallback versus unresolved classification.
- [ ] Document the procedure for adding a type, adding a family, overriding a classification, renaming/moving a page, rebuilding data and handling a split.
- [ ] State what is implemented, what remains proposed, and how SEO canonicals differ from editorial overviews. Remove contradictory current-architecture claims while preserving explicitly labeled historical decisions.
- [ ] Have the implementing agent demonstrate a new classification/route change using only these docs and linked files. No undocumented live taxonomy lookup or implicit name-based decision should be necessary.
