# The Wordhoard map

Every layer of the model, from the sources at the bottom to the votes at the top, and where each band stands. Read it upward: each band sits on the one below it.

- [`wordhoard-map.svg`](wordhoard-map.svg) — the diagram, vector (this is what the README embeds)
- [`wordhoard-map.png`](wordhoard-map.png) — the same at 2400 px, for slides and chat
- [`wordhoard-map.pdf`](wordhoard-map.pdf) — the whole page below as a printable document
- [`wordhoard-map.html`](wordhoard-map.html) — the page itself; open it locally for light and dark themes

![The Wordhoard map](wordhoard-map.svg)

**Legend.** Solid boxes with a thick outline exist and are on the word page today. Blue boxes exist in the data and go on the page in the next session (U1b, the thing side). Plain solid boxes are built. Dashed boxes are planned: their tables were sketched, applied, diffed and rolled back in S5 to prove they touch none of the thirteen tables, and nothing is shipped.

## The distinction the whole thing turns on

A **definition** is what a source says about a *word*. An **example** is what the culture attaches to a *thing*, or to a word or a sense when there is no thing. Don Jr. exemplifies nepotism the practice, not the string n-e-p-o-t-i-s-m. That is why the thing side of the word page (U1b) comes before the culture layer, and why the two sides are different tables that meet only through scored links.

Two rules the model enforces rather than promises: nothing appears without a source (a person's example is a row from a crowd-tier source, and it is dressed as one), and the crowd can nominate and vote but never define. The definitions stay with the dictionaries and the dead.

## Nepotism, traced through the bands

As the database holds it on 2026-09-07, and as the plan finishes it.

1. **Sources.** Two aristocrats have the word. Bierce: *"Appointing your grandmother to office for the good of the party."* Johnson has an entry too. WordNet has one sense. Wiktionary has the word in the index but no senses yet, because nepotism is outside both scopes; its senses arrive with the whole-lexicon pass.
2. **Word.** One row: *nepotism · noun*. Its page exists now at `/define/nepotism`.
3. **Definitions.** Bierce's, Johnson's and WordNet's, side by side in tier order. If they contradict each other, the page shows the contradiction; it never picks a winner.
4. **Word to word.** Today: broader words *favoritism* and *discrimination* from WordNet. After the Wiktionary pass: *nepotist*, *nepotistic* as family, *cronyism* as similar, and the antonyms.
5. **Thing.** Nepotism is a thing in Wikidata, a social practice with a Wikipedia article. It is not linked yet, for the same reason: linking runs per scope. The link is one task run away, and it carries a confidence.
6. **Examples.** Someone nominates *Donald Trump Jr.* He is a thing of his own, a person with a Wikidata item, so the example is a link from the thing *nepotism* to the thing *Donald Trump Jr.*, submitted by a user, pending until accepted. Someone else nominates a YouTube clip, a URL example, and a poem, a text example.
7. **Votes.** People and curator bots vote each example up or down. The score orders them, so the personality most people think represents the word rises to the top of the page.

## What was described, and where it lives

| You said | In the model | Status |
|---|---|---|
| A dictionary and an encyclopedia in one | the lexicon (words, senses, entries) and the encyclopedia (things), meeting through scored links | built |
| Definitions sit on top of words | `senses` and `entries` attach to a word by lemma and part of speech | built, on the page |
| A word can have many definitions | many senses per word; *cat* has 25 in Wiktionary and 8 synsets in WordNet | built, on the page |
| Same spelling, different meanings | separate senses under one word, and where they name different things, separate things: cat the animal and cat the Unix command | built; the thing half is next |
| Sources that contradict each other | every definition belongs to its source and sits beside the others; nothing is merged; a thing-level disagreement gets a plaque | built; the plaque is next |
| Conjugations and forms | forms fold into the headword; *oysters* lands on *oyster* with a note; variants are a chip group | built, on the page |
| Synonyms, antonyms, other relations | `lexical_relations`, grouped as similar, opposite, broader, narrower, parts, part of, family, see-also | built, on the page |
| Taxonomy and other hierarchies | `concept_relations`: taxonomy for living things, classes and instances for everything else; the chain, the kinds, the examples of a thing | built in the data; on the page next |
| A person as an example of nepotism | `examples`: a link from a word, sense or thing to another thing, a URL or a text, with a status and a score | planned; tables sketched and proven to fit |
| A poem, art, a YouTube video as an example | the same table: text and URL kinds; media unfurls into the evidence wall | planned (#67) |
| Quotes | a quote layer with provenance scoring, attached to senses and things | planned (#65) |
| People cannot write definitions | `senses` and `entries` require a source row; users and bots are sources of the crowd tier, which owns examples and votes only | a rule of the model |
| People vote on which example fits best | votes of ±1 by a person or a curator bot; the score orders the examples on the page | planned (#17 for the bots) |

What is still open is design, not structure: how a page with a Bierce joke, eight WordNet senses, a taxonomy chain, a top-voted example and a wall of clips stays readable. That is the design pass in #66, after the pages exist.

## Keeping it current

The diagram is hand-drawn SVG (`wordhoard-map.svg`); edit the text and boxes directly, then re-render the PNG and PDF:

```bash
"/Applications/Google Chrome.app/Contents/MacOS/Google Chrome" --headless=new --disable-gpu --hide-scrollbars --force-device-scale-factor=2 --window-size=1200,1060 --screenshot="$PWD/docs/map/wordhoard-map.png" "file://$PWD/docs/map/wordhoard-map.svg"
```

```bash
"/Applications/Google Chrome.app/Contents/MacOS/Google Chrome" --headless=new --disable-gpu --no-pdf-header-footer --print-to-pdf="$PWD/docs/map/wordhoard-map.pdf" "file://$PWD/docs/map/wordhoard-map.html"
```
