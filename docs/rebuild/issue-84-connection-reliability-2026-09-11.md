# Issue #84 — connection reliability and authoring evidence

This is the implementation record for the four ordered checkpoints in
[issue #84](https://github.com/razrfly/dictionary/issues/84). It records fresh
evidence produced on the review branch; it does not claim independent audit,
deployment authorization, or completion of #85/#86 provider/product work.

Baseline: `main` at `ab0cc0a`. No database reset, legacy-row migration or broad
source import was used.

## Starting reproduction

The unchanged historical audit was run before implementation:

```text
MIX_ENV=test mix test docs/audits/2026-09-09-issue73/reproductions.exs
7 tests, 5 failures
```

The failures were the documented stale acceptance, merged-page continuity,
`:merged`/`:merge` mismatch, split-context reconciliation gap, and rejected
`defines` projection leak.

## Checkpoint 1 — reliable existing connections

### Public visibility policy

There is one query policy in `DevilsDictionary.Claims.visible/2`, applied before
cursoring, limits and counts. Public reads:

- exclude withdrawn claim revisions and reviews whose standing decision is
  `rejected` or `withdrawn`;
- exclude claims attached to a currently withdrawn content/sense revision or an
  unresolved split/retired identity;
- retain pending (`needs_review`) and disputed claims, with those states shown
  explicitly rather than hiding the correction process;
- keep rejected/withdrawn history available only to call sites that obtained
  explicit internal authorization from the current database-backed reviewer
  role.

Rights are separate from relationship visibility. A current content revision is
metadata-only when `rights_metadata.display` is `restricted`, `metadata_only`,
`identity_only` or `none`, or when `allow_display`/`display_allowed` is false.
Bodies, excerpts and quoted detail are then redacted while the content identity,
source URL, revision ID and provenance remain available.

### Identity and review rules

- Merge and split operations lock all participants, require a nonblank reason,
  reject missing/inactive/repeated/incompatible/cyclic shapes, and always record
  an actor (a labelled registry-system actor only when the caller did not supply
  a human/import actor).
- `resolve/1` now reads the `:merge` operation and follows merge chains.
  Canonical reads aggregate the survivor's merge family without rewriting any
  historical assertion revision. Preferred labels become aliases; external IDs
  and source-owned assertions remain intact.
- Splits inspect subject, object, context and jurisdiction endpoints plus
  evidence/review-context attachments. Each ambiguity opens one reviewer case.
  Mapping produces a new claim revision and preserves the original history;
  unresolved and declined outcomes are recorded distinctly with actor/reason.
- A review context stores a canonical snapshot/fingerprint of the assertion
  attribution, meaningful revision fields, exact displayed endpoint revisions,
  citations and each citation target's current state. An accepted/disputed
  decision displays as `changed_since_review` when any of those inputs changes.
  Existing review rows are not fabricated or backfilled.

### Verification

```text
Historical audit, unchanged:                       7 tests, 0 failures
Checkpoint/source/schema/connected targeted suite: 139 tests, 0 failures
```

The targeted source suite covers completed/partial/interrupted-style ownership
stamping, reconciliation, multiple source support, resolver/linker reruns and
the rule that a partial/bookkeeping run cannot withdraw another record or
source's support.

Further checkpoint evidence is appended below as it is completed.

## Checkpoint 2 — bounded general entities

The kind-dependent linker exception is removed. Scoped runs now select exactly
scope members for every entity kind. `Linker.run_selected/2` is the only
out-of-scope path and accepts a bounded set of lexeme, target-identity or source
record IDs; it runs identifier-backed evidence only. The ordinary missing-scope
path raises instead of expanding globally. The regression uses the catalog's
real Ambrose Bierce (`Q191050`) and *The Devil's Dictionary* (`Q1197843`)
identities, proves equal selection, source provenance and unchanged rerun
history, and separately keeps name-only person inference excluded.

Wikidata now supports exact QID selection with entity/request/depth budgets and
restricts both materialization passes to records visited by that run. Its
checked-in representative fixture covers person, work, organization, place and
event projection plus two different IDs with the same label. Reclassification
keeps an existing object ID, metadata and name attachment; a local artifact with
no external identifier remains valid. The retention, projection and next-fetch
policies—including deliberately omitted qualifiers/references—are recorded in
`docs/adr/0002-bounded-general-entity-selection.md`.

Bounded live smoke import (exact QIDs `Q191050,Q92640,Q180,Q270,Q43653`):

```text
selection=explicit_qids  seed_qids=5  fetched=5  records=5
requests=1/2             entity budget=20       related depth=2
truncated=false          unresolved references=0
stored trim saving=98.9% concepts materialized=5
projected kinds=person,work,organization,place,event
```

The first smoke attempt exposed that fetch caps did not constrain the existing
stale-record materializer. That result is intentionally not acceptance
evidence. Both materialization passes were then restricted to the run's visited
QIDs, covered by regression tests, and the corrected smoke above was recorded.

```text
Checkpoint 2 ordinary suite: 798 tests, 0 failures
Historical audit, unchanged:    7 tests, 0 failures
```

## Checkpoint 3 — minimal authoring, review and challenge

`/connect` remains server-gated to a fresh database-backed internal contributor
or reviewer role. Within that gate, the composer now supports the complete
minimal path in the issue:

- search or create a local person, work, artifact, event or concept, with typed
  work fields, an optional creator and optional candidate external identifier;
- show duplicate candidates before creation and keep all local identities valid
  without an external identifier;
- restrict the predicate and object choices from the catalog's endpoint rules,
  including deliberate selection of an exact source meaning;
- distinguish claimant, submitter, creator/author and reviewer. `Me`, another
  selected actor and unknown are separate choices; an account never becomes a
  public person identity implicitly;
- attach any number of supporting or contradicting citations to exact content
  or sense revisions, with locators and attribution text;
- record rationale plus optional language, dates, jurisdiction and contextual
  object; and
- revise or challenge the claim with counterevidence. Every change creates a
  revision and returns the standing review to `needs_review`.

Stable `/evidence/content/:revision_id`, `/evidence/sense/:revision_id` and
`/evidence/source-record/:revision_id` destinations display the cited immutable
revision rather than redirecting to today's word or source state. The connection
page shows claimant and submitter separately, standing review, decision reason,
reviewed inputs, evidence and counterevidence, immutable history and the
permission-checked correction actions. Relevance votes remain an independent
model concern; this checkpoint does not claim the #67/#66 voting wall.

The server-side tests revoke a role after a LiveView session is established and
prove the next create/revise/challenge event is refused. They also cover local
types, duplicate candidates, invalid endpoints, exact sense choice, several
claims on one artifact, multiple evidence roles, unknown attribution, review
staleness and stable evidence destinations.

```text
Checkpoint 3 ordinary suite: 806 tests, 0 failures
```

## Checkpoint 4 — connected durability and unseen extension

### One continuous acceptance walk

`issue84_checkpoint4_acceptance_test.exs` performs one connected scenario, not
a set of disconnected endpoint assertions:

1. an authorized contributor creates the local artwork *Family Table*;
2. selects one exact fictional “nepotism” meaning, an unknown claimant, a
   rationale/context and two exact supporting revisions;
3. a different reviewer accepts that precise display context and both endpoint
   views show the same accepted claim;
4. a different contributor challenges it with counterevidence, producing claim
   revision 2, and the reviewer accepts that version;
5. the first source refreshes, so the page becomes `changed_since_review` while
   preserving the cited old revision;
6. the second source withdraws, while both immutable citations and the surviving
   source/editorial history remain;
7. the artwork identity merges, leaving the assertion's historical endpoint
   unchanged while the old and survivor URLs resolve to the survivor and expose
   the same claim; and
8. the selected meaning—which was also the context—splits. One reconciliation
   case records `object`, `context` and `review_context`; a reviewer maps it with
   a reason, producing revision 3 at `needs_review`, with revisions 1–3 and the
   counterevidence still inspectable.

The adjacent checkpoint tests cover multiple person/organization credits, an
anonymous work, a clearly labelled offline situationship fixture outside every
scope, and high-degree traversal using the existing 42,729-edge production-size
node. The actual contributor path issued 15 queries and the connection reader
24, both within the recorded cap of 24. Claims/evidence have no application page
cache; `:cache_scorecard` remained `false`, and a revision written after a read
was visible on the next build.

### A genuinely unseen extension

The post-baseline `adaptation_of` predicate is loaded from
`priv/predicates/extensions.json` and permits only work → work. The exercise
first removes that catalog seed inside the test transaction, creates an
`authored_by` attachment, then loads the new predicate. Cost: one controlled
JSON definition, no table, column, migration or identity rewrite. The original
attachment/revision and object ID remain unchanged; an adaptation succeeds and
an artifact endpoint is rejected. Score row E3 now includes this new predicate,
so the earlier translated-poem fixture is no longer accepted as the unseen
extension proof by itself.

### Large-corpus read hardening

The browser walk exposed two production-corpus facts that small fixtures did not:

- all 1,989,610 stored sense revisions use a JSON array for `examples`, while
  the schema accepted only JSON objects. `DevilsDictionary.Types.JsonValue`
  now loads both valid JSON shapes without rewriting a source row; and
- single-member canonical queries used `ANY([id])`, making an incoming page
  filter 1,059,970 assertion revisions before finding 100 rows. Scalar equality,
  a set-based latest-review join and partial public-visibility indexes restore
  the intended indexed plan. Entity aliases were also under an `OR EXISTS` that
  scanned all 92,973 entities; separate indexed candidate arms and prefix-only
  matching below three characters keep discovery bounded. A strict scorecard
  count no longer executes the complete visibility branch twice.

The index migration changes performance only: it adds no domain state. The new
adaptation itself remains the data-only extension described above.

### Browser walk

The real development app on port 4007 was driven through the complete composer,
connection and cited-evidence surfaces, not only route-tested. At 1280 px the
composer created local artifact object `3733873`, selected WordNet sense
`198799`, pinned Bierce content revision `551`, and submitted connection
`3856902`. The detail showed claimant `Unknown`, submitter `Account #1`,
`needs_review`, the exact locator and the immutable cited body. Direct navigation
to `/evidence/content/551` rendered that historical revision.

At both 1280 px and 375 px, the composer, connection detail, challenge page and
exact-evidence page measured `scrollWidth == clientWidth` (zero horizontal
overflow). At 375 px the expanded local-object creator remained open across
LiveView validation instead of collapsing after each keystroke. The known test
harness MutationObserver console noise is the same injected observer already
recorded in the issue #82 browser evidence; no application bundle observer was
introduced.

## Verification and reused rebuild evidence

The changes affect connection correctness and bounded read/write paths, not the
semantic materialization projection over the full archives. Therefore the
expensive independent rebuild was not repeated. The reused evidence is
`docs/rebuild/completion-2026-09-09.md` at commit `f4dd10a`: independent semantic
fingerprints matched after materialize/resolve. The post-full-Wiktionary
same-database replay/score evidence was independently audited at `44f9c3b` and
incorporated into the `ab0cc0a` baseline; the current scorecard still reports
identical fingerprints over 1,807,819 records across all six sources. This reuse
was checked independently from input and ownership integrity:

```text
mix dd.manifest:                                      5 / 5 inputs verified
historical issue #73 audit, unchanged:                7 tests, 0 failures
checkpoint-4/visibility/score targeted suite:         25 tests, 0 failures
mix precommit:                                       813 tests, 0 failures
animals score (--skip-parity):                       43 / 43 graded pass
  P1 137.472 ms p95 · P2 0.778 ms p95 · X2 74 ms p95
emotions score (--skip-parity):                      42 / 42 graded pass
  P1 130.516 ms p95 · P2 0.653 ms p95 · X2 95 ms p95
culture score (--skip-parity):                       41 / 41 graded pass
  P1 131.801 ms p95 · P2 0.641 ms p95 · X2 88 ms p95
```

Source ownership/history remains covered by the ordinary checkpoint-1 suite:
completed and partial runs, resumptions, multiple attestations, source refresh,
one-support withdrawal, unchanged replay, and reconciliation are asserted by
row/revision identity rather than semantic similarity alone.

## Requirement/evidence matrix

| Contract | Implementation evidence | Acceptance evidence |
|---|---|---|
| #84 C1A / #73 public visibility | one `Claims.visible/2`; rights-aware redaction; explicit internal historical gate | moved historical audit plus rejected/withdrawn/pending/disputed/count/history negatives |
| #84 C1B / #73 identity safety | locked validated merge/split operations, canonical family reads, five attachment roles, reviewer reconciliation | old URL + immutable endpoint tests; continuous merge and context-split walk |
| #84 C1C / #74 exact approval | snapshot/fingerprint of fields, attribution, displayed revisions, evidence and target state | endpoint/edit/evidence refresh/withdrawal and unchanged-context tests |
| #84 C1D / #74 source ownership | run-owned stamping and source-independent support preserved | completed/partial/resumed/multi-source targeted suite; two-source withdrawal walk |
| #84 C2A | uniform scoped linker plus bounded explicit selection | Bierce person/work symmetry, missing-scope refusal, no name-only inference |
| #84 C2B / #74 extensibility | bounded Wikidata QID traversal and ADR 0002 policy | five-kind live smoke, representative fixtures, ambiguity/reclassification/local-ID tests |
| #84 C3 / #73 contribution model | gated local creation, typed composer, distinct actors, exact multi-evidence, revise/challenge/history | command and LiveView suites including stale-role refusal and one-object/many-claims |
| #84 C4 / #74 durability | data-only `adaptation_of`, indexed public reads, uncached fresh connection builds | continuous acceptance walk, 15/24 query counts, all scorecards and two-width browser walk |

## Remaining release boundaries

This branch does not open contribution routes to the general public, implement
the polished mixed-media/relevance-voting wall from #67/#66, add exhaustive
Wikidata crawling or new #72 integrations, or perform deployment/CI
authorization. Those remain independent product/release work. Parent #73/#74
and issue #84 should be closed only after an independent audit; this branch and
its PR deliberately do not merge or close them.
