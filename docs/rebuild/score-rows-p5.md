# What the new rows measured, once there was a corpus to measure

Written at P5, as an appendix to [`score-rows.md`](score-rows.md). Everything
below is a change the full re-import forced, not a change of mind.

## The scorecard could not print its own new rows

`Mix.Tasks.Dd.Score.heading/1` maps a row's first letter to a section, and had no
case for `D` or `P`. So the moment D1–D6 and P1/P2 existed, `mix dd.score`
printed the absorb and materialize sections and then died with a
`CaseClauseError` on `"D"`. The sections are `DURABILITY` and `BUDGETS`.

That it survived P2 and P4 is worth noting: the rows were implemented and tested,
and the *task* that displays them was never run against a database that had them.

## M1 · parity, every source

Rewritten at P1 to compare **content** against the current revision rather than
counting rows, so it fails on the corruption probe the old row passed.

At P5 it earned its keep a second way. It counts an edge as missing when the
record that emits it does not own the resulting assertion — and that found a real
gap the counts could not: Wiktionary keys a record by etymology, so `bear/noun/2`,
`/3` and `/4` all assert *bear* → *mammal*. One claim, three attestations, and
`pending_relations` was keyed by the edge alone, so two of those records lost
their pending row before the resolver saw it. 99 gaps, all of that shape.

## A6 · Wikidata coverage

`union_covered/1` asked for the scope lemmas Wiktionary attests **or** something
is linked to, written as `A OR EXISTS (…)`. The `OR` stops Postgres using a
semi-join for the EXISTS, so it re-ran the subquery once per scope member:
25,383 times, **154 seconds**, and a connection-pool timeout that killed the run
before any row after M4 was reached.

The same set as a union of two id sets is **176 ms**. Both halves still read the
link rule from `linked_to_word/1`, so there is still one definition of what a
link is — the property the browse page and L1 both depend on.

## M2 · idempotent, offline

Graded from an `import_runs` row that `mix dd.materialize` writes, so it needs
that task run after a rebuild; the rebuild alone leaves it *pending*.

Independently of the row, the rebuild demonstrated it at full scale: Bierce,
Johnson, Wikidata and Wikipedia were each re-absorbed over the built corpus three
times while the other two scopes were built, and `content_revisions` did not move
off 113,447 — one revision per content item, no churn.
