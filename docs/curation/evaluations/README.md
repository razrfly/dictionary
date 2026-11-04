# Dated evaluation records

Durable copies of each curation trial's frozen manifest, gate and judgments
(#298 C7), byte for byte the files in the trial's run directory under
`/Volumes/LLM Models/dictionary/run/`, which is not in the repository. Each
folder's `SHA256SUMS` lists the copies. They hold ids, hashes, counts, dates and
short bases in the judge's own words only: no provider payloads, excerpts or
model reasons.

| Folder | Trial | Files |
|---|---|---|
| `2026-11-01-v6/` | v6 ten-page three-day trial (`voltaire-whole-entry-v6`, model config 7); primary cohort attempts 36–45, NO-GO (43 of 73 supported) | `frozen-manifest.json`, `love-gate.json`, `judgments-hour2.json`, `judgments-hour3.json`, `primary-scorecard.json` |
| `2026-11-03-v7/` | v7 ten-page three-cycle 6-hour trial (`voltaire-whole-entry-v7`, model config 8); primary cohort attempts 67–76, NO-GO (1 of 10 useful) | `frozen-manifest.json`, `love-gate.json`, `cycle1-judgments.json` |

The v7 window's dated B5 report and its final scorecard follow after the window
(stop 4 November 2026 09:18:26 UTC); add them here with their hashes when posted.

Templates for the next records:

- `trial-manifest.template.json`: a publishing trial's frozen manifest (#298 B2's fields).
- `comparison-batch-manifest.template.json`: a comparison batch's D0 manifest (#298 D0, D6).

`2026-10-28-phase-a.md` is the earlier Phase A note.
