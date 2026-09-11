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
