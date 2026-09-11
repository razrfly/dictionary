# Independent re-audit of #82 at 44f9c3b

**Grade: A− for the reader milestone. Not A+; recommend keeping #82 open for one operational-boundary correction and completion of PR review.** The prior two reader failures are fixed and the compact presentation requirement is met. The remaining finding is a new person-specific scope exception introduced by this patch, not a request to implement the deferred broad entity corpus or redo the schema.

Audited commit: `44f9c3be0868991fa2bb2482432acb4c012ba810`. Application working tree was clean. GitHub [PR #83](https://github.com/razrfly/dictionary/pull/83) is open with this exact head. `git ls-remote` independently confirms the same commit on `origin/codex/issue-82-reader-milestone`; the implementation is already pushed. CodeRabbit review was pending when inspected; GitGuardian passed. No merge or issue closure was performed. The audit only adds the evidence in this directory; it does not alter application code or import corpus data. Score commands record measurement runs normally.

## One remaining finding: linking eligibility depends on entity kind

`lib/devils_dictionary/absorb/linker.ex:566` implements:

```elixir
"(sl.lexeme_id IS NOT NULL OR e.entity_kind = 'person')"
```

The documented `mix dd.link --scope animals` command now processes identifier-backed people outside Animals while excluding equally identifier-backed non-people outside Animals. New tests intentionally encode both sides of that distinction in `test/devils_dictionary/absorb/linker_test.exs` (“identifier-backed people link outside the reporting scope with provenance” and “identifier-backed non-people remain inside the reporting scope”). This is established code behavior, not a speculative missing data source.

The actual Bierce evidence is good: a WordNet source record carries Q191050 and ILI i94474, and the current links point to the correct separate person. The problem is choosing *which records to process* with a person-only exception. It also means a scope-labelled run touches unrelated records. Adding the next work, organization or other entity would require different treatment despite equally strong identity evidence.

The implementation report explains that an exploratory general identifier pass caused Animals A7 to fail and that the person exception restored the green scorecard. That is useful disclosure, but a passing Animals scorecard is not sufficient justification for the encyclopedia's general eligibility rule. This is the same boundary the product has repeatedly asked to avoid: operational test populations should not determine which kinds of evidenced identities can participate in the backbone.

### Small, concrete remaining correction

Separate operational selection from identity evidence:

1. Keep scoped linking confined to the explicitly selected population for **all** entity kinds.
2. Provide an explicit, bounded way to process evidenced records outside that population, independent of entity kind: for example a selected source-record set through the same linker path. An explicit global identifier-only mode is also possible, but do not silently broaden a scope command or run a large global pass merely to prove Bierce.
3. Use that explicit path for the real Bierce record. Preserve the existing `refers_to` identity, provenance, completed run ownership and idempotency.
4. Test two out-of-scope fixtures with valid identifiers, one person and one work/non-person. A scoped run must not process either; explicit selection must process both through the same evidence rule. Keep name-only inference excluded for people and all existing negative/link integrity tests.
5. Document the command and its selection/run semantics. Do not lower A7 or classify people as Animals. Recheck the affected score and the ordinary suite after the correction.

This does **not** require ingesting every entity type, migrating old data, or redesigning the schema. It removes a newly introduced policy exception. It is the reason I am withholding A+, rather than reopening the now-fixed reader bugs.

## What is now verified

| Criterion | Result |
|---|---|
| Existing suite | Fresh `mix precommit`: **773 tests, 0 failures** |
| Original two independent navigation regressions | Fresh run: **2 tests, 0 failures**; equivalents are also in the ordinary suite |
| Work → author and edition → work | Confirmed by actual browser clicks in both directions, with separate relationship-inspection links |
| Person → work → edition | Confirmed by actual browser traversal |
| Real sense → person link | Fresh SQL: sense 342580 → person 1 via `wordnet_wikidata` and `wordnet_ili` |
| Evidence and run ownership | Source record **109124**, QID **Q191050**, ILI **i94474**, last-seen run **142**, status **done** |
| Word reader → person | Clicked from `/define/ambrose-bierce` to `/entities/1/ambrose-bierce` |
| Coverage | **1,533,898 / 1,541,668 = 99.50%**, unchanged |
| Complete Bierce pagination | **997 unique definitions across 42 pages**, work retained throughout |
| Mobile excerpt presentation | **6,383 px** first-page height at **375×812**, down from 8,214; 24 rows, no horizontal overflow |
| Desktop presentation | **4,117 px** at **1280×800**, no horizontal overflow |
| Mobile pagination | Second page has 24 distinct new rows; work remains visible |
| Excerpt integrity | Ordinary tests cover long prose, Markdown and verse and assert stored bodies remain unchanged |
| Auth boundary | Server-side gate retained; existing auth suite passes. Browser was already logged in as the internal account, so a fresh login was not independently repeated |

Viewport overrides were reset after inspection. Browser screenshot was visually inspected inline; no new screenshot file is claimed in this evidence directory. The completion report also references inline screenshots rather than repository screenshots. This is a retention limitation, not the principal architectural finding.

## Fresh dense-page performance

Same local corpus, warm cache, 3 warmups and 20 measurements. p95 is the 19th sorted sample. The budget remains 150 ms; these are backend page-building times, not browser paint measurements.

| Page | p95 ms | Maximum ms |
|---|---:|---:|
| cat | 21.733 | 21.756 |
| run | 73.959 | 82.300 |
| set | 57.528 | 59.673 |
| highest-degree entity, object 4 | 83.126 | 84.092 |

All pass. Slight differences from the implementation's timings are expected on the same machine under different load; no budget was changed.

## Deferred work remains deferred

The old #73 audit was freshly rerun: **7 cases, 5 failures**, unchanged. They concern stale review acceptance, merged identities/URLs, split-context reconciliation, rejected `defines` visibility and the resolver enum mismatch. They belong to Release C/#78 and are not the reason for withholding closure of this patch.

After the scope-selection correction and review, close #82 as the reader milestone. Then proceed directly to:

1. **Release C correctness:** make the five reproductions pass and verify related public read/identity paths. Keep contributions gated.
2. **Release D cultural examples:** complete meaning selection → attributed submission/rationale → review → display/filter → relevance voting → challenge/correction.
3. **Release E representative entities:** prove reusable paths for a bounded set of non-seeded people, works, organizations and events.

The data model remains a viable foundation. No new architecture planning cycle is needed. The next patch should remove the person-only selection exception, not change the model again.

## Final fresh scorecards

All three independent runs completed (146–148), with zero pending graded rows and unchanged thresholds:

| Scope | Graded result | P1 p95 ms | P2 p95 ms | X2 p95 ms | X3 |
|---|---:|---:|---:|---:|---:|
| animals | 44/44 | 57.084 | 0.479 | 83 | 4/4 |
| emotions | 43/43 | 58.923 | 0.510 | 85 | 4/4 |
| culture | 42/42 | 58.372 | 0.552 | 83 | 4/4 |

These successful measurements do not invalidate the entity-kind exception finding: the current tests expressly permit that behavior and the scope scorecards do not grade whether operational selection is kind-neutral.
