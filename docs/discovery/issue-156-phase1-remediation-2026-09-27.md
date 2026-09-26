# #156 Phase 1 remediation evidence — 27 September 2026

Measurements and keyboard order for PR #202 after the audit in
[#156 comment 5849658094](https://github.com/razrfly/dictionary/issues/156#issuecomment-5849658094).
Screenshots are the `issue-156-phase1-remediation-*-2026-09-27.png` files
beside this one.

**Conditions.** Worktree code served on port 4057 by `mix run --no-start`
with Oban `queues: false, plugins: false` (it executes no jobs), against the
shared dev database `devils_dictionary_v2`, read only. Playwright Chromium:
1280×900 at DPR 1, and 375×812 at DPR 2 with mobile and touch emulation,
`prefers-color-scheme` light and dark. Every page is
`/define/<word>?opening=fixture` unless marked *without opening*. "Before"
is the audited head `84d5ce5`, captured by the same script on 26 September
against the same database; "after" is this remediation. Section captures hide
the sticky site header, which an element screenshot would otherwise stitch
into the image.

## Compactness

Section height and the Definitions slab's top, in CSS pixels.

| Word | Width | Theme | Section before | Section after | Definitions before | Definitions after | Definitions without opening | Horizontal overflow |
|---|---|---|---|---|---|---|---|---|
| love | 1280 | light | 1489 | 975 | 1702 | 1188 | 197 | none |
| love | 1280 | dark | 1489 | 975 | 1702 | 1188 | 197 | none |
| love | 375 | light | 2851 | 1831 | 3967 | 2931 | 1068 | none |
| love | 375 | dark | 2851 | 1831 | 3967 | 2931 | 1068 | none |
| oats | 1280 | light | 595 | 459 | 808 | 672 | 197 | none |
| oats | 1280 | dark | 595 | 459 | 808 | 672 | 197 | none |
| oats | 375 | light | 923 | 751 | 1537 | 1349 | 566 | none |
| oats | 375 | dark | 923 | 751 | 1537 | 1349 | 566 | none |
| nepotism | 1280 | light | 447 | 375 | 660 | 588 | 197 | none |
| nepotism | 1280 | dark | 447 | 375 | 660 | 588 | 197 | none |
| nepotism | 375 | light | 599 | 591 | 1506 | 1482 | 859 | none |
| nepotism | 375 | dark | 599 | 591 | 1506 | 1482 | 859 | none |
| topographagnosia | 1280 | light | — | — | 197 | 197 | 197 | none |
| topographagnosia | 1280 | dark | — | — | 197 | 197 | 197 | none |
| topographagnosia | 375 | light | — | — | 526 | 526 | 526 | none |
| topographagnosia | 375 | dark | — | — | 526 | 526 | 526 | none |

What moved: each item's meaning, editorial preference, source record,
AI-generated note (with its author and review state) and non-required
locators went into one named disclosure per item (*Why this leads*, *Why this
is here*). What stayed on the page: the verbatim lead and quotations, their
register (*Satire*, *Sourced definition*, *Sourced quotation*), creator and
work, the continuation to the whole entry, every credit a source's terms
require, and the fixture's *AI-selected, not reviewed by a person* label. The
desktop artwork frame became square (the painting is still shown whole, with
`object-contain`).

## Keyboard and reading order

Real key presses, 45 Tab presses from the top of the page and then 45
Shift+Tab presses, recording which region holds focus.

| Width | Tab | Shift+Tab | Focus stops in headword / opening |
|---|---|---|---|
| 1280 | other → headword → opening → rail → definitions | definitions → rail → opening → headword → other | 3 / 14 |
| 375 | other → headword → opening → rail → definitions | definitions → rail → opening → headword → other | 3 / 14 |

The document order is the reading order at both widths: headword, opening,
the rest of the rail, definitions, the way out. There is no CSS `order`, no
`display: contents` and no duplicated markup; each id appears once. Keyboard
activation was also checked in the in-app browser at 375: Enter on
*Why this is here* opens it with a 2 px focus ring; Enter on *Read the whole
entry* opens `#card-bierce`, closes WordNet (the slab's own `name="sources"`
accordion) and scrolls to the card.

On a desktop the way-out block (related words and the source stack) follows
the Definitions in the document, so it can start no higher than they do.
Without an opening it starts 69 px below the end of the rail. With one it
starts 317 px below on *love* (248 px lower than without), 162 px on *oats*
(93 px lower) and 69 px on *nepotism*, whose opening is shorter than its
rail, so unchanged. The rail itself always sits directly under the headword,
and the Definitions directly under the opening.
