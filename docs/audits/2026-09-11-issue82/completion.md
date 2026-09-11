# Issue #82 bounded completion — 11 September 2026

This is the implementation follow-up to the independent audit in `README.md`. It addresses the two closure blockers and the compact-reader polish requested in issue comment `5634750465`. It does not close or merge the issue, and it does not include the five explicitly deferred #73 correctness cases.

All corpus writes below target `devils_dictionary_v2`. `devils_dictionary_dev` was not migrated, reset, or written.

## Relationship navigation

The four specialized predicates were reviewed against their declared endpoint rules:

| Predicate | Specialized entity-page direction | Remaining direction |
|---|---|---|
| `about` | incoming content → entity biography | entity cannot be its subject |
| `authored_by` | incoming work/content → person | outgoing work → author remains in connections |
| `edition_of` | incoming edition → work | outgoing edition → work remains in connections |
| `published_in` | incoming content → edition contents | entity cannot be its subject |

Only incoming predicates represented by named panels are suppressed. Outgoing role claims render a direct canonical endpoint link plus a separate relationship-detail link. The two independent audit reproductions were promoted into `entity_live_test.exs` and now pass. The ordinary suite also covers all four predicates, person → work → edition and the reverse paths, and independent incoming/outgoing pages with more than 24 rows and no overlap.

Real browser traversal succeeded:

```text
/words/341814/ambrose-bierce
  → /entities/1/ambrose-bierce
  → /entities/2/the-devils-dictionary
  → /entities/3/project-gutenberg-972-1911-text

work author href:  /entities/1/ambrose-bierce
edition work href: /entities/2/the-devils-dictionary
```

## Evidenced Bierce sense → person link

The source record already contained suitable durable evidence; no name match or special case was added:

| Field | Value |
|---|---|
| Lexeme | `341814` · Ambrose Bierce |
| Sense | `342580` |
| Source record | `109124` · `oewn-10870735-n` |
| Stored sense evidence | `wikidata: "Q191050"`, `ili: "i94474"` |
| Entity | `1` · person · Ambrose Bierce · `Q191050` |
| Claim | `refers_to` |
| Methods | `wordnet_wikidata` at `0.90`; `wordnet_ili` at `0.85` |
| Evidence metadata | signal, QID/ILI, and source-record id |
| Latest completed owning run | `141` |

The failure was scope selection, not adapter data loss: `mix dd.link --scope animals` excluded an evidenced proper-name sense because the lexeme is not an animal. Identifier-backed rungs now remain scoped for ordinary entities but also admit people backed by a source QID/ILI. Lower-confidence title and disambiguation inference stays fully scoped, and people remain excluded from name-only inference.

The linker now passes its import-run id into the shared assertion writer and records source-record ownership for sense-backed claims. Assertion metadata participates in revision equality, so evidence changes create history while an unchanged rerun does not. Two real runs left exactly one revision for each Bierce claim and advanced `last_seen_run_id` to the completed rerun. The non-seeded fixture proves the same behavior for a different person, including provenance, ownership, and idempotency.

An exploratory global identifier pass briefly proposed out-of-scope non-person links and made Animals A7 fail. The implementation was narrowed before delivery, and the 14,116 claims created by those two exploratory runs were withdrawn with history preserved. The corrected rerun emitted the prior Animals population plus three evidenced person senses. All scorecards returned to green.

## Compact reader

Entity definition summaries are a presentation projection only. Stored bodies remain byte-for-byte unchanged. The projection:

- removes common Markdown presentation markers and link destinations;
- normalizes paragraph and verse whitespace;
- truncates on a word boundary at 120 graphemes with an ellipsis;
- applies a reliable two-line visual clamp; and
- retains the canonical headword link as the full-content destination.

Tests cover a long one-paragraph definition, verse, Markdown, the bound, and unchanged stored content.

Exact same-origin iframe viewport probes were captured in the Codex task at 375×812 and 1280×800. The screenshots were visually inspected in the task; the automation API returned image bytes inline rather than a repository file path.

| Viewport | Page height | Horizontal overflow | Rows | Maximum summary | Clamp |
|---|---:|---:|---:|---:|---|
| Audit baseline, 375×812 | 8,214 px | none | 24 | unbounded | no |
| Completion, 375×812 | 6,383 px | none (`375 == 375`) | 24 | 120 | two lines (56px at 28px line height) |
| Completion, 1280×800 | 4,117 px | none (`1280 == 1280`) | 24 | 120 | at most two lines |

This is a measured 1,831px / 22.3% reduction on the mobile first page, not a new acceptance gate.

## Final verification

```text
focused implementation + independent regressions: 61 tests, 0 failures
mix precommit:                              774 tests, 0 failures
definition coverage:            1,533,898 / 1,541,668 = 99.50%
authored definitions:                 997 unique over 42 pages
authored work:                         1 separate item
```

Warm-cache dense pages (three warmups, twenty measured builds):

| Page | p95 | Maximum | Budget |
|---|---:|---:|---:|
| `cat` | 20.214 ms | 21.805 ms | 150 ms |
| `run` | 65.334 ms | 65.717 ms | 150 ms |
| `set` | 59.207 ms | 60.074 ms | 150 ms |
| entity `4` (42,729 edges) | 77.603 ms | 77.771 ms | 150 ms |

| Scope | Result | P1 p95 | P2 p95 | X2 p95 | X3 |
|---|---:|---:|---:|---:|---:|
| animals | 44 / 44 | 59.268 ms | 0.513 ms | 82 ms | 4 / 4 |
| emotions | 43 / 43 | 59.611 ms | 0.552 ms | 85 ms | 4 / 4 |
| culture | 42 / 42 | 57.355 ms | 0.538 ms | 82 ms | 4 / 4 |

Every scorecard has zero pending graded rows. Animals A7 is `10,399 / 10,399 = 100%`. The audit's seven inherited #73 reproductions remain an explicit Release C concern; this patch neither changes nor claims them.
