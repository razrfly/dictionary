# Routing Stage 2 handoff — backfill and review

**Status:** 27 September 2026, for [routing issue #194](https://github.com/razrfly/dictionary/issues/194).
- **Population:** a proposal. It was **refreshed** from a read-only export of the development corpus as captured at 13:29 UTC on 27 September (policy 1.0.0, 100,784 entities; export SHA-256 `7524e9e3…`) by [`candidates.py`](candidates.py), whose output is [`candidates.json`](candidates.json). It replaces the 26 September derivation (100,723 entities, 169 records), which differed by one record.
- **Backfill:** implemented, and rehearsed on isolated copies ([backfill](backfill.md)).
- **Development corpus:** nothing has been backfilled, allocated, approved or published on it.

Re-derive the population from a fresh export before any persistent run: the backfill refuses a population derived from any other export. After the proposed [corpus catch-up](corpus-catch-up.md), a fresh derivation has the same 170 records and dispositions. Only 14 records' stored kind changes (concept → work or event), which the policy does not classify by.

```bash
python3 docs/routing/stage-2/candidates.py docs/routing/stage-2/candidates.json
```

By default the script reads the ignored archives under `data/audits/2026-09-26-issue194/` (see [the audit's reproduction notes](../../audits/2026-09-26-issue194/policy-readiness.md#reproduce)). To re-derive the population from a fresh audit before Stage 2 writes:

```bash
psql -X -qAt -v ON_ERROR_STOP=1 -h localhost -U postgres -d devils_dictionary_v2 -f docs/audits/2026-09-26-issue194/policy-export.sql > /tmp/routing-input.jsonl
```

```bash
mix dd.routing.audit --input /tmp/routing-input.jsonl --output /tmp/routing-audit
```

```bash
python3 docs/routing/stage-2/candidates.py /tmp/candidates.json --audit /tmp/routing-audit --input /tmp/routing-input.jsonl
```

The export is read-only. The boundary and stratified selections name registry object ids, which a fresh export of the same database keeps. `--boundaries` and `--stratified` replace them. A selected id that the fresh audit lacks is listed under `selection_missing_from_audit`, not dropped silently. Run on the 26 September audit decompressed into that shape, the script yields the same records digest as the archives.

**The inputs are bound to the audit.** Otherwise descriptions from one snapshot could qualify classifications from another. The script refuses, and writes nothing, when:
- the export's SHA-256 over its uncompressed bytes differs from the audit summary's `input_sha256`;
- the summary's entity count or policy version does not match the assignments;
- an object id appears twice among the assignments or the exported entities.

The output's `summary.inputs` records the audit summary, the assignments and export files, their SHA-256 digests (for the archives, the assignments digest equals the one pinned in [`reproducibility.json`](../../audits/2026-09-26-issue194/reproducibility.json)), and the policy version and digest.

**Slugs are the application's.** The script's `slug/1` follows `Routing.Policy.slug/1` step for step:
- NFC normalization;
- per-character lowercase, so a final sigma stays σ, as in Elixir;
- `+ # & .` spelled out, and apostrophes removed;
- letters, marks and numbers kept, and every other run of characters turned into one hyphen;
- at most 120 bytes.

[`slug-parity.json`](slug-parity.json) records 29 cases, covering NFC/NFD, combining marks, punctuation and the byte limit. `slug_parity_test.exs` holds the application to them, and `test_candidates.py` holds the script to them. Collisions are detected on the normalized final paths.

All 130 distinct paths in the output pass `Routing.Address.parse/1` unchanged. These are 75 candidate paths, shared within collision groups, and 55 proposed qualifiers. Proposals are unique within their group, **across groups**, and against every candidate path in the snapshot (`global_proposal_conflicts: 0`).

```bash
python3 -m unittest discover -s docs/routing/stage-2 -p 'test_candidates.py'
```

## A bounded candidate population: 170 entities

Selected by a stated rule, not by hand:

| Selected because | Records |
|---|---:|
| Policy boundary examples, including every event, edition and artifact in the snapshot | 54 |
| The repeatable stratified mapped sample: six per family, all four mapped events | 46 |
| Named ADR edge cases present in the snapshot (Ambrose Bierce, The Devil's Dictionary, Apple, Mercury, Polish, Love/love, Human/human) | 46 |
| Every member of each candidate-path collision group touching any of the above: 11 groups, decided together | 65 |

Records can qualify for several reasons. All eight families are represented among the 112 mapped records: people 12, organizations 8, places 17, events 4, works 51, concepts 6, nature 8, subjects 6. Stored kinds span concept, event, person, work, place, taxon, artifact, organization and edition.

Named examples **absent** from the snapshot (C++, C+, c, Voltaire the philosopher, Putin, poutine, earthquake) are not minted to fill the set. They remain deliberate CI fixtures. `C++` and `C+` exist only as lexemes.

## Dispositions

Every record has exactly one. Classification and collision approval are **not** publication approval, which remains Stage 5's gate.

| Disposition | Records | What happens in Stage 2 |
|---|---:|---|
| Allocation candidate once classification review confirms the mapping | 50 | A reviewer confirms the mapping, then `Ledger.allocate/3`. |
| Collision review: readable, evidence-backed qualifier proposed | 55 | A reviewer approves or edits each qualifier, then allocation. |
| Collision review blocked: classification review first | 3 | Classify, then join their group's decision. |
| Duplicate-identity review first | 7 | Decide whether each group is one subject more than once (registry merge) or distinct subjects (then qualify). |
| Classification review: a sole candidate family needs a human decision | 14 | Override or leave for review. No allocation without a `mapped` decision. |
| Deferred: no family evidence | 38 | Stays unaddressed and visible with its reasons. |
| Deferred: identity lifecycle review | 1 | "Issue 84 split artwork", a development fixture present in the corpus; never publish it. |
| Excluded: source page | 2 | The Human and Polish disambiguation pages. Never subject addresses. They may inform a future choice or collection page, whose namespace is undefined. |

The other **100,614** entities stay deferred with their audit dispositions. Stage 2 must keep them visible, not silently drop them.

## Collision groups touching the population

Each group is decided as a whole, and import order never picks a primary. Qualifiers come only from each record's own evidence: a work's year, kind and, where needed, creator; a person's occupation; a place's location; an organization's origin and type. They are proposals, and a human approves each one.

| Group | Members | Proposal |
|---|---:|---|
| `/works/butterfly` | 19 | Year and kind, e.g. `/works/butterfly-1997-album`, `/works/butterfly-2015-film`, `/works/butterfly-novel` |
| `/works/human` | 15 | Year and kind, with the creator where year and kind collide, e.g. `/works/human-2014-album-max-cooper` and `/works/human-2014-album-masaharu-fukuyama` |
| `/places/vik` | 7 | Municipality, e.g. `/places/vik-vestnes`. Two members are blocked on classification review. |
| `/places/mount-tom` | 6 | State or county, e.g. `/places/mount-tom-new-hampshire` |
| `/people/billy-lee` | 5 | Occupation, e.g. `/people/billy-lee-irish-jockey`, `/people/billy-lee-baseball-player` |
| `/places/daman` | 2 | `/places/daman-afghanistan`, `/places/daman-india` |
| `/organizations/the-creatures` | 2 | `/organizations/the-creatures-australian-band`, `/organizations/the-creatures-british-group` |
| `/works/crocodile-tears` | 2 | The film qualifies as `/works/crocodile-tears-2024-film`; the novel is blocked on classification review. |
| `/works/the-devils-dictionary` | 2 | **Duplicate-identity review.** Seeded work 2 and record 3740879. Neither has a description to tell them apart. Likely one work twice. |
| `/works/mona-lisa` | 2 | **Duplicate-identity review.** The painting against an undescribed record. |
| `/works/love` | 3 | **Duplicate-identity review.** Three undescribed works named *Love*. The third (3742759) joined the corpus after the 26 September audit. |

Each record's proposal, evidence and disposition is in `candidates.json`.

## Rules Stage 2 inherits from Stage 1

- **Collection and choice pages stay unallocated.** Their namespace is undefined, and `Ledger.allocate/3` refuses them.
- **Split pages keep their existing address** and their ordered successor choice. A split never redirects to one successor.
- **Classification and address changes are separate.** A reclassification never moves an allocated address; only an approved `move/3` does.
- **A tombstone is never re-allocated by a batch.** Only a human `restore/3` or a rollback brings one back.
- **Refusals are per record.** `Ledger.allocate/3` and `Pages.ensure/3` return error tuples without rolling back a caller's batch transaction.

## Gates before any persistent backfill

1. **Tested recovery.** Delivered in Stage 1: [recovery procedure](../recovery.md) and `RecoveryTest`. Rehearsed on the development corpus in [Stage 2A](recovery-rehearsal.md), and again, with routing and curation state, in the [recovery repair](recovery-repair.md).
   - **Passes:** snapshot, restore and exact verification. Every provider re-projects to completion, with identities, references, routing history and curation approvals exact, and normal operations work on the projected copy.
   - **Open:** the corpus is not yet a fixed point of today's materializers. The measured [catch-up](corpus-catch-up.md) needs the owner's decision, and the checkpoint needs independent reassessment.

   This gate stays open until both are done.
2. **Repeat-run identity preservation.** Running the backfill twice must leave page, path and decision ids unchanged, compared as sets. **Shown**, in `BackfillTest` and on copies of the corpus ([backfill](backfill.md#rehearsal)). A second run, with or without reviews, wrote nothing. A second full pass under a new run key left every page, path, decision and ledger id identical, adding only its own checkpoint.
3. **Crash and resume.** An interrupted run resumed from its checkpoint (keyed by object id and policy digest) must equal an uninterrupted run, by exact identities and references. **Shown**, in `BackfillTest` and on a copy. A run was killed with `SIGKILL` after 72 of 170 records and resumed. Every one of the 170 objects then matched an uninterrupted copy: decision history, page, addresses, ledger rows and checkpoint references. Numeric ids differ only by the sequence values the killed batch consumed.

Stage 2's exit evidence:
- those three tests;
- every selected record resolved or explicitly deferred;
- a candidate launch manifest of page ids and paths;
- the deferred remainder visible with its dispositions;
- `mix dd.routing.verify` passing after a restore of the backfilled database.

On copies, all of it now exists: the manifest (`mix dd.routing.backfill --manifest`), and an exact restore of a backfilled copy. On the development corpus it waits for gate 1 and the owner's decisions below.

## Decisions the owner genuinely needs to make

These are the only decisions blocking Stage 2. None has been taken or assumed.

1. **The population.** Accept this 170-record rule, or change its size or composition.
2. **Classification and collision reviewers.** Name the human `user` accounts, with the existing reviewer role, who approve overrides, qualifiers and duplicate-identity outcomes. The database already refuses non-human overrides and route operations.
3. **Publication approver (Stage 5, not needed now).** Name who approves publication separately from the reviewers above. Stage 2 grants no publication.
