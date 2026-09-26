# ADR 0002 — Public routing, classification and curated On pages

- **Status:** accepted design, 26 September 2026; production route migration pending.
- **Approval:** the owner accepted the audit recommendations in this conversation and asked for the completed specification and corpus validation.
- **Owner:** project owner; implementation changes are reviewed through the repository's normal PR process.
- **Issue:** [Routing before launch](https://github.com/razrfly/dictionary/issues/194).
- **Policy:** `1.0.0`, [namespace registry](../../priv/routing/namespaces.json), [classification rules](../../priv/routing/classification-rules.json), [pinned vocabulary terms](../../priv/routing/vocabulary-terms.json).
- **Evidence:** [original audit](../audits/2026-09-26-issue194/README.md), [policy validation](../audits/2026-09-26-issue194/policy-readiness.md).
- **Relationship to ADR 0001:** this specifies the replacement for subject addressing in §10. Existing production code still implements the old routes. Registry identities, lexical identities and provenance contracts remain authoritative.

## 1. Decision and scope

Keep permanent local identities, evidence-backed classifications, page identities and allocated public addresses separate. Use eight approved subject families and the separate editorial On role. Borrow semantic meanings from external vocabularies; choose routes through a pinned local policy. No provider response or title change may mutate a published address.

The current implementation work is the **offline reference evaluator and specification**. The next implementation adds persistence, the resolver, reader navigation, metadata and publication controls. No new contextual route is currently deployed.

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

**Retain both lexical routes at launch.** `/words/:id/:slug` continues to address an exact lexeme; `/define/:slug` remains a lexical lookup/aggregation surface. Exact lexical lookup must return 404 for a missing/invalid ID and never substitute a record found by the slug. Search-result selection and provenance drawers retain the selected identity. Search aliases may produce multiple candidates.

The source-specific senses, content revisions, language, part of speech, homographs and inflections remain distinct. Preserve current aggregate lexical reachability, but do not perpetuate lossy slug-based merging. Exact form/lemma lookup precedes a slug-based choice list; capitalization is evidence, not identity equivalence. C++, C+ and c, and Polish/polish, require explicit regression fixtures.

An `/on/:slug` page is a separately authored treatment with a durable page ID, revisioned editorial body and ordered membership. Membership records whether an item supplies lexical material, discusses a subject, or forms an editorial association. Wordplay such as Putin/poutine is an association, never identity or synonymy. On pages are optional: lexical availability cannot depend on someone writing an overview. Do not create an On duplicate for every biography.

## 5. Persistence contract for the implementation

Use separate page tables; **do not add an On registry object kind** or alter entity kinds to fit URLs.

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
- For a prelaunch backfill, evaluate collision groups together. Import order does not choose a primary topic. After publication, the existing owner retains its path and later subjects must qualify; never churn earlier URLs merely because new names arrive.

## 6. Resolver, queries and HTTP

A shared resolver returns explicit results: canonical page, permanent alias, ambiguous choice, missing, retired or unavailable. Generate links through a common page/object-to-path helper. Update home search and Enter behavior, lexical/entity components, provenance drawers, trails, source pages, work catalogues and identity histories. Avoid a catch-all dynamic prefix that consumes account or operational paths.

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

1. Export the read-only corpus and evaluate the pinned rules. Account for every input entity and count the retained lexical population. Preserve ambiguous/unmapped/source-page dispositions.
2. Review a candidate launch population independently of the classifier. Resolve all conflicts in that population; the larger corpus can remain explicitly deferred. Define useful content by reader value and permitted display, not an invented word/page-count threshold.
3. Backfill decisions and durable pages in resumable batches. Save checkpoints keyed by stable object IDs and policy digest. Allocation within each page is atomic; restarting after interruption produces no extra pages or paths.
4. Implement the resolver and link helpers, then metadata/indexing and On editing. Keep classification changes separate from route moves.
5. Prove preservation of identity/content/evidence/membership sets, not just counts. Test a clean restore from registry plus editorial/route snapshots, including a changed provider import order. Replaying source data into newly numbered objects does not satisfy restore acceptance.
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
