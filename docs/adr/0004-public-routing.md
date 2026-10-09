# ADR 0004 — Public routing, classification and curated On pages

- **Status:** accepted design, 26 September 2026.
  - **Stage 1** is implemented: persistence, ledger, resolver and a tested [recovery procedure](../routing/recovery.md) ([record](../routing/stage-1-foundation.md)).
  - **Stage 2**'s resumable [backfill](../routing/stage-2/backfill.md) is implemented, was rehearsed on copies of the development corpus, and ran on the working corpus on 8 October 2026 ([CP4, #224](https://github.com/razrfly/dictionary/issues/224)): 124 addresses allocated as drafts on the owner's reviews, 5 deferred, 41 not addressed. The owner's [standing review rule](../routing/stage-2/backfill.md#under-the-standing-review-rule-237) decides every later population ([#237](https://github.com/razrfly/dictionary/issues/237) Part A′).
  - **Stage 2**'s backfill was corrected and rehearsed again under [#219](https://github.com/razrfly/dictionary/issues/219): every dependency is checked, and a confirmation is atomic.
  - **The reader (Stage 3)** is implemented under #219. It serves `/on/:slug` as the reading entry, `/words/:id/:slug` for one exact word, and the eight family routes, in public and internal reading modes (§4, §6). It was [demonstrated](../routing/on-demo/README.md) from `main` on a disposable copy of the corpus, and since the move ([#211](https://github.com/razrfly/dictionary/issues/211)) and the reviewed population ([CP4, #224](https://github.com/razrfly/dictionary/issues/224)) it serves the 124 namespace addresses on the owner's working installation in internal mode, as drafts; the public reader shows none until Stage 5 publishes them.
  - Pending: On editing and the page–composition binding (Stage 4); publication, indexing and sitemaps (Stage 5).
- **Approval:** the owner accepted the audit recommendations in this conversation and asked for the completed specification and corpus validation.
- **Owner:** project owner; implementation changes are reviewed through the repository's normal PR process.
- **Issue:** [Routing before launch](https://github.com/razrfly/dictionary/issues/194).
- **Policy:** `1.0.0`, [namespace registry](../../priv/routing/namespaces.json), [classification rules](../../priv/routing/classification-rules.json), [pinned vocabulary terms](../../priv/routing/vocabulary-terms.json).
- **Evidence:** [original audit](../audits/2026-09-26-issue194/README.md), [policy validation](../audits/2026-09-26-issue194/policy-readiness.md).
- **Relationship to ADR 0001:** this specifies the replacement for subject addressing in §10. Existing production code still implements the old routes. Registry identities, lexical identities and provenance contracts remain authoritative.

## 1. Decision and scope

Keep permanent local identities, evidence-backed classifications, page identities and allocated public addresses separate. Use eight approved subject families and the separate editorial On role. Borrow semantic meanings from external vocabularies; choose routes through a pinned local policy. No provider response or title change may mutate a published address.

The offline reference evaluator and this specification came first. [Stage 1](../routing/stage-1-foundation.md) adds the persistence of §5, the transactional ledger and the resolver of §6. Reader navigation, metadata and publication controls follow in later stages. No new contextual route is currently deployed.

The initial corpus contains incomplete classifications and source pages masquerading as subjects. A correct outcome may be `needs_review`. Coverage means every record receives an explicit disposition; it does not mean every record receives a publishable URL. Every namespace must support known local subjects without requiring a Wikidata identifier.

## 2. Families and boundaries

The machine-readable registry is normative for prefixes and scopes. The following rules settle the previously open cases.

| Family | Included | Excluded or separately identified |
|---|---|---|
| People | Human biographies, including pseudonymous authors. | Occupation concepts; fictional or mythological beings; the human species as a taxon. |
| Organizations | Institutions, businesses, governments, bands, teams and organized groups. | A brand alone; buildings/campuses; a country as territory. A dual-purpose institution/site record needs identity review. |
| Places | Named terrestrial sites, rivers, mountains, countries and administrative territories. | Celestial bodies; fictional places; general landform types. |
| Events | Particular occurrences, bounded historical episodes and named organized recurring event series. | General processes/practices, cultural observance concepts and geological/historical period concepts. Series and occurrences can have separate identities. |
| Works | Authored books, music, films, poems, software, visual artworks and recipes; publication editions as distinct edition pages. | A work's subject; a non-art physical object; an individual physical copy merely because its parent is a work. |
| Concepts | Ideas, emotions, languages, programming languages, mathematical concepts, practices, disciplines and cultural/historical periods. | All imported rows called `concept`; general natural phenomena. A software implementation is a Work. |
| Nature | Taxa, breeds, individual nonhuman organisms, celestial bodies, anatomy, geological periods, general natural phenomena and substances, including synthetic ones, considered scientifically. | Human biographies; named terrestrial places; particular dated occurrences; branded products. |
| Subjects | Identified subjects outside those scopes: non-art artifacts, devices, prepared dishes, brands considered independently, fictional/mythological beings and fictional places. | Unknown identity, incomplete typing, contradictions, or a convenient bucket for failed mappings. |

Apply specific scope rules before broad type ancestry: fictional identity overrides human/place/organism classifications; a human biography overrides biological grouping; a celestial body overrides location. Any other incompatible families require review. Broad roots such as Thing, entity, object and physical location do not allocate a family.

Examples: Mercury planet and element → Nature, Mercury deity → Subjects; Apple album → Works, fruit as a biological subject → Nature; Polish language → Concepts, breed → Nature; a particular earthquake → Events, earthquakes generally → Nature; a recipe → Works, prepared dish → Subjects; a museum's organization → Organizations, its building → Places. An artistic representation gets its own Work identity.

**Class versus instance matters.** A biography of a human belongs in People; an article about humans as a species belongs in Nature. A film belongs in Works; film as an art form belongs in Concepts. The evaluator has explicit class-subject rules and never recursively chains instance-of relations.

Imported disambiguation/list/category/index pages retain source identity and provenance but are excluded from automatic subject publication. They can inform an independently authored choice, collection or On page; copying their title never establishes a local editorial identity.

## 3. Classification evidence and evaluation

1. Respect registry lifecycle first: merged, split and retired identities enter explicit identity handling.
2. Retrieve stored evidence by verified external identity and source slug, not a display name or old numeric source metadata. Pin source revision IDs/checksums and the mapping version.
3. Read non-deprecated facts. Preferred statements supersede normal statements for the same property. Qualified statements require review unless an explicit domain adapter can preserve their meaning; unknown/no-value assertions are not positive evidence.
4. For individuals, inspect all accepted P31 values and follow only P279 ancestry. For class subjects, use explicit self/class rules and permitted P279 paths. Do not follow P31 twice. Do not infer types from part-of, authorship, depiction, topical relevance or lexical candidate links.
5. Traverse breadth-first, at most eight subclass edges and 128 visited nodes per input relation set. Detect cycles per path. A missing ancestor, unmapped branch or exhausted limit is recorded and makes the result reviewable. A mapped anchor ends that branch; broad ancestors must not undo a more specific mapped meaning.
6. Apply the explicit precedence table, then require at most one family. Multiple unresolved candidates remain visible in the result.
7. Typed local `work_details` and `edition_details` can support Works candidates without external identifiers. The stored entity kind alone never establishes semantic classification. Other local subjects receive a reviewed classification with evidence/rationale.
8. Emit `mapped`, `needs_review`, `excluded_source_page` or `identity_review`, together with candidate families, rule IDs, supporting paths, source pins and warnings. `mapped` means the versioned evaluator found a consistent mapping in the available evidence. It does **not** grant editorial publication or indexing approval.

The evaluator is [Routing.Policy](../../lib/devils_dictionary/routing/policy.ex). It does not access the database or network. It deliberately holds incomplete branches even when another branch suggests a plausible family.

### Authorities, mappings and overrides

Schema.org is the broad structured-data vocabulary, not a folder taxonomy. Wikidata supplies general identity and type evidence. Getty informs cultural-heritage terminology and named authorities; BIBFRAME informs work/edition/copy distinctions; biodiversity authorities may inform taxa. There is no universal first-provider-wins chain. Each new domain adapter declares which claims its source can establish.

Each mapping records its relation and direction, scope and rationale. A local grouping is not `sameAs` or an exact class equivalence. The pinned term file records upstream revision numbers, meanings and URLs. An updater must produce a reviewed policy diff; readers never fetch upstream taxonomy.

An editorial override stores object/page ID, family, rule/policy version, reviewer actor, timestamp, reason and the exact evidence fingerprint considered. Only the review service writes it; provider JSON cannot set it. An unchanged fingerprint preserves the override across reimport. New contradictory evidence marks the classification for review while the existing published URL stays fixed. Replacing an override produces history rather than erasing the old decision. The offline evaluator intentionally proposes source-based candidates; it does not fabricate overrides or reviewer approvals.

Existing trimmed Wikidata archives omit some qualifiers and references. Preserve that limitation in evidence records; do not claim the archive contains more than it does. Enrichment to retrieve missing detail runs as a bounded job through Req, with cached responses, budgets and explicit failures. It is never part of a route lookup.

## 4. Lexical pages and On pages

**On is the everyday reading entry; two lexical routes, one of them identity** (amended by [#219](https://github.com/razrfly/dictionary/issues/219), 28 September 2026). `/on/:slug` is the **aggregate** lexical reader, resolved exactly as `/define/:slug` was (`Lexicon.lookup/1`, `Lexicon.WordPage`) for every lexeme, and it needs no `pages` row: there are 1.5 million lexemes, and lexical availability cannot depend on someone writing an overview. It reads everything the slug reaches — `C++`, `C+` and `c` share `c`; `Mars`, `mars` and `MARS` share `mars` — and never claims to identify one word. `/words/:id/:slug` addresses the **exact** lexeme: an exact selection (a search result, a card, a drawer) goes there and survives a reload, and a missing or invalid id is a 404 that never substitutes a record found by the slug. `/define/:slug` is removed: nothing has been public, so there is no redirect layer. Search: Enter opens On for the word `Lexicon.lookup/1` finds; a slug several words share is one result opening On, with each word beneath it opening itself; a lone word opens itself. Search aliases may produce multiple candidates.

The source-specific senses, content revisions, language, part of speech, homographs and inflections remain distinct. Preserve current aggregate lexical reachability, but do not perpetuate lossy slug-based merging. Exact form/lemma lookup precedes a slug-based choice list; capitalization is evidence, not identity equivalence. C++, C+ and c, and Polish/polish, require explicit regression fixtures.

An **authored overview** is optional and layers onto the same URL: a `pages` row with role `overview`, a durable page ID, revisioned editorial body and ordered membership, allocated at `/on/<Policy.slug(lemma)>` through the ledger only when authored. Membership records whether an item supplies lexical material, discusses a subject, or forms an editorial association. Wordplay such as Putin/poutine is an association, never identity or synonymy. Do not create an On duplicate for every biography.

**An overview belongs to words by identity, never by a shared label or slug.** It is found only at its allocated address — `/on/:slug` resolves the requested path through the ledger — and nothing re-slugifies a displayed lemma to look for one. It renders above the lexical aggregate, as that aggregate's treatment, only when its current revision holds a `supplies_lexical_material` membership naming one of the aggregate's lexemes or one of their senses; with no lexeme behind it, the overview is the page (200 when served). An overview whose address collides with an unrelated lexical slug is shown as a separate, labelled choice on that page, never as one treatment. From any lexical page, the overviews linked are exactly those whose membership names one of its lexemes, at their allocated paths; an overview links back to each exact word it names. Where the routing slug differs from the lexeme slug (`/on/c-plus-plus` for `C++`, whose lexeme slug is `c`), the two pages link each other and neither redirects to the other.

**Subjects on an On page** come from two sources, kept apart on the page. **Curated** members — an overview's current revision's `discusses_subject` and `editorial_association` members, in stored order, with their relationship — are authoritative; a member whose name differs from the page's title is still a member, and a withdrawn, retired or missing member is withheld, never replaced. **Discovered** candidates — the lexical page's thing and disagreement, `Encyclopedia.candidates_for/2`'s `may_refer_to`, and active entities whose preferred label or recorded name equals a lemma after NFC and case folding — are labelled as unreviewed, deduplicated by object identity (never by label), exclude anything curated, and are sorted addressed first (served in the reading mode), then by family, label and id, capped with the total kept. Subject and edition pages both count. One bounded statement reads every card's state from its current classification decision and page (`Routing.Subjects`). A card shows an address only where the mode serves it, and a withdrawn page reads as none, in both modes, as a request for its address does. The section reads state and never writes it.

**Reading modes.** Links and direct requests are decided in one of two modes (`Routing.Resolver`'s `mode:`). **Public** serves only published pages. **Internal** also serves drafts, marked as drafts; it changes no publication state, approval or ledger row. Withdrawn pages are withheld in both, lifecycle rules (merged, split, retired, tombstones) are identical in both, and an alias or equivalent spelling answers with its destination's outcome in the same mode, so a public request never redirects to a draft. The same rules govern an overview and each of its members. The mode comes only from trusted configuration (`:internal_reading`, set in development and test and refused by a test in production configuration) or from an authenticated internal contributor or reviewer, read from the database; no request parameter can set it. Configuration that turns it on for every local request is a development convenience, so a development server with drafts must not be exposed through a tunnel.

**External standards inform classification; they do not prescribe the URL taxonomy.** Schema.org and Wikidata supply evidence about which family a subject belongs to (through `classification-rules.json` and the pinned vocabulary); the eight families and their paths are this site's own editorial scheme.

The page–composition binding below stays deferred: the reader renders authored overview revisions and their memberships, and does not deliver Stage 4. `Curation.Published` is not yet wired into the reader; the curated opening (#202) keeps its development-only fixture reader.

### Interface with curation persistence

[Curation persistence](https://github.com/razrfly/dictionary/issues/196) owns `editorial_compositions`, their immutable versions/items and human presentation approval. Routing owns page identities, paths, authored On bodies and page publication/indexability. `page_revisions` must not become a competing composition or ballot store.

Bind a page to a composition through an explicit, audited relationship between durable IDs, with at most one active binding per page. Validate language and intended scope/membership compatibility; a shared label or URL cannot establish a binding. Preserve both identities across route moves and scope changes. Render only the version selected by the composition publication service and still eligible under its rights/evidence checks. A routing-page approval cannot approve a draft composition or an unaccepted semantic claim.

Define this interface before the first schema implementation. Use actual foreign keys when the composition schema is available. If that work has not landed, defer the binding migration and continue with standalone manual On pages; do not create placeholder composition tables. The binding table's columns and rules are [recorded with Stage 1](../routing/stage-1-foundation.md#curation-composition-binding-recorded-migration-deferred); [#206](https://github.com/razrfly/dictionary/pull/206) created the composition schema on 27 September 2026, and the binding migration, with real foreign keys, belongs to Stage 4. Persona inference and visit-driven refresh are separately owned by [curated opening delivery](https://github.com/razrfly/dictionary/issues/193) and are not dependencies of the routing foundation.

## 5. Persistence contract for the implementation

Use separate page tables; **do not add an On registry object kind** or alter entity kinds to fit URLs. [Stage 1](../routing/stage-1-foundation.md) implements this table, maps each invariant to its database enforcement and test, and records eight implementation decisions (role namespaces, mapped-family allocation, human approvals, one page per target and locale, split pages keeping their address, reservations never released, refusals that never roll back a caller, tombstones returning only by a human restore or rollback).

| Table | Required data and integrity |
|---|---|
| `pages` | Durable bigint ID, role, locale, optional target object FK, publication state, canonical-path FK and current editorial revision FK. Roles: subject, edition, lexeme, overview, collection, choice. Target-object and role compatibility enforced at commit. Subject/edition share one unique target-object + locale constraint; lexeme has its own target + locale constraint. |
| `page_revisions` | Immutable page ID + revision number, editorial body, title, author/reviewer actors and evidence. Composite FK ensures a page's current revision belongs to that page. |
| `page_memberships` | Page ID, exactly one target object FK or target page FK, relationship role, order, rationale/evidence and revision history. Membership is not an identity assertion. |
| `public_paths` | Unique normalized full path, immutable original owner page, current destination page, kind (canonical/alias/tombstone), allocation record and history. The same uniqueness domain covers every kind. |
| `classification_decisions` | Object ID, candidates/selected family, status, rule and policy version, source pins/fingerprint, reviewer and override history. It is independent of the route assignment. |
| `route_changes` | Append-only before/after paths and targets, policy/decision reference, actor, reason, timestamp and rollback information. |

Published pages must have exactly one current canonical per locale. Enforce this with a unique partial canonical-destination index plus deferred consistency checks between the page's canonical-path FK and the path's destination/role. An alias/tombstone cannot also be another page's canonical. Historical path ownership is immutable. A redirect destination may change only for an approved equivalent page move/merge, with a route-change record; it cannot be repurposed for an unrelated subject.

Allocate under a transaction and a lock for the normalized path: insert/reserve path, update the page's canonical pointer and write history atomically. The unique index is the final arbiter under concurrency. Retry a serialization/unique race at most three times, then return an explicit allocation conflict; no caller invents a random route. Lock multiple pages in ID order for merges/moves. Test with independent concurrent database connections, not sequential inserts disguised as concurrency.

Aliases target the approved destination page, whose current canonical is resolved directly; they never target another alias. Redirect cycles and page-membership cycles are separate concerns. For redirects, validate acyclicity transactionally and return one HTTP hop. Keep a configurable operational error path for corrupt resolver state; never guess a destination.

### Slug and locale decisions

- Launch locale is `en`, with unprefixed English paths. Reserve `/l/:bcp47/:family/:slug` for future translated pages. A page locale is distinct from a subject's language and a source's language. Translation creates a locale-specific page without changing the subject identity.
- Generate slug proposals using NFC, Unicode lowercase, letters/marks/numbers and hyphens. Preserve non-Latin letters and accents. Expand `+`, `#`, `&` and `.` to `plus`, `sharp`, `and` and `dot`; remove apostrophes; collapse other separators. Reject empty proposals and segments over 120 UTF-8 bytes; do not silently truncate. [Policy.slug/1](../../lib/devils_dictionary/routing/policy.ex) is the executable proposal contract.
- URI-encode each segment when generating links. Resolve request paths by one validated URI decode, NFC and lowercase—not by rerunning label slugification. Reject malformed encodings, encoded path separators, NUL, dot segments and invalid segments. Normalize an equivalent case/Unicode/trailing-slash variant only when it resolves to one reserved path, then 301 to that canonical.
- Namespaces come only from the registry. Its reserved prefixes cover all current application, account, evidence, transport, asset and infrastructure routes. Article titles cannot create root routes. Reserve future locale and sitemap entry points before allocation.
- Where a base name collides, propose reviewed meaningful qualifiers: person context, work creator/year/type, edition details, scientific distinction or location. Review possible duplicate identities before qualifying. If qualifiers still collide or lack evidence, hold the route for review. **No automatic opaque suffix in v1.** The owner can approve a specific readable unique slug without changing identity.
  - *Amended by [#237](https://github.com/razrfly/dictionary/issues/237), 9 October 2026.* A readable qualifier generated under the owner's signed **standing review rule** (`priv/routing/review-rule.json`, `Routing.ReviewRule`) is an owner-approved slug. The rule generates it from the record's own evidence under the proposal rules above (`Routing.Qualifier`, the twin of `candidates.py`), takes it only where the population derived from the same export proposed the same path and found it free, only where the label and the qualifier are readable (nothing the slug would have to spell out as a word: `#`, `.`, `+`; an address the policy would spell from punctuation is deferred for a human to name, as the owner named three by hand in #224), and confirms a collision group only whole: a group with any member it cannot qualify — a classification or duplicate-identity review, no evidence, a qualifier that still collides or is held — is deferred whole, never qualified by import order. It never generates an opaque suffix, never chooses a family, and never moves an address a human or the rule already allocated. Signed once, the rule is the owner's standing decision; its digest is recorded in the run key, on every override it writes and on every publication made under it.
- For a prelaunch backfill, evaluate collision groups together. Import order does not choose a primary topic. After publication, the existing owner retains its path and later subjects must qualify; never churn earlier URLs merely because new names arrive.

## 6. Resolver, queries and HTTP

A shared resolver returns explicit results: canonical page, permanent alias, ambiguous choice, missing, retired or unavailable. Generate links through a common page/object-to-path helper. Update home search and Enter behavior, lexical/entity components, provenance drawers, trails, source pages, work catalogues and identity histories. Avoid a catch-all dynamic prefix that consumes account or operational paths.

**As served ([#219](https://github.com/razrfly/dictionary/issues/219)).** Subject pages live at eight explicit routes — `/people/:slug`, `/organizations/:slug`, `/places/:slug`, `/events/:slug`, `/works/:slug`, `/concepts/:slug`, `/nature/:slug`, `/subjects/:slug` — never a catch-all, answered only by `Routing.Resolver` in the request's reading mode; the page shows the entity's content with its family, a draft mark internally, the way back to On and the external identifier, and keeps the address's provenance (allocation, decision, evidence fingerprint) in an inspection drawer. `/entities/:id/:slug` stays the exact-identity route for a subject with no address. Every internal subject link goes through one helper, `Routing.Links`, which asks the resolver in the current mode and otherwise falls back to `/entities`; no caller derives a namespace from a stored kind or rebuilds a slug. `DevilsDictionaryWeb.ReadingStatus` answers a direct request before the LiveView renders: 301 with `location` for an alias or equivalent spelling of a page served in the mode, 404 for missing or not served (a draft, publicly), 410 for a tombstone of a page the public saw, 400 for a malformed path, 500 (logged, with diagnostics) for inconsistent ledger state; `/on/:slug` is 404 with did-you-mean when neither words nor a served overview answer it, and `/words/:id/:slug` is 404 for a missing id. Live navigation follows redirects in the LiveView itself.

| Request/result | Required behavior |
|---|---|
| Published canonical | Initial GET/HEAD 200; useful server-rendered content; exactly one canonical and appropriate metadata. |
| Published equivalent old path | 301 directly to the current 200 canonical; internal links and sitemap already use the destination. |
| Unknown exact path/ID | 404, without name-based substitution or a label-only success page. |
| Identity merge | Approved survivor if page purpose is equivalent; retained identity history. Otherwise keep an explanatory page pending page-level review. |
| Identity split | Useful choice/history page, with explicit successors and unresolved attachments retained. Never arbitrarily choose one successor. |
| Retirement | Retain a useful history/provenance page when warranted; deliberately removed resources return 410. Reserve their old paths. |
| Corrupt/cyclic resolver state | Operational failure with diagnostics; never a guessed identity, redirect loop or unrelated fallback page. |

The no-legacy-public-URL premise applies to the launch migration; do not build mass redirects for unpublished subject paths. Existing evidence URLs retain their exact revision semantics. Future published moves must use the ledger and redirect behavior above.

UI-only `from`, `trail`, provenance-drawer state and validated display state may be preserved in navigation while the canonical names the underlying page. Development `demo` views are never indexable. Discovery/filter combinations are noindex and omitted from sitemaps. Entity section cursors are non-indexable UI variants with a stable base canonical; material reachable only through those cursors must also have direct canonical object/evidence links. Any future independently indexable paginated collection must have its own URL and canonical instead of pointing every page at page one. All query parsing remains allowlisted and bounded.

## 7. SEO and publication gate

One canonical represents one useful page and locale. A substantive On treatment and distinct subject pages each have their own canonical. Consolidate only equivalent URLs. Namespace count is not an SEO success metric; track correct identity, useful content, index coverage and canonical consistency.

Separate the WebPage/Article/CollectionPage node from its main subject in JSON-LD. Use evidenced subject types, verified identity links and stable internal node identifiers. Never emit `schema:Nature` or force every concept into DefinedTerm. A fallback subject can be a Thing with an appropriate externally identified additional type. Emit initial server-rendered head data and update it correctly on live navigation. Do not expose licensing-restricted bodies through markup.

Publication requires **all** of: resolved identity; approved classification/exception; unique allocated path; useful distinct public content; permitted display/licensing; editorial approval; complete canonical/metadata; no known blocking integrity issue. Fixture status and imported-label status cannot pass this gate. Classification mapping alone satisfies none of the other approvals.

The publication manifest explicitly lists approved page IDs/locales and their gates. An empty manifest is not a successful launch. Sitemaps contain only approved, indexable, canonical 200 pages; maximum 50,000 URLs and 50 MB uncompressed per sitemap, with an index when needed, following [Google's sitemap limits](https://developers.google.com/search/docs/crawling-indexing/sitemaps/build-sitemap). Last-modified timestamps reflect content changes, not audit runs. Search, raw evidence, operations, fixtures, unresolved pages and uncurated lookup variants are noindex by default; useful lexical pages can be approved independently of On. Let crawlers retrieve noindex responses. Treat operational access control separately from indexing.

## 8. Migration, verification and maintenance

[Implementation rollout and agent prompt](../audits/2026-09-26-issue194/implementation-rollout.md) orders this contract into five reviewable stages under the existing routing delivery issue. It includes related-work boundaries and the specification-review checkpoint.

1. Export the read-only corpus and evaluate the pinned rules. Account for every input entity and count the retained lexical population. Preserve ambiguous/unmapped/source-page dispositions.
2. Review a candidate launch population independently of the classifier. Resolve all conflicts in that population; the larger corpus can remain explicitly deferred. Define useful content by reader value and permitted display, not an invented word/page-count threshold.
3. Backfill decisions and durable pages in resumable batches. Save checkpoints keyed by stable object IDs and policy digest. Classify only while every record the evaluation depended on — matched, visited without a match, or looked for and absent — is still what the export saw. A reviewer's confirmation is atomic per record: its override, page, path and ledger rows are written together or, on any refusal, not at all, and the batch continues. Restarting after interruption produces no extra pages or paths.
4. Implement the resolver and link helpers, then metadata/indexing and On editing. Keep classification changes separate from route moves.
5. Prove preservation of identity/content/evidence/membership sets, not just counts. Test a clean restore from registry plus editorial/route snapshots, including a changed provider import order. Replaying source data into newly numbered objects does not satisfy restore acceptance. The supported [recovery procedure](../routing/recovery.md) and its test implement this; destructive tasks refuse a database holding routing state without a covering snapshot.
6. Use a feature flag for launch. Verify direct HTTP and live navigation, then publish only the approved manifest. Rollback restores the previous accepted mapping/reader behavior and preserves path reservations and historical redirects.

To add a detailed type: declare authority, pin evidence, write inclusion/exclusion examples and expected fixture outcomes, amend the rule file, bump policy version, run the full dry run and review changes. A new public family additionally needs owner approval, a scope/overlap charter and migration analysis. A rename updates the label by default; an intentional public move uses a route-change transaction. A split retains choices until attachments have been reviewed. Rebuilds restore durable identity, editorial state, overrides and the address ledger before source projections.

### Required implementation tests

- Golden examples for every family and populated entity kind; missing Mercury/Voltaire/Putin identities use deliberate CI fixtures, not fabricated local records.
- C++, C+, c, Polish/polish, accents, combining Unicode, non-Latin names, empty/long labels, same-name people/works, editions and reserved paths.
- Conflicting/missing/deprecated/qualified type evidence, incomplete/cyclic graphs, local identities without external IDs and versioned overrides.
- Concurrent allocation, repeat backfill, crash/resume, provider reorder, renamed labels, vocabulary upgrades, restore and rollback. Inspect exact destinations and references.
- Real HTTP status and redirect headers alongside LiveView tests. Test missing IDs, equivalence moves, chains, loops, merges, splits and retirement.
- Source-sense/content/evidence sets and selected identity survive lookup, Enter, drawers, trails, collections and pagination.
- Canonical/JSON-LD/title consistency, noindex policy, sitemap membership and publication gates for each page role.

The reference evaluator's tests cover mapping and audit behavior only. Transactional allocation, resolver HTTP behavior, On editing and publication tests are **mandatory work in the route implementation**, not claims made by the offline audit. Run targeted tests and `mix precommit` for that implementation.

## Sources

The design is our application policy informed by the [Schema.org hierarchy](https://schema.org/docs/full.html), [Wikidata membership rules](https://www.wikidata.org/wiki/Help:Basic_membership_properties), [SKOS Primer](https://www.w3.org/TR/skos-primer/), [Getty vocabulary scope](https://www.getty.edu/publications/vocabularies-editorial-guidelines/aat-guidelines/1_about_aat/1.1/), [BIBFRAME distinctions](https://www.loc.gov/bibframe/faqs/), and current [DCMI Metadata Terms](https://www.dublincore.org/specifications/dublin-core/dcmi-terms/). SEO behavior follows [Google's URL guidance](https://developers.google.com/search/docs/crawling-indexing/url-structure), [canonical guidance](https://developers.google.com/search/docs/crawling-indexing/consolidate-duplicate-urls), and [structured-data policies](https://developers.google.com/search/docs/appearance/structured-data/sd-policies). These sources do not prescribe this site's folder layout or promise ranking gains.
