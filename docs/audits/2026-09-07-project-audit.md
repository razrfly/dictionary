# Wordhoard project audit — 7 September 2026

**Overall grade: B− as a foundation for the intended product. B+ for the static MVP-0 engineering; C for readiness to grow into a living, participatory encyclopedia.**

The project deserves to continue on its current Phoenix/Postgres architecture. It does not need a rewrite or a graph database. It does need a correctness milestone before durable community contributions, automated refreshes, or public deployment. The claim that the remaining work is only design, and that the original thirteen tables need never change, is not supported by this audit.

These grades are engineering judgments, not an average of the existing scorecard. Unbuilt roadmap features are not bugs; their absence limits what the current system proves.

## Scope and evidence

Audited local commit `a2ef867`, confirmed to match GitHub `main`, with a clean starting working tree and `origin` set to `https://github.com/razrfly/dictionary.git`. Read the README, model documentation, schema, ingestion/materialization/resolution/linking paths, read contexts, LiveViews, workers, configuration, and relevant tests. Retrieved GitHub issues [#69](https://github.com/razrfly/dictionary/issues/69), [#64](https://github.com/razrfly/dictionary/issues/64), [#65](https://github.com/razrfly/dictionary/issues/65), and [#67](https://github.com/razrfly/dictionary/issues/67).

Ran `mix precommit`: **487 tests, zero failures**, including compilation with warnings as errors and formatting. Reproduced the full Animals scorecard with parity: **36/36 graded, 1 report, zero pending**, in 25.1 seconds. Ran Emotions with `--skip-parity`: **34/34 graded, 2 reports, 1 explicitly skipped parity row**; the Animals run already checked parity across all six sources. M2 in these scorecards reads historical rebuild records; this audit did not independently destroy and rebuild the development database.

Used read-only SQL against the development corpus. Ran adversarial refresh probes in the test database under Ecto SQL Sandbox and rolled them back. Used the running browser to test search → result navigation and inspect the real cat page and its provenance drawer. No product code or development data was deliberately changed. This is not a full penetration test, load test, current mobile certification, or source-licensing opinion.

Saved evidence: [Animals scorecard](evidence-2026-09-07/animals-scorecard.txt), [Emotions scorecard](evidence-2026-09-07/emotions-scorecard.txt), [isolated refresh reproduction](evidence-2026-09-07/refresh-probes.exs), and [reproduction output](evidence-2026-09-07/refresh-probes-output.txt). To reproduce against the test sandbox, run `MIX_ENV=test mix run docs/audits/evidence-2026-09-07/refresh-probes.exs` from the project root. The script rolls back its data; it prints observed defects rather than asserting the desired behavior.

## Where the product actually stands

| Measure | Current observation |
|---|---|
| English lexical rows | 1,541,669 |
| Rows marked enriched | 195,368, approximately 12.7% |
| Rows with neither a sense nor a lexical entry | 1,346,326, approximately 87.3% |
| Raw records across six sources | 344,635 |
| WordNet | 120,564 records; 212,659 senses; 1,047,918 resolved edges |
| Wiktionary enrichment | 22,534 raw records; 37,730 senses |
| Historical texts | 997 Bierce entries; 42,726 Johnson entries |
| Wikipedia | 70,925 entries, including duplicate article representations |
| Scope membership | Animals 25,402; Emotions 809 |
| Animals high-confidence linking | 58.6% of all scope rows; scorecard reports 82.5% against its reachable denominator |
| Emotions high-confidence linking | 37.2% of all scope rows; 49.2% against its reachable denominator |
| Search p95 | 65 ms and 92 ms in the two local scorecard runs |

The distinction between lexical rows, distinct written words, and useful pages matters. The 1.54 million figure includes parts of speech, forms, casing, and symbols. It establishes breadth of an imported index, not universal coverage of English or 1.54 million fully defined words.

Representative reads:

| Word | Source cards | Linked primary concept |
|---|---|---|
| cat | 8 cards from 5 sources | cat |
| joy | 7 cards from 4 sources | joy |
| nepotism | Johnson, Bierce, WordNet | none |
| bank | Johnson and WordNet | none |
| performative | none | none |
| situationship | none | none |

This fulfills much of the absorption-first skeleton in #69. It does not yet deliver the central participatory experience in #64/#67. Users, submissions, moderation, votes, bots, first-class verified quotations, real evidence media, feeds, API, PWA, and iOS remain unimplemented. `?demo=1` is a useful layout exercise and is isolated from scoring, but is not evidence those features work.

The older issues still refer to `TopicLive`, definitions, and `TopicRelationship`; these are obsolete implementation names. Their product intent must be translated into the current model before implementation. The README's newer aggregator-only rule also supersedes #64's allowance for editor-written definitions.

## What should be kept

**Words and things are correctly separated.** A source-specific sense is not a universal concept. Keeping definitions from different sources separate preserves the disagreements and historical perspectives that make this product interesting. Optional sense-level concept links are the right direction.

**The modular monolith is appropriate.** Phoenix LiveView, Ecto/Postgres, Req, and Oban fit this workload. The contexts provide a useful boundary between sources, lexicon, encyclopedia, ingestion, and presentation. Pure materializers, batched transactions, keyset pagination, raw payloads excluded from ordinary queries, and explicit source attribution are good choices. Recursive SQL and indexed adjacency tables are sufficient for the demonstrated traversal workload.

**Extensibility has real evidence.** Johnson was absorbed without a new domain migration. Emotions uses a data-defined scope. These experiments establish that another compatible source or scope is practical. They do not establish that every future content model fits unchanged.

**The test suite is substantial.** Fixtures, offline HTTP testing, transaction failure tests, and LiveView interaction tests provide useful regression protection. The provenance drawer works on the inspected card and exposes the cited raw records. Source text rendering escapes HTML before generating the supported markup.

## Findings to address before expansion

### 1. P1 — Refresh is additive; withdrawn assertions survive

The materializer upserts emitted rows but does not reconcile the old output set against the new one. The linker likewise inserts/updates currently found links without removing unsupported old links. Forms and pronunciations fill empty slots; etymology keeps its old non-null value; metadata is merged. These are initial assembly policies, not adequate source-update policies.

An isolated real-Wiktionary-adapter probe started with two meanings, an old form, a hypernym, and a QID. After replacing the raw record with one meaning, a new form, no hypernym, and no QID:

- Two sense rows remained, both now reading “second meaning.”
- The old hypernym remained.
- The old concept link remained.
- The form still read `oldform` rather than `newform`.
- Parity reported **zero gaps**.

The same general risk applies to deleted dictionary entries, changed taxonomy, and successful records becoming absent. Source records are themselves overwritten rather than versioned, so the earlier evidence is not retained as an intentional historical version.

**Required outcome:** distinguish current assertions from historical assertions; reconcile outputs per source record/version; retain enough ownership information to retract only the relevant source's contributions. Shared lexemes and concepts should survive when other sources still attest them. Prefer tombstoning/versioning over deleting identity objects that people will reference.

Evidence: [materializer](../../lib/devils_dictionary/absorb/materializer.ex), [source upserts](../../lib/devils_dictionary/sources.ex), [linker](../../lib/devils_dictionary/absorb/linker.ex).

### 2. P1 — Meaning identities are not durable

Wiktionary sense keys are `word/pos/etymology_number#position`. Reordering or inserting meanings changes what an existing database ID denotes. In the probe above, the ID for “first meaning” was overwritten with “second meaning.” Existing relations and future quotations, votes, or examples could silently move to a different meaning without any foreign-key violation.

**Required outcome:** define stable source assertion identity and versioning before attaching user-owned content. Use upstream IDs where dependable; otherwise reconcile changes explicitly and flag ambiguous matches. A content hash alone also changes when wording changes, so this needs an identity policy rather than just a new hash column.

Evidence: [Wiktionary sense construction](../../lib/devils_dictionary/absorb/sources/wiktionary.ex), [sense upserts](../../lib/devils_dictionary/absorb/materializer.ex).

### 3. P1 — Page identity loses distinctions preserved by the database

The schema distinguishes spellings, but slugification folds punctuation and accents. Searching for **C++** and clicking the result navigated to `/define/c`, whose heading was **-c-**, with many unrelated parts of speech and definitions. The database has **28,306 slug groups containing more than one distinct lowercased lemma**. Some are legitimate spelling variants; this count is not a count of independently adjudicated bugs.

Examples include `C++`, `C+`, and `c` in the `c` group, and `resume`, `resumé`, and `résumé` in one group. Grouping parts of speech is sensible; implicitly asserting equivalence because a slug generator discarded characters is not.

**Required outcome:** use a lossless word identity in URLs, or a stable ID plus cosmetic slug. Make spelling/case aggregation an explicit presentation decision. Test exact search selection through actual navigation, not only direct lookup and successful page construction.

Evidence: [slug generation](../../lib/devils_dictionary/lexicon/lexeme.ex), [lookup](../../lib/devils_dictionary/lexicon.ex), [home search](../../lib/devils_dictionary_web/live/home_live.ex).

### 4. P1 — One Wikipedia article becomes several displayed entries

The cat page renders the same 1,840-character Wikipedia summary **six times**. SQL confirms six entries with the same body hash and concept, originating from `cat`, `domestic cat`, `Felis catus`, `Felis domesticus`, `house cat`, and `concept:Q57818409` probe records.

Across the database, **3,852 concepts have multiple Wikipedia entries, with 6,173 entries beyond one per concept**. That broader count measures multiplicity; the cat example verifies identical displayed duplication.

Entries are unique by `(source_record_id, position)`, while a source record represents a probe rather than a canonical Wikipedia article. The renderer then displays every entry. This confuses retrieval history with publication identity.

**Required outcome:** preserve all probe evidence while normalizing articles by source + canonical page identity, with explicit redirect handling. Render each article once and keep its supporting records accessible in provenance. Do not simply delete duplicates while parity still expects one output per probe.

Evidence: [Wikipedia entry materialization](../../lib/devils_dictionary/absorb/sources/wikipedia.ex), [entry card assembly](../../lib/devils_dictionary/lexicon/word_page.ex), [entry unique index](../../priv/repo/migrations/20260905094219_create_lexicon_schema.exs).

### 5. P1 — Public routes can enqueue imports and trigger expensive diagnostics

`/admin/imports` and `/health` use the ordinary browser pipeline in all environments. No authentication or authorization guards the import event. An ordinary connected visitor can enqueue absorb jobs. Health exposes full-source parity and cache-bypassing recomputation. The workers do not specify job uniqueness, so repeated submissions can queue repeated work.

This is a deployment blocker, not a claim that the localhost instance has been attacked. CSRF protection does not restrict a visitor who can load the page legitimately.

**Required outcome:** protect operational routes and server-side events, validate source/scope arguments, and coalesce duplicate jobs. Separate operational work from public reading capacity.

Evidence: [router](../../lib/devils_dictionary_web/router.ex), [import event](../../lib/devils_dictionary_web/live/admin/imports_live.ex), [health events](../../lib/devils_dictionary_web/live/health_live.ex), [worker](../../lib/devils_dictionary/workers/absorb_worker.ex).

### 6. P2 — The scorecard measures less than its names imply

M1 checks the presence of expected natural keys, not field equality or unexpected extra rows. It does not directly compare lexeme fields or concept links. After deliberately replacing stored glosses with `CORRUPTED` in the isolated test, parity still returned zero gaps. M2 compares counts from a historical replay, not semantic equality or reconstruction from an empty derived database.

Other limitations:

- X1 builds a page struct for 200 samples; it does not verify the selected word survives routing. This misses the C++ defect.
- U3/U6 use six named words, not every page. Link-out presence does not prove the remote URL works.
- U4 checks that dated screenshots exist; it does not measure current mobile behavior.
- E3 checks that the sketch file exists; a migration applying successfully says little about relationship semantics.
- E1 fails when total migrations differ from two, so a healthy future migration would fail the historical extensibility claim.
- O3 is a literal pass in the scorecard. The independently executed precommit suite is the evidence that tests currently pass.
- A7 calls a global Wikipedia coverage query even when the scorecard is scoped to Emotions.
- L1 divides all qualifying linked scope words by a separately counted reachable population, without intersecting its numerator with that population. Treat it as the implemented ratio, not a rigorously measured conditional success rate.

Animals and Emotions also have different configured link/image thresholds. This is reasonable for different domains, but green scores do not mean equivalent coverage. Neither scope score measures human-judged link precision.

**Required outcome:** separate live measurements, sample checks, historical attestations, and product acceptance. Add bidirectional semantic parity, stable-identity assertions, actual navigation tests, and a human-reviewed linking evaluation set across domains.

Evidence: [parity](../../lib/devils_dictionary/health/parity.ex), [score rows](../../lib/devils_dictionary/health/score.ex), [page probes](../../lib/devils_dictionary/health/pages.ex), [coverage queries](../../lib/devils_dictionary/health.ex).

### 7. P2 — Relationship confidence, ambiguity, and editorial decisions need stronger semantics

The link ladder is an explainable heuristic, but `0.85` is not an empirically established 85% probability. Two shared words of four or more letters promote a title match to 0.85; no linguistic disambiguation or measured calibration justifies interpreting it probabilistically.

Multiple meanings are classified as “disagreement” whenever multiple concepts are asserted across the lexemes supplied to the page. Cat the animal and cat the Unix utility are ordinary polysemy; they do not establish that sources contradict each other. The UI says “the sources name more than one thing,” which is more careful than the internal disputed/conflict terminology, but the model still conflates the cases. One primary concept is selected for the whole page, so secondary meanings do not get an equivalent browsable concept panel.

A separate isolated test marked an automatic QID link `rejected`, reran that rung, and observed it return to `auto`. A separate manual-method row is not the same as preserving a rejection of a machine-generated assertion.

**Required outcome:** distinguish ambiguity, unresolved matching, conflicting claims about the same meaning, and explicit editorial judgment. Preserve editorial decisions across recomputation. Keep method/evidence separate from confidence, and calibrate only if probabilities are needed.

Evidence: [linker](../../lib/devils_dictionary/absorb/linker.ex), [candidates and disagreement](../../lib/devils_dictionary/encyclopedia.ex), [primary concept selection](../../lib/devils_dictionary/lexicon/word_page.ex).

### 8. P2 — Some graph assertions are already semantically unsafe

The Wikidata readers return statement values regardless of rank. The stored corpus contains **906 deprecated statements** among retained properties, and **131 stored concept edges match deprecated statements**. This does not establish that every matching edge lacks separate valid support, but it demonstrates the path is ingesting deprecated evidence without distinguishing it. Wikidata says deprecated statements represent erroneous or formerly believed knowledge and should be excluded from default queries; preferred statements take precedence where applicable. [Wikidata ranking documentation](https://www.wikidata.org/wiki/Help:Ranking).

The trimmer preserves rank but removes statement IDs, qualifiers, and references. The derived graph stores the provider/property but not the originating statement. That is insufficient for explaining why a historically qualified claim applies now or which evidence supports an edge.

The current database also contains **five reciprocal canonical pairs**: paddymelon/pademelon, Jacobin/jacobin, flatty/flattie, marten/martin, and gill/jill. The resolver's two-cycle check can miss simultaneous updates, because both sides are chosen against the prior state. This is a real canonicalization invariant failure, although the inspected lookup follows one hop rather than recursing indefinitely.

**Required outcome:** apply an explicit Wikidata rank policy, retain minimal statement identity and necessary qualifiers/references, and enforce acyclic canonicalization with a stable representative. Keep non-taxonomic graph expansion bounded by configurable policy; dropping unfetched endpoints is a useful MVP limit, not a complete general ontology.

Evidence: [Wikidata readers](../../lib/devils_dictionary/absorb/clients/wikidata.ex), [trim](../../lib/devils_dictionary/absorb/sources/wikidata.ex), [canonical resolver](../../lib/devils_dictionary/absorb/resolver.ex).

### 9. P2 — The raw-first rebuild promise has an important exception

The full Wiktionary index writes projected lexemes directly. It does not retain a source record for every bare index entry. Replaying database `source_records` cannot reconstruct the entire 1.54-million-row lexicon. Recovery needs the pinned original dump, catalog/scope inputs, index pass, materialization, resolution, linking, and scope-building order.

Shared fields are also assembled using import-order-sensitive policies. Multiple etymology records collapse into one lexeme's etymology/forms, and the index pass processes chunks unordered. The inspected cat header shows “Abbreviations” for noun/adj and the Unix origin for verb, illustrating why one shared headword-level etymology is inadequate.

**Required outcome:** either store a compact replayable index projection or explicitly treat archived dumps as required recovery inputs. Prove restoration into a separate empty database. Define deterministic field ownership and preserve source/etymology-specific assertions. Do not equate an in-place upsert replay with disaster recovery.

Evidence: [Wiktionary index pass](../../lib/devils_dictionary/absorb/sources/wiktionary.ex), [materialization task](../../lib/mix/tasks/dd.materialize.ex), [shared field merge](../../lib/devils_dictionary/absorb/materializer.ex).

### 10. P2 — The community sketch does not express the promised concept-to-example relationship

The model map explicitly describes nepotism the concept → Donald Trump Jr. the concept. The sketch requires `lexeme_id`, optionally accepts `sense_id`, and has a single `concept_id` representing the example object. It has no separate subject concept. Consequently it cannot attach the claim directly to a concept and share it across synonymous words without relying on an external, changeable word-to-concept inference.

Other sketch limitations matter before shipping:

- The text-example uniqueness index omits `body`; a submitter cannot add two distinct text examples to the same word/sense with the same other fields.
- `votable_type`/`votable_id` have no foreign-key target integrity.
- The voter check permits both a user and bot simultaneously; it is OR, not exactly one.
- There are no checks that a sense belongs to the chosen lexeme or that an example kind has its required object.
- No required submitter/source provenance or moderation event history exists.

**Required outcome:** separate the thing being illustrated from the illustrating object and from the claim/attachment between them. Give media and quotations their own identity, attach them to explicit word/sense/concept targets, and attach votes/moderation to the claim where appropriate. A person appearing in culture must not be confused with the `people` row representing a historical author or the `users` row representing an account.

The analogous existing schema has gaps too: concept links do not enforce sense-to-lexeme consistency or confidence bounds, and the entries check allows both lexeme and concept even though a read-layer comment calls it XOR. The live check found zero mismatched concept-link senses; these are missing protections, not claims of existing corruption in that particular field.

Evidence: [community sketch](../sketches/README.md) (retired at #74), [model narrative](../map/README.md), [baseline constraints](../../priv/repo/migrations/20260905094219_create_lexicon_schema.exs).

## Relationship assessment

| Relationship | Judgment |
|---|---|
| Source → raw record | Good for latest snapshots; needs version/recovery policy |
| Lexeme → source-specific senses | Correct separation; identity across refresh is unsafe |
| Lexeme/concept → prose entry | Useful split; normalize article identity and clarify dual-target policy |
| Word → word relation | Useful typed graph; uniqueness omits target POS/group/subtype, which can collapse distinct assertions |
| Sense → concept | Correct abstraction; enforce ownership and durable sense identity |
| Concept → concept | Appropriate typed adjacency model; ranks/provenance and graph completeness need work |
| Scope ↔ lexeme | Good data-driven many-to-many membership with reasons |
| Variant → canonical word | Useful, but needs cycle-safe, deterministic resolution |
| Concept/word/sense → community example | The idea is sound; the sketch needs redesign |
| User/bot → vote on contribution | Practical, once actor/target integrity and score concurrency are defined |

Source tier should remain a presentation property. Historical, institutional, and crowd provenance do not establish truth, authority, permissions, or license suitability by themselves. The source FK alone does not enforce that crowd users cannot create definitions; that boundary must exist in authorized application write paths.

Required Wikidata QIDs are a deliberate MVP constraint. Historical encyclopedia subjects or locally introduced concepts without QIDs will require a changed identity policy, already acknowledged in #69. This is another reason to retire the promise of no changes to the original tables.

## Operational and presentation limits

Local query performance is encouraging; it is not a concurrent production load test. API pacing is per process, and separate absorb/enrich processes or multiple nodes do not share a global limiter. Positive API responses are generally cached until explicit refresh. Wikidata's stored-QID skip does not consult expiry on absent records. There is no scheduled source sweep or complete freshness lifecycle.

No `.github` CI directory was present. Production configuration is largely generated scaffolding; deployment, backups/restoration, migration procedure, resource limits, monitoring, and alerting remain to be established. The publicly routable diagnostics make that separation particularly important.

The UI has readable components and working provenance, but its information architecture needs more than styling: repeated POS labels, interleaved etymologies, duplicate articles, and long relation chains obscure meaning. The modal-like provenance overlay lacks explicit dialog semantics/focus trapping/Escape behavior in the inspected implementation. A dated 375px screenshot set is useful historical evidence, not a current accessibility or mobile regression suite.

Source-level attribution is a useful baseline; media needs per-asset author, license, original URL, and retrieval metadata. Provider popularity metrics should remain separate from local relevance votes. This is a data-model recommendation, not a determination that current or proposed source reuse is legally permitted.

## Recommended next milestone and acceptance gates

**Milestone: make the backbone safe to attach things to.**

1. Fix lossless navigation and canonical article identity. Acceptance: C++ lands on C++; cat shows one Wikipedia article while preserving all probe citations.
2. Establish durable sense/claim identity, source-version ownership, refresh reconciliation, and preservation of editorial decisions. Acceptance: insert/reorder/remove meanings and retract links without silently moving attachments or leaving active stale assertions.
3. Strengthen parity and recovery. Acceptance: corrupted content and unexpected rows fail checks; a separate database can be recreated from explicitly archived inputs, with deterministic semantic results.
4. Correct graph rules and constraints. Acceptance: no canonical cycles; ranked Wikidata claims follow policy; link ownership and confidence bounds are enforced.
5. Guard operational surfaces before public access. Acceptance: anonymous sessions cannot enqueue work or run diagnostics; duplicate submissions coalesce.
6. Finalize the community model and rewrite the stale implementation issues. Acceptance: one concept-level example appears correctly across synonymous words, a sense-level example stays on that meaning, multiple text examples work, and votes/moderation survive source refresh.
7. Build a small real culture-oriented scope and one complete contribution flow. Use nepotism, performative, situationship, and deliberately ambiguous terms. Acceptance: attributed source content → chosen meaning/concept → evidence submission → moderation → vote → source refresh, with the contribution still correctly attached.

Design work can continue alongside these fixes. Broad new-source ingestion and permanent social data should follow the identity/reconciliation work. JSON API, PWA, and iOS should consume the stabilized model; GraphQL is optional rather than a prerequisite.

**Decision:** proceed with the architecture, but change the next milestone. The project has demonstrated a useful static aggregation engine at meaningful scale. The next proof must be semantic correctness over time and a real culture contribution, not another green coverage total or another mockup.
