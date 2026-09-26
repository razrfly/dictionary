# Routing Stage 1 — the durable foundation

**Status: implemented, 26 September 2026, for [routing delivery issue #194](https://github.com/razrfly/dictionary/issues/194); awaiting independent review.** [ADR 0004](../adr/0004-public-routing.md) is the contract; this page records how Stage 1 implements §5–6, the decisions taken while implementing it, the evidence and what Stage 2 inherits.

Stage 1 adds storage, invariants, a ledger and a resolver. It **adds no route, rewrites no reader, allocates no production path and publishes nothing.** `/words/:id/:slug`, `/define/:slug` and `/entities/:id/:slug` are unchanged; nothing in the router calls the new code. Backfill (Stage 2), reader integration (Stage 3), On editing (Stage 4) and publication (Stage 5) remain.

## What exists now

One additive migration, `20260926193256_create_routing_foundation`, creates six tables. No existing table is altered.

| Table | Holds | Integrity, and where it is enforced |
|---|---|---|
| `pages` | Durable page identity: role (subject, edition, lexeme, overview, collection, choice), locale, optional target object, `publication_state` (draft/published/withdrawn), `lifecycle_state` (active/merged/split/retired), `merged_into_page_id`, current-revision and canonical-path pointers. | Target required exactly for subject/edition/lexeme (CHECK). Role fits target kind — a subject page targets a non-edition entity, an edition page an edition, a lexeme page a lexeme (deferred trigger). One subject/edition page per target and locale; one lexeme page per target and locale (partial unique indexes). Role, locale and target never change; a page is born active and unrouted; pages are never deleted (triggers). |
| `page_revisions` | Immutable editorial revisions: number, title, body, author/reviewer actors, evidence, `membership_count`. | Unique `(page_id, revision_number)`. The page's current revision must be its own (composite FK). No UPDATE or DELETE (trigger). |
| `page_memberships` | Ordered, typed members of one revision: `supplies_lexical_material`, `discusses_subject`, `editorial_association`, `choice_option`, `split_successor`; exactly one target object or target page. | Revision ownership by composite FK. The revision's `membership_count` seals it: a row can only fill positions `1..n`, and at commit all `n` are filled — nothing can be added afterwards (BEFORE + deferred triggers). No self-membership, UPDATE or DELETE. |
| `public_paths` | Every reserved address, stored decoded and normalized (`/people/чехов`): kind (canonical/alias/tombstone), immutable `original_page_id`, current `destination_page_id`, `last_route_change_id`. | **One uniqueness domain** for every kind. One canonical per page (partial unique index). Spelling and original owner never change; no DELETE. A path serves its owner or that owner's approved merge successor and nothing else; its locale prefix matches its page (deferred trigger). |
| `classification_decisions` | Versioned evaluator results and human overrides: status, selected family, candidate families, rule ids, reasons, warnings, policy version, evidence fingerprint, source pins, reviewer, reason, `supersedes_id`, `is_current`. | One current decision per entity. A family is selected **only** by `mapped`; review, exclusion and identity review select none (CHECK) — no silent Subjects fallback. Immutable except losing currency. An override needs a human (`user`) reviewer and a reason (trigger). No foreign key to any path. |
| `route_changes` | The append-only ledger: operation id and sequence, operation (allocate, move, merge, split, retire, rollback), a path transition (kind and destination before/after) and/or a page transition (lifecycle, canonical pointer, merge successor, revision before/after), classification decision and policy version, actor, reason, `reverts_operation_id`. | No UPDATE or DELETE. Every operation other than allocation needs a human actor (trigger). |

### How the ledger stays complete

A path's `kind` or `destination_page_id`, and a page's lifecycle, canonical pointer, merge successor or (with them) current revision, change only if the same statement names a **new** `route_changes` row whose before-state equals the old row and whose after-state equals the new one. The BEFORE triggers check this immediately, so a raw `UPDATE` from a console, a future bug or a hand-written backfill fails at the statement rather than leaving unrecorded history. The ledger row is written first; its `path_id` foreign key is deferred because a new path is inserted after the row that describes it.

Cross-row rules are deferred constraint triggers checked at commit, because a move or merge is legitimately inconsistent between its statements:

- a page's canonical pointer names a canonical path whose destination is that page, and a canonical path's page points back at it;
- a published active or split page has a canonical;
- a merged page receives no paths; a retired page keeps only tombstones;
- a merged page's successor has the same role and locale;
- a path's destination is its original owner or reachable from it along `merged_into_page_id` (bounded at 64 hops).

```text
allocate(/people/voltaire)       move(/people/arouet)                 merge(page 7 → page 9)
page 7 ─canonical─▶ /people/…    /people/arouet   canonical ▶ page 7   /people/arouet   alias ▶ page 9
                                 /people/voltaire alias     ▶ page 7   /people/voltaire alias ▶ page 9
                                   (301 → /people/arouet)              page 7: merged, successor 9
                                                                       original owner of both: page 7
```

Every alias names a destination **page**, and the resolver reads that page's current canonical directly, so an old address is one 301 from its answer however many moves or merges followed.

## Operations

`Routing.Ledger` is the only writer of addresses. Each operation is one transaction; locks are taken in one order — advisory locks on the normalized paths (sorted), then page rows by id, then path rows by id — so operations cannot deadlock each other. The unique indexes are the final arbiter: an operation that loses a unique, serialization or deadlock race is attempted at most three times in all (each retry emits `[:devils_dictionary, :routing, :retry]`), then returns `{:error, :allocation_conflict}`. No caller invents a substitute path.

| Operation | Actor | Effect |
|---|---|---|
| `allocate(page, path)` | any (a batch job) | Reserves a new canonical for an active page. Idempotent; restores the page's own alias or tombstone. A subject or edition page needs its target's **current decision to be `mapped` to the path's family**, and the ledger row records that decision and policy version. A taken path returns `{:path_taken, owner}`; a second canonical returns `{:page_has_canonical, path}`. |
| `move(page, path)` | human | New canonical; the old one becomes a permanent alias. Moving back promotes the alias. |
| `merge(from, into)` | human | Every path serving `from` serves `into`; canonicals become aliases. Requires the registry to have merged `from`'s identity into `into`'s (editorial pages merge on the approving human's judgement). A published page cannot merge into an unpublished one. |
| `split(page, successors)` | human | Requires a registry split; each successor must be the page of one split output. Writes a revision with `split_successor` memberships in the given order; the page keeps its paths and resolves to a choice. Never redirects to a successor. |
| `retire(page)` | human | Every path becomes a tombstone: reserved forever, 410. |
| `rollback(operation)` | human | Restores each recorded before-state in reverse order, as a new ledger operation. A path the operation created stays reserved as a tombstone of its page. Refused as stale if anything it changed has changed since, and refused if it would leave a published page without a canonical. |

`Routing.Pages` creates pages (`ensure/3` is idempotent under concurrency) and writes whole revisions. `Routing.Classifications` records `Routing.Policy.classify/3` results and human overrides:

- an unchanged evidence fingerprint keeps an override current and writes nothing;
- changed evidence that still offers the override's family keeps it current (a Wikidata revision bump is not a review);
- contradictory evidence — the family is no longer a candidate, or the evidence now reaches an exclusion or identity review — writes a new current `needs_review` decision superseding the override, which stays in history;
- an override names the fingerprint the reviewer saw and is refused as `:stale_evidence` if it has changed.

None of it moves an address.

## Resolver

`Routing.Resolver.resolve/1` takes the raw request path; `resolve_page/1` takes an exact page id; `link/1` gives the encoded canonical for an id. Each returns a `Routing.Resolution`:

| Outcome | When | Status |
|---|---|---|
| `:canonical` | a published page's canonical, spelled exactly | 200 |
| `:redirect` | an alias, a merged page's id, or an equivalent spelling (case, Unicode form, trailing slash, hex case) | 301 |
| `:choice` | a published split page, with its successors in order | 200 |
| `:missing` | no such address or id; a near match is never substituted | 404 |
| `:gone` | a tombstone | 410 |
| `:unavailable` | a real page not published | 404 |
| `:invalid` | malformed or truncated escape, invalid UTF-8, encoded `/` `\` or NUL, dot or empty segment | 400 |
| `:corrupt` | state the invariants should prevent; diagnostics are logged | 500 |

A request is decoded once, NFC-normalized and lowercased, never re-slugified: `/concepts/c%2B%2B` is missing, not C++.

## Decisions taken while implementing

These refine the ADR without changing it; each is conservative and reversible with a policy change.

1. **Namespaces by role.** Subjects use their mapped family, editions `/works`, On overviews `/on`. Lexeme pages are not ledger-addressed — the lexical routes stay as they are. The registry defines no namespace for collection or choice pages yet, so allocating one is refused as `:namespace_undefined`; Stage 4 or 5 decides.
2. **Allocation requires a mapped classification in the path's family.** An unclassified, under-review or differently mapped subject cannot get an address, so an unknown subject cannot slip into `/subjects`. After allocation a new decision moves nothing.
3. **Approvals are human.** Move, merge, split, retire and rollback require a `user` actor, in both the Elixir API and the database. Allocation may be an importer's.
4. **One page per target and locale, ever.** A retired or merged page keeps its target; a new treatment of the same object in the same locale is a rollback or a new locale, not a second page.
5. **Split pages keep their address.** The split page becomes a choice at its own canonical rather than a new page, and records its successors as a revision.
6. **An undone allocation leaves a tombstone.** Reservations are permanent even when the allocation is rolled back; the same page can reclaim the path.

## Curation-composition binding (recorded; migration deferred)

[Curation persistence (#196)](https://github.com/razrfly/dictionary/issues/196) owns `editorial_compositions`, their immutable versions and items, and human presentation approval. Those tables do **not** exist on main, so Stage 1 creates no binding table and no placeholder composition table. When #196 lands, one additive migration adds:

| Column | Rule |
|---|---|
| `page_composition_bindings.id` | bigint |
| `page_id` | FK `pages`, restrict |
| `composition_id` | FK `editorial_compositions`, restrict — a real foreign key |
| `state` | `active` or `ended`; unique active binding per page, and per composition |
| `bound_by_actor_id`, `ended_by_actor_id` | FK `actors`; human only, as for route operations |
| `reason`, `evidence` | why these two identities describe the same scope |
| `bound_at`, `ended_at` | append-only history; ending and rebinding never rewrite a row |

The binding service must validate that the composition's language equals the page's locale and that its scope membership is compatible with the page's membership. A shared label, slug or URL never establishes a binding. The page renders only the composition version the curation publication service has selected and that is still eligible under its own rights/evidence checks. A page approval cannot approve a draft composition or accept a semantic claim, and composition approval grants no page publication. Route moves and merges keep the binding on the page id. A split page has no single scope, so its binding goes to human reconciliation rather than being carried to a guessed successor (#196: split scopes are never guessed). Persona inference and refresh (#193) are not dependencies.

## Evidence

- `mix test test/devils_dictionary/routing`: **3 doctests, 67 tests, 0 failures** (44 new, beside the 23 policy/audit regressions), stable across six consecutive runs on a private partition.
- `mix precommit` on the branch: **19 doctests, 2,132 tests, 0 failures** — main's 16 doctests and 2,088 tests plus exactly the new 3 and 44.
- The migration was applied, rolled back and re-applied on a private test database.

| Invariant (ADR §5–6, §8) | Proven by |
|---|---|
| Real concurrent allocation; the index is the final arbiter | `concurrency_test.exs`: six independent connections, distinct backend pids, released at a barrier, racing for one path (one winner, five `:path_taken` naming it, exactly one path and one two-row ledger operation) and for one page (exactly one canonical); a lock-free writer holding an uncommitted duplicate, which makes the allocator wait on the index, fail, retry once and return `:path_taken` with its half-written ledger row rolled back. Real commits, so the deferred checks run at COMMIT. |
| Bounded race handling | three attempts, then `:allocation_conflict`; a non-race error is re-raised |
| No deadlock under opposed multi-page locks | three pairs of merges racing in opposite directions: one wins each pair |
| Global uniqueness; immutable historical ownership | `schema_integrity_test.exs` raw SQL: second canonical refused, path spelling/owner change refused, delete refused, an honestly ledgered re-point to an unrelated page refused at commit |
| Atomic pointer/allocation/history | raw updates without a ledger row, or with a ledger row that misstates the before-state, refused |
| Exactly one canonical per published page | pointer at another page's canonical refused; publishing without a canonical refused |
| Moves, merges, splits, retirement | `ledger_test.exs`: exact destinations and original owners after a move, a move back, a three-page merge chain (every old address one hop to the final survivor), a split choice with ordered successors, tombstones that stay reserved |
| Rollback | exact restoration of a move and a merge, tombstone reservation after an undone allocation, stale and double rollbacks refused, a rollback that would unpublish refused |
| Versioned overrides | `classifications_test.exs`: human-only, stale evidence refused, preserved across identical and agreeing evidence, contradicted into review with history, published address unchanged throughout |
| Exact-ID 404, no guessing | `resolver_test.exs`: near misses, unknown ids and draft pages never resolve to something else; corrupt states produce diagnostics, never a destination |
| C++, C+, c; Unicode; malformed requests | `address_test.exs`, `resolver_test.exs` |
| Revisioned On bodies and typed membership | `pages_test.exs`: whole revisions with exact ordered membership; an association writes no names or identifiers |

Additive preservation of existing readers is the unchanged full suite. Tests stand in for Stage 5's publication gate by setting `publication_state` directly (`RoutingFixtures.published!/1`); no application code publishes, and no test result is a publication approval.

## Known limits

- **Restore.** A `mix dd.snapshot` dump carries the routing tables with everything else. `mix dd.rebuild` replays sources into newly numbered objects and does not carry pages, decisions or the ledger. The ADR's restore order — registry, editorial state, overrides and the address ledger before source projections — needs a real restore procedure and test (Stage 5, or earlier if Stage 2's backfill needs it).
- **Publication** has a column and a resolver outcome, but no transition, gate or manifest.
- **Collections and choice pages** have storage but no namespace.
- **Composition binding** waits for #196.
- The shared test database's unboxed tests truncate every table, as all unboxed tests do; run concurrency tests on a private `MIX_TEST_PARTITION`.

## Proposed Stage 2 scope

Stage 2 is backfill and review, against a fresh snapshot, with no publication.

1. **Record decisions for every entity.** A resumable batch job runs `Routing.Policy.classify/3` over a read-only export and `Classifications.record/1`s each result, checkpointed by object id and policy digest. A rerun writes nothing (`:unchanged`); a crash resumes without duplicates. Compare per-object outcomes with the 26 September dry run (38,576 / 56,228 / 5,917 / 2) and explain every difference.
2. **Pages for a candidate population only.** `Pages.ensure/3` for the reviewed candidate set, not the corpus. Page ids are keyed by target object, so a rerun finds the same pages.
3. **Readable collision resolution.** For the 1,406 collision groups, propose evidence-backed qualifiers (person dates, work creator/year/type, scientific distinction, place) as review items; review possible duplicate identities first. No opaque suffixes; import order never picks a primary.
4. **A review workflow** for classification (overrides) and collisions, using the existing reviewer role; every decision a human `user` actor.
5. **Allocation only for reviewed records**, through `Ledger.allocate/3` with an import actor, producing a **candidate launch manifest** of page ids and paths. Candidate status grants no publication.
6. **Evidence:** repeat and interrupted runs preserve exact page ids, paths and decision ids (compared as sets); deferred records stay visible with their dispositions; a restore procedure for the routing tables is at least specified.

Stage 2 needs from the owner: which population is the first candidate launch set, and who reviews it.
