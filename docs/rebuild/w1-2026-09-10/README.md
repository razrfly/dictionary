# W1 — corpus spike and budgets

Session W1 of [#79](https://github.com/razrfly/dictionary/issues/79). Date 2026-09-10.
Base `main` at `f4dd10a`. Database `devils_dictionary_v2`. `devils_dictionary_dev`
untouched; no third database created.

W1 measures what a full Wiktionary records pass would cost, so W2 and W3 can be
committed to rather than guessed at. It does not build that pass.

## Method

`mix dd.absorb wiktionary --sample-every N` (added here) runs the *same* stream,
trim, insert and materialize machinery as the scoped absorb, with scope
membership swapped for a 1-in-N sample. The numbers therefore transfer.

Sampling is `rem(:erlang.phash2(word), N) == 0`, not `--limit`:

- the dump is in page order — it opens with `dictionary`, `free` — so a
  head-limited sample is biased and cannot be extrapolated;
- a hash is stateless, so it survives `Task.async_stream` without a shared
  counter, and the same N re-selects the same words;
- it selects *words*, so every part of speech for a sampled headword arrives
  together — the same lemma granularity the scoped pass has.

Two samples were run, N=30 and N=31, giving near-disjoint sets. N=31 is the clean
timing: its records were fresh, where N=30's had already been inserted by the run
that hit the defect below.

## Census

The `--limit`-free walk decodes the whole dump each time and reports it.

| | |
|---|---|
| Dump lines, all languages | 10,806,865 |
| English records (decoded, `lang_code == "en"`) | **1,487,639** |
| Indexed lexemes | 1,541,668 |

#79 estimated "~1.3 M". The real figure is **1,487,639**, essentially 1:1 with the
index. A `grep -c '"lang_code": "en"'` gives 1,540,602 — it over-counts nested
occurrences, so the decoded number is the one to use.

## The defect the spike exposed

The first unscoped run **aborted the entire materialize transaction**:

```
** (Postgrex.Error) ERROR 22001 (string_data_right_truncation)
   value too long for type character varying(255)
   ... Materializer.write_relations/5 -> insert_count/3
```

`origin_key` is `varchar(255)` on both `assertions` and `pending_relations`, and
every one of them is built by interpolating strings the source chose. Wiktionary's
`coordinate_terms` can name a whole series in a single target —
`A-shaped - B-shaped - … - Z-shaped` — giving a 315-byte key. `to_pos` was nil
throughout and `to_lemma` is `text`, so the key is the only offender.

The three test scopes never contained one. Frequency in the sample: **1 key in
94,034 records** (~0.001 %), so roughly 15–30 across the full corpus — rare, and
fatal every time, because one row aborts the whole batch transaction.

Fixed in `Materializer` by bounding all four `origin_key` builders through one
`bounded_key/1`: keep the readable head, make the tail a 16-hex digest of the
whole key. Deterministic (a re-run upserts onto the same row), inspectable, and
**no migration** — the value fits the column it always had. Regression test:
`materializer_test.exs`, "bounds an origin_key a source's relation target would
overrun", which also asserts stability across a re-run.

## Measured

| | N=30 | N=31 (clean) | combined |
|---|---:|---:|---:|
| Records absorbed | 48,891 | 45,143 | 94,034 |
| Newly defined lexemes | 44,862 | 41,565 | 86,427 |
| Define ratio | 0.918 | 0.921 | **0.919** |
| DB bytes added | 110.7 MB | 101.3 MB | 211.9 MB |
| Trim saving | 61.9 % | 62.0 % | — |

- **Bytes per record: 2,254.**
- **Dump walk: 19.4 s**, constant, measured at `--sample-every 4000` where writes
  are negligible.
- **Insert + materialize: 28.2 s for 45,143 records → 1,601 records/sec.**
- **Resolve** (`mix dd.resolve --source wiktionary`): 14.3 s for 288,028
  relations, +123 MB. **R2 = 91.1 %** resolved, against an 80 % bar.
- Relations per record: 1.96.

Coverage moved **12.7 % → 18.3 %** on a 6.3 % sample.

## Extrapolated to the full pass

Remaining after the spike: 1,370,709 records.

| | |
|---|---:|
| Absorb + materialize | **~15 min** |
| Resolve (~2.91 M relations) | ~2.4 min |
| Storage, records | 3.09 GB |
| Storage, resolve | 1.25 GB |
| **Projected database** | **~9.5 GB** (from 4.9 GB at session start) |

**Coverage.** The linear extrapolation of the 0.919 define ratio saturates — it
lands at 100.0 % of 1,541,668, which is past the ceiling. Read it as: essentially
the whole index gets a definition.

The structural bound is *not* the record count. 1,487,639 counts decoded English
**records**, and a record is `(word, pos)` — separate records share that key when
Wiktionary splits a word by etymology, so the record count overstates distinct
lexemes. Measured directly: **1,470,121 of 1,541,668 lexemes (95.4 %) carry
`wiktionary` in `source_ids`**. The sample agrees independently — run N=31 wrote
47,399 records for 46,917 lexemes, a ratio of 0.9898, which extrapolates to
1,472,511 (95.5 %).

So the ceiling is **95.4 %**, the ratio decays as coverage fills, and the honest
expectation is **the low-to-mid 90s versus 12.7 % today**. W3 measures the real
figure rather than inheriting this one.

## Recommendation: one pass, not batched by frequency band

Fifteen minutes and 3 GB does not need banding. Banding was proposed against a
guess that the pass might run for hours; it does not. One pass is simpler, has no
band-boundary bookkeeping, and W2's resumability requirement stands on its own —
the run should still be interruptible, because a 15-minute job that cannot resume
is a 15-minute job you run twice.

Two things W2 must not inherit from this spike:

1. **`sample/1` is a measurement path, not the pass.** It never claims
   completeness and materializes without reason ordering, because there is no
   scope to order by. W2 needs its own ordering decision.
2. **The 2,254 bytes/record figure includes index growth on a table that is
   already large.** It is a good planning number, not a guarantee; W3 re-measures.

## What is unmeasured

- Page latency at dense-sense scale. X2's warm-cache p95 was 66–72 ms on a corpus
  where most words had no senses. W3 must re-measure, and this is the most likely
  place the scale-up bites.
- The scorecard on all three populations after the full pass.
- Whether any *other* `varchar(255)` in the write path has the same latent
  overflow. `origin_key` is now bounded at all four builders; the rest of the
  write path was not swept.

## Reproduce

```
mix dd.absorb wiktionary --sample-every 30
mix dd.resolve --source wiktionary
```

Raw before/after snapshots: `before.txt`, `pre30.txt`, `post30.txt`, `pre31.txt`,
`post31.txt` in this directory. They are the literal captures, so their key sets
differ as the questions narrowed — read them with this mapping:

| `before.txt` | later files | meaning |
|---|---|---|
| `n_defined_lexemes` | `n_defined` | lexemes with any definition |
| `source_records_bytes` | `sr_bytes` | `pg_total_relation_size('source_records')` |
| `source_record_revisions_bytes` | `srr_bytes` | ditto, revisions |
| `sense_revisions_bytes` | `sense_rev_bytes` | ditto, sense revisions |
| `n_lexemes` | *(dropped)* | constant at 1,541,668 throughout |

`pre31.txt` and `post31.txt` carry only the three keys that moved, because by then
the storage-per-record figure was already established from the N=30 pair.
