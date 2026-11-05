# Curated-page sketches · #309 D2

Static HTML mockups of the curated page, `/on/:slug`, as its own article:
phone first, one document order on every screen size. Open
[`index.html`](index.html); add `?theme=dark` to any file for the dark page.
Review each at 375 px before 1280 px.

**Nothing here is loaded, compiled or served by the application.** These files
are read by a browser and by the screenshots under
[`../../discovery/`](../../discovery/) (`issue-309-d2-*`), and by nothing else.

| File | What it is |
|---|---|
| `nepotism.html` | **the full entry**: nepotism version 5 (record 39) with its nine items: the lead, In the news, Definitions, Quotations, In culture (image, film, music, book), the editor, related words, about this version |
| `truth.html` | the longest case in the data: truth version 5 (record 45), ten items, In culture holding five works and a news item |
| `love.html` | love version 9 (record 55), the version the live page shows today |
| `bestiality-abstained.html` | the abstained state: assessed and never published (composition 10) |
| `greed-withheld.html` | withheld as a whole: greed version 4 (record 40), the state of four of the nine published pages today |
| `content.json` | the content, captured once by `capture.exs` |
| `capture.exs` | reads a private copy of v2 and writes `content.json` |
| `build.py` | writes the HTML pages from `content.json` |
| `tailwind.css` | the stylesheet input: the app's own `assets/css/app.css` plus this directory |
| `sketch.css` | the built stylesheet, committed so the sketches open from disk |
| `build.sh` | runs `build.py`, then rebuilds `sketch.css` |

```sh
./docs/sketches/curated-page/build.sh
```

## What the words are

Every word on a sketch is one of three things:

- a fixed label from the D1 table (#309, c6637566629);
- a record the site holds itself (Bierce, Johnson, WordNet, Wiktionary), quoted as the page quotes it, with the credits its terms require;
- the editor's stored reason, as stored, with the mark *cut at 100 characters* where a reason stops at the cap mid-sentence.

Anything else is a **[bracketed] placeholder.** A shelf item (an image, film,
album, book, poem, quotation or headline found by discovery) is held for seven
days under its provider's terms, so its title, creator, image and credit text
are not copied into the repository. The sketch keeps the provider's name, the
dates, and the editor's reason. The stored abstain reason is the model's
text, which the built page shows; the sketch keeps only its length and its
attempt id.

## What the content is

Captured on 4 November 2026 by `capture.exs`, from a private copy of
`devils_dictionary_v2` taken read-only at 17:27:48 UTC, never from v2 itself.
A published version is mapped by the page's own reader
(`PublishedReader.arrangement/3`), including the versions that are withheld as
a whole today (configuration 1 moved to version 9 on 3 November at 15:18 UTC),
so a sketch shows what a version holds, and the state it is in now is drawn
separately.
