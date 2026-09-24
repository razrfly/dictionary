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
