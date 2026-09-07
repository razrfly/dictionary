# The 375 px pass — scorecard row U4

**Attested 2026-09-07, session U3 of [#71](https://github.com/razrfly/dictionary/issues/71).**

Row **U4** of the [#69](https://github.com/razrfly/dictionary/issues/69) scorecard asks that the
pages hold at 375 px with no horizontal scroll. It is the one row no query can answer — a page
either scrolls sideways on a phone or it does not, and the only honest instrument is a viewport
and a pair of eyes. So it is graded the way **E3** is: a dated attestation with checked-in
evidence, and `Health.Score` fails the row if any screenshot below goes missing. An attestation
nobody can check is a claim, not a measurement.

## What was measured

For every page in the table, at a **375 × 812** viewport at device scale 2, against the full
development database (1,541,669 lexemes, 344,635 records), with **every `<details>` on the page
forced open** so no disclosure could hide an overflow:

```js
document.documentElement.scrollWidth - document.documentElement.clientWidth === 0
```

All twelve returned **0**.

Elements still extending past the viewport edge are inside their own `overflow-x-auto` container
and were checked by hand: the drawer's raw-JSON `<pre>`, and `/health`'s scorecard table. That is
the rule the pages are built to — wide content scrolls inside itself, the page body never does —
not an exception to it.

| Page | Screenshot |
|---|---|
| home | [`375-home.jpg`](375-home.jpg) |
| the word page (`/define/oyster`) | [`375-word.jpg`](375-word.jpg) |
| its relation groups | [`375-word-relations.jpg`](375-word-relations.jpg) |
| its thing panel (`/define/cat`) | [`375-word-thing.jpg`](375-word-thing.jpg) |
| the provenance drawer, a full-width sheet | [`375-word-drawer.jpg`](375-word-drawer.jpg) |
| fake-data mode (`?demo=1`) | [`375-word-demo.jpg`](375-word-demo.jpg) |
| the evidence wall, one column | [`375-evidence-wall.jpg`](375-evidence-wall.jpg) |
| browse (`/s/animals`) | [`375-browse.jpg`](375-browse.jpg) |
| one source (`/sources/johnson`) | [`375-source.jpg`](375-source.jpg) |
| imports (`/admin/imports`) | [`375-imports.jpg`](375-imports.jpg) |
| health (`/health`) | [`375-health.jpg`](375-health.jpg) |
| the theme check (`/kit`) | [`375-kit.jpg`](375-kit.jpg) |

## Reproducing it

Headless Chrome over CDP, because the viewport has to be exact and page zoom in a real window is
not. With the app running on `localhost:4007`:

```bash
"/Applications/Google Chrome.app/Contents/MacOS/Google Chrome" --headless=new --disable-gpu \
  --remote-debugging-port=9333 --user-data-dir=/tmp/cdp-profile --hide-scrollbars &
```

Then, per page: `Emulation.setDeviceMetricsOverride` with `width: 375, height: 812,
deviceScaleFactor: 2, mobile: true`, navigate, force every `<details>` open, evaluate the
expression above, and `Page.captureScreenshot`. `--window-size` alone is not enough — it sets the
window, not the layout viewport, and `--dump-dom` returns nothing in Chrome 152.
