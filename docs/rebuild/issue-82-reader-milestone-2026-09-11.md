# Issue #82: reader milestone verification, 11 September 2026

This pass delivers the subject-independent reader milestone described in issue #82 and its owner clarification. It does **not** claim that the original participatory MVP is complete. Public contribution visibility, identity merge/split reconciliation, stale review/evidence presentation, and the complete cultural-example workflow remain Release C/D work. Public registration creates a reader account; `/connect` is server-gated to reviewers and the seeded internal development account.

The working corpus is `devils_dictionary_v2`. The baseline `devils_dictionary_dev` was not written, reset, or migrated.

## What changed

- Canonical lookup now requires an enriched exact-case headword before a case-folded group can win lemma lookup. Once established, legitimate case variants still share the page. Enriched inflection rows and a genuine uppercase `CATS` headword cannot prevent `cats` from resolving to `cat`.
- Wiktionary has a strict, unscoped `--full` mode. It walks the pinned dump in stable source order, skips records whose identical current payload was already materialized, and resumes without refreshing their source-observation timestamps.
- Sense matching prevents two outputs in one batch from claiming the same durable identity. The regression includes the exact `Hryhorivka/name/0#0` / `#5` order that failed the first restart.
- Reconciliation covers pending relations as well as materialized objects and assertions. A source relation withdrawn before its target appears can no longer be resurrected by a later resolver run.
- Entity pages fetch biography, works, definitions, editions, contents, and other connections independently. Each section has its own stable cursor. Incoming role edges represented by named sections are excluded from the connection wall; outgoing author and parent-work roles remain canonical navigation. Definition summaries are normalized plain text, capped at 120 characters, and visually clamped to two lines without changing stored content.
- Home discovery returns typed word and entity results with separate canonical destinations. The linker excludes people from name-only title matching, preserves evidenced/QID-backed person links, and withdraws unreviewed name-only person candidates.
- Login and registration use the Oatmeal component language. The local mailbox is routed only when development routes are compiled. A seeded, confirmed `internal-contributor@example.test` account can use the contribution composer without publishing a password or making public accounts writable.
- Index-only pages say explicitly that no definition or sense content has been absorbed and offer Wiktionary/search recovery links.

## Corpus run and restart evidence

The first real `--full` run was interrupted during materialization. The terminal exited, but the BEAM process remained alive with a PostgreSQL transaction; process and `pg_stat_activity` checks found it and an exact-PID termination was required. Run 119 is recorded as failed with that reason rather than left falsely running.

Restart run 120 resumed at the stored-record boundary and exposed a same-batch sense-identity collision (`ERROR 21000`). After the general identity fix and exact-order regression, run 122 completed:

| Measurement | Actual |
|---|---:|
| Wall time | 17m 45s |
| Dump bytes read | 2,387,777,740 |
| Trimmed bytes retained | 921,994,503 |
| Trim saving | 61.4% |
| English records seen | 1,487,639 |
| Materialized records | 1,335,429 |
| Resumed records | 150,290 |
| Lexeme observations | 1,325,979 |
| Sense observations | 1,530,409 |

W1 projected about 15 minutes; the actual run was 2m 45s slower. The final database is 14,036,727,487 bytes (about 13 GB), above the projected 9.5 GB. These are findings, not revised targets.

The complete offline replay then checked 1,485,718 stored Wiktionary records. A second replay produced identical semantic fingerprints. Resolution closed 2,466,084 of 2,629,595 Wiktionary edges (93.8%). Integrity checks found zero active senses without a current revision, zero duplicate current sense revisions, and zero active Wiktionary materialized outputs without a run owner.

## Coverage and scorecards

Actual current non-empty sense content covers **1,533,898 of 1,541,668 indexed lexemes (99.50%)**. This measure does not count an enrichment timestamp or an index-only row as a definition.

Final scorecards, each with zero pending graded rows:

| Scope | Result | P1 page p95 | P2 traversal p95 | X2 search p95 | X3 |
|---|---:|---:|---:|---:|---:|
| animals | 44 / 44 | 59.497 ms | 0.634 ms | 88 ms | 4 / 4 |
| emotions | 43 / 43 | 56.915 ms | 0.568 ms | 82 ms | 4 / 4 |
| culture | 42 / 42 | 55.696 ms | 0.516 ms | 86 ms | 4 / 4 |

The issue's named warm-cache dense-page probes used three warmups and twenty measured builds per page:

| Page | p95 | max |
|---|---:|---:|
| `/define/cat` | 20.905 ms | 23.934 ms |
| `/define/run` | 62.126 ms | 64.775 ms |
| `/define/set` | 58.559 ms | 61.480 ms |
| highest-degree entity (42,727 edges) | 69.526 ms | 76.454 ms |

All remain below the unchanged 150 ms page budget.

## Browser evidence

The real server ran on port 4007 through an in-app browser at explicit 1280×800 and 375×812 viewports.

- Home, cross-kind `Ambrose` results, `/define/cats`, `/define/run`, the index-only `/define/inferred` state, registration, login, and the Ambrose Bierce entity page had `scrollWidth == clientWidth` at the tested widths.
- `Ambrose` returned ten word destinations and three independently labelled entity destinations. The person result links to `/entities/1/ambrose-bierce`; the same label's word result links to `/define/ambrose-bierce`.
- Bierce's first and second definition pages each contained 24 distinct rows with no overlap. All 42 pages contain 997 distinct authored definitions; the separately authored work is the issue's 998th authored item. The work section remained visible after paging definitions, and the query carried only `definitions_after`.
- An anonymous `/connect` request redirected to login. The seeded internal account completed the local magic-link flow through `/dev/mailbox`, then loaded the five-form contribution composer at `/connect` with a 200 response.
- The browser harness injects a `MutationObserver` that logs an error on navigation. The served application bundle contains no `MutationObserver` or `.observe(` call; this is harness noise rather than an application console source.

## Verification

`mix precommit` passes **774 tests with zero failures**, including the focused mailbox regression assertion and the linker provenance regression added during review.

The scope configuration item inherited from N1 was applied with `mix dd.scope.new animals`; the denylist is now represented in the development database's scope rules as well as in `priv/scopes/animals.json`.

## Overclaims corrected during the work

1. The first lookup patch was reported as restoring X3 4/4 on the partial corpus. The full corpus then exposed an enriched non-form uppercase `CATS` row, proving that “exclude form rows” alone was insufficient. Exact-case headword establishment is the general rule now, with both the enriched-form and uppercase-headword regressions.
2. The first sense-collision fix guarded a changed row from taking an unchanged neighbour's identity. Restarting the full import exposed the symmetric order: an earlier changed row could claim an identity and a later ambiguous row could still reuse it. The matcher now carries a claimed set across both paths, and the exact failing record order is a regression.

After independent review, #82 can close as this reader milestone. It does not authorize calling the original layered/participatory MVP complete; the owner-described Release C, D, and representative-entity follow-through remain separate work.
