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
