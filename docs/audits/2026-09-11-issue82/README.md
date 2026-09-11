# Independent audit of #82 — 11 September 2026

**Grade: B. Keep #82 open for a bounded completion patch.** The corpus milestone is substantially delivered and the reader is much more useful, but connected navigation has a reproduced regression and the required real lexical-sense → person connection is still absent. This is not a reason to redesign the schema or repeat the full import.

Audited local commit: **b04cf52**, branch `codex/issue-82-reader-milestone`, based on `c942d19`. Application working tree was clean at the start. No PR for this branch was returned by GitHub during the audit; the branch has no configured upstream. This report does not certify external review or merge readiness. No application code, corpus records, issue state or remote branch was changed by this audit. Score tasks record their normal measurement runs; regression tests use the test database.

The contract is [#82](https://github.com/razrfly/dictionary/issues/82), including the owner's reader-versus-participatory-MVP clarification, captured in `issue82.json`. #82 supersedes #79's execution sequence. Explicitly deferred #73/#78 defects are reported separately below rather than silently added to #82's scope.

## Findings that block closure

### 1. Removing duplicate edges also removes the only author and parent-work links

`EntityPage.other_connections/3` excludes `about`, `authored_by`, `edition_of` and `published_in` in **both** directions (`lib/devils_dictionary/encyclopedia/entity_page.ex:59,122`). Specialized sections render incoming roles, but do not replace the corresponding outgoing roles.

Consequences:

- A work's `authored_by → person` relationship disappears from its page.
- An edition's `edition_of → work` relationship disappears from its page.
- A reader can follow person → work → edition but cannot follow those relationships back through the displayed model.

Two independent LiveView reproductions fail on this commit: `reader_regressions_test.exs`, output `reader-regressions.log`. The real work page also lacked the author link. This is a reader regression introduced by B1, not a deferred identity/review defect.

**Required fix:** suppress only relationships actually represented by another visible section, taking direction and endpoint role into account, or render explicit outgoing author/work panels. Promote the reproductions into the ordinary suite. Verify both directions for person/work/edition and a high-degree fixture.

### 2. Cross-kind search works; the actual Bierce word/person connection does not

The homepage now returns distinct typed word and person results with different destinations. That is correct and important. The generic QID-backed person-link unit test (`test/devils_dictionary/absorb/linker_test.exs:155`) also demonstrates a non-seeded `Ada Example` fixture. Name-only person candidates are excluded/withdrawn rather than treated as identity evidence.

However, current corpus inspection finds no active `refers_to` or `lexeme_entity_candidate` link to person object **1**. The `Ambrose Bierce` lexeme is **341814**, its sense **342580**; its current outgoing results contain two `other` source relations and no person connection. Separate search destinations therefore do not yet deliver B3's required evidenced lexical-sense → person traversal. See `corpus.sql` and `corpus.log`.

**Required fix:** use valid source evidence through the general linking path to connect the real name sense to the person; do not add a name-only equivalence or special-case Bierce. Retain the non-seeded fixture and demonstrate real browser traversal from the lexical entry to the person. If suitable evidence is absent, record that explicitly and obtain an acceptance change rather than claiming the requirement is done.

## Acceptance assessment

| Requirement | Assessment | Evidence / qualification |
|---|---|---|
| Actual definition coverage ≥90% | Pass | Fresh SQL: **1,533,898 / 1,541,668 = 99.50%** have current active non-empty sense content. **7,770** remain without that content. |
| Canonical inflection lookup and regression tests | Pass | Fresh suite; browser `cats` displays `cat`; score X3 probes. The implementation covers enriched-form and uppercase-headword collisions. |
| Full unscoped resumable Wiktionary materialization | Substantially delivered | Code and regression coverage inspected. Implementation records a real interrupted run, collision repair, successful resume and repeated offline replay. Long import/replay was **not repeated** in this audit. |
| Independent role pagination | Pass for corpus reachability; regression in reverse navigation | Fresh traversal: **997 distinct definitions over 42 pages**, with works present throughout. First two pages also clicked in browser. |
| Compact mobile person page | Improved; polish remains | At 375×812, first page measured **8,214 px**, no horizontal overflow. First-line-only truncation leaves long one-paragraph definitions large and raw Markdown visible. |
| Typed word/entity search | Pass | Real search returns independently labelled destinations. Exact person appears after ten lexical results; ranking can improve. |
| Evidenced word/sense → person connection | Incomplete | Generic QID fixture passes; actual Bierce connection absent. |
| Styled account pages and internal contribution boundary | Implemented | Kit-based auth pages, development mailbox and server-side route gate are present; green suite. Current browser session was already the internal account, so its original login was not independently repeated. |
| Missing-content recovery | Implemented | Index-only state explicitly explains missing absorbed content and provides recovery links. |
| Tests | Baseline pass, independent regressions fail | Fresh **766 tests, 0 failures**; two additional reader regressions both fail. |
| Performance / scope scorecards | See fresh results below | Warm-cache backend composition is not browser paint time or cold-cache performance. |
| Reviewable delivery | Pending evidence | Local committed implementation exists; no branch PR found during audit. No independent code-review completion confirmed. |

The issue says “998 definitions.” The current corpus has **997 authored definitions plus one authored work**. The corrected reachable-definition count is not data loss.

## Measurements and evidence limits

The implementation's report, `docs/rebuild/issue-82-reader-milestone-2026-09-11.md`, records a 17m45s full import, 1,485,718 replayed stored records, identical second-replay fingerprints, and 93.8% resolved Wiktionary edges. These are implementation-run results, not newly reproduced long-run measurements.

It also records a **14,036,727,487-byte database**, versus a 9.5 GB projection: approximately **48% larger**. The run was approximately 18% slower than the 15-minute projection. This does not itself fail #82, which calls for reporting variance, but storage forecasts should use the actual result. A 93.8% resolved-edge rate is not evidence that every source relationship is correct or complete.

Fresh test output is retained in `precommit.log`. New regression output is retained in `reader-regressions.log`. `pagination.exs` and `pagination.log` reproduce whole-person reachability. `dense_pages.exs` records 3 warmups and 20 samples per named page. Score logs are retained alongside this report. SQL measurements are read-only against `devils_dictionary_v2`.

Browser audit: real app at port 4007, desktop 1280×800 and mobile 375×812; search → person, definition pagination, work page, and `cats` canonical destination were inspected. Mobile page width stayed 375; first two definition pages were disjoint with the work still present. Desktop person screenshot was visually inspected in the audit conversation. This report does not claim a full cross-browser accessibility audit or retained screenshot files.

## Older correctness work still outstanding — the next release

Freshly rerunning `docs/audits/2026-09-09-issue73/reproductions.exs` gives **7 tests, 5 failures** (`inherited-audit.log`):

1. Changed endpoint text still displays the old review as current acceptance.
2. A merged input's entity page continues to present the old identity.
3. Splitting a claim context does not open the expected reconciliation case.
4. A rejected `defines` relationship remains visible in an authored-definition summary.
5. `Registry.resolve/1` fails on a merge because it queries enum value `:merged`, while the enum supports `:merge`.

These are concrete remaining problems, not hypothetical future-proofing concerns. They prevent claiming the original participatory encyclopedia is finished. They were explicitly deferred from #82; fix them in the agreed Release C, with public contribution gating retained until the release guarantees hold. The old seven-case audit now passes two cases, so quoting the previous failure count unchanged would be inaccurate.

## Architecture assessment

**The model remains a sensible foundation.** Distinct lexical identities, senses, people, works, editions and attributed content can be connected through typed assertions without collapsing them by spelling. Sources and authored definitions remain distinguishable. The broad Wiktionary materialization and independently paginated sections demonstrate useful scale. Nothing in this audit calls for another schema rewrite or legacy-data migration.

**The weak point is enforcing those semantics consistently through read paths and identity lifecycle operations.** A sound table model does not ensure every specialized page respects rejected edges, every merged URL resolves, or every relationship remains navigable. The new outgoing-edge regression and the inherited reproductions show precisely where the application breaks the intended model. Green corpus scorecards do not exercise all those guarantees.

Extensibility is therefore promising, not proven for every future use case. The current entity population still contains only two people, two works and two editions; broad entity ingestion was deliberately out of scope. Retain a representative test matrix across roles, directions, visibility, identity changes and pagination rather than expanding a taxonomy of special-case pages.

## Recommended next steps

1. **Finish #82 with one bounded patch:** restore outgoing author/work navigation, establish and demonstrate the real evidenced name-sense/person link, retain regression tests and browser evidence, and submit a reviewable PR. Tighten mobile excerpts while touching that presentation if practical. Re-run affected tests, `mix precommit`, and affected measurements; do not restart the full import without a data-path reason.
2. **Then close #82 as the reader milestone**, following independent review. Do not close #73/#78 or call the original MVP complete on that basis.
3. **Release C: correctness.** Make the five reproduced failures pass, audit adjacent public read paths, and verify ownership/integrity after the relevant import/resolve/reconcile sequence.
4. **Release D: one complete cultural-example workflow.** Register → choose a meaning → submit link/text/media-reference with rationale and provenance → review → display/filter → relevance vote → challenge/correct. Preserve the distinction between source definitions, editorial interpretation and public examples.
5. **Release E: representative general entities.** Demonstrate non-seeded people, a work, an organization and an event through reusable creation/import and linking paths. This is a bounded demonstration, not an all-Wikidata import or schema redesign.

**Decision:** substantial progress, reader grade **B**, not ready to close today. Finish the small reader gaps, then move directly into the already-planned correctness work.

## Fresh performance results

All times below are milliseconds, warm cache, on the local full corpus. Independent score runs overlapped only with read-only audit checks, not corpus imports.

| Dense page (3 warmups, 20 measurements) | p95 | Maximum | Budget |
|---|---:|---:|---:|
| cat | 22.486 | 22.541 | 150 |
| run | 67.775 | 69.582 | 150 |
| set | 57.771 | 58.393 | 150 |
| highest-degree entity, object 4 | 73.572 | 74.498 | 150 |

The baseline suite's 766 passing tests and the independent failing cases measure different coverage: the new cases are deliberately outside the ordinary test directory until the implementation owner fixes and incorporates them. Reproduce with `mix test docs/audits/2026-09-11-issue82/reader_regressions_test.exs`. Do not interpret the ordinary green suite as disproving the regressions.

All three fresh scope runs completed successfully (measurement runs 136–138):

| Scope | Graded rows | P1 composition p95 | P2 traversal p95 | X2 search p95 | X3 |
|---|---:|---:|---:|---:|---:|
| animals | 44/44 | 57.360 | 0.536 | 86 | 4/4 |
| emotions | 43/43 | 58.303 | 0.568 | 81 | 4/4 |
| culture | 42/42 | 59.178 | 0.704 | 87 | 4/4 |

There were zero pending graded rows in every run. Search maxima were 162, 151 and 153 ms respectively; the passing result is the specified **p95**, not a guarantee that every request is below 150 ms.
