# #212 Build 2: "Why this example is here"

Captures of `/define/coward` and the person page, from a preview on port 4057. The preview ran with `DD_NO_OBAN=1`, so it executed no jobs, against a scratch database, `devils_dictionary_ex212`. That database was migrated from empty and seeded only with fixtures:
- a fictional person, "Pat Fixture", nominated through `Contributions.propose/6`, accepted, then composed and published in a lexeme composition for *coward*;
- a legacy claim with no actor, "A Fixture Etching";
- evidence URLs on `example.test`.

The shared dev database was not touched.

## Method

- Playwright Chromium (1.58).
- Two sizes: 1280 × 900 at DPR 1, and 375 × 812 at DPR 2 with mobile and touch emulation.
- `prefers-color-scheme` set to light and to dark.
- Section captures of `#examples` and `#entity-cited-as`, with the sticky header made static.
- On every capture, `document.documentElement.scrollWidth` equals the viewport width.

"Before" is the same page and database served by PR #218's code (`4839c6f`), which has no disclosure. "After" is this branch. The "why-open" captures have every "Why this example is here" disclosure opened.

## Page height (#111's method: every disclosure closed)

The page has two exemplar cards.

| Width | Page before → after | Screens | `#examples` before → after | Per card, closed | Per card, opened |
|---|---|---|---|---|---|
| 1280 × 900 | 3,284 → 3,340 px | 3.65 → 3.71 | 581 → 637 px | +28 px | +240 px more |
| 375 × 812 | 5,063 → 5,159 px | 6.24 → 6.35 | 961 → 1,057 px | +48 px (a 44 px tap target) | +684 px more |

Light and dark measure the same. Opening both disclosures takes the page to 3,772 px at 1280 and 6,359 px at 375.

## Files

| File | What |
|---|---|
| `issue-212-build2-coward-{1280,375}-{light,dark}-before.png` | the section before, from PR #218's code |
| `issue-212-build2-coward-{1280,375}-{light,dark}-why-open.png` | the section after, with both disclosures open |
| `issue-212-build2-person-{1280,375}-light.png` | the person page's *cited as* panel, with the "featured in the opening of…" line |
