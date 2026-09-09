# Scorecard row mapping — issue #74

Every one of the 37 rows in `DevilsDictionary.Health.Score` mapped to
**retained / revised / retired**, with a reason and a replacement. #74 requires
this at the first checkpoint, and it is what stops the rebuild from quietly
dropping a check to keep a score green.

Rules this mapping follows, from #74 and the 7 September audit:

- Migration count and table count are **not** acceptance. Extensibility is
  proved by a test that adds something, not by counting `schema_migrations`.
- A live measurement, a sample, a historical attestation and a product
  acceptance are four different things and are labelled as such.
- New measurements may sit at `:pending` during the spike. Completion needs
  them passing. No permanently red suite, and no check disabled to stay green.

| Row | Was | Now | Reason |
|---|---|---|---|
| **A1** every source absorbed | present + pinned | **Revised** | Pinning now means an entry in `priv/sources/MANIFEST.json` that `mix dd.manifest` verifies, not a config key that exists. Today four of five inputs have no digest. |
| **A2** WordNet is full | ≥120,000 synsets / ≥155,000 lexemes | Retained | Ported query. |
| **A3** Wiktionary index is full | ≥1,200,000 lexemes | Retained | Ported query. |
| **A4** scope built with reasons | ≥`bars["a4"]`, 0 unreasoned | Retained | `bars` stays in `scopes.rules`. |
| **A5** Wiktionary coverage of scope | ≥90% ex. scientific names | Retained | The v2 amendment (any rank, not just binomials) stands. |
| **A6** Wikidata coverage | 0 dangling | Retained | Ported to `external_identifiers`. |
| **A7** Wikipedia coverage | 100% of asserted concepts | Retained | Already v2 — graded on concepts a scope word actually links to. |
| **A8** Bierce is full and attached | ≥997 entries, ≥95% attached | Retained | 997 is right and the index hit rate stays the informative number. |
| **A9** links back everywhere | 100% | Retained | |
| **A10** images | ≥`bars["a10"]`% | Retained | |
| **M1** parity | 0 gaps, by natural key | **Revised** | Natural-key *presence* is not semantic equality. Replacing every gloss with `CORRUPTED` still returns zero gaps. New M1: bidirectional semantic parity — field equality, unexpected extra rows, wrong endpoints, and stale outputs a run failed to retire. Must fail on the corruption probe. |
| **M2** idempotent, offline | historical row counts from `import_runs.stats` | **Revised** | Reading counts back from a past run is an attestation, not a measurement. New M2: rebuild into a separate empty database and compare **normalised semantic content**. |
| **M3** atomic writes | proven by `materializer_test` | Retained | Correctly labelled as test-proved already. |
| **M4** trimmed raw | ≥50% smaller | Retained | The `materialize(trim(r)) == materialize(r)` invariant is unchanged. |
| **R1** WordNet edges resolved | 100% | Retained | |
| **R2** Wiktionary edges resolved | ≥80% | Retained | |
| **R3** chains render | probes pass | Retained | |
| **L1** link rate | ≥`bars["l1"]`% of reachable | **Revised** | The numerator is not intersected with the reachable denominator, so the ratio is not the conditional rate its name implies. New L1 intersects, and reports the raw share beside it. |
| **L2** conflicts surfaced | `:report` | **Revised** | Ordinary polysemy is currently counted as disagreement. New L2 separates polysemy, unresolved matching, and genuine conflicting claims about one meaning. |
| **L3** taxonomy reaches the root | ≥`bars["l3"]`%, reports without a root | Retained | |
| **L4** disambiguation handled | 100% of nominal hits | Retained | |
| **X1** every word has a page | 200-lexeme sample builds | **Revised** | Building a page struct does not prove the router lands on the word: this is the row that missed `C++` → `/define/c`. New X1 asserts search → selection → page keeps the intended lexeme. |
| **X2** search is fast | p95 < 150 ms, 20 fixed probes | Retained | Same probes, same budget, same population — that is what makes it comparable across the rebuild. |
| **X3** forms and variants resolve | both probes land | Retained | |
| **U1** the pages exist | six routes present | **Revised** | The set grows: word, entity, work, connection detail, composer. It stays route-data, not prose. |
| **U2** flagship words | cat, dog, oyster build | Retained | |
| **U3** provenance everywhere | 100% of cards, six named words | **Revised** | Six words is a sample, not a population; it is now drawn at random and its size is reported. |
| **U4** mobile | 12 dated screenshots exist | Retained | Correctly a dated attestation that fails when evidence goes missing. Re-attested at P5. |
| **U5** coverage is legible | badges == `dd.health` | Retained | |
| **U6** every card links out | 100% | **Revised** | Presence of a link-out is reported separately from whether the remote URL resolves; today the row's name implies the second. |
| **E1** a new source is cheap | `schema_migrations == 2` | **Revised** | A hard equality against a literal 2 fails any healthy future migration — the audit's point, and this rebuild would trip it on day one. New E1 is a **test that actually adds** a source, a predicate and an entity kind, and asserts the cost: one catalog row, one module, one registry line, one `predicates` + `predicate_endpoint_rules` pair, and no schema change. |
| **E2** a new scope is data | ≥2 scopes, every member reasoned | Retained | `culture` becomes the third, exercising a new rule kind. |
| **E3** the community layer fits | `File.exists?` on a rolled-back sketch | **Revised** | The sketch is retired: the community layer is shipped schema now, so a file-existence check would be measuring nothing. New E3 is #74 milestone 5's extension exercise — a translated poem passage added through the documented path — graded by its tests. |
| **O1** the scorecard runs itself | this table | Retained | |
| **O2** it is fast enough | dumps ≤2 h; APIs reported | Retained | Carried forward with its actual population and measurement definition. |
| **O3** clean and offline-testable | `mix precommit` green | Retained | The independently executed suite is the evidence, as the audit says. |
| **O4** health page | `mix dd.health` + `/health` | Retained | |

## New rows

These have no predecessor. They exist because the audit reproduced a defect
that no existing row could catch.

| Row | Checks | Wants |
|---|---|---|
| **D1** refresh reconciles | withdraw a source record's output and re-materialize | the withdrawn sense/relation/link is **retired**, other sources' support for the same object is untouched |
| **D2** meaning identity is durable | insert, reorder and remove Wiktionary senses | every existing attachment stays on its original meaning, or a `reconciliation_cases` row opens; never a silent reassignment |
| **D3** editorial decisions survive | reject a link, rerun its rung | it stays rejected |
| **D4** review context is pinned | change an endpoint's text after a review | the old review still records what was displayed; the claim is marked needs-review, the vote does not transfer |
| **D5** integrity holds on bulk writes | `insert_all` and raw SQL with bad endpoints, missing subtypes, out-of-range confidence, duplicate verified external ids | every one rejected by the database |
| **D6** inputs are pinned | `mix dd.manifest` | 5/5 verified; an altered byte fails |
| **P1** page composition | full word/entity page p95 on high-degree nodes | the budget agreed at Gate 0 |
| **P2** bounded traversal | incoming and outgoing assertion queries on the 1,768-degree lexeme | the budget agreed at Gate 0 |

*What these rows measured once there was a corpus to measure, and the two that
changed:* [`score-rows-p5.md`](score-rows-p5.md).
