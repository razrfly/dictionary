# #181 build 1 — the Examples section, measured

Twenty captures: `/define/{war,dictator,poet,traitor,coward}` at 375 and 1024 px,
light and dark, clipped to `#examples` (for *coward*, which has no section, the
definitions and what follows). Headless Chrome through CDP device emulation at
DPR 2 — not `--window-size`, which headless Chrome clamps to 500 px.

**The data is not `devils_dictionary_v2`.** The dev database has not been
re-materialized since the mapping changed, so its instance edges are still
`other` rows and the section would show only Wikidata's. The captures come from a
scratch database, `devils_dictionary_ex181`, seeded from `devils_dictionary_v2`'s
own rows: the 193 WordNet source records for the five class synsets and every
synset filed under them, run through the real `Wordnet` adapter and
`Materializer.run_batch/2`, plus *War*'s 16 Wikidata P31 rows and the one
`refers_to` link among them (*Peloponnesian War*). Every other source was set
inactive, so nothing was requested from a provider.

| page | chips | shown / disclosed | byline | `scrollWidth` at 375 |
|---|---|---|---|---|
| war | 44 (29 WordNet synsets + 16 Wikidata − 1 both) | 12 / 32 | WordNet · Wikidata, 1 of them a word | 375 |
| dictator | 6 (from 20 member edges) | 6 / — | WordNet | 375 |
| poet | 145 (from 350 member edges) | 12 / 133, scrolling box | WordNet | 375 |
| traitor | 1 (Benedict Arnold; *Arnold* is an alias) | 1 / — | WordNet | 375 |
| coward | no section | — | — | 375 |

## Build 2 — the exemplar register and the person page

Eight captures: `/define/coward` clipped to `#examples`, and Jeff Bezos's entity
page clipped to the header and *cited as an example of*, at 375 and 1024 px,
light and dark, through CDP device emulation at DPR 2. `scrollWidth` equals the
viewport on every one (375 and 1024).

**The data is a scratch database, `devils_dictionary_ex181b2`**, cloned from
build 1's `devils_dictionary_ex181`, plus `Sources.Catalog.seed!/0` (the new
`community` row) and `devils_dictionary_v2`'s own WordNet records for the
*hypocrite* and *appeaser* synsets, run through the real adapter. On it:

1. `mix dd.exemplars.seed priv/exemplars/first-v1.json --as curator@scratch.test --dry-run`:
   three rows *would seed*, each *would mint the subject*; nothing written, no request.
2. The same without `--dry-run`: three claims created, three people minted from
   one real `wbgetentities` request (`minted_by: community`).
3. The same again: all three *held*, nothing written.
4. One reviewer's accept on the Bezos claim, through `Contributions.review/6`.
   The other two stay `needs_review`, so the public sees neither.

*coward* has no instance row beneath the card because WordNet names nobody
under *coward* — the issue's own line between the record and the culture. That
the chips are unchanged with a card above them is proved in
`word_exemplars_test.exs` (a WordNet instance plus an accepted exemplar on one
page, the chip row's HTML identical before and after).

The dev database was not touched.
