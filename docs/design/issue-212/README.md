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

> The Build 2 captures above were taken on `/define/coward`, before #219 replaced that route; the same page is now `/on/coward`.

# #212 Build 3: an exemplar in the curated opening

These are captures of `/on/coward?opening=fixture`, the development gate #202 added. They came from a preview on port 4057 that ran from the Build 3 branch with `DD_NO_OBAN=1`, so it executed no jobs.

The preview read a scratch database, `devils_dictionary_test_212shots` on 5434. It was migrated from empty and seeded only with fixtures:

- *coward* with WordNet's sense, under the source identity the committed `coward` composition names;
- **Pat Fixture** (`Q999999212`), nominated through `Contributions.propose/6` by Account #2 and accepted by Account #1;
- **Fixture Adverse Person** (`Q999999213`), nominated and never reviewed;
- **Fixture Pending Work** (`Q999999214`), nominated and never reviewed. Its examples card is public under #190's person-only gate; the opening is not.

`devils_dictionary_v2` was not read for the captures, and was not written.

## What they show

- **Highlight 1** is Pat Fixture: "Example · person", the name, and "cited as an example of" the gloss.
- **Its "Why this is here"** holds the meaning, the reason given, and the six stages:
  - Source, Nominated, Model and Reviewed read exactly as on the examples card further down the page;
  - Shown here and Opening say a development fixture chose it and that it is not published.
- **Highlights 2 and 3**, the two nominations nobody accepted, are not there. *How this was chosen* lists each as "it is not an example a reviewer has accepted", which names no one.
  - The adverse person's name appears nowhere in the page's HTML.
  - The pending work's card is public further down the page, but nothing of it is in `#opening`.

## Method

- Playwright Chromium, with `prefers-color-scheme` light and dark, and the sticky header made static:
  - 1280 × 900 at DPR 1;
  - 375 × 812 at DPR 2, with mobile and touch emulation.
- Each capture is a full-page clip of `#opening`. The phases:
  - **closed**: every disclosure closed, the reader's default;
  - **open**: the highlight's "Why this is here" and "How this was chosen" both open.
- `document.documentElement.scrollWidth` equals the viewport width on every capture.

## Size

| Viewport | Page without the fixture → with it, closed | `#opening`, closed → open | "Why this is here" summary |
|---|---|---|---|
| 1280 × 900 | 3,181 → 3,460 px (+279) | 263 → 875 px | 28 px |
| 375 × 812 | 4,848 → 5,279 px (+431) | 399 → 1,573 px | **44 px** |

Light and dark measure the same. The opening renders only behind the development gate, so no public page pays for it.

The 44 px summary on a phone is new in this build. It applies to every disclosure of the opening, the lead's included: #202's shared summary was a 28 px target, while the examples card's disclosure was already 44 px. Its desktop size is unchanged.

| File | What |
|---|---|
| `issue-212-build3-coward-{1280,375}-{light,dark}-closed.png` | the opening with the exemplar tile, disclosures closed |
| `issue-212-build3-coward-{1280,375}-{light,dark}-open.png` | the same, with "Why this is here" and "How this was chosen" open |
