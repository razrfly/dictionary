# Draft routing rollout and Stage 1 handoff

[Routing delivery issue](https://github.com/razrfly/dictionary/issues/194) is the single delivery tracker. [The specification PR](https://github.com/razrfly/dictionary/pull/200) contains the accepted design and offline evaluator. [ADR 0004](../../adr/0004-public-routing.md) is the normative contract; [the evidence report](policy-readiness.md) records the measured corpus and test results.

The five stages below are a rough sequence for the existing acceptance checklist. Refine each stage when work reaches it. Start with comments on the main issue; create a separate child issue only when a stage needs its own scope or owner. One agent can retain ownership across stages. No issue was closed by the audit, and this outline creates no new issues.

## Before implementation

Check the latest issue, specification PR, main branch and applicable AGENTS.md. Verify that the specification PR is merged and its review findings are resolved before starting from main. Its A+ grade is the author's assessment of the brief, not external approval or production certification.

Independent review of the specification is the first merge checkpoint. Start Stage 1 from the reviewed specification on current main. The implementing agent must not treat its own tests as independent review.

## Five stages

| Stage | Work | Exit evidence |
|---|---|---|
| 1. Durable foundation | Pages, immutable editorial revisions, typed membership, classification decisions, path reservations and append-only route history; constraints, transactional allocation and resolver result types. Record the curation-composition interface before writing migrations. | Real concurrent allocation, canonical uniqueness, history ownership, overrides, moves/merges/splits and rollback tests. Additive changes preserve existing readers. |
| 2. Backfill and review | Resumable classification/page backfill, per-record dispositions, evidence-backed readable collision qualifiers, review workflow and candidate launch manifest. | Repeat and interrupted runs preserve exact identities and references. Every selected launch record has resolved identity/classification/path issues; deferred records remain visible. Candidate status grants no publication approval. |
| 3. Reader integration | Shared link/resolver helpers across search, Enter, lexical/entity pages, drawers, trails, source pages and histories. | Direct HTTP plus LiveView tests prove canonical resolution, exact-ID 404s, single-hop 301s and selected-identity preservation. Existing lexical routes remain available. |
| 4. Curated On pages | Revisioned authored treatments, typed membership, human review, and the explicit curation-composition binding when that schema is available. | A useful manual On page works without model inference. Lexical access remains independent. Composition selection, semantic claims and page publication keep their separate approvals and eligibility checks. |
| 5. Publication and release | Initial and live-navigation metadata, canonicals, structured data, noindex/sitemaps, feature flag and documented release/rollback procedure. | An independently reviewed, nonempty launch manifest; rights/content gates; exact preservation/restore/restart tests; targeted tests and mix precommit. Enable only approved pages through the project's release authorization. |

Each implemented stage should leave reviewable changes, test evidence and a progress comment on the delivery issue. The outline does not require exactly one PR per stage. Split work or add a child issue when the implementation reveals a useful boundary. Record findings and the next stage's proposed scope at each checkpoint.

## Related work and ownership

- [Curation persistence](https://github.com/razrfly/dictionary/issues/196) owns durable editorial compositions, versions/items and their human presentation approval. Routing owns page identity, addresses, authored On bodies and publication/indexability. Link these identities explicitly as defined in ADR 0004; do not recreate the composition, ballot or claim-review system.
- [Curated opening delivery](https://github.com/razrfly/dictionary/issues/193) owns the persona/runtime/refresh pipeline. That pipeline is not a prerequisite for a manually authored On page or the routing foundation. If composition tables have not landed, defer their binding migration without creating placeholder tables that compete with their owner.
- [Creator identity](https://github.com/razrfly/dictionary/issues/164) and [people population](https://github.com/razrfly/dictionary/issues/165) remain separate. Reuse their implemented services after inspecting current code. An open issue may contain completed pieces; its dated description is not proof of current behavior. Do not mint missing people merely to make routing examples pass.
- The routing audit did not close these issues. Close an issue only when its own acceptance criteria have been verified. The routing delivery tracker stays open until its release criteria pass; broader unresolved corpus records may remain explicitly deferred.

## Expected release

The measured snapshot has 100,723 entities: 38,576 mapped, 56,228 requiring classification/evidence review, 5,917 excluded source pages and two lifecycle cases. It has 1,406 candidate-path collision groups. These are planning evidence, not a frozen assumption about a future database. Rerun against the actual implementation snapshot.

The first release covers an approved, useful subset and preserves lexical access. It does not require inventing classifications for the entire corpus. The dry run allocated no paths and approved no pages. A mapped family, a model vote, passing tests or the brief's grade cannot substitute for the publication approvals.

## Copyable Stage 1 prompt

This starter prompt begins the foundation only. Later stage prompts can use the actual results and refined scope recorded on the main issue. Creating this document has not started implementation.

```text
Implement Stage 1, the durable routing foundation, for https://github.com/razrfly/dictionary/issues/194.

First inspect the current issue and comments, the latest state and reviews of https://github.com/razrfly/dictionary/pull/200, current main, AGENTS.md, README, docs/adr/0004-public-routing.md, and docs/audits/2026-09-26-issue194/policy-readiness.md. Use docs/audits/2026-09-26-issue194/implementation-rollout.md for the rough five-stage context. Verify the specification PR is merged and its review findings are resolved; then branch from current main using the codex/ prefix. Reuse a suitable free worktree and account for local edits before changing its branch.

Own Stage 1 through a reviewable PR or small set of PRs: durable page identity, revisioned On body and typed membership storage, persisted classification decisions, unique path reservations, canonical pointers, append-only history, transactional allocation, and explicit resolver result types. Preserve existing reading behavior. Full corpus backfill, reader route replacement, On editing UI and production publication belong to later stages.

Before migrations, inspect the current code and https://github.com/razrfly/dictionary/issues/196 and record how routing pages bind to curation compositions. Routing owns pages/paths/On bodies; curation owns compositions and their presentation approval. Semantic-claim review remains separate. Do not create competing composition or ballot tables. If the composition schema has not landed, defer its binding migration and continue the independent foundation work. Persona inference is not a prerequisite.

Use the accepted ADR constraints and the project's Ecto migration conventions. Preserve permanent registry identities, source/content/evidence revisions, existing local edits and published-address ownership. Keep PostgreSQL and active source code on the internal drive. Classification and display-label changes must not silently move a published address. Missing or conflicting classifications remain reviewable, with no silent Subjects fallback.

Implement and test the Stage 1 invariants: exactly one canonical for a published page/locale; global current/historical path uniqueness; atomic pointer/allocation/history updates; bounded race handling; explicit approved moves/merges/splits; immutable historical reservations; versioned override evidence; and restore/rollback behavior. Prove concurrency with independent database connections. Preserve exact references as well as counts. Only add tests that demonstrate required behavior.

Keep each implementation PR reviewable and address independent review findings before merge. Do not infer publication approval from a passing test.

Run appropriate targeted tests and mix precommit. Keep README, ADR and implementation status synchronized. Post a concise Stage 1 result to the routing issue with PR links, tests, schema changes, remaining blockers and a proposed refined scope for Stage 2. Use an issue comment initially; create a child issue only if there is a concrete benefit, keeping the main issue as the delivery tracker.

Complete Stage 1 and prepare the next-stage handoff. Do not close the routing issue or unrelated issues, run a production corpus backfill, or enable production publication as part of this foundation task. Surface actual scope conflicts or required human decisions while continuing unblocked Stage 1 work.
```
