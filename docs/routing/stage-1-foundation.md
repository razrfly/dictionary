# Routing Stage 1 — the durable foundation

**Status: implemented, 26–27 September 2026, for [routing delivery issue #194](https://github.com/razrfly/dictionary/issues/194), in [PR #205](https://github.com/razrfly/dictionary/pull/205). Completed against [the Stage 1 audit](https://github.com/razrfly/dictionary/issues/194#issuecomment-5850535055); awaiting reassessment and review before merge.** [ADR 0004](../adr/0004-public-routing.md) is the contract. This page records how Stage 1 implements §5–6 and §8's recovery requirement, the decisions made while implementing it, the reviews it has had, the evidence (kept separate by kind), an [acceptance matrix](#acceptance-matrix), and the [Stage 2 handoff](stage-2/README.md).

Stage 1 adds storage, invariants, a ledger and a resolver. It **adds no route, rewrites no reader, allocates no production path and publishes nothing.** `/words/:id/:slug`, `/define/:slug` and `/entities/:id/:slug` are unchanged, and nothing in the router calls the new code. Backfill (Stage 2), reader integration (Stage 3), On editing (Stage 4) and publication (Stage 5) remain.

## What exists now

One additive migration, `20260926193256_create_routing_foundation`, creates six tables. No existing table is altered.

| Table | Holds | Integrity, and where it is enforced |
|---|---|---|
| `pages` | Durable page identity: role (subject, edition, lexeme, overview, collection, choice), locale, optional target object, `publication_state` (draft/published/withdrawn), `lifecycle_state` (active/merged/split/retired), `merged_into_page_id`, current-revision and canonical-path pointers. | Target required exactly for subject/edition/lexeme (CHECK). Role fits target kind (deferred trigger). One subject/edition page per target and locale; one lexeme page per target and locale (partial unique indexes). Role, locale and target never change; a page is born active and unrouted; it is never deleted. A page about a registry object can merge only into a page about the same surviving identity, and is split only when its identity is (deferred trigger). |
| `page_revisions` | Immutable editorial revisions: number, title, body, author/reviewer actors, evidence, `membership_count`. | Unique `(page_id, revision_number)`. A page's current revision must be its own (composite FK). No UPDATE or DELETE. Changing the current revision of a split, merged or retired page is a routing change and needs a ledger row. |
| `page_memberships` | Ordered, typed members of one revision: `supplies_lexical_material`, `discusses_subject`, `editorial_association`, `choice_option`, `split_successor`; exactly one target object or target page. | Revision ownership by composite FK. The revision's `membership_count` seals it: a row can only fill positions `1..n`, and at commit all `n` are filled, so nothing can be added afterwards. No self-membership, UPDATE or DELETE. |
| `public_paths` | Every reserved address, stored decoded and normalized (`/people/чехов`): kind (canonical/alias/tombstone), immutable `original_page_id`, current `destination_page_id`, `last_route_change_id`. | **One uniqueness domain** for every kind. One canonical per page. A registered namespace, NFC, lowercase, no dot segment, and a slug whose ASCII is only `a-z`, `0-9` and single inner hyphens (CHECK), so no stored path is one a request could never name. Spelling and original owner never change; no DELETE. A path serves its owner or that owner's approved merge successor and nothing else, in the page's locale (deferred trigger). |
| `classification_decisions` | Versioned evaluator results and human overrides: status, selected family, candidate families, rule ids, reasons, warnings, policy version, evidence fingerprint, source pins, reviewer, reason, `supersedes_id`, `is_current`. | One current decision per entity. A family is selected **only** by `mapped`; review, exclusion and identity review select none (CHECK), so there is no silent Subjects fallback. Immutable except losing currency. An override needs a human (`user`) reviewer and a reason. No foreign key to any path. |
| `route_changes` | The append-only ledger: operation id and sequence; operation (allocate, move, merge, split, retire, rollback); a path transition (kind and destination before/after) or a page transition (lifecycle, canonical pointer, merge successor, revision before/after); classification decision and policy version; actor; reason; `reverts_operation_id`. | No UPDATE or DELETE. Every row changes something, and a page row changes its route, not only its revision. Only allocation may be a machine's, and an `allocate` row can only create or reclaim a canonical for its own page. A rollback names an earlier operation. Every row was applied and continues the previous row for its path or page (deferred trigger). |

The six tables refuse TRUNCATE, including one cascading from `objects`. The only exception is an explicit, transaction-local opt-in (`dictionary.allow_routing_truncate`), which the test suite's reset uses.

### How the ledger stays complete and true

A path's `kind` or `destination_page_id`, a page's lifecycle, canonical pointer or merge successor, and the revision of a page that is not active, change only if the same statement names a **new** `route_changes` row. That row's before-state must equal the old row and its after-state the new one. BEFORE triggers check this immediately, so a raw `UPDATE` from a console, a future bug or a hand-written backfill fails at the statement rather than leaving unrecorded history. The ledger row is written first; its `path_id` foreign key is deferred because a new path is inserted after the row that describes it.

The converse holds at commit: each ledger row must have been applied and must continue the previous row for its path or page. The ledger is therefore a verified chain, with no gaps and no invented links.

Other cross-row rules are deferred constraint triggers checked at commit, because a move or merge is legitimately inconsistent between its statements:

- a page's canonical pointer names a canonical path whose destination is that page, and a canonical path's page points back at it;
- a published active or split page has a canonical;
- a merged page receives no paths, and a retired page keeps only tombstones;
- a merged page's successor has the same role and locale. If the page is about a registry object, the registry must have merged that object, and both pages' targets must resolve to the same survivor. Survivors are read as `Registry.canonical_id/1` reads them: a chain through a split, or a cycle, has no survivor but the object itself;
- a split page's identity is split in the registry;
- a path's destination is its original owner or reachable from it along `merged_into_page_id` (bounded at 64 hops). Changing a page's lifecycle or successor re-checks every path whose owner's merge chain passes through it.

```text
allocate(/people/voltaire)       move(/people/arouet)                 merge(page 7 → page 9)
page 7 ─canonical─▶ /people/…    /people/arouet   canonical ▶ page 7   /people/arouet   alias ▶ page 9
                                 /people/voltaire alias     ▶ page 7   /people/voltaire alias ▶ page 9
                                   (301 → /people/arouet)              page 7: merged, successor 9
                                                                       original owner of both: page 7
```

Every alias names a destination **page**, and the resolver reads that page's current canonical directly. An old address is therefore one 301 from its answer however many moves or merges followed.

## Operations

`Routing.Ledger` is the only writer of addresses. Each operation is one transaction that locks, validates and only then writes.

- **Lock order.** Every operation takes its locks in one order: advisory locks on the normalized paths (sorted), then page rows by id, then path rows by id. Operations therefore do not wait on each other in a cycle.
- **Races.** The unique indexes on addresses are the final arbiter. An operation that loses a race on them, or hits a serialization or deadlock failure, is attempted at most three times in all. Each retry emits `[:devils_dictionary, :routing, :retry]`. After the third attempt it returns `{:error, :allocation_conflict}`; no caller invents a substitute path. Other violations are defects and are raised, not retried.
- **Inside a caller's transaction.** Every refusal is decided before anything is written and comes back as `{:error, reason}` without rolling the caller back. A batch can therefore refuse one record and keep the rest. The operation's locks are then held until the caller's transaction ends. A lost race inside a caller's transaction is re-raised, because a retry needs a fresh transaction.

| Operation | Actor | Effect |
|---|---|---|
| `allocate(page, path)` | any (a batch job) | Reserves a new canonical for an active page, or reclaims the page's own alias — **never a tombstone**, which it refuses as `{:tombstoned, owner}`, in code and in the database. A subject or edition page needs its target's **current decision to be `mapped` to the path's family**, and the ledger row records that decision and its policy version. Idempotent: re-allocating a page's own canonical returns it and writes nothing, even after the page was reclassified. A taken path returns `{:path_taken, owner}`; a second canonical returns `{:page_has_canonical, path}`. |
| `move(page, path)` | human | New canonical; the old one becomes a permanent alias. Moving back promotes the alias; moving to the current canonical is a no-op; moving onto a tombstone is refused. |
| `merge(from, into)` | human | Every path serving `from` serves `into`, with canonicals becoming aliases. Requires the registry to have merged `from`'s identity into `into`'s; editorial pages merge on the approving human's judgement. A published page cannot merge into an unpublished one. |
| `split(page, successors)` | human | Requires a registry split, and each successor must be the page of one split output. Writes a revision with `split_successor` memberships in the given order. The page keeps its paths and resolves to a choice, never a redirect to one successor. A published page's successors must be published. |
| `retire(page)` | human | Every path becomes a tombstone: reserved forever. It answers 410 for a page the public has seen (published or withdrawn) and 404 otherwise. |
| `restore(page, path)` | human | The deliberate way back from a removal: one of the page's own tombstones becomes its canonical again, passing the same family check as an allocation. A retired page becomes active; an active page's current canonical becomes an alias. Its other tombstones stay removed. |
| `rollback(operation)` | human | Restores each recorded before-state in reverse order, as a new ledger operation. A path the operation created stays reserved as an alias of its page: a historical 301 where the page keeps a canonical, 404 where it has none. An editorial revision made since is kept unless the operation itself changed the revision (a split). Operations are undone newest first: an operation can be rolled back while every later change to its paths and pages has itself been rolled back, so merge chains and move sequences unwind all the way back. Otherwise it is refused as `{:stale, …}`, even when the state looks the same again (A→B→A), because the later operations are still in force. A rolled-back rollback is in force again, so its operation can be undone once more. Also refused if it would leave a published page without a canonical. |

`Routing.Pages` creates pages and writes whole revisions. `ensure/3` is idempotent under concurrency. It rejects a nil target (`:target_required`), a non-integer or non-positive target (`:invalid_target`) and an unknown role (`:invalid_role`) before any query. A missing object (`:target_not_found`), a wrong target kind and a malformed membership also come back as error tuples rather than database exceptions, so a malformed record is one record's error inside a caller's batch transaction.

`Routing.Classifications` records `Routing.Policy.classify/3` results and human overrides:

- **What is stored.** A family is stored only for a `mapped` result. The evaluator also names a sole candidate as `family` on review results, but that is not a selection.
- **Fingerprint.** It covers the pinned evidence, matches and warnings, and also the outcome: status, reasons and candidates. A lifecycle change or a disambiguation flag is therefore new evidence.
- **Unchanged evidence.** An unchanged fingerprint keeps an override current and writes nothing.
- **Changed evidence that is not new against the override.** Either the evaluator offers the candidates the reviewer already saw, with no new exclusion or identity review, or it still offers the override's family. The override stays current, and the new evidence is kept as a non-current decision. A second override, made after a contradiction, stands on the evidence it was made on in the same way.
- **Contradictory evidence.** This writes a current `needs_review` decision that supersedes the override. That review is sticky: later imports refresh its evidence, but only a new human override ends it.
- **Stale reviews.** An override names the fingerprint the reviewer saw, and is refused as `:stale_evidence` if that fingerprint has changed.

None of it moves an address.

## Resolver

`Routing.Resolver.resolve/1` takes the raw request path, `resolve_page/1` an exact page id, and `link/1` returns the encoded canonical for an id. Each decision is made from rows read in **one statement**: the path, its page and that page's canonical together. A move or merge committing mid-request therefore never looks like corruption. Each call returns a `Routing.Resolution`:

| Outcome | When | Status |
|---|---|---|
| `:canonical` | a published page's canonical, spelled exactly | 200 |
| `:redirect` | an alias, a merged page's id, or an equivalent spelling (case, Unicode form, trailing slash, hex case) | 301 |
| `:choice` | a published split page, with its successors in order, expanded one level | 200 |
| `:missing` | no such address or id; a near match is never substituted | 404 |
| `:gone` | a tombstone of a page the public has seen (published or withdrawn) | 410 |
| `:unavailable` | a real page, or a reservation, that is not published | 404 |
| `:invalid` | malformed or truncated escape, invalid UTF-8, encoded `/` `\` or NUL, dot or empty segment | 400 |
| `:corrupt` | state the invariants should prevent; diagnostics are logged | 500 |

A request is decoded once, NFC-normalized and lowercased, never re-slugified: `/concepts/c%2B%2B` is missing, not C++. A trailing slash is removed as one byte, never as a grapheme.

## Decisions made while implementing

These refine the ADR without changing it. Each is conservative and reversible by a policy change.

1. **Namespaces by role.** Subjects use their mapped family, editions `/works`, and On overviews `/on`. Lexeme pages are not ledger-addressed; the lexical routes stay as they are. The registry defines no namespace for collection or choice pages yet, so allocating one is refused as `:namespace_undefined`. Stage 4 or 5 decides.
2. **Allocation requires a mapped classification in the path's family.** An unclassified, under-review or differently mapped subject cannot get an address, so an unknown subject cannot slip into `/subjects`. After allocation, a new decision moves nothing.
3. **Approvals are human.** Move, merge, split, retire and rollback require a `user` actor, enforced both in Elixir and in the database. Allocation may be an importer's, and only within the allocation shape.
4. **One page per target and locale, ever.** A retired or merged page keeps its target. A new treatment of the same object in the same locale is a rollback or a new locale, not a second page.
5. **Split pages keep their address.** The split page becomes a choice at its own canonical rather than a new page, and records its successors as a revision.
6. **Nothing reserved is ever released.** An undone allocation or move leaves its path as an alias of its page. That alias is a redirect where the page keeps a canonical and unavailable where it has none, and the page can reclaim it.
7. **A refusal never rolls back the caller.** This lets Stage 2 batch allocations inside one transaction and record per-record refusals.
8. **A tombstone returns only by a human decision.** Allocation, including a batch's, can create a path or reclaim an owned alias. A tombstone records a deliberate removal, so it comes back only through `restore/3` or a rollback. Both are human operations, enforced in the database.

## Curation-composition binding (recorded; migration deferred)

[Curation persistence (#196)](https://github.com/razrfly/dictionary/issues/196) owns `editorial_compositions`, their immutable versions and items, and human presentation approval. Those tables do **not** exist on main, so Stage 1 creates no binding table and no placeholder composition table. When #196 lands, one additive migration adds:

| Column | Rule |
|---|---|
| `page_composition_bindings.id` | bigint |
| `page_id` | FK `pages`, restrict |
| `composition_id` | FK `editorial_compositions`, restrict: a real foreign key |
| `state` | `active` or `ended`; unique active binding per page, and per composition |
| `bound_by_actor_id`, `ended_by_actor_id` | FK `actors`; human only, as for route operations |
| `reason`, `evidence` | why these two identities describe the same scope |
| `bound_at`, `ended_at` | append-only history; ending and rebinding never rewrite a row |

The binding service must validate that the composition's language equals the page's locale, and that its scope membership is compatible with the page's membership. A shared label, slug or URL never establishes a binding.

The page renders only the composition version that the curation publication service has selected and that is still eligible under its own rights and evidence checks. A page approval cannot approve a draft composition or accept a semantic claim, and composition approval grants no page publication.

Route moves and merges keep the binding on the page id. A split page has no single scope, so its binding goes to human reconciliation rather than being carried to a guessed successor (#196: split scopes are never guessed). Persona inference and refresh (#193) are not dependencies.

## Recovery

Registry ids exist only in the database, and a rebuild from sources renumbers every object, so routing state is **restored, not regenerated**. The [recovery procedure](recovery.md) takes these steps:

1. Snapshot the source.
2. Restore into an isolated database.
3. Verify exact identities, references, resolutions and sequences with `mix dd.routing.verify`.
4. Re-project from source records in any provider order (`mix dd.replay`, `mix dd.materialize --all`), and verify again.
5. Exercise the ledger and resolver.

`RecoveryTest` runs these steps end to end against disposable databases, re-projecting with the providers reversed.

`mix dd.reset`, `mix dd.snapshot --restore` and `mix dd.rebuild` refuse a database holding routing state unless a snapshot records its current routing high-water marks. The procedure has not yet been run on the development corpus; that is Stage 2's first gate.

## Independent review

A separate review agent attacked the first version with raw SQL, real races and property checks, and confirmed **17 defects**:

- `Classifications.record/1` crashed on review results that had a sole candidate.
- The resolver's reads were torn, turning about 4% of reads during moves into spurious 500s.
- Allocation's machine-only shape was not enforced, and merge successors were not tied to registry identity. Together these let an address be repurposed by ledgered raw SQL.
- Pages could be un-merged without re-checking their paths.
- Rollback had ABA and editorial-revision errors.
- A grapheme-based trailing-slash strip changed the path.
- Split successors were unguarded, and resolving successors could recurse without bound.
- The database accepted phantom ledger rows.
- TRUNCATE bypassed the immutability triggers.
- `move` could deadlock.
- A refusal inside a caller's transaction rolled the caller back.
- Idempotent allocation failed after reclassification.
- The database accepted unregistered or unnormalized paths.
- A never-published page answered 410.

All 17 are fixed above, and each has a regression test. The review also showed that sandboxed tests can mask two-commit attacks, which is why `committed_integrity_test.exs` now commits its setup before attacking.

A second pass re-ran every scenario against the fixes. It confirmed 13 findings fully fixed and three partly fixed, and found three regressions:

- Rollbacks could no longer be chained, so a merge chain could not be unwound.
- A second override, made after a contradiction, was contradicted again by the same evidence.
- `public_paths.destination_page_id` was unindexed. Retiring a survivor with 300 merged pages took 1,142 ms at 50,000 paths.

It also found lower-severity gaps: a revision-only phantom ledger row, a raw split with no registry split, `+`/`'`/`--` slugs accepted by the database, and a survivor function more permissive than the registry.

All are fixed, with tests. The same retirement now takes 91 ms at 50,602 paths, the same as at 301.

{{THIRD_REVIEW}}

These are agents' reviews and CodeRabbit's, not the owner's. Passing tests and review are not publication approval.

## Evidence

Three kinds of evidence, kept apart because they prove different things.

**Local test results.** {{LOCAL_EVIDENCE}}

**GitHub checks.** The repository has **no test-suite CI**: there is no `.github/workflows`. The checks on PR #205 are GitGuardian, a secrets scan, and CodeRabbit's review status. Neither runs the tests. CodeRabbit's green status means its review completed, not that it found nothing: its review of `0b045d8` posted two actionable findings (the tombstone reclaim and `Pages.ensure`), and both are fixed here.

**Independent review.** See [Independent review](#independent-review). The implementing agent's own tests are not independent review.

| Invariant (ADR §5–6, §8) | Proven by |
|---|---|
| Real concurrent allocation; the index is the final arbiter | `concurrency_test.exs` — six independent connections (distinct backend pids, barrier start, real commits):<ul><li>racing for one path: one winner; five `:path_taken` naming it; exactly one path and one two-row ledger operation;</li><li>racing for one page: exactly one canonical;</li><li>a lock-free writer holding an uncommitted duplicate: the allocator waits on the index, fails, retries once and returns `:path_taken`, and its half-written ledger row is rolled back.</li></ul> |
| Bounded race handling | three attempts, then `:allocation_conflict`; a non-race error is re-raised |
| No deadlock under opposed multi-page locks | merges racing in opposite directions (one wins each pair); crossing moves onto each other's canonical, with no retry needed |
| Consistent reads | 60 moves racing continuous resolution by path and by id: only `:canonical` and `:redirect`, never `:corrupt` |
| Global uniqueness; immutable historical ownership | `schema_integrity_test.exs` and `committed_integrity_test.exs`, raw SQL: second canonical, spelling or owner change, delete and truncate refused; an unregistered, uppercase, decomposed, `+`, `'` or double-hyphen path refused; a split without a registry split refused; a re-point to an unrelated page refused whether ledgered as a move or disguised as a merge; un-merging a page with paths routed through it refused |
| Atomic pointer/allocation/history | an update without a ledger row, with a false before-state, a phantom (unapplied) row, a no-op row, a rollback of nothing, an importer's `allocate`-named retirement, and an unledgered swap of a split page's successors — all refused |
| Exactly one canonical per published page | a pointer at another page's canonical is refused; publishing without a canonical is refused |
| Moves, merges, splits, retirement | `ledger_test.exs`: exact destinations and original owners after a move, a move back, and a three-page merge chain (every old address one hop from the final survivor); a split choice with ordered successors, expanded one level; tombstones stay reserved, answering 410 if published and 404 if not |
| Rollback | exact restoration of a move and a merge; two moves and a three-page merge chain unwound newest first; undo, redo and undo again; a created path kept as a redirect; ABA, out-of-order and double rollbacks refused; an editorial revision survives a rollback; a rollback that would unpublish is refused |
| Batch safety | a refusal inside a caller's transaction keeps the caller's earlier allocation |
| Versioned overrides | `classifications_test.exs`: human-only; stale evidence refused; sole-candidate review stored without a family; lifecycle-only change is new evidence; an override survives both identical evidence and the evaluator's own overridden outcome, and so does a second override made after a contradiction; contradiction is sticky until a human decides; the published address never moves |
| Tombstones are not resurrected by machines | `committed_ledger_test.exs`, every step committed: an importer's `Ledger.allocate/3` and a hand-written `allocate` promotion are both refused (`route_changes_allocate_shape`), and the ledger, path and page are byte-for-byte unchanged afterwards; a human `move/3` onto a tombstone is refused; a human `restore/3` brings it back as a `restore` operation and it resolves again; a retired page is restored at one address while its other stays gone |
| Malformed targets in a batch | `committed_ledger_test.exs`: nil, string, negative and float targets and an unknown role return error tuples inside one committed transaction, which still commits the valid page |
| Recovery | `recovery_test.exs`, against disposable databases created and dropped by the test: exact restore; re-projection with the providers reversed, shown to have really run; exact again; ledger and resolver work afterwards; verification shown to be non-vacuous; the source only read. Guards refuse reset, restore-over and rebuild without a covering snapshot, and reject stale, unmarked and missing snapshots |
| The suite's own database claim | `data_case_test.exs`: the claim's lock stays on a connection the pool never hands out, through a sandbox mode change. This test fails on the previous claim implementation |
| Exact-ID 404, no guessing | `resolver_test.exs`: near misses, unknown ids and draft pages never resolve to something else; corrupt states produce diagnostics, never a destination |
| C++, C+, c; Unicode; malformed requests | `address_test.exs`, `resolver_test.exs` |
| Revisioned On bodies and typed membership | `pages_test.exs`: whole revisions with exact ordered membership; an association writes no names or identifiers; malformed membership is an error tuple |

Additive preservation of existing readers is shown by the unchanged full suite. Tests stand in for Stage 5's publication gate by setting `publication_state` directly (`RoutingFixtures.published!/1`). No application code publishes, and no test result is a publication approval.

## Known limits

- **Recovery on the real corpus.** The procedure is tested on disposable databases built by the test. It has not been run against `devils_dictionary_v2`, and the manifest's running time at corpus scale is unmeasured. `mix dd.rebuild` still cannot preserve routing identity, and is guarded rather than changed.
- **Publication** has a column and resolver outcomes, but no transition, gate or manifest.
- **Collections and choice pages** have storage but no namespace.
- **Editorial pages.** Merging On pages rests on the approving human's judgement; the database cannot tell whether two authored treatments are "related".
- **Database roles.** The TRUNCATE refusal guards against accidents, including cascades. A session that sets the opt-in deliberately can still truncate, so production should also withhold TRUNCATE and trigger control from the application role.
- **Slug characters.** The database enforces the slug's ASCII rules; a non-ASCII punctuation character written by raw SQL is caught only by `Routing.Address`.
- **Scale.** Path lookups by page are indexed. Stage 2 should still measure allocation throughput and the commit-time checks on the real candidate population.
- **Composition binding** waits for #196.
- **Test isolation.** The database-backed routing tests are synchronous, because a sandboxed test holds its advisory path locks and uncommitted paths for its whole transaction. Run them on a private `MIX_TEST_PARTITION`; the concurrency and committed-integrity tests commit for real.

## Acceptance matrix

Each requirement, where it is implemented, and what verifies it.

| # | Requirement (source) | Implementation | Verification |
|---|---|---|---|
| 1 | Durable page identity, never an object kind (ADR §5; Stage 1 prompt) | `pages`; `Routing.Page`, `Routing.Pages` | `schema_integrity_test`, `pages_test`, `concurrency_test` (one page per target under races) |
| 2 | Revisioned On body, typed ordered membership, never an identity claim (ADR §4) | `page_revisions`, `page_memberships` (sealed by count) | `pages_test`, `schema_integrity_test` |
| 3 | Persisted classification decisions; versioned override evidence; no silent Subjects fallback (ADR §3) | `classification_decisions`; `Routing.Classifications` | `classifications_test`, `schema_integrity_test` |
| 4 | Global uniqueness of current, historical and reserved paths; immutable ownership (ADR §5) | `public_paths` unique index, shape and slug checks, guards, the repurposing check | `schema_integrity_test`, `committed_integrity_test`, `concurrency_test` |
| 5 | Exactly one canonical per published page (ADR §5) | partial unique index and deferred pointer checks | `schema_integrity_test` |
| 6 | Atomic pointer, allocation and history; append-only ledger (ADR §5) | `route_changes` guards and the continuity trigger; `Routing.Ledger` | `schema_integrity_test`, `committed_integrity_test` |
| 7 | Transactional allocation; bounded race handling; real concurrency (ADR §5) | `Ledger.allocate/3`, `transact/2` | `concurrency_test` (independent connections, real commits) |
| 8 | Explicit approved moves, merges and splits (ADR §5–6) | `Ledger.move/merge/split`; database identity checks | `ledger_test`, `committed_integrity_test` |
| 9 | Rollback behaviour (Stage 1 prompt) | `Ledger.rollback/2` | `ledger_test`, `recovery_test` (rollback of a pre-snapshot operation after restore) |
| 10 | Explicit resolver results; never a guessed destination (ADR §6) | `Routing.Resolver`, `Routing.Resolution` | `resolver_test`, `concurrency_test` (consistent reads) |
| 11 | Classification changes never move a published address (ADR §3) | no path foreign key on decisions; allocation reads a decision only when it writes | `ledger_test`, `classifications_test` |
| 12 | Existing readers preserved; additive change (Stage 1 prompt) | one additive migration; no router change | full `mix precommit` |
| 13 | Curation-composition interface recorded; no competing tables (ADR §4) | [binding contract](#curation-composition-binding-recorded-migration-deferred) | review of the migration: no composition tables |
| A1 | No machine tombstone reclaim; human restoration preserved (audit 1) | allocation shape (`before_kind IS NULL OR 'alias'`); `allocate`/`move` refuse; `Ledger.restore/3` | `committed_ledger_test` |
| A2 | `Pages.ensure` rejects nil and malformed targets before querying (audit 2) | guard clauses | `committed_ledger_test` (a committed batch), `pages_test` |
| A3 | Tested recovery with exact identities; changed provider order; destructive tasks guarded (audit 3) | `Snapshot`, `Routing.Recovery`, `mix dd.routing.verify`, guards in `dd.reset`/`dd.snapshot`/`dd.rebuild`; [procedure](recovery.md) | `recovery_test` |
| A4 | Verification claims separated (audit 4) | [Evidence](#evidence) | this document, the PR description and the issue comment |
| C5 | Targeted regressions and `mix precommit` on the final commit; the claim-lock failure investigated (completion) | the claim's dedicated connection | [Evidence](#evidence); `data_case_test` |
| C6 | Fresh independent review of the final changes (completion) | — | [Independent review](#independent-review) |
| C7 | README, ADR, Stage 1 record, PR and issue synchronized (completion) | — | these documents |

## Stage 2 handoff

Not started. The [Stage 2 handoff](stage-2/README.md) proposes a bounded, reproducible candidate population. It has 169 entities spanning all eight families and the ADR's edge cases, derived read-only from the audit manifest. It resolves the 11 collision groups touching that population with evidence-backed qualifier proposals, and sends three suspected duplicate identities to review. Every other record keeps an explicit disposition. The handoff keeps classification and collision approval separate from publication, and leaves collection and choice namespaces unallocated. It requires three gates before any persistent backfill: recovery exercised on the development corpus, repeat-run identity preservation, and crash/resume proof. The owner decisions it needs are the population, the reviewers and, for Stage 5 only, the publication approver.
