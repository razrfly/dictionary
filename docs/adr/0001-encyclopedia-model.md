# ADR 0001 — The encyclopedia model: an addressable-object registry with attributed, revisioned assertions

- **Status:** accepted, 2026-09-08
- **Issue:** [#74](https://github.com/razrfly/dictionary/issues/74), superseding the
  migration requirements of [#73](https://github.com/razrfly/dictionary/issues/73) and
  keeping [#72](https://github.com/razrfly/dictionary/issues/72)'s source-correctness contract
- **Evidence:** [`docs/spikes/2026-09-gate0/`](../spikes/2026-09-gate0/README.md) — run, not reasoned about
- **Supersedes:** the thirteen-table MVP-0 baseline (`priv/repo/migrations/20260905094219_create_lexicon_schema.exs`)

## Context

MVP-0 assembles correctly and does not survive change. The 7 September audit
([`docs/audits/`](../audits/2026-09-07-project-audit.md)) reproduced five defects that
share one cause — **nothing in the schema carries identity that is independent of what a
source happened to call something on the day we read it**:

- Wiktionary senses are keyed `word/pos/etymology#position`, so reordering meanings
  silently repoints existing attachments. No foreign key is violated; parity reports zero gaps.
- Refresh is additive. A withdrawn source assertion stays live.
- Slugs assert equivalence: `C++` navigates to `/define/c`.
- One Wikipedia article renders six times, because a retrieval probe is treated as a publication.
- A rejected link returns to `auto` on the next run.

The owner has ruled the current derived data disposable. So this is a rebuild from
sources, not a migration.

## Decision

### 1. An addressable-object registry, not typed relationship tables

`objects(id, kind, lifecycle_state)` with `kind ∈ lexeme | sense | entity | content`, and
one typed subtype table per kind holding the domain fields.

*Why not typed relationship tables:* an assertion's endpoint is "whatever kind of thing
this is". Typed tables force either a table per endpoint-pair combination, which does not
extend, or a `(type, id)` pair, which has no referential integrity at all. The registry
buys a real foreign key for one join, and Gate 0 measured that join: bounded endpoint
reads run at 0.256 ms p95 on the highest-degree node in the corpus.

*The cost, paid:* "exactly one subtype per object" is not expressible as one constraint.
It takes three mechanisms, all built and all tested — a composite `(object_id, kind)`
foreign key against a generated column for *at most one, of the right kind*; a deferred
constraint trigger for *at least one, at commit*; and an immutability trigger on
`objects.kind`. Gate 0 also found the direction the first draft missed: deleting a subtype
row orphans its object while assertions still point at it, so `AFTER DELETE` constraint
triggers close it. **An identity is retired via `lifecycle_state`; it is never deleted out
from under the claims that reference it.**

### 2. Predicate endpoint compatibility is a foreign key

`assertion_revisions` carries four denormalised endpoint-kind columns filled by a
`BEFORE` trigger, and a composite FK into `predicate_endpoint_rules`. Because
`objects.kind` and `entities.entity_kind` are immutable, the copy cannot go stale.

*Why not a validating trigger:* the linker, resolver and scope builder are entirely raw
SQL, and the materializer writes through `insert_all`. #74 requires rejection "including
on bulk writes". Gate 0 confirmed a multi-row `INSERT` with one bad row rejects the whole
statement. Subkinds use the sentinel `'-'` rather than `NULL`, because an FK with a NULL
column is not enforced under `MATCH SIMPLE` — which would have silently disabled the
check for every lexeme and sense endpoint.

### 3. Current revision: a partial `is_current` index, and no pointer

Gate 0 measured three strategies on the full corpus (1.16 M assertions, 2.03 M revisions):

| | outgoing p95 | incoming p95 | buffers (outgoing) |
|---|---|---|---|
| explicit pointer | 2.576 ms | 4.535 ms | 7,957 |
| `DISTINCT ON` | 1.670 ms | 2.976 ms | 5,989 |
| **partial `is_current` index** | **0.256 ms** | **0.489 ms** | **41** |

A partial index contains only current rows, so the read touches 194× fewer pages than the
pointer, which must scan an endpoint index over all history and then probe `assertions`
per candidate.

Correctness is the harder half, and #74 is right that a partial unique index proves only
*at most one*. It is completed by a deferred constraint trigger for *at least one at
commit*, and by `SELECT … FOR UPDATE` on the assertion row as the **first statement** of
the write path — Gate 0 showed that without it, an adversarial statement ordering loses a
write to a duplicate-key error. Atomic switching was measured rather than assumed, since a
partial unique index cannot be `DEFERRABLE`; single-statement flag moves work in both
directions on PostgreSQL 18.

**The pointer is dropped entirely.** #74 warns against maintaining both a pointer and a
flag without enforcing agreement; the cheapest way to honour that is to have one source of
truth.

*Two of the audit's expectations did not survive measurement:* it predicted the pointer
would be fast and `DISTINCT ON` slow. `DISTINCT ON` beat the pointer on every figure.
Neither claim should be repeated.

**Currentness and lifecycle are separate columns.** The designated current revision may
read `withdrawn`.

### 4. Lexical relations live in the assertion model

No separate `lexical_assertions` table. The fallback named in planning is not needed:
1,163,659 relations became 1,163,659 assertions and 2,029,069 revisions in 1,118 MB,
against `lexical_relations`' 730 MB — 1.53×, for a full revision history and a 10× faster
endpoint read.

Endpoint rules must declare **`sense → lexeme`** as well as `lexeme → lexeme` and
`sense → sense`. 36,434 real relations are a meaning pointing at a *word* without naming
which of its meanings, and #74 §C requires preserving those "without inventing sense IDs".

### 5. Sense identity is content-matched, never position-keyed

`external_key` records what the source called a sense, for provenance. It is not identity.
Identity is matched on part of speech, etymology number and normalised gloss similarity.
A confident match keeps the identity; an uncertain one — nothing above the strong
threshold, *or* two candidates within a band of each other — opens a
`reconciliation_cases` row and sets `identity_state = 'needs_review'`. An existing sense
with no incoming match is **retired**, not deleted.

Proved on the real Wiktionary `bank/noun/1` record: after deleting a sense from the middle,
`"Money; profit."` moves from position 5 to 4 and **keeps its identity**, while position 5
resolves to a different sense. The curator attachment made before the edit still means what
it meant. Byte-identical input produces zero new identities and zero new revisions.

**Amended at P5, on evidence.** The rule above is right for a key that encodes a
*position*, and wrong for a key derived from an identifier the source itself keeps
stable. WordNet's `oewn-84481488-n#sequoia` is a synset id and a member name, and the
synset id is precisely what WordNet promises not to move. Its glosses, meanwhile, are
written to be near-neighbours: *sequoia* the tree and *sequoia* the wood differ by the
words "wood of", which scores 0.79 — past any threshold worth having. The first full
re-import collapsed **194 synsets** into their neighbours on that similarity, and left
each survivor rewriting its gloss one way on the first pass and back on the second, a
new revision each time, for ever. It also stranded 1,665 `pending_relations` rows whose
subject no longer matched the edge that wrote them.

So `Absorb.Source.sense_key_stability/0` lets a source declare which kind of key it has.
`:positional` is the default and the assumption that costs nothing when it is wrong — an
unnecessary review case. `:stable` means the key **is** the identity: the same key is the
same meaning however the gloss was rewritten, and two different keys are two meanings
however alike they read. Only WordNet claims it today. This does not reinstate
key-as-identity for Wiktionary, which is the case #74 exists for and which still gets
content matching.

### 6. One person, one identity

`people` is deleted. A person is `objects(kind: entity)` + `entities(entity_kind: person)`
+ `person_details`. Bierce's authorship, his biography and any cultural claim about him
all name the same object id. Login accounts are `users`; a claimant is an `actors` row.
**An account is never automatically the person it claims to be.**

### 7. Local identity, external identifiers

`concepts.qid NOT NULL` is gone. Internal `object_id` is identity; QIDs, Wikipedia
pageids and WordNet ILIs live in `external_identifiers(namespace, external_id, status)`,
unique per namespace only among `verified` rows so unresolved candidates can coexist.
A local artwork or event exists without a QID, and adding one later leaves its identity
and every attachment unchanged.

### 8. Source records are versioned, and outputs are owned

`source_records` keeps identity; `source_record_revisions` holds immutable payloads keyed
by the content checksum, which is still taken **before** `trim/1`. Every derived row is
stamped with `last_seen_run_id` in `source_materialized_outputs` /
`source_assertion_outputs`; anything a run does not re-stamp is **retired, never deleted**,
and never another source's support.

### 9. Migration history is replaced, and migration count stops being acceptance

Nothing is deployed and the data is disposable, so one new baseline replaces the old one
rather than a rebuild path being written for thirteen tables we are deleting. Scorecard
row **E1** stops counting `schema_migrations` — a hard equality against `2` would fail any
healthy future migration, including this one — and becomes a test that actually adds a
source, a predicate and an entity kind and asserts the cost. **E3** stops being
`File.exists?` on a rolled-back sketch; the sketch is deleted and E3 becomes the extension
exercise. Full mapping in [`docs/rebuild/score-rows.md`](../rebuild/score-rows.md).

### 10. URLs carry identity, slugs are cosmetic

Canonical: `/words/:object_id/:slug`, `/entities/:object_id/:slug`. `/define/:slug`
survives as a resolver — unambiguous slugs redirect, ambiguous ones (28,306 slug groups
today hold more than one distinct lemma) show a disambiguation list. `lexemes.lexical_key`
is case- and punctuation-preserving, so `C++`, `C+` and `c` are three identities.

## Consequences

**Accepted:**

- Writing a revision costs ~21 µs of trigger work per row (23.8 s for 1.13 M rows on load).
  That is the price of endpoint compatibility being a foreign key.
- Every object write is two rows in one transaction. The materializer's `Ecto.Multi`
  per batch is therefore not optional.
- The assertion half of the corpus is 1.53× the bytes of `lexical_relations`.
- Six parsers keep their code and their 159 pure tests; their *output maps* are rewritten.
  `Materializer`, `Linker`, `Resolver` and `ScopeBuilder` are rewritten against new tables.
- `entries`, `lexical_relations`, `concept_links`, `concept_relations`, `concepts` and
  `people` are retired as tables.

Added at P5, from the first full re-import — each of these is a cost the design
implies and the plan had not spelled out:

- **Deferring a constraint means a writer must own a transaction.** Two of the
  registry's rules are checked at `COMMIT`, so any writer that mints an identity
  in one statement and its subtype or first revision in the next has to enclose
  them. That is now true of `write_assertions/3` itself rather than of each
  caller — the linker is raw SQL by design and has no transaction of its own.
- **And it means the SQL sandbox cannot test them.** A test that wraps a whole
  case in one transaction never reaches the commit where a deferred constraint
  fires. Bulk-writer tests run unboxed.
- **Every output carries the run that wrote it, and every batch reconciles.**
  Ownership by `last_seen_run_id` is only a mechanism until something stamps it;
  `Batch.run/3` opens a run when its caller does not own one, so a new source
  cannot make refresh additive again by forgetting a keyword.
- **A rebuild's last five stages are its earlier ones again.** The scope's third
  rule needs a taxonomy that does not exist on the first pass, and Wikidata's
  recorded P31/P279 edges need entities Wikipedia introduces afterwards. Neither
  is a retry: a straight line whose stages depend on later stages has to come
  back round once.

**Rejected, with reasons:**

- *A graph database.* The workload is bounded adjacency with provenance, and Postgres
  measures at 0.256 ms p95 on the highest-degree node. Nothing here needs a second engine.
- *A universal ontology.* Predicates are a registry with enumerated endpoint rules, not
  arbitrary strings between arbitrary rows.
- *Migrating the existing 1.5 M rows.* The owner ruled them disposable, and the identity
  policy changes what a sense row *means* — a backfill would have to invent the answer.
- *Keeping both a pointer and a flag.* One source of truth, per #74.

**Deferred:**

- Full word-page composition p95 — needs the ported `WordPage` builder to measure
  honestly; established at P2 against a matched baseline run on `devils_dictionary_dev`.
  Recorded as pending rather than guessed.
- ConceptNet. The assertion contract is validated against its endpoint types and dataset
  lineage before the schema freezes; the ingest itself stays in #72.
