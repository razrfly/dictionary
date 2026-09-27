# #212 Build 2: "Why this example is here"

These are captures of `/define/coward` and of the person page's *cited as* panel. They came from a preview on port 4057 that ran with `DD_NO_OBAN=1`, so it executed no jobs.

The preview read a scratch database, `devils_dictionary_ex212`. It was migrated from empty and seeded only with fixtures:

- **Pat Fixture**, a fictional person. The nomination went through `Contributions.propose/6` as Account #2 and was accepted by Account #1. Account #1 then selected it in a lexeme composition for *coward* under the enabled **global default** configuration, and published it.
- **A Fixture Etching**, a legacy claim with no actor.
- Evidence URLs on `example.test`.

The shared dev database was not touched.

## Method

- Playwright Chromium 1.58, at 1280 × 900 (DPR 1) and at 375 × 812 (DPR 2, with mobile and touch emulation).
- `prefers-color-scheme` light and dark.
- Section captures of `#examples` and `#entity-cited-as`, with the sticky header made static.
- On every capture, `document.documentElement.scrollWidth` equals the viewport width.

The phases:

- **before**: the same page and database, served by PR #218's code (`4839c6f`), which has no disclosure.
- **after-closed**: this branch's code, with every disclosure closed, which is the reader's default.
- **why-open**: this branch's code, with both disclosures open.

## Page height (#111's method: every disclosure closed)

`/define/coward` has two exemplar cards.

| Viewport | Page, before → after | Screens | `#examples`, before → after | Per card, closed | Per card, opened (Pat Fixture / Etching) |
|---|---|---|---|---|---|
| 1280 × 900 | 3,284 → 3,340 px | 3.65 → 3.71 | 581 → 637 px | +28 px each | +240 / +192 px more |
| 375 × 812 | 5,063 → 5,159 px | 6.24 → 6.35 | 961 → 1,057 px | +48 px each (a 44 px tap target) | +712 / +544 px more |

With both disclosures open, `#examples` is 1,069 px at 1280 and 2,313 px at 375. Light and dark measure the same at every size.

The person page's *cited as* panel gains the "selected for the opening of coward since … · not yet shown on its page" line:
- at 1280: 145 → 169 px (+24 px, on a page of 1,854 → 1,878 px);
- at 375: 243 → 299 px (+56 px, on a page of 2,332 → 2,388 px).

## Files

| File | What |
|---|---|
| `issue-212-build2-coward-{1280,375}-{light,dark}-before.png` | the section, before (PR #218's code) |
| `issue-212-build2-coward-{1280,375}-{light,dark}-after-closed.png` | the section after, disclosures closed |
| `issue-212-build2-coward-{1280,375}-{light,dark}-why-open.png` | the section after, both disclosures open |
| `issue-212-build2-person-{1280,375}-{light,dark}-{before,after}.png` | the person page's *cited as* panel, before and after |
