# #172 final sweep, 2026-09-27

The scripts, queries and captured output behind the *Final sweep, on the
restored database* section of `docs/integrations/wikiquote.md`, run against
the dev database `devils_dictionary_v2` at `main` `c6bd882` (plus the red-link
parser fix for run 400). Kept so the sweep can be read, checked and re-run;
they are not part of the application and nothing compiles them.

Every script carries a one-line header naming what it produced. The data
files (`hwm.csv`, `recovery.sha256`, `*.out`) are byte-identical to what the
sweep wrote: `recovery.sha256` holds `hwm.csv`'s checksum, and the outputs are
captures, so neither was annotated.

## The files, in the order they ran

| # | file | what it is | produced |
|---|---|---|---|
| 1 | `baseline.sql` | read-only: links per method (active, current, revisions), English lexemes and pages with a sense link, word-level-only pages, promotions that share a sense with a source link | `baseline.out` |
| 2 | `hwm.csv`, `recovery.sha256` | the recovery point: high-water marks on every table the sweep could write, and the checksums of `hwm.csv` and `current_links.csv` | — |
| 3 | `promote.exs` with `DRY=1` | `Linker.corroborate/1` per scope inside a transaction that is rolled back; Repo only, no app, no Oban | stdout only (predicted 267 withdrawals) |
| 4 | `promote.exs` | the same for real, one `link` import run per scope | import runs **206–208**, `run1.out` |
| 5 | `promote.exs` again | the repeat run; wrote nothing | import runs **209–211**, `run2.out` |
| 6 | `baseline.sql` again | coverage after the runs | `after.out` |
| 7 | `run_pages.exs` with `ONLY=wikiquote` | Wikiquote for the thirteen probe words, in-process | discovery runs 366 (*war*), 367 (*power*); `probes_run.out` |
| 8 | `probes.sql` | read-only: each probe's recipe, tier, page, hop and results | `probes.out` |
| 9 | `wl_art.sql` | read-only: word-level pages whose candidate the artwork catalog depicts (found *bunny*) | — |
| 10 | `run_pages.exs` | every covering provider for *bunny*, *grief*, *situationship*, so a page visit admits no run | discovery runs 368–399, `pages_run.out` |
| 11 | `run_pages_refresh.exs` with `REFRESH=1 ONLY=wikiquote` | *bunny*'s Wikiquote run again, after the red-link fix | Wikiquote run **400** |
| 12 | `serve.exs` | this branch's app on port 4172, Oban in `:manual` with no queues or plugins | no runs, no jobs |
| 13 | `shoot.py`, then `shoot_empty.py` | CDP screenshots at 375 and 1024, light and dark; the second retook the empty note cropped to it | `docs/discovery/issue-172-sweep-*-2026-09-27.jpg` |

`run_pages.exs` runs a provider **without letting any other Oban node claim
the job**. The main checkout's server (4007) and another (4017) run Oban on the
same database. It calls `Discovery.request/3` inside an outer transaction,
deletes the `oban_jobs` row that request inserted before the transaction
commits, then calls `Discovery.execute_run/1` in its own process.

## Re-running it for #214

#214 re-measures a fixed 200-page sample after each change. Start from:

- `probes.sql`: replace the thirteen `VALUES` with the sample's lemmas and target ids.
- `run_pages.exs`: run it over the same lemmas (`ONLY=wikiquote,met,commons` for the three tiered shelves).

`baseline.sql` gives the database-wide counts to set beside them.

## The recovery point

`current_links.csv` is too large to commit (3.9 MB, 92,476 rows): one row per
`refers_to` and `lexeme_entity_candidate` claim, giving its current revision
id before the sweep's first write. It lives at

```
/Volumes/LLM Models/dictionary/recovery/2026-09-27-issue-172-sweep/current_links.csv
```

with its SHA-256, `7bab1e87789d14c43dbe68d7f6b8f6c78fc2461a573411b44777521ea448fa39`
(in `recovery.sha256` here and in `current_links.csv.sha256` beside it). Check
it with `shasum -a 256 -c current_links.csv.sha256` in that directory.

## Reversing the sweep, if it is ever needed

Never needed so far and never run; this is the procedure the marks were taken for.

**What the sweep wrote:**
- **Claims:** 267 revisions, ids 4,373,828–4,374,094, every one `corroborated_gloss` → withdrawn. Ids 4,373,561–4,373,827 were used by the rolled-back dry run and hold nothing. There are no new assertions (the mark was 3,901,280).
- **Import runs:** 206–211, rows of history.
- **Discovery:** runs 366–400 and their results, all ordinary cache rows.

**To put the 267 promotions back:**
1. Confirm nothing newer has revised the same assertions:
   `SELECT count(*) FROM assertion_revisions WHERE assertion_id IN (SELECT assertion_id FROM assertion_revisions WHERE id BETWEEN 4373828 AND 4374094) AND id > 4374094;`
   This must be 0; otherwise stop, because the history has moved on.
2. In one transaction:
   - delete the revisions with `id BETWEEN 4373828 AND 4374094`;
   - load `current_links.csv` into a temporary table;
   - set `is_current = true` on each listed revision id whose assertion was one of those 267.

   Deleting first keeps `assertion_revisions_one_current_index` satisfied.

The next promotion run would withdraw the same 267 again, because the restored source links still contradict them. So the only reason to reverse is to rebuild the pre-sweep state for a comparison.
