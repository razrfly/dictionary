# Word-page sketches · #131 Phase 1

Static HTML mockups of three whole-page layouts for `/define/:slug`, on the
content the real pages held on 2026-09-20. Open
[`index.html`](index.html) and start there; add `?theme=dark` to any file to
see it dark.

**Nothing here is loaded, compiled or served by the application.** These files
are read by a browser and by the screenshots under
[`../../discovery/`](../../discovery/), and by nothing else.

## What is in here

| File | What it is |
|---|---|
| `index.html` | the contact sheet |
| `final-{love,nepotism}.html` | **the selected page** — wide rail that scrolls away, opening on a reference source |
| `rails.html` | the contact sheet for the five rail variations |
| `alt-{a,b,c}-{love,nepotism}.html` | three layouts × two words, every `<details>` closed |
| `alt-{a,b,c}-love-open.html` | the same pages with the disclosures opened |
| `rail-r{1..5}-{love,nepotism}.html` | the selected direction (C) held five different ways — dividers, panels, tiers, bands, slabs |
| `rail-r{1..5}-love-open.html` | the same five with the disclosures opened |
| `hard-cases.html` | the components neither word exercises, each with the real word it comes from |
| `gifs.html` | #111's three GIF-shelf versions, and the playback question answered |
| `entry.html` | **#156 Phase 0 — the contact sheet for the entry band**: four variants on `love`, a rotation page, three honest cases |
| `entry-v{1,2,3,4}-*-love.html` | the epigraph, the plaque, the mosaic, the broadsheet — one voice and a few well-chosen things above the Definitions, the cards untouched |
| `entry-rotation-love.html` | V1 on three consecutive days: same word, same rules, a different pick, every tier kept |
| `entry-words-{nepotism,rizz,topographagnosia}.html` | a lead-only band, the inverted band in its loading state, and no band at all |
| `entry-build.py` | regenerates every `entry-*.html` and `entry.html`: `python3 docs/sketches/word-page/entry-build.py docs/sketches/word-page`, then rebuild the stylesheet |
| `tailwind.css` | the stylesheet input |
| `sketch.css` | the built stylesheet — generated, committed so the sketches open from disk |
| `build.sh` | rebuilds `sketch.css` |

## Why a stylesheet of its own

Tailwind emits only the classes it finds in the sources it is told to scan, and
`assets/css/app.css` scans `lib/devils_dictionary_web` and the content-type
table. A sketch that used one class the app does not already use would render
unstyled against the app's own build.

So `tailwind.css` imports `assets/css/app.css` — the same `@theme` tokens, the
same heroicons plugin, the same `data-theme` dark variant — and adds this
directory as one more source. The sketches are the app's visual language
rearranged; nothing here redefines a token or introduces a second design
system. `sketch.css` is committed for the same reason the screenshots are: a
reviewer opens a file and sees the thing.

```sh
./docs/sketches/word-page/build.sh
```

From a worktree without its own `_build`, point the main checkout's binary at
this input instead: `NODE_PATH=<main>/deps:<main>/_build/dev
<main>/_build/tailwind-* --input=docs/sketches/word-page/tailwind.css
--output=docs/sketches/word-page/sketch.css --minify`, with `deps` symlinked
to the main checkout's so the heroicons plugin resolves.

## What the content is

Real, and captured once so the three alternatives are compared on identical
material. The `entry-*` pages (#156, 2026-09-22) were captured the same way
from `discovery_results` on `devils_dictionary_v2`, the Bierce source, the
Commons files the app links, and one live Urban Dictionary call; a GIF whose
title could not be read back is labelled *A GIF for “love”* rather than given
one. Headwords, entries, senses, relations and every shelf item were read
off the live pages at `localhost:4007` against `devils_dictionary_v2`; the
attested lines on the quote-first text cards come from
`discovery_results.match_details`, which already holds them. Thumbnails and
posters are hotlinked from the providers' hosts, exactly as the app hotlinks
them, so an offline reviewer will see empty frames and nothing else will
change.

The hard cases are real too, and labelled with the word each one belongs to:
`love`'s twelve pronunciation rows, `little`'s sixty-six forms, `set`'s five
origins and its 39,955-character Johnson card, `logomachy`'s empty Films shelf.
Nothing was invented and nothing was attributed to a word that does not have
it.
