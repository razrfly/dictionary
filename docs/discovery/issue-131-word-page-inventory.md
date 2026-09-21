# The word page, item by item

Phase 1 of [#131](https://github.com/razrfly/dictionary/issues/131), measured on
`main` @ `6cdfe5b`, 2026-09-20, against the development database
`devils_dictionary_v2` and the dev server on `:4007`. Every height is Chrome,
`getBoundingClientRect()`, every `<details>` closed — the reader's default —
at 1280 × 900 and 375 × 812.

This is what the page holds, not what it should hold. The comparison of three
layouts is in
[`issue-131-word-page-comparison.md`](issue-131-word-page-comparison.md); the
sketches are under [`../sketches/word-page/`](../sketches/word-page/).

## Where the page stands

| | `/define/love` | `/define/nepotism` | `/define/set` |
|---|---:|---:|---:|
| desktop, 1280 × 900 | 12,383 px · **13.8 screens** | 4,024 px · 4.5 screens | 40,118 px · **44.6 screens** |
| phone, 375 × 812 | 18,563 px · **22.9 screens** | 5,448 px · 6.7 screens | 61,682 px · **76.0 screens** |
| first definition | 1,064 / 1,556 px | 498 / 690 px | — |
| first meaningful image | 9,005 / 14,317 px · screen 10 / 18 | 1,443 / 2,255 px | — |

`love` reproduces #111's measurement to within one pixel, which is the check
that this harness and that one agree. **`love` is not the worst case.**
`/define/set` — nine parts of speech, five origins and a Johnson verb card
holding 39,955 characters in two entries — is 44.6 desktop screens, and no
rule in #111 was written against it.

## The inventory

Position is the order the renderer emits. *Growth* is what the corpus actually
contains, not a guess. *Proposed* is the compact default the three alternatives
all apply; where they differ, the comparison says so.

### Page chrome and notices

| # | Item | Shape | Now | Growth | Controls | Proposed |
|---|---|---|---|---:|---|---|
| 1 | Account bar (`#account-navigation`) | two links | 40 px, above the navbar | fixed | — | unchanged |
| 2 | Navbar | logo, theme toggle | 84 px, sticky | fixed | theme toggle | unchanged; the section nav docks under it |
| 3 | Demo banner (`Demo.demo_banner`) | notice | only under `?demo=1` | fixed | — | unchanged |
| 4 | Trail (`#trail`) | breadcrumb of walked words | first in the article | capped at 12 in `WordLive` and again in the parser | links | unchanged; already bounded |
| 5 | Disambiguation (`#disambiguation`) | note + list of lemmas sharing the slug | before the headword | 28,306 slug groups hold >1 lemma; `love` shows 3 | links | unchanged. 162 / 218 px on `love`, and it is the page telling the reader it may be the wrong page |

### The headword block (`#headword`) — 633 / 1,069 px on `love`

| # | Item | Shape | Now | Growth | Controls | Proposed |
|---|---|---|---|---:|---|---|
| 6 | Lemma | `<h1>`, display face | — | one line | — | unchanged |
| 7 | Pronunciations (`#pronunciations`) | IPA strings | beside the lemma | **`love` holds 12 rows: 9 IPA and 3 recordings. `WordPage` keeps 3 and the component renders neither the regional tags it built nor the other 9.** | none | the 3 stay, tagged; `+N variants` opens the full list with tags and the recordings. **The cap already exists; what is missing is that it says so** |
| 8 | Parts of speech (`#parts-of-speech`) | interpunct list, muted when not enriched | — | `set` has 9, `war` 7, `dog` 7 | — | unchanged; one line at every count measured |
| 9 | Forms (`#forms`) | interpunct list | — | **uncapped: `little` 66, `fuck` 40, `master` 24** | none | 8 inline, `+N more` to the rest |
| 10 | Etymologies (`#etymology-N`) | one paragraph per distinct text | — | **uncapped: `love` 1,284 + 79 chars, `dog` 1,615, `set` five of them, one a flattened etymology tree** | none | first sentence inline, the rest in a disclosure that names its length |
| 11 | Redirected-from (`#redirected-from`) | one line | only when reached by a form or the canonical route | one line | — | unchanged |
| 12 | Also-a-form-of (`#also-a-form-of`) | links | conditional | small | links | unchanged |
| 13 | Source line (`#sources`) | *Defined here by N sources* | under the block | one line | — | becomes the index of the cards: in A and B a count, in C a list of links |

### Definition cards (`section[id^=card-]`)

Order is tier, then part of speech (`WordPage`). `love` renders 9, `set` 11,
`nepotism` 4.

| # | Item | Shape | Now on `love` | Growth | Controls | Proposed |
|---|---|---|---:|---:|---|---|
| 14 | Card frame | left rule; amber tint and wash for 👑 | — | one per source × part of speech | — | unchanged |
| 15 | Card header | glyph, source, year, part of speech, ↗, ⓘ | — | one line, wraps | ↗ out, ⓘ drawer | unchanged. **A card without a ↗ is a bug, not a missing icon** (U6) |
| 16 | Prose entry (`entry.body_html`) | rendered markdown | **johnson-noun 3,816 / 5,532 px from 4,727 characters** | **uncapped. `love` 4,727 · `set` 32,527 in one entry · `dog` 2,277 · Wikipedia 2,455** | none | ≤ 600 characters whole; longer ones preview ~360 characters to a block boundary, then *Read the rest of this entry · N characters*. **Split, never duplicated: the preview is the opening of the original** |
| 17 | Several entries in one card | repeated prose | `war` 2 · **`set` 2, 39,955 characters** | one per source record | none | the card previews one entry and counts the rest in a card-level control. The bound belongs to the card, not the entry |
| 18 | Entry authors | *By Samuel Johnson* | one line | small | links to `/entities/…` | unchanged |
| 19 | Card thumbnail | image above the entries | rare | one | — | unchanged |
| 20 | Sense groups (`-group-N`) | a synset, or a source's numbered glosses | wordnet-noun 632 / 1,160 px | **WordNet gives `love` 6 synsets, `dog` 7; each brings a relation row and a broader chain** | glosses capped at 3 with *show N more* | glosses keep their cap; **the number of groups gains one: 3 shown, the rest in one control that counts the senses behind it** |
| 21 | Sense line | marker, gloss, tags | — | Wiktionary files 27 senses on `dog`'s noun | — | unchanged |
| 22 | Per-sense relation rows | named row of chips | — | capped at 12 with `+N`; `love`'s family row hides 269 | `+N` disclosure | unchanged; already bounded |
| 23 | Broader chain | `bivalve › mollusk › …` | — | capped at 8 | links | unchanged, but it is the most expensive line on a phone: it wraps to three |

### The culture block (`#in-culture`) — 1,378 / 1,518 px on `love`

One section, one chrome per shelf, since #109/#116/#126.

| # | Item | Shape | Now on `love` | Growth | Controls | Proposed |
|---|---|---|---:|---:|---|---|
| 24 | Films shelf | 2:3 posters | 360 / 384 px, 12 items | *Load more* adds 12 | rail, About, Load more | unchanged |
| 25 | Artworks shelf | square, credit when carried | 376 / 400 px, 4 items | live results then the saved catalog | same | unchanged |
| 26 | Images shelf | square, **credit required and unclamped** | 372 / 412 px, 12 items | search-only shelves are capped at one page and demoted last (#126 D1) | same | unchanged. The credit is a licence condition and is not touched |
| 27 | Texts shelf | title, author, year; wider column, no image slot | 228 / 280 px, 21 items | Open Library + PoetryDB | same | **quote-first: the attested line leads, in the display face, then the work. `match_details.lines[0].text` already carries it — no new field, no provider change** |
| 28 | Shelf byline | contributing sources, tier then slug | one line | 4 sources on `war` | — | unchanged |
| 29 | *About these results* | one per shelf, a section per source, a sentence per item | closed | one line per item on the rail | disclosure | unchanged |
| 30 | *Load more* | one per shelf, advances every source | — | 24-item cap then the browse page is L5, not yet built | button | unchanged |
| 31 | Loading / deferred / failed | `role="status"` paragraphs | — | one per provider | — | unchanged |
| 32 | Empty shelf | heading + *No matching film for this term yet.* | 60 / 64 px on `logomachy` | one per absent type | — | **absent. An honest empty is nothing, not a sentence about nothing** |
| 33 | GIFs (`#giphy-…`) | **its own component, its own chrome, 400 px below the block; a row of stills that never move** | 328 / 332 px | browser-only, never persisted | Play per card, Load more | inside the culture block with the shared chrome; motion resolved in [`gifs.html`](../sketches/word-page/gifs.html) |

### After the block

| # | Item | Shape | Now on `love` | Growth | Controls | Proposed |
|---|---|---|---:|---:|---|---|
| 34 | Related words (`#related-*`) | one section per part of speech | 312 / 600 px | chips capped at 12 per row, `+N` for the rest | `+N` | unchanged in A and B; in C it moves into the rail |
| 35 | The thing (`#thing`) | concept card: image, description, Wikipedia/Wikidata, kinds, may-also-refer-to | 341 / 429 px, **below the fold by 13 screens** | one | ⓘ, links | unchanged in A and B; in C it follows the culture block |
| 36 | Provenance drawer | fixed panel, driven by `?provenance=` | outside `Layouts.app` on purpose | one at a time | ⓘ links, URL | unchanged |
| 37 | Demo evidence wall | conditional | `?demo=1` only | — | — | unchanged |
| 38 | Footer | source list, licences | 556 / 780 px | grows with sources | links | unchanged |

### States that are a page rather than an item

| # | State | Where | Covered by a mockup? |
|---|---|---|---|
| 39 | Bare index row (`#bare-row`) | a word in the index nothing has been absorbed for — 1.3 million of them | no, and it does not need one: a headword, a paragraph and two links, already under a screen |
| 40 | No such word (`#no-such-word`) + *did you mean* | `/define/zzzz` | no; the trigram's five suggestions are already bounded |
| 41 | Ambiguous slug | `/define/love` itself | yes — item 5, and `love` carries it |

## What the inventory changes about the plan

1. **Every uncapped thing on this page is prose or metadata, and both are
   `WordPage`'s to bound.** Glosses, chips and chains already have caps and
   have held. Entries, forms and etymologies have none.
2. **Two caps are already there and say nothing.** Pronunciations are cut from
   nine spellings to three, and the tags are built and dropped. A silent cap is
   worse than no cap: the reader cannot tell the word has one accent from the
   fact that the page shows one.
3. **Bounding length is not bounding quantity.** `set`'s Johnson verb card is
   two entries. WordNet's `love` is six synsets. A rule that only shortens an
   item lets a source with many items spend the whole page.
4. **`love` is the wrong worst case to design against.** It is 13.8 screens;
   `set` is 44.6. Any budget that is met on `love` should be re-measured on
   `set` before it is called a budget.
5. **The culture block is now the second-largest section and the only one with
   pictures in it.** Four shelves and 49 items sit under nine screens of prose,
   and a fifth shelf of GIFs sits 400 px below them in a chrome of its own.
