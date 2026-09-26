# Routing Stage 2 handoff — backfill and review (not started)

**Status:** a proposal, 27 September 2026, for [routing issue #194](https://github.com/razrfly/dictionary/issues/194). Nothing here has been backfilled, allocated, approved or published. The population and dispositions were derived **read-only** from the 26 September audit manifest (policy 1.0.0, 100,723 entities) by [`candidates.py`](candidates.py), whose output is [`candidates.json`](candidates.json). Re-derive them from a fresh export before Stage 2 writes anything: the database has moved since the audit.

```bash
python3 docs/routing/stage-2/candidates.py docs/routing/stage-2/candidates.json
```

The script reads the ignored archives under `data/audits/2026-09-26-issue194/` (see [the audit's reproduction notes](../../audits/2026-09-26-issue194/policy-readiness.md#reproduce)). Every proposed and candidate path in the output passes `Routing.Address.parse/1`.

## A bounded candidate population: 169 entities

Selected by a stated rule, not by hand:

| Selected because | Records |
|---|---:|
| Policy boundary examples, including every event, edition and artifact in the snapshot | 54 |
| The repeatable stratified mapped sample: six per family, all four mapped events | 46 |
| Named ADR edge cases present in the snapshot (Ambrose Bierce, The Devil's Dictionary, Apple, Mercury, Polish, Love/love, Human/human) | 45 |
| Every member of each candidate-path collision group touching any of the above: 11 groups, decided together | 64 |

Records can qualify for several reasons. All eight families are represented among the 111 mapped records: people 12, organizations 8, places 17, events 4, works 50, concepts 6, nature 8, subjects 6. Stored kinds span concept, event, person, work, place, taxon, artifact, organization and edition.

Named examples **absent** from the snapshot (C++, C+, c, Voltaire the philosopher, Putin, poutine, earthquake) are not minted to fill the set. They remain deliberate CI fixtures. `C++` and `C+` exist only as lexemes.

## Dispositions

Every record has exactly one. Classification and collision approval are **not** publication approval, which remains Stage 5's gate.

| Disposition | Records | What happens in Stage 2 |
|---|---:|---|
| Allocation candidate once classification review confirms the mapping | 50 | A reviewer confirms the mapping, then `Ledger.allocate/3`. |
| Collision review: readable, evidence-backed qualifier proposed | 55 | A reviewer approves or edits each qualifier, then allocation. |
| Collision review blocked: classification review first | 3 | Classify, then join their group's decision. |
| Duplicate-identity review first | 6 | Decide whether each pair is one subject twice (registry merge) or two subjects (then qualify). |
| Classification review: a sole candidate family needs a human decision | 14 | Override or leave for review. No allocation without a `mapped` decision. |
| Deferred: no family evidence | 38 | Stays unaddressed and visible with its reasons. |
| Deferred: identity lifecycle review | 1 | "Issue 84 split artwork", a development fixture present in the corpus; never publish it. |
| Excluded: source page | 2 | The Human and Polish disambiguation pages. Never subject addresses. They may inform a future choice or collection page, whose namespace is undefined. |

The other **100,554** entities stay deferred with their audit dispositions. Stage 2 must keep them visible, not silently drop them.

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
| `/works/the-devils-dictionary` | 2 | **Duplicate-identity review.** Seeded work 2 against 3740879, which has no description. Likely one work twice. |
| `/works/mona-lisa` | 2 | **Duplicate-identity review.** The painting against an undescribed record. |
| `/works/love` | 2 | **Duplicate-identity review.** Two undescribed poems. |

Each record's proposal, evidence and disposition is in `candidates.json`.

## Rules Stage 2 inherits from Stage 1

- **Collection and choice pages stay unallocated.** Their namespace is undefined, and `Ledger.allocate/3` refuses them.
- **Split pages keep their existing address** and their ordered successor choice. A split never redirects to one successor.
- **Classification and address changes are separate.** A reclassification never moves an allocated address; only an approved `move/3` does.
- **A tombstone is never re-allocated by a batch.** Only a human `restore/3` or a rollback brings one back.
- **Refusals are per record.** `Ledger.allocate/3` and `Pages.ensure/3` return error tuples without rolling back a caller's batch transaction.

## Gates before any persistent backfill

1. **Tested recovery.** Delivered in Stage 1: [recovery procedure](../recovery.md) and `RecoveryTest`. Before the first persistent write, **exercise it on the development corpus**: snapshot `devils_dictionary_v2`, restore it into a separate database, run `mix dd.routing.verify`, and record the timing.
2. **Repeat-run identity preservation.** Running the backfill twice must leave page, path and decision ids unchanged, compared as sets.
3. **Crash and resume.** An interrupted run resumed from its checkpoint (keyed by object id and policy digest) must equal an uninterrupted run, by exact identities and references.

Stage 2's exit evidence: those three tests; every selected record resolved or explicitly deferred; a candidate launch manifest of page ids and paths; the deferred remainder visible with its dispositions; and `mix dd.routing.verify` passing after a restore of the backfilled database.

## Decisions the owner genuinely needs to make

These are the only decisions blocking Stage 2. None has been taken or assumed.

1. **The population.** Accept this 169-record rule, or change its size or composition.
2. **Classification and collision reviewers.** Name the human `user` accounts, with the existing reviewer role, who approve overrides, qualifiers and duplicate-identity outcomes. The database already refuses non-human overrides and route operations.
3. **Publication approver (Stage 5, not needed now).** Name who approves publication separately from the reviewers above. Stage 2 grants no publication.
