# Issue 88 re-audit — 12 September 2026

Scope: PR #89 after its issue-comment re-audit, CodeRabbit review, and rebase onto the repaired PR #87 head. This is the automatic CineGraph discovery MVP, not human curation or live GIPHY/Artsy integrations.

## Assessment

Grade: **A+ for the MVP**. The earlier repair work and the accepted CodeRabbit findings resolve the previous audit. Another architecture or implementation issue is not necessary; independent review should now focus on verifying the implemented contracts.

The implementation supports unprepared definition visits, asynchronous discovery, positive and negative caches, bounded pagination, provider eligibility, durable withdrawal, provider backoff, cleanup/recovery, multiple provider slots and a repeatable warming/resume task. Discovery remains separate from authoritative definitions and future attributed curation.

## Fixes made during this re-audit

1. **Retry allowance belongs to each page.** Cursor requests previously copied the root run's transport-attempt counters. A successful root that needed all three attempts left later pages unable to fetch. Cursor requests now retain resolved keyword IDs but start with fresh attempt counters. A regression makes both pages succeed on their third request.
2. **Disposable previews stay disposable.** Persisting a result previously copied its full preview and keyword match into immutable source-record revisions. Cache cleanup could never remove those copies. Durable records now retain external identity only; previews and match details remain in discovery results. A regression retrieves the same film under two terms and verifies one identity-only source revision. This changes new writes; it does not retroactively erase source revisions produced by previous development runs.
3. **Worker ownership survives recovery.** Run admission now re-reads and locks the run after acquiring the provider lock. Completion, failure, deferral and exception recovery check the execution lease under a row lock. Delayed workers cannot mutate a recovered attempt. PubSub notifications are emitted after commit. Regressions reproduce delayed success, malformed response and exception after another execution has finished.
4. **Deterministic health fixture.** The U6 link-out test used a helper that created another sense under an arbitrary source while expecting the definition-card count to stay fixed. It now links the existing WordNet sense. This changes the test fixture, not application behavior.
5. **Provider-safe page rendering.** Word pages select only film-capable server providers, preserve term/relevance metadata across PubSub updates, clear pagination loading state on immediate rejection, and ignore incompatible provider events.
6. **Versioned mappings and true rolling budgets.** Automatic mappings exclude superseded adapter versions. Each outbound attempt now has its own timestamp, so the shared 60-second budget expires requests individually instead of retaining a run's lifetime count.
7. **Transport and catalog hardening.** Runtime provider overrides feed the source catalog, missing image-base configuration produces posterless cards, Req connection establishment uses the configured timeout, and malformed negative `Retry-After` values fail safely.
8. **Queued-work lifecycle proof.** Retire, split and merge regressions execute already-queued work and prove it fails before any provider request.

The pagination, permanent-preview and delayed-success/failure regressions failed against the preceding code before being fixed.

## Verification and limits

- The previous audit's seven independent regression cases pass against the updated implementation.
- Final `mix precommit`: **875 tests, zero failures** (seed 175372). Compilation with warnings as errors, formatting and the manifest verification passed.
- `git diff --check`: passed.
- The first full run was blocked only by missing WordNet/Kaikki files in this worktree. The existing main checkout's `data` directory was linked temporarily so the manifest test could verify the actual inputs.
- This pass rechecked code, database behavior and automated tests. It did not repeat the prior agent's authenticated live-provider and desktop/mobile browser demonstrations or perform a distributed load test. Those earlier demonstrations are documented in `docs/discovery/issue-88-handoff-2026-09-12.md`; they are not newly measured evidence from this pass.
- The fixes are committed to the existing PR branch. No merge or issue closure was performed.

A production rollout still needs its normal configured-credential smoke check and monitoring of hit rate, empty results, latency and provider budgets. Curation and additional real providers remain separate follow-up work.
