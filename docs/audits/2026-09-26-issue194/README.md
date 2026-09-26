# Issue #194 routing and classification audit

**Follow-up:** the owner accepted the recommendations. [ADR 0002](../../adr/0002-public-routing.md) now settles the design, and [policy readiness](policy-readiness.md) records the executable policy's full-corpus results. The B− grade below applies to the original issue version, not the completed handoff.

**Grade: B−, 76/100 against the requested implementation-ready brief.** The architecture is sound; the issue is a strong design proposal. It explicitly calls itself a design issue, so missing implementation is not a defect. The deduction is for decisions and evidence an implementing agent would still have to invent.

**Recommendation:** keep the small public vocabulary and the separation between identity, classification, routes and presentation. Use Schema.org for supported semantic descriptions, specialist vocabularies for detailed evidence, and an explicitly versioned local policy to choose routes. Complete the contracts below before starting the routing migration. More namespace folders do not establish better SEO.

Audited [issue #194](https://github.com/razrfly/dictionary/issues/194), updated **2026-09-26 17:45:12 UTC**, against commit `0d6934641a65a8d650187308bd17feca2fa3f5a2`. Database: local `devils_dictionary_v2`, read-only observations on **26 September 2026**, including development fixtures. The issue's historical code baseline matches this checkout. No production database was queried. The GitHub issue was not edited.

## 1. Score and strengths

| Area | Score | Assessment |
|---|---:|---|
| Identity and semantic architecture | 22/25 | Correct separation; external classes do not automatically own URLs. |
| Corpus evidence and coverage | 15/20 | Historical counts reproduce exactly; proposed assignments have not been validated. |
| Implementation contract | 15/25 | Slug policy, lexical destinations, classification evaluation and page storage remain open. |
| SEO and URL lifecycle | 17/20 | Good canonical and stability principles; needs executable HTTP and indexing rules. |
| Writing and agent documentation | 7/10 | Clear research and proposal/history separation; no README acceptance item or authoritative decision record. |
| **Total** | **76/100** | **Keep the direction; finish the specification.** |

The issue gets several difficult points right: a word is not its referent; an overview is not a subject's canonical page; natural-language names collide; external identifiers are optional; classification can be multiple while a page has one canonical address; published paths should survive name and taxonomy changes. It also correctly rejects arbitrary page-count thresholds for adding namespaces.

The grade is an editorial assessment using this rubric, not a measured classification accuracy. No proposed production classifier exists to score for accuracy.

## 2. Complete-population measurements

[measurements.jsonl](measurements.jsonl) contains the SQL measurements. [screen-summary.json](screen-summary.json) contains the all-entity risk screen. [examples.csv](examples.csv) preserves 54 representative entity records, including all events, editions and artifacts. Every one of the **100,723 entities** was inspected by that screen, with exactly one disposition. Lexical collision measurements cover all **1,541,669 lexemes**. This is full row coverage, with targeted semantic review of boundary examples; it is not a human verification of every subject or article.

### Inventory reproduced from the issue

| Stored kind | Rows |
|---|---:|
| concept | 66,160 |
| taxon | 17,097 |
| work | 8,440 |
| person | 6,863 |
| organization | 1,524 |
| place | 617 |
| event | 14 |
| artifact | 6 |
| edition | 2 |
| other | 0 |

There are also **1,989,579 source senses** and **109,591 content objects**, for **3,741,562 registry objects**. Two entity identities are split; the rest are active. All lexemes are currently English, across 28 parts of speech. The historical totals in the issue are accurate at this snapshot.

### The classification debt is larger than two illustrative mistakes

These direct P31 values occur on records currently stored as `concept`:

| Stored classification evidence | Rows | Candidate family under the proposal |
|---|---:|---|
| [Album, Q482994](https://www.wikidata.org/wiki/Q482994) | 2,425 | Works |
| [Film, Q11424](https://www.wikidata.org/wiki/Q11424) | 1,881 | Works |
| [Television series, Q5398426](https://www.wikidata.org/wiki/Q5398426) | 771 | Works |
| [Video game, Q7889](https://www.wikidata.org/wiki/Q7889) | 520 | Works |
| [Musical group, Q215380](https://www.wikidata.org/wiki/Q215380) | 982 | Organizations |
| [River, Q4022](https://www.wikidata.org/wiki/Q4022) | 557 | Places |
| [Mountain, Q8502](https://www.wikidata.org/wiki/Q8502) | 336 | Places |
| [Inner Solar System planet, Q3504248](https://www.wikidata.org/wiki/Q3504248) | 4 | Nature |

After source-page and metadata-conflict checks, these eight probes yield **7,475 distinct reclassification candidates**. This is a conservative screening result, not 7,475 adjudicated corrections. It excludes many classes and does not follow subclass chains.

The current importer only recognizes a short set of direct classes and otherwise defaults to `concept`; see [Wikidata classification](../../../lib/devils_dictionary/absorb/sources/wikidata.ex#L655). Existing rows remain coarse even where today's importer recognizes a class, as the 1,881 film rows demonstrate. Repairing an import function alone is not an audited backfill. Routing must not trust the stored kind as semantic truth.

### Source-page roles and contradictory evidence

- **5,115** entities have direct P31 `Q4167410` (Wikimedia disambiguation page).
- **738** have `Q13406463` (Wikimedia list article), and **72** have `Q15623926` (Wikimedia set index article).
- Their union is **5,917**, because some records have multiple classifications.
- The separate `metadata.disambiguation` flag is true on **4,942** entities. It misses **436** P31 disambiguation records and flags **263** records without that P31 value.
- For example, **Crocodile Tears 1846395** is described as a novel and **Laris 1877206** as an insect genus, but both carry the disambiguation flag. These require source-evidence reconciliation, not an automatic exclusion based on the flag.

A source's disambiguation page may supply evidence for a local choice page. It is not automatically our curated `/on` article, an abstract concept, or an identity equivalence between its subjects.

### Evidence coverage and naming

- **21,889 concepts** have neither stored P31 nor P279. Missing external classification is not proof that a local identity is invalid. Local reviewed evidence must remain usable.
- **6,794 of 7,332 distinct P31 targets** and **6,698 of 7,936 distinct P279 targets** lack a locally verified Wikidata identity to traverse. A classifier cannot assume the imported subject corpus is a complete class graph.
- **4,263 lowercased entity-label groups** contain 18,602 entities. **4,035 groups still collide within a single stored kind**. Namespace separation leaves most of this naming problem intact. These are label collisions, not proof of distinct subjects or actual normalized-path collisions.
- Lexemes have **58,547 slug groups with multiple exact lemmas**, **28,306 with multiple lowercased lemmas**, and **97,800 spanning parts of speech**.

### All-entity risk-screen disposition

| Disposition | Rows | Meaning |
|---|---:|---|
| Candidate from existing kind | 34,534 | Provisional family; semantic correctness and publication readiness unverified. |
| Reclassification candidate | 7,475 | Eight direct P31 probes disagree with the kind-to-family mapping. |
| Source-page review | 5,917 | Disambiguation/list/index roles need a policy. |
| Metadata review | 260 | Remaining disambiguation-flag conflicts after source-page checks. |
| Boundary review | 21 | Active event, edition or artifact records need role/scope decisions. |
| Identity review | 2 | Split identities. |
| Unresolved concept | 52,514 | The deliberately small probe does not establish a family. |
| **Total** | **100,723** | **Every exported entity accounted for.** |

The unresolved count measures the limited probe's coverage, not the failure rate of the proposed taxonomy. It would be misleading to call the other rows “correctly routed.” Publishable-page counts also remain unknown: a stored label, description, or article attachment does not establish sufficient useful, publicly displayable content.

## 3. Findings that block a dependable implementation

### P1 — Define the classification evaluator and its uncertainty states

The issue lists useful vocabularies but no executable decision contract. Specify source precedence, pinned revisions, allowed relation paths, missing-parent handling, disagreement handling, and manual overrides. An override must record evidence and reviewer rationale and survive reimport.

For instance classification, use a subject's accepted P31 values followed by bounded P279 ancestry; for class subjects, inspect P279 as class evidence. Do not repeatedly follow P31 or use `part_of`, depiction, authorship, relatedness, a matching label, or a candidate lexical link as type inheritance. [Wikidata distinguishes these relations and their inference rules](https://www.wikidata.org/wiki/Help:Basic_membership_properties).

Add cycle detection and explicit outcomes when the graph is missing or truncated. Resolve matching rules by documented precedence and explicit exceptions. Incompatible matches go to review. Generic roots such as Thing or entity must never cause most of the corpus to inherit a family. External lookup belongs in a bounded enrichment job with cached evidence, not a page request.

**Subjects is for a known subject that genuinely falls outside the chosen families.** Unknown identity, contradictory types and missing evidence need separate review states. Otherwise the fallback disguises the very failures the audit is meant to detect.

### P1 — Decide lexical pages separately from curated On pages

The new design names entity families and a curated overview, but leaves the destination of 1.54 million lexical records unresolved. `/define` currently aggregates lexical records; `/words/:id/:slug` addresses one lexeme. Neither is automatically a curated article.

Recommended default: retain a lexical page role and identity-addressed lexical navigation until its replacement is explicitly specified. Create `/on` only for durable editorial treatments with explicit membership. If removing both existing lexical paths is a launch requirement, the design must first specify their complete replacements, including language, homographs, part of speech, inflections and punctuation. That work cannot be inferred from `/on/:slug`.

Prove the same source-sense and content identities remain reachable before and after migration. `C++` must not become `C+` or `c`; `Polish` and `polish` must not merge; love's noun and verb material must survive. The current [WordLive fallback](../../../lib/devils_dictionary_web/live/word_live.ex#L100) can resolve an invalid exact ID by its slug. The new exact resolver must return a missing result instead of substituting a different identity.

### P1 — Finish family boundaries and source-page eligibility

Nature is a workable editorial grouping, but it needs exclusions. Events is particularly risky: stored `event` rows include **repentance**, **flypast**, **Call for Bids**, and **brit milah**—general activities/practices, not particular dated occurrences. **Hero's** is described as an MMA promoter despite its event kind. A smaller count does not imply cleaner data.

Decide class versus instance, recurring events, languages, programming languages, software, food, substances, anatomical structures, breeds, individual organisms, fictional places, historical periods, editions and physical objects. The boundary matrix below gives recommended defaults. Each default must become a versioned rule or an explicit reviewed exception before backfill.

### P1 — Specify a persistent address ledger and identity-safe rebuild

“Allocate transactionally” is right but insufficient. Require a single uniqueness domain covering both current and historical paths; one current canonical per page and locale; nonempty normalized segments; a deterministic, persisted collision decision; retries under concurrent allocation; and reserved operational prefixes.

Meaningful qualifiers can still collide. When author/date/type qualifiers cannot distinguish records, hold allocation for review or use an explicitly approved stable suffix. Do not silently merge records or let import order choose the famous subject. Keep a qualified address once allocated, even if a competing record later disappears.

Preserve registry identities, page identities, path allocations, historical aliases, overrides and On memberships across rebuilds. Replaying providers into newly allocated integer IDs is not sufficient. A rebuild must restore this durable editorial state and prove each old path still targets the same identity. An external QID is not a required replacement key.

### P2 — Turn SEO principles into an HTTP and indexing matrix

The issue correctly distinguishes unique subjects and duplicates. Add observable requirements for initial server responses, live navigation, canonical metadata, JSON-LD, query state, missing paths, identity merges/splits, and sitemap eligibility. Existing `push_navigate` behavior is not proof of a permanent HTTP redirect.

An ordinary unknown path should return 404. A published same-page move should return one permanent redirect to a 200 destination. A genuine identity split needs a useful choice/history page. A retired object may retain a meaningful provenance page; 410 is appropriate only when the resource is deliberately gone. Imported labels, fixtures and unresolved records must not enter the index just because a route can be allocated.

### P2 — Make README and the decision record explicit deliverables

The checklist contains no README task. Worse, the README's old backbone says encyclopedia identity is a Wikidata QID and depicts the retired concept-centric model. The current [registry](../../../lib/devils_dictionary/registry.ex) permits locally created entities and optional external IDs.

This audit updates that summary and adds a clearly marked proposal section. The implementation must also add an authoritative routing ADR, the versioned mapping/rules, regeneration instructions, edge-case examples, and the change process. Update [ADR 0001 §10](../../adr/0001-encyclopedia-model.md) with a supersession link when the replacement is implemented. Do not let historical prose and a new README both claim to define the current canonical system.

## 4. Current examples and recommended destinations

Paths here are **illustrative recommendations**, not allocated or implemented URLs. Stored metadata is evidence for review, not independently verified truth about every subject.

| Existing record(s) | Assessment and proposed handling |
|---|---|
| Mercury planet **1879477**, Mars **1831413**, both `concept` | Nature; `/nature/mercury-planet`, `/nature/mars`. |
| Mercury element / Roman god | Expected Q925/Q1150 identifiers are absent. Add fixtures and verify intended identities before treating the full Mercury example as covered. |
| Apple album **1841806**, fruit **1985448**, both `concept` | Works for album, Nature for fruit as a biological subject. Fruit lacks stored P31/P279, so record reviewed evidence rather than guessing from its label. |
| Polish language **1829906**, chicken breed **1852573**, disambiguation **1852597** | Suggested Concepts, Nature, source-page review respectively. Polish/polish lexical records remain distinct. |
| love emotion **1867856**; Love poems **3737584**, **3739174** | Concepts and distinct Works, with author/version qualifiers after identity checks; an On treatment requires separate useful editorial content. |
| Voltaire lexemes **407799**, **297574**; Aurelio Voltaire **1845556** | Musician is People; do not use him as the philosopher. Q9068 is absent. Name aliases may return several candidates. |
| Putin lexemes **531459**, **206058**, Vladimir Putin **206387**, poutine **325903** | Q7747 and exact-label person/dish entities are absent. Editorial association must not assert identity or synonymy. |
| Ambrose Bierce **1**, lexical name **341814** | One People subject, separate lexical identity. |
| Mount Everest **1838436**, United States **1873905**, both `concept`; Warsaw **1968096**, `place` | Places. A country's government is a distinguishable Organization. |
| Harvard University **1959866**, `concept`; Wikimedia Foundation **3733859**, `organization` | Organizations; Harvard has no stored P31/P279. A separately identified campus is a Place. |
| cat animal **1830860**, Felis catus taxon **1857525** | Nature candidates with distinct identities and an explicit relationship; shared biology does not authorize automatic merging. |
| cat Unix utility **1830738**, CAT TV series **1875719** | Works candidates; software and television need explicit mappings. |
| Cat fictional character **1892804**, Zeus god **1863456**, Zeus fish genus **1857160** | Subjects, Subjects, Nature respectively. Classify the intended referent, not the name. |
| water **1831199** | Nature as a chemical substance. A product, brand or depiction needs its own identity and classification. |
| 1948 Ashgabat earthquake **1876187**, `concept` | Events candidate. General earthquakes belong under Nature; a football team with “Earthquakes” in its name belongs elsewhere. |
| Apollo 11 **3733865**, Theatre Royal disaster **1886855**, Del Águila family killings **1885503**, Killing of Mene Ogidi **1886941**, The Streak **1854978** | Events candidates for particular episodes, subject to source verification. |
| repentance **1901727**, flypast **1877688**, brit milah **1833630**, Call for Bids **1851364** | Concepts candidates for practices/processes; current `event` kind is unsuitable evidence for the proposed scope. |
| Mentioned in Despatches **1851553**, Hero's **1864142** | Review the distinction/award concept and promoter organization respectively. Do not blindly route either by `event`. |
| Remembrance of the Dead **1878772**, Remembrance Sunday **1895205**, European Youth Event **1891666** | Decide observance versus recurring event series. Recommended: cultural observance Concepts; an identified organized event series Events, with occurrences separately identifiable. |
| Mona Lisa **1894610**, **3734402** | Both Works candidates, different QIDs. Investigate whether they are different works/versions or duplicates before choosing qualifiers; the famous title is not proof of identity. |
| The Devil's Dictionary **2**, **3740879**; edition **3** | Work identities also have different QIDs; reconcile first. Edition retains its own identity even if its public family is Works. Do not collapse it into the work URL. |
| Edition **6** (LEME transcription) | Explicit edition route or a precise edition-detail destination; retain evidence links. Suggested public family Works, qualified as an edition. |
| Artifacts **3733873**, **3733876**, **3733878–3733880**, **3733888** | Development fixtures, including a split. Exercise lifecycle routing but exclude from launch publication. A real authored artwork can use Works; a non-art physical object may use Subjects. |

Additional boundary fixtures are still needed for individual nonhuman organisms, synthetic substances, prepared dishes/recipes, named storms, buildings with dual organization/place identity, historical versus geological periods, class subjects, non-Latin names, multilingual editions and metadata conflicts. These are proposed tests, not claims that matching records were found locally.

## 5. Are the external standards a good fit?

**Yes, as complementary sources with a local application policy.** They do not supply a complete, mutually exclusive routing tree.

| Source | Appropriate role | Constraint |
|---|---|---|
| [Schema.org hierarchy](https://schema.org/docs/full.html) | Broad web semantics and structured data. | Types can have multiple parents. No natural one-to-one mapping to these folders. |
| [Wikidata membership model](https://www.wikidata.org/wiki/Help:Basic_membership_properties) | Fine-grained identities and classification evidence. | Store provenance, ranks and review decisions; constrain graph traversal. |
| [SKOS Primer](https://www.w3.org/TR/skos-primer/) | Local family identifiers, labels, scope notes and mappings between conceptual schemes. | A category concept is different from its real-world members. Do not claim equivalence to an external class merely because it suggests a route. |
| [Getty AAT and companion vocabularies](https://www.getty.edu/publications/vocabularies-editorial-guidelines/aat-guidelines/1_about_aat/1.1/) | Art terminology, named artists, places and works. | AAT's generic vocabulary is distinct from named subjects in ULAN/TGN/CONA. |
| [BIBFRAME](https://www.loc.gov/bibframe/faqs/) | Work / publication embodiment / particular copy distinctions. | A bibliographic model does not classify the whole encyclopedia or automatically resolve a painting's work/object identity. |
| [DCMI Metadata Terms](https://www.dublincore.org/specifications/dublin-core/dcmi-terms/) | Describe resource forms where relevant. | The issue links an older Type Vocabulary page that itself points here for current documentation. Update that citation. |
| [Bioschemas biodiversity profiles](https://bioschemas.org/tutorials/howto/howto_right_profile) | Additional guidance for biological taxa and taxonomic names, if needed. | A taxon is not an individual organism. Profiles can inform markup without defining public namespaces. |

The claims about [Person](https://schema.org/Person), [DefinedTerm](https://schema.org/DefinedTerm) and [Taxon](https://schema.org/Taxon) are sound: the proposed People family is narrower than Schema.org Person; DefinedTerm is not every concept; Taxon describes a biological grouping and currently carries the “new” status. Pin the actual release or source revision used, not just a retrieval date. Do not fetch a live vocabulary to make routing decisions at request time.

No universal “Schema.org first, then Wikidata, then Getty” chain is appropriate. Decide the authority by domain and claim. A source can establish a work's identity without establishing biological taxonomy, and two sources can legitimately model different levels of the same subject.

## 6. SEO assessment

The goal should be **one stable canonical per useful page**, with clear links between distinct meanings. Namespace uniqueness is a database and information-architecture property; it is not a demonstrated ranking metric. Google's [URL guidance](https://developers.google.com/search/docs/crawling-indexing/url-structure) supports readable, simple addresses and avoiding unnecessary variants. It does not establish a ranking bonus for maximizing the number of folders.

Keep separate canonicals for a substantive Mercury overview and its planet, element and deity pages. Consolidate equivalent URLs using consistent redirects, canonical links, internal links and sitemaps, following [Google's canonical guidance](https://developers.google.com/search/docs/crawling-indexing/consolidate-duplicate-urls). A generic label-only record should not become an indexable page merely to increase URL count.

Represent the page and its subject as separate linked nodes. Use the supported, evidenced subject type or a broad Thing with an appropriate external type; never invent `schema:Nature`. Verify `sameAs` identity links. Accurate markup can support search features, but [Google does not guarantee rich results](https://developers.google.com/search/docs/appearance/structured-data/sd-policies).

Specify indexing by page role. If using `noindex`, let crawlers retrieve the response so they can observe it; blocking that URL in robots.txt is not an equivalent mechanism. See [Google's indexing controls](https://developers.google.com/search/docs/crawling-indexing/block-indexing). UI-only parameters may canonicalize to the underlying page; pagination that changes substantive content needs an explicit policy rather than blanket removal of all query strings.

## 7. Concrete completion requirements

[issue-addendum.md](issue-addendum.md) provides a ready-to-use implementation-handoff checklist, including the README requirement, proposed defaults, storage invariants, backfill gates and tests. Treat it as a proposed amendment, not an assertion that new routes are implemented or all product decisions have been approved.

The minimum evidence for acceptance is: every input entity and lexical record accounted for; every launch page assigned by an approved rule or exception; no unresolved identity/type conflicts in the publishable set; no path collisions or orphaned references; exact preservation of lexical/evidence membership; repeatable backfills; stable rebuilds; and passing route/HTTP/SEO tests. Semantic precision must be assessed against independently reviewed fixtures and a stratified sample, not against the classifier's own outputs.

## 8. Reproduce the audit

From the repository root, with PostgreSQL running:

```sh
psql -X -q -v ON_ERROR_STOP=1 -h localhost -U postgres -d devils_dictionary_v2 -f docs/audits/2026-09-26-issue194/export.sql > /tmp/issue194-entities.csv
psql -X -qAt -v ON_ERROR_STOP=1 -h localhost -U postgres -d devils_dictionary_v2 -f docs/audits/2026-09-26-issue194/measure.sql > /tmp/issue194-measurements.jsonl
python3 docs/audits/2026-09-26-issue194/screen.py /tmp/issue194-entities.csv --rows /tmp/issue194-screen.csv --summary /tmp/issue194-screen-summary.json
```

Both SQL scripts use repeatable-read, read-only transactions and a 120-second statement timeout. They are separate snapshots; compare their counts if imports are running. The Python script uses only the standard library, has no network access, records an input SHA-256 and checks that each identity occurs once. It performs no route allocation or database writes. Large per-entity CSVs remain temporary; committed summaries and scripts preserve the measurement method. These outputs include development fixtures and are not production or launch-readiness claims.

### Validation

- Re-ran the final SQL measurement script: all ten non-timestamp measurement groups reproduced exactly.
- Reconciled the export, kind totals and screening dispositions: 100,723 entity identities, each accounted for once.
- Checked the report's entity example IDs against the export and verified all local Markdown links in the changed documents.
- `git diff --check` passed.
- `mix precommit` passed: **16 doctests, 1,896 tests, zero failures**; seed 546650, 123.6 seconds of tests. Compilation with warnings as errors and formatting also completed.
- The pre-existing word-page test change and unrelated API audit file were preserved. This work changes documentation and adds read-only audit tooling; it does not implement routes or mutate the development corpus.
