# Repository reconciliation before Stage 1

Audited 26 September 2026 against main `828cdf2be650a216adb44090e1a99aa1edab3d86`, before the routing specification merge. This records what was found and retained; it is not a claim that the issue backlog is complete.

## GitHub and branches

The only open pull request at the audit was [#200](https://github.com/razrfly/dictionary/pull/200), containing the routing specification, evaluator and handoff. Main had 35 commits absent from the primary local checkout. There were 64 local branch refs and 27 registered worktrees.

Most local branch tips were already ancestors of main. The exceptions were checked rather than merged indiscriminately:

| Old local work | Evidence and disposition |
|---|---|
| `74-encyclopedia-model` | All non-main commits are patch-equivalent to main; delivered through PR #76. |
| `codex/issue-82-reader-milestone` | All non-main commits are patch-equivalent to main; delivered through PR #83. |
| `merge-154` | Merge-only history; no unique non-merge patch. |
| `claude/143-spotify-music-6bb8a8` | Range comparison maps old `9076b78` to rebased `5850714`; reviewed follow-ups landed through PR #146. |
| `claude/144-kit-de9e9d` and phases 1–3 | Range comparisons map `46eba05`, `8306e0e`, `561ba87`, `889237a` to `a457c81`, `4ef6b56`, `934e138`, `3b7db54`. Rebased changes and subsequent fixes landed through PRs #147–150. The DOM assertion commit is patch-equivalent too. |
| `codex/routing-policy-194` | Current routing specification, tracked by PR #200. This is the work to review and merge before Stage 1. |

Historical branch refs are retained. Their old SHAs need not become ancestors of main when reviewed, rebased replacements already landed.

## Local work accounted for

- The primary checkout's routing files duplicate PR #200. Reconcile them with the merged specification when updating local main.
- A local word-page test workaround narrowed assertions to selected sources. Main already fixes the underlying arbitrary fixture source selection in `5b66ad71cfb7a4cbdf54a82a40531fb3373f2e74` (PR #161). Preserve the patch in the local archive; retain main's stronger assertions.
- The [21 September provider audit](../historical-drafts/2026-09-21-api-saturation.md) and [12 September editorial guide](../historical-drafts/2026-09-12-encyclopedia-guide.md) are preserved in Git as historical drafts. Their outdated directions must not override current README, code, routing ADR or curation issues. The old guide's README-link patch is retained locally rather than adding it as active guidance.
- The `dictionary-word-page-grouping-2c67e4` worktree has local preview port settings in `.claude/launch.json` and `config/dev.exs`. These are retained in place and backed up; Stage 1 has no dependency on them.
- Most other dirty worktrees contain only a `data` symlink to the existing internal-drive corpus. These are local resources, not missing source commits.
- One locked Claude worktree still has a live owning process. Its head is already in main. Preserve the checkout and lock; do not retire another session's resources.

Original patches, original draft text, the full branch/worktree inventory and SHA-256 checksums are stored locally in ignored `data/audits/2026-09-26-main-readiness/`. The routing snapshot remains under ignored `data/audits/2026-09-26-issue194/`. Neither directory contains required new application code.

## Start gate

After PR #200's independent review findings are handled and the PR is merged, fast-forward the primary main checkout and verify it is clean and matches origin/main. Keep the routing worktree available for reuse; implementation starts on a fresh branch from current main. Use the [Stage 1 prompt](implementation-rollout.md#copyable-stage-1-prompt).

The routing issue #194 and related curation issues remain open because their production acceptance criteria are future work. No issue is closed just to make the repository appear finished.
