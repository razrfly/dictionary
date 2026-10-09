# Routing Stage 2 backfill

**Status:** implemented and rehearsed on isolated copies, 27 September 2026, for [routing issue #194](https://github.com/razrfly/dictionary/issues/194); corrected under [#219](https://github.com/razrfly/dictionary/issues/219) and [rehearsed again on the corrected code](#re-run-on-the-corrected-code-219) on 28 September. **Run on the working corpus on 8 October 2026** ([CP4, #224](https://github.com/razrfly/dictionary/issues/224)), after the [corpus catch-up](corpus-catch-up.md): the population re-derived from a fresh export (`candidates.json`, SHA-256 `c2cbd2ef…`); the run without reviews, twice; then the run with the owner's own review file (129 reviews under the one reviewer account: 124 confirmations, 5 deferrals, each naming the fingerprint reviewed), twice. The second run of each pair wrote nothing. The result is 124 allocated addresses on 124 draft pages (122 subject, 2 edition), 5 records deferred by review (the duplicate identities of *The Devil's Dictionary*, *Mona Lisa* and the three *Love* works) and 41 not addressed; nothing refused, nothing published. The candidate launch manifest is run `9639fc28…`'s (`manifest-rev1.json` in the CP4 evidence). The remaining 100,749 entities stay deferred with the audit's dispositions.

`Routing.Backfill` (`mix dd.routing.backfill`) implements step 3 of ADR 0004 §8: decisions and durable pages in resumable batches, with checkpoints keyed by object identity and policy digest.

## What a run is bound to

A run is keyed by the SHA-256 of four inputs and the backfill's own version (`routing-backfill/2` since #219, so a run keyed under version 1 is never resumed by the corrected code). It refuses inputs that do not agree with each other.

| Input | What it is | Bound by |
|---|---|---|
| Export | `policy-export.sql`'s read-only output for this database | its SHA-256 |
| Policy | `priv/routing/*.json` | its SHA-256, which the export's audit recorded |
| Population | `candidates.py`'s output for that export | its SHA-256; its own `inputs` must name the export's and policy's digests |
| Reviews (optional) | the reviewers' decisions, one per record | its SHA-256. The file names the population's digest, and each confirmation names the evidence fingerprint of the decision reviewed, from a run's manifest |

The same four digests are the same run, and it resumes from its checkpoint. A new review file makes a new run over the same population. Its writes are the same idempotent writes, so every page, path and decision carries over.

## Per record, in object-id order

1. **Is the evidence still what the export saw?** The record's evaluator input is read back from the database and compared with the export. Then every graph record the evaluation **depended on** is checked, not only the ones it matched: `Policy.classify/3` lists as `dependencies` each record it read — the entity's own, and every class it walked through, whether or not the walk found a mapping — and each record it looked for and did not find. A policy anchor that ends a matched path is matched by its identifier and never read, so it is not a dependency: a refresh of Q5, which every person matches through, defers nothing. A self-classified subject's walks are not read either. A record it read must still be at its **current** revision: the revision whose key is the record's content hash. That is not always the newest, because a payload that returns to an earlier one adds no revision. A record it did not find must still be absent. The result — its outcome, evidence and fingerprint — is a function of the input, the policy and exactly those records (a seeded property test mutates everything else and checks), so if they all still hold, a fresh evaluation reaches the same result. If anything has moved, the record is deferred with its reason, `input_changed` or `evidence_changed` (naming the records), and needs a fresh export, a fresh decision and a fresh review fingerprint. It is never classified from stale evidence.
2. **Classify.** `Policy.classify/3` runs, then `Classifications.record/1`. Unchanged evidence writes nothing, and a standing override is kept.
3. **Act on the population and the reviews:**

| Population disposition | Without a review | With a reviewer's `confirm` | With `defer` |
|---|---|---|---|
| allocation candidate | draft page, `awaiting_review` | the reviewer's override (once), the page, the uncontested candidate path allocated | `deferred_by_review` |
| collision review (proposed qualifier, or blocked) | draft page, `awaiting_review` | override, page, and the path **the reviewer names**, allocated. A collision is never qualified by import order. | `deferred_by_review` |
| classification or duplicate-identity review | `awaiting_review`, no page | override to the reviewer's family, page, and the reviewer's path | `deferred_by_review` |
| deferred or excluded | `not_addressed` | — | — |

A confirmation must name the fingerprint of the decision now current. A review made on other evidence is refused as stale, so it can neither outlive its evidence nor end a contradiction review. The one exception is Stage 1's: a reviewer's standing override stays current through new evidence that does not contradict it, and keeps the fingerprint it was made on, so a confirmation naming that fingerprint still matches it.

A confirmation that cannot stand is `refused` for that record alone, and **leaves nothing it wrote**. What can be checked before writing is checked first: stale evidence, a collision confirmed without a path, a path someone else holds, a tombstone, an edition's address outside `/works`, a page that is not active or already has another address. The override, the page and the address are then written under one savepoint inside the batch's transaction. A refusal at any of those steps — the page's role, the ledger's own refusals, or something a concurrent writer changed after the checks — rolls back to the savepoint: the record's decisions, page, paths and ledger rows are what they were before the confirmation, its checkpoint says `refused` with the reason, and the batch goes on. The evaluator's own decision, recorded in step 2, stays: it is what a reviewer must see next. A reviewer may replace their own override.

An edition gets an edition page, whose address is in `/works`. Every other entity gets a subject page ([Stage 1, decision 1](../stage-1-foundation.md)).

4. **Checkpoint.** One `routing_backfill_items` row per record holds the disposition, its reason, and the decision, page and path ids.

A batch is one transaction: its writes and its checkpoint rows commit together. An interruption loses at most the batch in hand, and a resumed run starts after the last committed record. Every writer refuses per record without rolling the batch back ([Stage 1, decision 7](../stage-1-foundation.md)).

## Reviews

```json
{"population_sha256": "…",
 "reviews": [
  {"object_id": 1, "action": "confirm", "family": "people", "evidence_fingerprint": "…", "reviewer": "reviewer@example.com", "reason": "…"},
  {"object_id": 1846558, "action": "confirm", "family": "places", "path": "/places/daman-afghanistan", "evidence_fingerprint": "…", "reviewer": "…", "reason": "…"},
  {"object_id": 1846559, "action": "defer", "reviewer": "…", "reason": "…"}
]}
```

- **Where it comes from.** A run without reviews writes the manifest, which gives each record's current decision and its `evidence_fingerprint`. Reviewers decide from it.
- **Bound to the population.** The file names the population's digest. Each review names one record the population addresses, and each record gets at most one.
- **Paths.** A path is in the confirmed family. No two reviews approve the same path, and no review takes another record's proposed qualifier.
- **Reviewers.** Each is an account with the reviewer role. All are checked before anything is written.
- **Refused at load:** a file marked `"rehearsal": true`, which comes from a rule rather than from reviewers, except on a rehearsal copy. A signed standing review rule is not a rehearsal ([below](#under-the-standing-review-rule-237)).
- A duplicate-identity outcome of "the same subject" is a registry merge, which is outside the backfill: `defer` the record until it is merged.
- **No review may be written for someone.** The file records decisions people made.

## What it never does

- Publish. Pages stay `draft`, and candidate status grants no publication approval.
- Allocate without a named reviewer's confirmation or the owner's signed standing rule, or qualify a collision by import order.
- Allocate a collection or choice page. It creates subject pages, and edition pages for editions.
- Touch a record outside the population. The rest of the corpus stays deferred, with the audit's dispositions.

## Under the standing review rule (#237)

The owner's rule of 8 October 2026: **no human decides a record, ever.** `priv/routing/review-rule.json` is the owner's standing decision, signed once by the owner's reviewer account; with it, `--rule` replaces a review file, and nobody reads a row.

```bash
DD_NO_OBAN=1 mix dd.routing.rule                        # the rule, its digest and its signature, checked
DD_NO_OBAN=1 mix dd.routing.rule --sign --reviewer EMAIL # the owner's one act: asks for the account's password
DD_NO_OBAN=1 mix dd.routing.backfill --snapshot EXPORT.jsonl --population candidates.json \
  --rule priv/routing/review-rule.json --dry-run [--decisions OUT.json]
DD_NO_OBAN=1 mix dd.routing.backfill --snapshot EXPORT.jsonl --population candidates.json \
  --rule priv/routing/review-rule.json --manifest MANIFEST.json
```

**The rule.** Ten clauses, each with its owner-readable text in the file and its implementation in `Routing.ReviewRule`; the code refuses a file whose clauses are not exactly these, in this order:

| Clause | Action |
|---|---|
| `standing_decision` | A decision a human made stands: an allocated address stays, an override keeps its family, a reviewer's deferral stays deferred, a page a human retired, merged or split and a tombstone a human left are deferred (and a collision group with such a member waits whole). The rule decides only what no human has. |
| `excluded_source_page`, `identity_lifecycle_review` | deferred (the population leaves them unaddressed) |
| `classification_review` | anything whose current decision is not `mapped` is deferred: the rule never chooses a family |
| `duplicate_identity_review` | deferred: one subject or two is the registry's decision |
| `uncontested_mapping` | a mapped record is confirmed at its candidate path when that is the policy's proposal for its label, the label is readable (nothing the slug would spell out: `#`, `.`, `+`), no group shares the path, no record proposes it and no page holds it |
| `qualified_collision` | a collision group is confirmed whole, each undecided member at the qualifier its own evidence gives (`Routing.Qualifier`), when no member is deferred or held for review and every such path is the population's own proposal, readable, distinct and free |
| `unqualified_collision` | otherwise the group is deferred whole, and two groups whose qualifiers meet at one path are both deferred whole; so is a mapped record whose path is taken, is a group's shared path, is not readable, or unproposed |
| `publish_confirmed` | Stage 5: a page the rule confirmed may be published when it passes the eight gates |
| `index_lexical` | Stage 5 (D1): lexical pages stay noindex, except the On page of each lexeme a published page names, listed in the launch manifest as a lexical entry |

**Its digest and signature.** The digest is the SHA-256 of the rule's canonical content without its signature; the content includes `implementation`, the version of `decide/2` the clauses are signed for, so a change in what the rule does refuses the old file and needs a new signature. The digest is the fourth input of the run key (`rule:<sha256>` in place of a review file's digest) and is recorded on the run's row (`routing_backfill_runs.rule_sha256`; `reviews_sha256` stays null), it is on every override the rule writes (`rule_ids` holds `review_rule:<sha256>`, and the override's reason names it), and every checkpoint row's `review` names it with the clause that decided the record, or `stale` for a record the batch deferred before the rule's decision could apply. `mix dd.routing.rule --sign` checks the account's password and reviewer role, then records the signing in `review_rule_signatures` (append-only, reviewer accounts only, part of the routing digest and of every snapshot) and writes the same signature into the file, in one transaction; `load` refuses a rule that is unsigned, changed since it was signed, signed by an account that is not (or no longer) a reviewer, or whose signature has no matching row on this installation. So a signature written into the file by hand does not load, and forging one needs write access to the repository and to that table. It is an attestation, not cryptography.

**How a run uses it.** Before the first batch, `Backfill.decisions/2` decides every record at once from what the run would see — the evidence check, the decision `Classifications.record/1` would leave current (`Classifications.preview/1`), each record's page with its lifecycle and canonical address, who holds each address it might take and as what kind of path, the latest review a human made — so a group is decided together and import order decides nothing. That is the dry run, and it writes nothing; the task passes those decisions into the run, which executes them. Each record is then processed as a review would be: before a confirmation is written its collision group (or the record alone) is decided again from what the batch now sees, and the record is deferred if any member's decision moved — a human deferred it meanwhile, a page was retired, an address was taken — so the run writes what it printed or defers, never something else; a confirmation writes the signer's override (once), the page and the address, atomically as before; a kept address writes nothing; a deferral is `deferred_by_review` with the clause, and gets no page. A population whose collision groups are not its own (a member that is not a record, a member whose candidate path is not the group's, an empty group) is refused at load. A run is decided by a review file or by the rule, never both.

**What it reproduces** (`review_rule_reproduction_test.exs`, on #224's own population, the part of its export the evaluation reads, its worksheet and the owner's review file, `test/fixtures/routing/cp4-224/`; C10 as the owner amended it on 9 October 2026):

- From the evidence alone, with nobody's decision, it confirms **96** (47 uncontested, 49 in qualified groups) and defers **33**. Every confirmation is one the owner made, in the owner's family and at the owner's path. It never confirms what the owner deferred. The 28 of the owner's confirmations it defers are exactly the judgments its clauses forbid a rule: the 14 sole-candidate classifications, the 3 blocked collision rows and the 6 members of the two groups they block (`/places/vik`, `/works/crocodile-tears`), the 2 duplicate identities the owner told apart, and the 3 addresses the policy would spell from punctuation (`project-gutenberg-sharp-972-1911-text`, `leme-ver-dot-1-dot-0-…`, `martins-famous-pastry-shoppe-inc-dot`), which the owner named by hand and the rule leaves to a human.
- From the state #224 left, the rule keeps exactly the owner's **124 confirmations and 5 deferrals** — family, path and fingerprint — and writes nothing: every confirmation is an address the owner's review already allocated, which `standing_decision` keeps. That is a read-back, not a reproduction: what it shows is that the rule never decides over a human.
- `Routing.Qualifier` regenerates all 55 of the population's proposed qualifiers from the export (`qualifier_test.exs`). On adversarial text the port and `candidates.py` can differ (Unicode word classes, control characters, Unicode versions); every such divergence makes a path the population did not propose, which the rule defers, never another address.
- C10's remaining part, a `--rule` run on a disposable copy deciding a widened population, is PR 3's, before the launch manifest is generated.

## Checkpoint integrity

`routing_backfill_runs` and `routing_backfill_items` are append-only in the database. The one exception is a run's `finished_at`, which is set once. Both refuse `TRUNCATE` as the routing tables do.

## Limits

- **Dependencies, not the whole graph.** A run checks the records the evaluation read or looked for, which is everything its result depends on. It does not re-read the rest of the graph, and it does not re-evaluate from the database: a change it detects defers the record rather than classifying it afresh. Collision groups are the population's, fixed at export: an entity that arrives later on the same bare path does not stop a confirmation made without a path, although the ledger still gives the path to one page only.
- **Races.** The ledger's locks turn a concurrent writer into a refusal, which the savepoint rolls back. A writer that bypassed those locks loses to an address's unique index instead; inside the batch's transaction the ledger cannot retry that, so it raises, the batch rolls back and the run stops. Running it again resumes it, and the taken address is then refused before anything is written. A batch holds the ledger's locks (addresses, pages, paths) for its records until it commits, so it can deadlock with any concurrent ledger operation that takes them in another order — a second run, or a human allocation; PostgreSQL aborts one side. An aborted batch rolls back and its run stops; running it again resumes it. Two runs confirming one record in different families serialise: the second refuses the address the first allocated (a regression).
- **Run key and code.** The run key names the inputs, the policy data and the checkpoint format (`routing-backfill/2`), not the evaluator's code. A run begun on code older than `ba873db`, which stopped pinning matched anchors, and resumed on newer code finds its confirmations' fingerprints stale and defers them. That is safe, and only rehearsal copies hold such runs.
- **Recovery.** The checkpoint is not part of the routing guard's digest. Losing it costs a re-run, and the re-run's writes are idempotent.
- **Which database.** The export's `database` attestation is not compared with the database being written, because a copy has another name. The content checks decide.

## Run

```bash
DD_NO_OBAN=1 mix dd.routing.backfill --snapshot EXPORT.jsonl --population candidates.json --manifest MANIFEST.json
```

Add `--reviews REVIEWS.json` once the reviewers have decided. The manifest is the candidate launch manifest: every population record with its disposition, decision, draft page, and its address, allocated or proposed.

## Rehearsal

On 27 September, at `495c118`, on copies of the development corpus as captured at 13:29 UTC (the scratch cluster; the source was only read). The copies were made from the capture itself, with no rehearsal fixture, and exported as the population was ([`candidates.json`](candidates.json), export SHA-256 `7524e9e3…`).

**Migration.** Checked against a reference made from the source's own schema and migration history. The copies carry two migrations from unmerged #210, which no empty reference could reproduce. The migration kept all 66 pre-existing tables unchanged and added exactly one migration, two tables and 67 schema rows.

**Runs on the first copy:**

| Run | Records | Result | Time |
|---|---:|---|---:|
| Without reviews | 170 | 129 `awaiting_review` (108 draft pages), 41 `not_addressed` | 2.3 s |
| The same again | 170 | nothing written: every id identical | 1.0 s |
| With rehearsal reviews, made from that run's manifest | 170 | 105 `allocated`, 24 `deferred_by_review`, 41 `not_addressed` | 2.5 s |
| The same again | 170 | nothing written: every id identical | 1.0 s |
| **The same reviews in other bytes**: a new run key over the same state | 170 | every record processed again. Every page, path, decision and ledger id unchanged; only the 170 new checkpoint rows added | 2.0 s |

**The rehearsal reviews are a rule, not approvals.** They confirm every allocation candidate's family, confirm every proposed qualifier as proposed, and defer the rest. Each names the fingerprint the manifest reported. Their only purpose is to exercise allocation at corpus scale on an isolated copy. The file is marked `"rehearsal": true`, which the backfill refuses anywhere else (`rehearsal/backfill.exs`).

**Crash and resume.**
- A second copy ran the same inputs. Its run without reviews matched the first copy's id for id.
- Its reviewed run was killed with `SIGKILL` after 72 of 170 checkpoint rows, unfinished, and then resumed.
- Afterwards all 170 objects matched the uninterrupted copy (`Backfill.state/1`): checkpoint rows and what they reference, the full decision history (275 decisions), the pages, their addresses, and every ledger row (210).
- Page ids were identical. The ids of paths, decisions, ledger rows and checkpoints differ only by the sequence values the killed batch consumed before it rolled back.

**Recovery of backfilled state.** The first copy, after all five runs, was snapshotted, restored into a new database, and `mix dd.routing.verify` matched it exactly: 275 decisions, 108 pages, 105 paths, 210 ledger rows, 510 checkpoint rows, 3 runs, and every path and page resolution.

**What the rehearsal and a review found.**
- The first corpus run refused both editions in the population, *Project Gutenberg #972* and the LEME 1755 transcription: it asked for a subject page, which `Pages.ensure/3` rightly refuses for an edition. The backfill now takes the page role the evaluator gives.
- An internal review found that reviews were not bound to the evidence reviewed, that pins were compared with the newest revision rather than the current one, and that an override could be written before a refusal. It also found gaps in the load checks and a checkpoint open to `TRUNCATE`, and that the repeat-run proof reused one run key. All are fixed in `495c118`. The regressions for binding, pin currency and refusal order fail without their fixes.
- The [independent audit](https://github.com/razrfly/dictionary/issues/194#issuecomment-5860062126) reproduced two defects that remained at `4b4a64b` and `0415e5b`. **P1:** only the matched evidence was checked for currency, so a class the walk visited without a match could change after the export — gaining an ancestor that maps elsewhere — and an old confirmation still allocated. **P2:** the override was written before the page and the ledger were asked, so a later refusal (a retired page, in the audit's probe) left a permanent reviewer override behind. Both are fixed under [#219](https://github.com/razrfly/dictionary/issues/219): every dependency is checked, and a confirmation's writes share one savepoint. The audit's two probes are regressions in `backfill_test.exs`, with seven more: newly arrived ancestry, a contradicting unmatched branch, a page of another role, a path taken and a canonical given by a concurrent writer after the checks, a subject's kind changing mid-batch, and a writer that bypassed the ledger's locks. Eight of the nine fail on the unfixed code; the ninth records a raise that was already right and now also proves the resume. The independent re-review added three, at `ba873db`: a matched anchor's own record changing after the export defers nothing, whether the export held it or not (a policy anchor is matched by its id and never read, so it is not a dependency); and two concurrent runs confirming one record in different families leave one override and one address. The runs above predate these fixes; the [re-run on the corrected code](#re-run-on-the-corrected-code-219) follows.

**Before a persistent run:**
1. The owner decides on the corpus catch-up, the population and the reviewers.
2. The population is re-derived from a fresh export of the corpus as it then is.
3. The run: without reviews first. Its manifest is what the reviewers review.
4. Then the run with the reviewers' own file, and the candidate launch manifest from it.

## Re-run on the corrected code (#219)

On 28 September, at `e47d749`: #216's `ba873db` merged with #208's `771f471`, the code both PRs merge. Every copy was fresh. Each was restored with the corrected tooling from the frozen 13:29 capture (`c1.dump`) and verified exact against `devils_dictionary_stage2r_c1` (69 sections). The export, audit, population and rehearsal reviews were all regenerated; nothing from the first rehearsal was reused.

**Inputs.**
- **Migration:** checked against a reference made from the capture's own schema. The 66 pre-existing tables were unchanged. Exactly one migration (`20260927200717`), two tables and 67 schema rows were added.
- **Export**, with the committed SQL: 173,805 lines, SHA-256 `3a2528f7…`. Only line 1 differs from the first rehearsal's export, because it records the database and the time.
- **Audit:** only `dependencies` and `evidence` differ from before, on 26,510 entities. The only change is dropped policy anchors (Q5, Q16521, Q11424, …). No outcome changed.
- **Population:** the same 170 records, dispositions, families and paths (records digest `c493ba0e…`, as before). File SHA-256 `33ea8229…`.
- **Rehearsal reviews**, made from this run's own manifest: 129 (105 confirm, 24 defer), each naming the fingerprint this run reported. SHA-256 `ff3ed353…`; the same reviews in other bytes are `60a1b025…`.

**Runs on the first copy** (batches of 5):

| Run | Records | Result | Time |
|---|---:|---|---:|
| Without reviews | 170 | 129 `awaiting_review` (108 draft pages), 41 `not_addressed` | 3.9 s |
| The same again | 170 | nothing written (`pg_stat_user_tables`); ids and manifest identical | 2.8 s |
| With rehearsal reviews | 170 | 105 `allocated`, 24 `deferred_by_review`, 41 `not_addressed` | 4.3 s |
| The same again | 170 | nothing written; ids and manifest identical | 3.3 s |
| The same reviews in other bytes: a new run key | 170 | the same outcomes; only 170 checkpoint rows and one run added | 4.0 s |

No record was deferred as `evidence_changed` or `input_changed`, and none was refused.

**Crash and resume.**
- A second copy's run without reviews matched the first copy's manifest exactly.
- Its reviewed run was killed with `SIGKILL`, by its exact process id, at 30 checkpoint rows, unfinished, and then resumed.
- `Backfill.state/1` is byte-identical to the uninterrupted copy's (`732692e2…`), and so is the manifest.
- Page, path, ledger and checkpoint ids are identical. One decision id differs: the sequence value the killed batch drew before it rolled back.

**Recovery of backfilled state.** The first copy was snapshotted, restored into a third, and `mix dd.routing.verify` matched it exactly: 71 sections and every path and page resolution. The runs wrote 275 decisions, 108 pages, 105 paths, 210 ledger rows, 510 checkpoint rows and 3 runs. The capture's 12 earlier pages, 14 paths, 12 decisions and 42 ledger rows were untouched.

**Against the first rehearsal, only fingerprints and ids changed.** Dispositions, reasons, families, addresses, proposed paths and page roles are the same for every object. The evidence fingerprint differs on 54 of the 170. Those are exactly the objects whose dependencies lost an anchor; Bierce's pins, for example, went from `[Q191050, Q5]` to `[Q191050]`.

The evidence is local, under `data/audits/2026-09-28-219/a5-final/`, with `SHA256SUMS`. The backfilled dump is `219d-backfilled.dump` (SHA-256 `6335d6f2…`). The copies `devils_dictionary_stage2r_219d`, `_219e`, `_219f` and `_219ref2` stay on the scratch cluster for #219's database inventory.
