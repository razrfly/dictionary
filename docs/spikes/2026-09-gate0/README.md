# Gate 0 — executable proof before schema freeze

Issue [#74](https://github.com/razrfly/dictionary/issues/74) requires this before the
schema is frozen or any adapter is rewritten. Everything below was **run**, on a named
scratch database, against the real corpus — not reasoned about.

## Environment

| | |
|---|---|
| Date | 2026-09-08 |
| Host | Apple M4 Max, 64 GB |
| PostgreSQL | 18.2 (Postgres.app), `aarch64-apple-darwin23.6.0` |
| Elixir / Erlang | 1.19.0-otp-28 / 28.1 |
| Scratch database | `devils_dictionary_spike` (created and dropped by this spike; `devils_dictionary_dev` untouched) |
| Cache state | warm — every read was run once before measuring, and all plans report `shared hit` with zero `read` |

## Reproduce

```
createdb devils_dictionary_spike
psql -d devils_dictionary_spike -f 01-schema.sql
psql -d devils_dictionary_spike -f 02-integrity.sql        # every block must ERROR
# export the corpus from devils_dictionary_dev (see 03-load.sql header), then:
psql -d devils_dictionary_spike -f 03-load.sql
psql -d devils_dictionary_spike -f 04-unsensed.sql
psql -d devils_dictionary_spike -f 05-indexes.sql
psql -d devils_dictionary_spike -f 07-switching.sql
psql -d devils_dictionary_spike -f 08-exactly-one.sql
psql -d devils_dictionary_spike -f 10-reconcile.sql
psql -d devils_dictionary_spike -f 11-drift.sql
psql -d devils_dictionary_spike -f 12-drift-run3.sql
psql -d devils_dictionary_spike -f 13-ambiguity.sql
```

## Population loaded

Not a sample. The whole resolved corpus from `devils_dictionary_dev`.

| Table | Rows |
|---|---|
| `objects` | 1,792,058 |
| `lexemes` | 1,541,669 |
| `senses` / `sense_revisions` | 250,389 / 250,389 |
| `assertions` | 1,163,659 |
| `assertion_revisions` | 2,029,069 (rev 1 ×1,127,225 + revs 2–5 ×225,461 each) |

Revision depth is deliberate: every fifth assertion carries five revisions, because #74
says to "measure costs with multiple revisions, not just a history-free corpus". The
highest-degree nodes are in: object 6476 has 1,229 outgoing, object 10143599 has 1,573
incoming.

Load wall time, per stage: lexemes 21.6 s · senses 9.3 s · assertions 3.6 s ·
**assertion_revisions rev 1 23.8 s** · revision depth 42.7 s. Total 1 m 51 s.

The 23.8 s for 1.13 M revision rows (≈ 21 µs/row) is the write cost of the endpoint
trigger that fills the four denormalised kind columns. That is what buys endpoint
compatibility as a real foreign key rather than an application check.

---

## Proof 2 — the registry's exactly-one rule

`02-integrity.sql`, output in `02-integrity-output.txt`. **Eleven rejections, and the
valid Bierce anchor commits.**

| Case | Result |
|---|---|
| Object with no subtype row | rejected **at COMMIT** (`object 900 (kind lexeme) has no lexeme row`) — and legal mid-transaction, which it has to be |
| Subtype of the wrong kind | rejected immediately by the composite FK |
| Two subtypes for one object | rejected by the composite FK |
| `objects.kind` changed | rejected by the immutability trigger |
| `person_details` on a concept entity | rejected by the entity-subtype composite FK |
| **Deleting a subtype, orphaning its object** | rejected — see below |
| Deleting the object itself | allowed; the cascade path is not blocked |

**The gap this spike found.** The first draft had only an `AFTER INSERT` trigger on
`objects`. Deleting Bierce's `entities` row left object 101 (kind `entity`) with no entity
row *while `authored_by` still pointed at it* — a registry in exactly the broken state
#74 warns about. `AFTER DELETE` constraint triggers on all four subtypes close it, and
the rule they leave standing is the one the issue asks for: **retire an identity via
`lifecycle_state`, never delete it out from under the claims that reference it.**

## Proof 3 — predicate endpoint compatibility

Compatibility is a **real foreign key**, not a trigger check:

```sql
FOREIGN KEY (predicate_id, subject_kind, subject_subkind, object_kind, object_subkind)
  REFERENCES predicate_endpoint_rules (...)
```

filled by a `BEFORE INSERT OR UPDATE` trigger. Rejected: `defines` → a person;
`refers_to` from a lexeme rather than a sense; confidence 1.4; an assertion pointing at
another assertion's revision. **And on a bulk write** — one good row and one bad row in a
single multi-row `INSERT` rejects the whole statement rather than filtering it, which is
what makes this hold for `insert_all`, `COPY` and the linker's raw SQL.

Subkinds use the sentinel `'-'`, never `NULL`: an FK with a NULL column is not enforced
under `MATCH SIMPLE`, which would have silently disabled the check for every lexeme and
sense endpoint.

### A finding from the real population

Declaring only `lexeme → lexeme` and `sense → sense` dropped **36,434 of 1,163,659**
relations on the floor. They are `sense → lexeme`: a source saying "this meaning relates
to that *word*", without naming which of the word's meanings. #74 §C requires exactly
that — "preserve unsensed lexical relations without inventing sense IDs" — so the rule
set gains a third pair rather than the rows being dropped or a sense ID being invented.
After `04-unsensed.sql`: 1,047,918 sense→sense, 79,307 lexeme→lexeme, 36,434 sense→lexeme,
**0 assertions without a current revision**.

This is the whole argument for running the gate: the shape was found by loading the real
corpus, not by reading the schema.

---

## Proof 7 — the current-revision shootout

Three strategies on identical rows. 3,000 transactions each, one client, warm cache,
`pgbench -l` per-transaction latencies.

| Strategy | direction | p50 ms | p95 ms | p99 ms | buffers |
|---|---|---|---|---|---|
| **A** pointer (`assertions.current_revision_id`) | outgoing | 2.161 | 2.576 | 3.161 | 7,957 |
| | incoming | 3.780 | 4.535 | 6.007 | 12,361 |
| **B** `DISTINCT ON` over history | outgoing | 1.483 | 1.670 | 2.595 | 5,989 |
| | incoming | 2.649 | 2.976 | 4.217 | 9,685 |
| **C** partial index on `is_current` | outgoing | **0.219** | **0.256** | 0.283 | **41** |
| | incoming | **0.403** | **0.489** | 0.562 | **912** |

Plans in `06-plans.txt`.

**C wins by an order of magnitude, and the buffer counts say why** — 41 pages versus
7,957 on the outgoing read, a 194× difference. A partial index on
`(subject_object_id, predicate_id) WHERE is_current` contains only current rows, so the
read is a single index scan that returns exactly what it touched. The pointer has to scan
an endpoint index containing *all* 2.03 M revisions, then probe `assertions` once per
candidate to discover which one is current.

**Two of the audit's expectations do not survive contact.** It predicted the pointer
would be fast and `DISTINCT ON` slow; measured, **B beats A** on every figure. And #74 is
right that `DISTINCT ON` need not scan all history — with `(assertion_id, revision_number DESC)`
it does a bounded per-assertion probe. Neither claim should be repeated as fact.

Index cost for C: `ar_one_current` 25 MB + `ar_subject_current` 18 MB +
`ar_object_current` 19 MB = 62 MB, against `ar_latest` 62 MB for B and `a_current` for A.
The strategies cost the same to index; they do not cost the same to read.

## Proof 7b — is C actually *correct*?

#74: "A partial unique index alone proves **at most one**, not exactly one." True, so C
needs three things, all tested in `07-switching.sql` and `08-exactly-one.sql`:

1. **At most one** — `CREATE UNIQUE INDEX … (assertion_id) WHERE is_current`. Inserting a
   second current revision is rejected.
2. **At least one, at commit** — deferred constraint triggers on `assertions` and
   `assertion_revisions`. An assertion with no revisions, or whose flag was cleared, is
   rejected at COMMIT.
3. **Atomic switching** — *measured, not assumed*, because a partial unique index cannot
   be made `DEFERRABLE` (only table-level `UNIQUE` constraints can, and those cannot be
   partial). A single `UPDATE … SET is_current = (revision_number = N) WHERE assertion_id = X`
   **works in both directions** on PostgreSQL 18; the two-statement clear-then-set also
   works.

**Currentness and lifecycle stay separate columns.** Proved: the designated current
revision of assertion 11 reads `lifecycle_state = 'withdrawn'`. #74 forbids overloading
one value with both, and this shows the schema does not.

Two trigger functions, not one: `assertions` names the key `id` and `assertion_revisions`
names it `assertion_id`; plpgsql resolves `NEW.<col>` at run time, so a shared function
raises `record "new" has no field "assertion_id"`. Found by running it.

## Proof 7c — concurrent writers

Two sessions adding a revision to the same assertion, A holding the lock through a
`pg_sleep(1)` so B is guaranteed to arrive mid-transaction:

- **With `SELECT … FOR UPDATE`**: serialised. A writes revision 2, B waits, re-reads and
  writes revision 3. Exactly one current row.
- **Without it, statements in the usual order**: also fine — but only by accident. The
  `UPDATE … SET is_current = false` takes the row lock itself, which is what serialises
  them.
- **Without it, with the INSERT ordered first**: one writer **loses** with
  `duplicate key value violates unique constraint "assertion_revisions_number"`. No
  corruption, but a lost write and an error that does not explain itself.

**Contract:** the write path takes `SELECT … FROM assertions WHERE id = $1 FOR UPDATE` as
its first statement. Relying on statement order works today and is not a guarantee.

## Write cost

The full write path — lock, clear the old flag, insert the new revision, set the new flag:

| clients | tps | p50 | p95 | p99 |
|---|---|---|---|---|
| 1 | 975 | 0.925 ms | 1.627 ms | 3.103 ms |
| 4 | 5,841 | 0.614 ms | 1.195 ms | 1.561 ms |
| 8 | 13,756 | 0.511 ms | 0.904 ms | 1.152 ms |

---

## Proofs 4 and 5 — sense identity across a source edit

Run on the **real** Wiktionary `bank/noun/1` record, captured from the pinned 2.6 GB dump
(`mix dd.fixtures.capture --source wiktionary --lemma bank`, one full pass, 47 s). It has
10 senses; the whole record has 7 entries across 4 etymologies.

The policy (`10-reconcile.sql`): `external_key` still records what the source called the
sense, for provenance, but **it is not identity**. Identity is matched on content — part
of speech and etymology number must agree, then the normalised gloss is scored with
`pg_trgm`. Above `strong` (0.60) with a clear gap: matched. Above `weak` (0.30), or within
`band` (0.08) of the runner-up: **ambiguous**. Below: a new identity.

**Run 2, byte-identical input** — all ten senses matched to themselves at 1.000. Zero new
identities, zero new revisions. *(Proof 4.)*

**Run 3, the audit's reproduction** — "A branch office of such an institution." is deleted
from position 1, one gloss is reworded, one new sense is appended. Every position after
the deletion shifts down by one, so `"Money; profit."` moves from position 5 to 4.

| | shipped `word/pos/etym#position` | this policy |
|---|---|---|
| `"Money; profit."` | id `bank/noun/1#5` now holds the *dominos* gloss | keeps sense **20000005** |
| incoming position 5 | silently becomes the old #5 | resolves to **20000006**, a different identity |
| curator's attachment | now means something else, with no FK violation | still reads `"Money; profit."` |
| the deleted sense | overwritten | **retired**, still resolvable, history intact |
| the new sense | takes a recycled id | new identity (scored 0.165) |

**Runs 4 and 5, ambiguity** — both routes into `ambiguous` are exercised, because there
are two and both have to work:

- *Nothing good enough*: an edited gloss sitting between `bank`'s two "fund" senses scores
  0.430 — above `weak`, below `strong`. Ambiguous.
- *Too close to choose*: a gloss scoring **0.897 against two senses with a 0.000 gap**.
  Above `strong`, but picking the higher would be arbitrary — it would be decided by
  `object_id`. Ambiguous.

In both cases a `reconciliation_cases` row opens, the sense goes to `needs_review`, **no
revision is written, no attachment moves, and no identity is reused for a new meaning.**

---

## Decisions this gate freezes

1. **Registry with typed subtypes, confirmed.** The exactly-one rule is enforceable and
   enforced, with the delete direction closed. Real foreign keys to endpoints are the
   thing typed relationship tables cannot give.
2. **Current revision: strategy C — a partial `is_current` index** — with the partial
   unique index for at-most-one, deferred constraint triggers for at-least-one, and
   `SELECT … FOR UPDATE` as the first statement of the write path. **The explicit pointer
   is dropped**, so there is one source of truth and #74's "do not maintain both pointer
   and flags without enforcing agreement" cannot be violated. Reads are 10× faster; writes
   sustain 13.7 k tps.
3. **Lexical relations live in the assertion model.** 1,163,659 relations became
   1,163,659 assertions + 2,029,069 revisions in **1,118 MB** against `lexical_relations`'
   730 MB in dev — a 53% increase in bytes for a full revision history and a 10× faster
   endpoint read. The typed-fallback table named in the plan is **not** needed.
4. **Endpoint rules must include `sense → lexeme`.** 36,434 real rows depend on it.
5. **Sense identity is content-matched, never position-keyed**, with an explicit ambiguous
   state and a reconciliation queue.

## Naming hazards found

`SYMMETRIC` was already known. Two more, both found by running the SQL:

- **`POSITION`** is reserved in a `RETURNS TABLE` column list (it is the SQL string
  function), so `RETURNS TABLE (position int, …)` is a syntax error. `sense_revisions`
  keeps a `position` column — legal there — but no function signature may use the bare name.
- Sharing one trigger function across two tables whose key columns differ by name fails at
  run time, not at creation.

## Budgets, agreed from these measurements

| Budget | Value | Basis |
|---|---|---|
| Bounded incoming/outgoing assertion read, p95 | **< 5 ms** | measured 0.256 / 0.489 ms on the highest-degree nodes; ~10× headroom |
| Single-assertion write path, p95 | **< 10 ms** | measured 0.904 ms at 8 clients |
| Search p95 | **< 150 ms** | carried forward from X2 unchanged, same 20 probes |
| Storage, assertion half | **≤ 2× `lexical_relations` today** | measured 1,118 MB against 730 MB = 1.53× |
| Dump processing | **≤ 2 h**, APIs reported separately | carried forward from O2 |

Full word-page composition p95 is **not** set here: it needs the ported `WordPage`
builder to measure honestly, and is established at P2 against a matched baseline run on
`devils_dictionary_dev`. Recorded as pending rather than guessed.
