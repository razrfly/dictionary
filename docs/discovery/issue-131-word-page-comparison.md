# Three word pages, measured

Phase 1 of [#131](https://github.com/razrfly/dictionary/issues/131).
The inventory is
[`issue-131-word-page-inventory.md`](issue-131-word-page-inventory.md); the
sketches open at
[`../sketches/word-page/index.html`](../sketches/word-page/index.html).

Chrome, `document.documentElement.scrollHeight` and
`getBoundingClientRect()`, every `<details>` closed, 1280 × 900 and 375 × 812,
2026-09-20. Screenshots in this directory are named
`issue-131-phase1-<page>-<width>-<theme>-2026-09-20.jpg`.

## The two words

**`love` — heavy, and #111's own measurement.** 9 source cards, 5 parts of
speech, 2 origins, a 4,727-character Johnson entry, WordNet's 6 synsets,
Wiktionary's 19 noun senses, Wikipedia's 2,455-character summary, 4 live
shelves carrying 49 items, 8 GIFs, related words in two parts of speech, a
thing panel, **and an ambiguous slug** — `love`, `Love` and `LoVe` are three
lemmas under one slug, so the page also carries the disambiguation notice.

**`nepotism` — light, and chosen after inspecting the corpus rather than
assumed.** 1 part of speech, 1 origin, 1 form, 4 source cards, and the two
shortest authored entries in the pair: Johnson at 292 characters and Bierce at
**64**. No Wikipedia card, no Artworks shelf, no thing panel, no trail, no
disambiguation. Its Images shelf is the search-only case #126 D1 was written
against. It is the word that tests *keep short content whole*: if a fold
touches a 64-character Bierce entry, the fold is wrong.

Between them they miss five things, so those are shown in
[`hard-cases.html`](../sketches/word-page/hard-cases.html) with the real word
each belongs to: `love`'s 12 pronunciation rows, `little`'s 66 forms, `set`'s
5 origins and its 39,955-character Johnson card, and `logomachy`'s empty Films
shelf. Nothing was invented.

## What all three do the same

The rules are identical in A, B and C, so the comparison measures placement,
grouping and density rather than who folds harder.

| Rule | Value | Why that value |
|---|---|---|
| Prose entry kept whole | ≤ 600 characters | Bierce on `love` is 428 and Johnson on `nepotism` 292. A fold that reaches either is a fold aimed at the page's reason to exist |
| Prose preview | ~360 characters, to a block boundary | ≈ 4 lines at 1280 against a 68ch column, ≈ 8 at 375. A paragraph longer than the budget splits at a sentence end, so Wikipedia's single paragraph is not an exemption |
| Entries previewed per card | 1, the rest counted in one card-level control | `set`'s Johnson verb card is 2 entries and 39,955 characters |
| Sense groups previewed per card | 3, the rest counted in one control | WordNet gives `love` 6 synsets, each with a relation row and a broader chain |
| Glosses per group | 3, unchanged | already capped, already holds |
| Chips per relation row | 12, unchanged | already capped; `love`'s family row hides 269 |
| Pronunciations | 3 inline **with their tags**, `+N variants` to all 12 | the cap exists today and says nothing |
| Forms | 8 inline, `+N more` | `little` has 66 |
| Origin | first sentence, the rest in a disclosure naming its length | `dog` 1,615 characters, `set` five of them |
| Shelf | one row, 12 items, one About, one *Load more* | #126, unchanged |
| Texts shelf | **quote-first** — the attested line leads | `match_details.lines[0].text` already holds it |
| GIFs | inside the culture block, shared chrome, motion on intent | #111 L6 and the [GIF review](../sketches/word-page/gifs.html) |
| Empty shelf | absent, not a sentence about absence | |
| Section nav | one scrolling line, sticky under the navbar | #111 L8 |

**Prose is split, never duplicated.** The preview is the opening of the
original and the disclosure holds the remainder, so no word is rewritten,
reordered, dropped or printed twice. Expanded text is not under the budget:
fully opened, all three pages are the page we have today.

| Every disclosure opened, `love` | 1280 | 375 |
|---|---:|---:|
| A | 12,332 px · 13.7 screens | 18,796 px · 23.1 |
| B | 12,519 px · 13.9 | 18,839 px · 23.2 |
| C | 9,993 px · 11.1 | 16,203 px · 20.0 |
| today's page, for comparison | 12,383 px · 13.8 | 18,563 px · 22.9 |

C is shorter opened only because its culture block still shows one rail.

## The three

**A · Same order, folded.** Today's section order with nothing moved: notices,
headword, nine cards in tier order, the culture block, related words, the
thing. The control in this comparison — it answers what folding alone buys.

**B · The world in the middle.** #111 L7. *Written by someone* — Johnson and
Bierce, as cards — then the culture block, then *Reference sources*: WordNet,
Wiktionary and Wikipedia as one row each, carrying the source's own first
gloss and its sense count, opening in place to everything they hold today.

**C · The word in a rail.** Facts about the word — sound, forms, origin, the
source index, related words — in a sticky column of their own; every source,
authored or not, is one row; and the culture block is one rail with counted
chips (*Films 12 · Artworks 4 · Texts 21 · Images 12 · GIFs 8*) instead of five
stacked rails. On a phone the rail linearises above the content.

## Measurements

### Closed page

| | `love` 1280 | screens | `love` 375 | screens | `nepotism` 1280 | `nepotism` 375 |
|---|---:|---:|---:|---:|---:|---:|
| **today** | 12,383 | 13.8 | 18,563 | 22.9 | 4,024 · 4.5 | 5,448 · 6.7 |
| **A** | 7,604 | 8.4 | 11,100 | 13.7 | 3,898 · 4.3 | 5,338 · 6.6 |
| **B** | 6,327 | 7.0 | 8,735 | 10.8 | 3,933 · 4.4 | 5,229 · 6.4 |
| **C** | 4,007 | **4.5** | 6,463 | **8.0** | 2,090 · **2.3** | 3,452 · **4.3** |
| B + C's culture block | 4,847 | 5.4 | 7,035 | 8.7 | — | — |

The last row is measured, on a scratch build of B carrying C's culture block,
not kept as a file. The culture block is the one lever that is independent of
layout, and it is worth 1,700 px on a phone by itself.

### What is in the first viewport, and where the rest starts

| `love` | first definition | first image | | first definition | first image |
|---|---:|---:|---|---:|---:|
| | **1280** | | | **375** | |
| today | 1,064 | 9,005 · screen **10** | | 1,556 | 14,317 · screen **18** |
| A | 886 | 4,367 · screen 5 | | 1,070 | 7,019 · screen 9 |
| B | 886 | 2,315 · screen **3** | | 1,094 | 3,443 · screen **5** |
| C | 434 | 2,440 · screen 3 | | 1,116 | 4,106 · screen 6 |

On a desktop, A and B open on the headword and Johnson's first sense; C opens
on the headword, the source index and the first three sources. On a phone all
three open on the headword alone — 375 × 812 minus 124 px of chrome is not
enough for a headword *and* a definition, whatever the layout.

### Section by section, `love` at 375

| | today | A | B | C |
|---|---:|---:|---:|---:|
| headword / rail | 1,069 | 501 | 501 | 522 |
| section nav | — | 49 | 49 | 49 |
| all source cards | 12,484 | 5,540 | 3,057 | 2,748 |
| culture block | 1,518 + 332 GIFs | 2,278 | 2,278 | 578 |
| related words | 600 | 600 | 600 | 600 |
| the thing | 429 | 472 | 472 | 472 |
| footer | 1,264 | 780 | 780 | 780 |

Two things to notice. **The nine cards fall from 12,484 px to 3,057 px in B
and 2,748 px in C** — that is where the page's height lived. And **the culture
block gets bigger in A and B**, from 1,850 px to 2,278 px: giving the GIFs
shelf the same chrome as the other four costs about 300 px, which is the price
of #111 L6 and is worth naming rather than hiding.

### Behaviour

| | A | B | C |
|---|---|---|---|
| a missing section | nothing renders; `nepotism` shows 4 cards, 4 shelves, no thing panel | same | same, and its chip and its row are absent too |
| long content | preview + disclosure naming its length | same | same |
| keyboard | every control is a `<summary>` or a link in document order; the nav is anchors | same | the rail precedes the content in the tab order on a phone — the one real cost of C |
| reduced motion | GIFs never swap; the *Play* control stays | same | same |
| dark mode | shot at both widths | same | same |
| horizontal overflow at 375 | none | none | none |
| JavaScript | none — every control is `<details>` or an anchor | same | the culture chips are radio inputs in the sketch; the app would drive them the way it drives everything else |

## Trade-offs

**A** is the cheapest to build and the least useful. It halves the page and
still puts the first image on screen 9 of a phone, because the only thing
between the reader and it is nine definitions that are shorter but still all
there. It buys the compact system without answering what the compact system
was for.

**B** is the page the project is about. Johnson and Bierce arrive as cards —
the authored voice, whole where it is short and previewed where it is not —
and the world arrives right behind them, on screen 3 of a desktop and screen 5
of a phone. The reference sources, the part every other dictionary already
has, become nine lines that open into everything they hold. The risk is real
and worth stating: collapsing WordNet and Wiktionary to a row each is a
judgement that their senses are reference rather than reading, and a reader
who came for *the nineteen senses of love* has one more click than today.

**C** is the most compact by a distance and the most changed. The rail is
genuinely better on a desktop — the word's facts stop competing with the
word's definitions, and the source index makes nine sources navigable for the
first time. On a phone the rail linearises into a preamble, which is why C's
first definition is *lower* than A's and B's despite the page being shorter.
The tabbed culture block is the single best height lever on the page and the
single biggest thing put behind a control: four of five shelves are one tap
away rather than one scroll away. The chips name and count them, so nothing is
undiscoverable — but a reader who would have scrolled past an artwork now has
to ask for it.

## Against #111's budget

#111 L1 asks for ≤ 4 desktop and ≤ 7 phone screens on `love`, every
disclosure closed.

| | desktop | phone |
|---|---:|---:|
| target | ≤ 4.0 | ≤ 7.0 |
| A | 8.4 | 13.7 |
| B | 7.0 | 10.8 |
| B + C's culture block | 5.4 | 8.7 |
| C | **4.5** | **8.0** |

**No alternative reaches it, and the gap is not in the definitions.** In C the
nine sources cost 2,748 px of a 6,463 px phone page. The other 3,715 px are
the rail (522), the culture block (578), related words (600), the thing (472),
the footer (780) and the gaps between them. Reaching 7.0 phone screens from C
means finding 778 px in that list, and the honest candidates are the footer —
780 px on a phone for a licence paragraph and six source links — and the
related-words block, whose `love` verb row is 532 px of chips.

So the target is reachable on `love`, but by trimming the page's furniture
rather than its content. That is the owner's call, and it is the one number in
this document that is a decision rather than a measurement.

One further measurement for scale: **`/define/set` is 44.6 desktop and 76.0
phone screens today** — nine parts of speech, five origins and a Johnson verb
card holding 39,955 characters. Whatever budget is set on `love` should be
re-measured there before it is called a budget.

## Recommendation

**B, with C's culture block.** Measured: 5.4 desktop and 8.7 phone screens on
`love`, 4.4 / 6.4 on `nepotism`, first image on screen 3 of a desktop and
screen 5 of a phone.

The reasoning, in the order it matters:

1. **B's order is the one this project has an argument for.** #66's descent
   through the tiers, #111 L7, and the plain fact that Johnson and Bierce are
   why the page is not Wiktionary. A reader meets the authored voice, then the
   world, then the reference.
2. **C's rail is the better desktop and the worse phone**, and the phone is
   where the page is 22.9 screens. A layout whose main idea evaporates at
   375 px should not be the layout.
3. **C's culture block is separable from C's layout**, costs nothing to move
   into B, and is worth 1,700 px on a phone — more than any other single
   decision here.
4. **C's source index belongs in B anyway**, as the *Defined here by N
   sources* line rather than as a rail: a list of the nine sources, each an
   anchor. That is one line of B's headword block doing more work, and it does
   not need a column.

For the GIFs shelf: **version B, motion on intent**, with version A's shared
chrome around it — the two combine, and A on its own leaves the complaint that
started this unanswered (a row of stills is a broken GIF shelf). **Playback is
hover, focus or tap, not in-viewport.** In-viewport playback fetches twelve
animated renditions per page view against a key that allows a hundred requests
an hour for everyone, puts twelve looping animations beside the reading
matter, and leaves a reduced-motion reader with a shelf that never works
rather than one they can operate. The reasoning is laid out beside the three
versions in [`gifs.html`](../sketches/word-page/gifs.html).

## What the rest of the field does

Nine reference sites were measured with this same harness, and the published
research read alongside them:
[`issue-131-how-others-do-it.md`](issue-131-how-others-do-it.md). It changes
three things in this document — the mobile recommendation is withdrawn, the
prose column should be wider rather than narrower, and the tier ordering is
the highest-stakes open question rather than a settled default. Read it before
acting on the recommendation below.

## Selected: C, and five ways to enclose it

The owner chose **C · The word in a rail** on 2026-09-20, on the strength of
its encapsulation — "different parts, different elements in different ways".
Five variations follow, at
[`../sketches/word-page/rails.html`](../sketches/word-page/rails.html).

Everything that is not enclosure is identical across the five: the rail's
contents, one row per source, the tabbed culture block, the compact rules, the
content itself. What varies is how a region is held, so the choice is a
grammar rather than a layout. They are laid out along the surfaces ladder —
whitespace, dividers, background, wells, cards — lightest first.

| | Enclosure | `love` 1280 | `love` 375 | What it is for |
|---|---|---:|---:|---|
| **R1 · Dividers** | hairlines only | 3,984 px · 4.4 | 6,412 px · 7.9 | the lightest thing that works, and the shortest page |
| **R2 · Panels** | a card per region | 4,061 px · 4.5 | 7,220 px · 8.9 | the strongest separation, and the most furniture |
| **R3 · Tiers** | a different rung per kind | 4,098 px · 4.6 | 6,834 px · 8.4 | the enclosure says what kind of thing it holds |
| **R4 · Bands** | background alone | 4,371 px · 4.9 | 6,391 px · 7.9 | no borders anywhere; the edge between two backgrounds is the separation |
| **R5 · Slabs** | wells with pinned headers | 4,524 px · 5.0 | 6,883 px · 8.5 | the page always says which region you are in, so there is no jump bar |

Three things the measurements say. **Enclosure is not free**: the heaviest
costs 540 px of desktop over the lightest, all of it padding. **It costs most
on a phone**, where R2's panels add 808 px over R1 — a panel's gutter is spent
twice at 375 px, once on each side. And **R4's separation is free**: 21 px
under the undivided baseline on a phone, because a background band needs no
padding to be visible.

The light word says the same thing more quietly: on `nepotism` the five run
2,090 / 2,188 / 2,214 / 2,254 / 2,391 px on a desktop and 3,452 / 3,721 /
3,580 / 3,480 / 3,624 px on a phone, in the same order.

R3 is the odd one out by design. The other four put one rung under everything;
R3 puts a gilded slab under an authored entry, a plain row under a reference
source, and a well under everything that was found rather than written. That
is #66's descent through the tiers made structural — a reader learns the
grammar once and then never has to read a byline to know what they are looking
at — and it is the only one of the five that carries an argument rather than a
taste.

### What the owner is being asked to settle

1. **The page order** — B's (authored · world · reference), or A's (everything,
   then the world).
2. **The culture block** — five stacked rails, or one rail with counted chips.
3. **The reference sources** — cards, or one row each opening in place.
4. **The budget** — accept 5.4 / 8.7 on `love`, or take the footer and the
   related-words block down to reach 4 / 7. Expanded text stays uncapped
   either way.
5. **The GIFs shelf** — A, B, C or a combination, and in-viewport versus
   on-intent playback.
6. **The source index** — in the headword block (recommended), or in a rail.

Phase 2 turns whichever of these the owner picks into acceptance criteria and
builds them in the slices #131 already lists, definitions first.
