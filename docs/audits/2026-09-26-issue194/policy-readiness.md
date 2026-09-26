# Routing policy v1 — implementation handoff

**The design decisions are settled and the issue is ready for implementation.** The owner accepted the original audit's recommendations. [ADR 0002](../../adr/0002-public-routing.md) is now the authoritative contract; the earlier B− audit remains a record of the issue before this work.

**Updated grade: A+ for the implementation brief. Production launch readiness remains unproven.** This is a judgment of the specification's clarity, completeness, reproducible evidence and explicit failure handling, not a claim that every classification is correct or that the routing feature is implemented.

The original gaps are closed at the specification level: family boundaries, uncertainty, lexical/On coexistence, normalization, locale strategy, slug collisions, database invariants, published moves, rebuild persistence, source evidence, HTTP behavior, indexing and README ownership all have explicit decisions. The offline evaluator and its tests make the classification policy executable.

**This is not an all-clear to publish the corpus.** Classification coverage, editorial readiness and production routing correctness are different gates. The route migration, transactional address allocation, On editing and HTTP/SEO integration remain implementation work with explicit acceptance tests. An A+ implementation brief must state these limits rather than describe existing app tests as proof of unbuilt behavior.

## Full-corpus policy run

Read-only development snapshot on 26 September 2026. The export includes **100,723 entities**, **72,997 saved class-evidence records**, and the retained lexical population of **1,541,669 lexemes**. Source definitions are pinned in [vocabulary-terms.json](../../../priv/routing/vocabulary-terms.json); the input and policy digests are in [policy-summary.json](policy-summary.json).

| Classification outcome | Entities |
|---|---:|
| Mapped by the versioned policy | 38,576 |
| Needs classification/evidence review | 56,228 |
| Excluded source-page role | 5,917 |
| Identity lifecycle review | 2 |
| **Total** | **100,723** |

The evaluator retains candidate families even when a missing alternative branch requires review. Unknown subjects never silently become Concepts or Subjects. Mapped means a consistent rule result in the available evidence; it is not independently verified semantic accuracy.

| Candidate address outcome | Entities |
|---|---:|
| Unique candidate with mapped classification | 34,048 |
| Candidate requiring classification review | 2,364 |
| Candidate requiring collision review | 4,643 |
| No address proposed | 59,668 |

There are **1,406 candidate-path collision groups**. The dry run allocates **zero paths** and grants **zero publication approvals**. Addresses are proposals, not a ledger. The retained lexical layer is counted and stays available; this run does not rewrite 1.54 million lexical URLs.

The warnings include missing class evidence, incomplete ancestry, **17 source/projection disagreements**, and **one unversioned type projection**. Warning totals count warning occurrences and are not mutually exclusive entity counts. The source graph is incomplete, so the run deliberately defers some plausible assignments.

## Boundary and sample review

[policy-boundaries.jsonl](policy-boundaries.jsonl) retains evaluator results for all **54** representative records from the original audit. These include every event, edition and artifact in the current database. Missing philosopher, person, element or deity examples remain missing; no identities were fabricated to improve coverage.

[stratified-review.json](stratified-review.json) records a repeatable sample: the first six mapped rows per family ordered by a SHA-256 of the object ID, or the whole family when smaller. This yields **46 records** across all eight families.

- **43** have descriptions consistent with their proposed charter-level family.
- **3** require further verification: a brand/organization identity boundary and two records without descriptions sufficient for an independent check.

This was a same-auditor review of available metadata, not independent expert adjudication, and is not a population precision estimate. The sample demonstrates why publication has a separate review gate. Do not convert 43/46 into a claim that a corresponding percentage of the whole corpus is correct.

## Decisions now fixed

- Eight subject families; On is a separate editorial role. Nature includes scientific substances, including synthetic ones. Subjects includes known scope exceptions and never hides unknown classification.
- Human/fictional/celestial overlaps have explicit precedence. Other incompatible matches require review.
- Lexical routes remain at launch. On pages are separately authored and cannot replace lexical coverage. Missing exact IDs return 404 in the route implementation.
- English launches unprefixed; future translations use the reserved locale prefix. Slug proposals preserve Unicode and deliberately distinguish C++, C+ and c. Empty/overlong proposals are held, not truncated into collisions.
- Meaningful collision qualifiers require evidence. No automatic opaque suffix; no first-import-wins primary topic.
- Separate durable page, path, classification-decision and editorial-membership records. Current and historical paths share one uniqueness domain. Published moves use 301 redirects; aliases resolve directly to the destination page's current canonical.
- Provider rebuilds restore registry/editorial/route state; they cannot regenerate identity from import order. Classification updates alone leave published routes fixed.
- Publication and indexing require explicit useful-content, identity, rights, classification, path and editorial gates. No automatic sitemap expansion from imported rows.

## Specification acceptance and implementation boundary

| Gate | Handoff status | Remaining production proof |
|---|---|---|
| Authority, scope, provenance and versions | Defined; class meanings pinned | Provider enrichment and reviewer integration |
| Deterministic classification and uncertainty | Executable; all input entities accounted for | Independent review of the chosen launch set |
| Slug semantics and collision behavior | Executable proposals; collisions retained | Transactional ledger and concurrent allocation |
| Lexical/On distinction | Explicit decision and data contract | On storage/editor and lossless reader navigation |
| Identity moves and rebuilds | Explicit invariants and rollback procedure | Real database restore/merge/split/rollback tests |
| HTTP, metadata and indexing | Explicit request and page-role matrix | Initial HTTP and live-navigation assertions |
| Agent documentation | README, ADR, policy files and reproduction commands linked | Keep documentation synchronized as feature phases land |

The future implementing agent has no need to invent these contracts. New factual exceptions still require evidence, as they will for any evolving encyclopedia.

## Reproduce

```sh
psql -X -qAt -v ON_ERROR_STOP=1 -h localhost -U postgres -d devils_dictionary_v2 -f docs/audits/2026-09-26-issue194/policy-export.sql > /tmp/routing-input.jsonl
mix compile
mix dd.routing.audit --input /tmp/routing-input.jsonl --output /tmp/routing-audit
mix test test/devils_dictionary/routing
mix precommit
```

The SQL export uses one repeatable-read, read-only transaction. The Mix task is offline and starts neither the application nor a database connection. It writes a full per-entity manifest and summary to the chosen directory. Keep full manifests as audit artifacts rather than committing tens of megabytes of repeated evidence into Git.

The exact input and output from this run are preserved locally as compressed archives in the ignored `data/audits/2026-09-26-issue194/` directory. They contain classification inputs, not account data or licensed content bodies. These archives are not part of the PR; a fresh clone needs database access for a new export. To repeat this exact snapshot on the audit machine, decompress `input.jsonl.gz` and compare the resulting manifest with `assignments.jsonl.gz` and the committed SHA-256 evidence.

For a type change, update the pinned vocabulary/rule files, add expected positive and negative fixtures, bump the policy version and repeat the complete run. Compare records by permanent identity and review every changed launch assignment. A new family also requires its scope charter and public-address impact assessment.

## Verified checks

- All **23** evaluator/audit regressions pass, including contradictory types, qualified or unpinned ancestry, subclass-only evidence, duplicate identities, source-page exclusion, Unicode slugs and collisions.
- Separate evaluator processes produced **byte-identical manifests for all 100,723 entities**, including with the complete input in reversed line order. Summaries match except for the expected input-file digest. [Reproducibility evidence](reproducibility.json) pins the manifest and evaluator files.
- On the original audit checkout, `mix precommit` passed **16 doctests and 1,919 tests, zero failures**. On current main (`828cdf2be650a216adb44090e1a99aa1edab3d86`), the isolated review checkout passed **16 doctests and 2,088 tests, zero failures**. Its full-corpus manifest also matches byte for byte. The worktree reuses the existing local source archives required by the manifest test; no source data was downloaded.
- Local documentation links and `git diff --check` pass. The pre-existing word-page test edits are unchanged.
- No development corpus rows, public paths or publication approvals were changed. The full JSONL manifest remains an audit artifact; the repository includes its summary, digest and boundary sample.
