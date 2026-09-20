# How everyone else does it

Posted to [#131 as a comment](https://github.com/razrfly/dictionary/issues/131#issuecomment-5751495603),
with wireframes W4–W8 for the revised direction. The Phase 1 summary is the
[comment before it](https://github.com/razrfly/dictionary/issues/131#issuecomment-5751352520).

Nine reference sites, the same word, the same harness that measured our own
pages: Chrome, `document.documentElement.scrollHeight`, 1280 × 900 and
375 × 812, nothing clicked, 2026-09-20. Desktop and mobile user agents were
set honestly, because Wikimedia serves a different page to each and three
sites answer a headless UA with a challenge screen instead of an entry.

This is observed behaviour, not marketing copy. Where a site's own design
team has published its reasoning it is quoted in the second half.

## The measurements

| | desktop | phone | text column | persistent rail | collapsed regions |
|---|---:|---:|---:|---|---:|
| Wikipedia · *Love* | **24.6** | **4.3** | 688 px | 208 px ToC + 196 px tools | 15 of 19 → 14 of 14 |
| Collins | 23.4 | — | 574 px | none | 0 |
| Wordnik | 21.7 | 6.0 | 528 px | none | 0 |
| Wiktionary | 19.9 | 7.8 | — | 208 px ToC + 196 px tools | 16 of 16 → 18 of 18 |
| Merriam-Webster | 14.8 | 18.9 | — | 224 px nav + 350 px ad | 6 of 6 |
| **wordhoard, today** | **13.8** | **22.9** | **uncapped, 1,200 px** | none | 10 |
| Dictionary.com | 11.7 | 14.9 | 884 px | 300 px right + 948 px sticky jump bar | 1 |
| Cambridge | 11.4 | 17.8 | 585 px | none (ad slots) | 14 of 16 |
| Oxford Learner's | 7.4 | — | 364 px | none | 0 |
| Vocabulary.com | 4.3 | 7.2 | 800 px | none | 0 |
| **wordhoard, scenario O1** | **3.4** | **6.9** | 68ch ≈ 490 px | 320–384 px | 20 |

Collins, Oxford Learner's and Britannica are partly or wholly behind consent
or challenge screens at 375, so their phone figures are withheld rather than
guessed.

## What the numbers say

**1. Nobody's desktop entry is short, and ours is exactly median.** The nine
run from 4.3 to 24.6 screens with a median near 14. Our 13.8 is the middle of
the field. *The page being long is not our defect* — it is what a reference
entry is. The two genuinely short ones are short because they show **one**
dictionary: Vocabulary.com at 4.3 and Oxford Learner's at 7.4 are single-source
pages. Nobody in this set aggregates nine sources on one screen, which is the
problem we actually have.

**2. Mobile is where the good ones win, and they win by collapsing
everything.** Wikipedia goes from 24.6 desktop screens to **4.3** on a phone,
and Wiktionary from 19.9 to **7.8** — because the mobile skin ships every
section collapsed: 14 of 14 and 18 of 18 regions closed. Every site that does
not do this gets *worse* on a phone, not better: Merriam-Webster 14.8 → 18.9,
Cambridge 11.4 → 17.8, Dictionary.com 11.7 → 14.9.

Ours goes **13.8 → 22.9**, a ratio of 1.66 — the worst measured, worse than
every site that does nothing at all. That is the single most damning number in
this exercise, and it is not about how much content we hold. It is that we
have no phone-specific default.

**3. A reference text column is 530–690 px wide, and ours is 1,200.** The
measured median is 585. Wikipedia's 688 is the deliberate cap its Vector 2022
redesign introduced; Dictionary.com's 884 is the widest in the set and is an
outlier. Our prose runs the full 1,200 px of the container, which is wider
than anybody's, and the 68ch cap in the sketches (≈ 490 px) is at the narrow
end of the field — defensible, and with room to grow toward 600 if we want it.

**4. A nav rail is about 200 px; a content rail is about 300.** Wikipedia and
Wiktionary pin a 208 px table of contents and a 196 px tools column.
Merriam-Webster pins 224 px of navigation. Dictionary.com pins a 300 px right
column. Our proposed 320–384 px rail is the widest in the set, which is
defensible only because it carries content rather than links — the counts, the
sound, the forms, the origin, the related words — and not merely a menu.

**5. A sticky in-page jump bar is real practice, not an invention.**
Dictionary.com pins a **948 px** entry-group navigation bar across the whole
width of its entry column, immediately under its 64 px site header. This is
#111 L8, already shipped by somebody.

**6. The first picture arrives almost immediately, everywhere.** Wikipedia
435 px, Wiktionary 334, Wordnik 325, Dictionary.com 388 at 375 px. Ours today
is **9,005 px on a desktop and 14,317 on a phone**. Scenario O1 brings it to
1,507 / 3,236.

## What we take from it

- **Do not ship a phone default that collapses everything.** This was the
  obvious read of the measurements above and it is wrong — see
  *[What collapsing actually costs](#what-collapsing-actually-costs)*. Wikipedia's
  4.3 mobile screens are bought at a price Wikimedia has measured and
  published, and it is steep.
- **Cap the prose column.** Somewhere between 600 and 690 px, in the company
  of Wikipedia and Cambridge rather than alone above Dictionary.com.
- **Keep the rail, and justify its width by its contents.** 320 px is wide for
  the field; it earns that only by holding facts, not links.
- **The jump bar is safe.** It is what Dictionary.com already pins.
- **Do not take "our page is too long" as the finding.** It is median for the
  field. The findings are the mobile ratio, the uncapped column, and the fact
  that no other site in the set has to place nine sources at once — which
  means the accordion is ours to get right, with no prior art to copy.

---

# What the literature says

The measurements above are what the pages do. This is what has been published
about whether it works — the e-lexicography literature, the design teams' own
writeups, and controlled studies. Where it contradicts the measurements, it
wins, and it contradicts them in one important place.

## What collapsing actually costs

**Wikimedia A/B tested exactly the thing its mobile skin does**, and published
the result: readers in the *expanded* group read for **190 s against 146 s at
the 90th percentile**, and scrolled more sections into view than control
readers ever *opened*. Roughly **60% of mobile readers never expand a single
collapsed section**.
([Research:Collapsed vs uncollapsed section view on mobile web](https://meta.wikimedia.org/wiki/Research:Collapsed_vs_uncollapsed_section_view_on_mobile_web))

So Wikipedia's 24.6 → 4.3 screens is not a free win. It is a trade: a page
that fits, read by people who mostly never open it. The IDS *elexiko* study
found the same shape in a dictionary — usefulness ratings were identical
whether examples were shown or hidden, but shown examples were far more likely
to be **read**, and users preferred expanded lists as the default.

This directly qualifies our own accordion. One source open means eight sources
closed, and the literature says most readers will leave them closed.

## Nobody collapses senses. Everybody collapses evidence.

The most consistent finding across eleven sites. Cambridge ships **31
accordions with exactly one open** — every one of them wrapping examples,
thesaurus entries, SMART Vocabulary or translations. Oxford Learner's hides
Verb Forms, Extra Examples and Collocations *per sense*. The OED shows the
earliest and latest quotation with *Show more quotations*. Wordnik has no
*show more* anywhere on the page.

Merriam-Webster's `set` renders **152 senses** and Dictionary.com's **184**,
both uncollapsed, on pages of 22,823 px and 25,407 px.

**The thing every one of them declines to hide is the thing our accordion
hides.** That is not fatal — none of them has nine sources to place — but it
means the burden of proof is on us.

## Showing the first sense and hiding the rest is the worst documented case

Lew, Grzelak & Leszkowicz (2013), *Lexikos* 23: 228–254
([PDF](https://doi.org/10.5788/23-1-1213)) eye-tracked sense selection. Of 50
erroneous selections, **35 — 70% — were the user taking sense 1**. Only 60% of
searches fixated every sense, and reading everything did not help (17% vs 23%
error, p = 0.18). **Users self-truncate; the page does not need to truncate
for them.** Sense count did not predict failure (r = 0.28, p = 0.16).

McCreary (2008, EURALEX) is the warning that matters most for us. Scoring
comprehension out of 8: NOAD **7.04**, MEDAL 5.89, **Merriam-Webster
Collegiate — which orders senses historically — 3.96**. For *aspersion*, users
of a historically-ordered dictionary scored **below the unaided control**.
Students underlined the first sense, and in a historical ordering the first
sense is the oldest and often archaic one.

**We order by tier, and our top tier is Johnson 1755 and Bierce 1911.** Our
page order is a historical-first ordering. Combined with first-sense bias, the
literature predicts that whichever source opens by default gets
disproportionate weight — which makes *which source opens first* a content
decision with measured consequences, not a layout detail.

## Merging senses across sources has been tried and failed in production

Koppel, Tavast, Langemets & Kallas (2019), *Aggregating Dictionaries into the
Language Portal Sõnaveeb*, eLex 2019
([PDF](https://elex.link/elex2019/wp-content/uploads/2019/09/eLex_2019_24.pdf)),
on their attempt to unify senses across source dictionaries:

> "this stage of unification resulted in a very unclear display of information
> in Sõnaveeb… This was so counter-intuitive for readers that we temporarily
> disabled version updates of Sõnaveeb, displaying the previous stage
> instead."

And the reason: *"datasets differ in their sense divisions, often
deliberately… so there are no direct correspondences between meanings across
datasets."* Their shipped answer was not merging but **audience modes** —
simple (short definitions) vs advanced (long).

This validates a decision #131 already made: source-card merging across parts
of speech stays deferred, and nothing is unified.

## Put the cue beside the thing, not in a menu at the top

Lew (2010, EURALEX), 90 learners, distributed sense shortcuts against
entry-top menus: access speed was identical (p = 0.82) but **translation
accuracy was 50.4% against 45.3%, significant at p = 0.04**. Nesi & Tan (2011,
*IJL* 24(1): 79–96, 2,109 consultations) agree.

A rail full of jump links is an entry-top menu. This is evidence for keeping
the counts and the previews **on the rows themselves**, which is what the
condensed accordion row already does, and against leaning on the rail to
compensate for what the rows do not say.

## Never label an expander "Show more"

Nielsen (2009): users perceive about **two words** when scanning a link. A
link opening with "Introducing" scored **0% comprehension and 15% correct
selection**. *Show more*, repeated nine times down a page, is the worst case —
nine identical labels with no scent.

Our disclosures already carry their size (*Read the rest of this entry · 4,217
characters*, *19 senses*, *+9 variants*). The literature says keep doing that,
and the three sites worth stealing from agree: Duden heads a section
**`Bedeutungen (4)`**, Wiktionary **`Languages (41)`**, Wordnik **`synonyms
(958)`**. **Tell the reader the size, then show it.**

## Attribution: two levels, and a period rather than a publisher

**Cambridge is best in class.** Each block opens `set | American Dictionary`
and closes with the formal credit — *(Definition of set from the Cambridge
Academic Content Dictionary © Cambridge University Press)*. A short
consumer-facing label in the heading; the full product name in fine print at
the foot.

**Collins is the failure mode.** Two of its four blocks are both headed *love
in American English* and can only be told apart by the copyright line at the
bottom of each.

**Le Robert has the best idea for our case.** It appends the 1690 *Dictionnaire
universel de Furetière* as a final section and labels it in the navigation
**`17e siècle`** — by *period*, not publisher. For Johnson 1755 and Bierce 1911
that is friendlier and more honest than a man's name, and it sidesteps the
first-sense/historical-ordering trap by telling the reader up front what kind
of thing they are about to read.

## Rails: converged in practice, cautioned in research

Merriam-Webster pins a **224 px** left rail of section links (verified holding
at scroll 4,940) with three responsive forms — vertical rail, arrowed
horizontal scroller, 50 px chip bar on mobile. Duden pins **207 px**. The OED's
CONTENTS panel is the only true per-sense navigation in the field: a sticky
collapsible tree carrying truncated definition text per sense.

Against that:

- **Dziemianko (2014), *IJL* 27(3): 259–279** — set-apart collocation boxes
  "fail to demonstrate any usefulness". The best lexicography-specific test of
  a module beside the text.
- **NN/g banner blindness** — readers skip anything *positioned or styled like
  an ad*, the right rail worst of all; participants failed to notice a sticky
  table of contents whose links lacked visual signifiers.
- **But** Wikipedia infobox links draw **0.9% CTR against 0.14% for body
  links**, roughly 6×, and eyetracking found readers look at the table of
  contents first. NN/g (Wang, 2023): participants **skipped the ToC when
  browsing and used it once they had a specific need** — which is the
  dictionary case exactly.

The best-evidenced aid for a long page is not a rail at all: **sticky section
headers** (Hollender, 2018, Wikimedia) were discovered unprompted by four of
six participants, everyone who found them kept using them, and no drawbacks
were recorded. That is what scenario O1 already does.

And the ceiling: **Nielsen (2006), Progressive Disclosure** — three or more
levels of disclosure "typically result in low usability because users often
get lost". Our page currently stacks tab → accordion row → prose fold. That is
three.

## One free advantage

The fold on every ad-supported competitor is mostly advertising. Oxford
Learner's shows **zero** definitions above 800 px, Duden zero, Collins one,
Cambridge two. Not selling ads starts us roughly 500 vertical pixels ahead of
the field.

## What this changes

1. **Drop the "collapse everything on mobile" idea.** Wikimedia measured the
   cost and published it.
2. **Which source opens by default is a content decision**, and the
   historical-ordering evidence says opening Johnson 1755 first may be the
   wrong default even though it is the best writing on the page.
3. **Label the historical sources by period**, not by author, in navigation.
4. **Keep counts in every disclosure label.** Never *Show more*.
5. **Count our disclosure levels and stop at two.** Tab → row → prose fold is
   three.
6. **Nobody has solved our actual problem.** No published usability research
   exists on consumer dictionary aggregators, and the one serious attempt to
   unify senses across sources was rolled back in production. We are not
   behind the field here; there is no field.

# Encyclopedias and aggregators

The dictionaries are the wrong comparison for half our page. Nobody in that
set carries posters, artworks and GIFs, and nobody carries nine sources. The
encyclopedias and media aggregators do.

## Wikipedia's numbers, from its own stylesheet

Vector 2022's `variables.less`, not inference: page container **1596 px**,
content container **948 px** (the published figure of 960 is stale — T335155
changed it), rail columns **196 px** rising to **248 px** on wide screens,
`@scroll-margin-heading: 75px`, header 50 px.

Both rails are **`position: sticky; top: 24px; max-height: calc(100vh - 48px);
overflow-y: auto`** — they scroll internally when the contents outrun the
screen. **Below 1000 px the left rail is `display: none` and the table of
contents collapses inline above the article.** That is the breakpoint rule we
should copy verbatim.

Measured content column: **752 px at 1280**, 948 at 1680 and above. In
characters per line that is **79 at 1280 and 97 at 1680** — and the team's own
cited research says 40–75, with WCAG asking for 80 or fewer. **Wikipedia
knowingly ships above its own target**, and published why: readers "skim and
search within pages" rather than read linearly, so a narrower column
"lengthens the page" and hinders scanning. That reasoning applies to a
dictionary more strongly than to an encyclopedia.

Published results for the sticky table of contents: readers **jumped between
sections 50% more** than with the old in-page one; the sticky header
**decreased scrolling to the top by 16%** and searches started rose **30%**.
Prototype testing across five placements found testers "preferred persistent
access" and — the finding that killed every floating variant — "did not want
the ToC to overlap the content."

**The humbling one.** Wikimedia's content-separation user test, 219
participants: **89% did not notice that two articles had different visual
designs at all.** Only 24 of 219 spotted it unprompted. We spent a round
comparing five enclosures; this is the evidence that the enclosure is the
least consequential decision on this page.

## Rail widths: the consensus band is 230–270 px

Measured across eleven sites: Wikipedia 196–248, Scholarpedia 208,
Stanford Encyclopedia 227, Letterboxd 230, MusicBrainz 235, Britannica 270,
Genius 300, AllMusic 307, Discogs 367, IMDb 424.

**Our O1 rail is 320–384 px — outside that band at every breakpoint.**

And a rule worth taking seriously: **the only sites whose rail is sticky are
the ones whose rail is navigation** — Wikipedia, AllMusic, Britannica. Discogs,
Letterboxd, MusicBrainz, Scholarpedia and the Stanford Encyclopedia at rest
have *zero* sticky elements. O1's rail is both wider than the band and sticky
while carrying content rather than navigation, which is two departures at
once. Either narrow it toward 280 and keep it sticky, or keep it wide and let
it scroll away.

## Shelves: the evidence is better than the carousel reputation suggests

The famous anti-carousel research is about **auto-advancing hero rotators**
and does not transfer. The eye-tracking work on browse shelves —
*Riding the Carousel* (IUI '26, 87 participants, 2,610 screens, Tobii at
90 Hz) — found users browse **vertically about twice as often as
horizontally**, skip rows rarely, and are **more likely to re-examine the five
visible items than to swipe for the next five**. After a swipe they read
**right-to-left**.

- **Item count: 8–12, ceiling 15–20.** NN/g's only empirical anchor is that
  users should reach the last item in **3–4 steps**. Our 12 is right; #111 L5's
  24-item cap is at the edge and everything past the second screenful is close
  to dead inventory.
- **Slice the edge item.** The peek affordance is the single best-corroborated
  decision in the whole survey — NN/g ranks "the illusion of continuity,
  created by half images" the strongest signifier and calls dots weak; Baymard
  found partial thumbnails effective; eye-tracking found a user "never glanced
  at the arrows."
- **Put the count in the heading and the remainder in the tile.** IMDb's
  `Photos 562` → six thumbs → a final tile reading **`+ 556`** is the cleanest
  pattern found anywhere. Better than our *Load more*, and it composes with it.
- **Spotify caps third-party content sets at 20** with a link onward. Our
  browse-page escape hatch is the same idea.

**An accessibility trap we have already avoided by accident.** Chrome 130
re-enabled keyboard-focusable scrollers, but only "if the scroller does not
contain any keyboard focusable children" — a shelf of card links always does,
so **there is no free keyboard scrolling**. Our rails already carry
`tabindex="0"` and an `aria-label`, which is the correct manual fix. Keep it.
Also: `overflow: hidden` draws focus rings where nobody can see them, and
offscreen cards stay in the tab order — both fixes people reach for first
(removing them from tab order, `aria-hidden` on a focusable card) are
violations.

## Attribution, cheapest to richest

1. **Byline in the heading** — AllMusic's `<h2>Packed Review by Stephen Thomas
   Erlewine</h2>`, degrading to a house byline. The cheapest way to make a
   sourced definition read as *authored* rather than scraped.
2. **One horizontal seam** — Letterboxd closes its metadata with
   `133 mins — More at [IMDb] [TMDB]`; everything below that line is members.
3. **Per-block timestamp and confidence** — MusicBrainz gives free text its
   *own* "last modified", separate from the page's, plus an explicit
   `Data quality: Normal` and a public `Open edits` link for pending changes.
4. **Nested contributor counts** — Genius counts at page (576), section (2)
   and fragment (11) simultaneously.
5. **Per-claim structured references, collapsed, with the count in the
   label** — Wikidata's `"3 references"`. 353 statements fit on one page
   because the count is in the collapsed label: you can see *that* a claim is
   sourced, and how heavily, without expanding anything.

**For wholesale public-domain text — Johnson and Bierce — Wikipedia's own
convention is a bottom-of-page block under a bold `Attribution:` line, not a
per-section badge.**

Two more worth stealing. **Wikidata's property label is `position: sticky`**,
pinning while its values scroll — the only in-content sticky element found
anywhere, and directly transferable to a headword with many senses.
**MusicBrainz prints counts inside tab labels** (`Disc IDs (16)`,
`Cover art (23)`) and makes `Edit` a peer tab rather than a pencil.

## The cautionary example

Britannica's *nepotism* page puts the first sentence of encyclopedia prose
**eleventh** — after a sticky header, a category bar, a rail, a breadcrumb,
the H1, a figure, a byline, an "Britannica AI" module and a "Top Questions"
accordion. About 90 px of actual prose is above the fold. Everything we are
tempted to put between the headword and the first definition has been tried
there.

## Sources

Koppel et al. 2019 eLex · Engelberg & Müller-Spitzer 2014, HSK 5.4 pp.
1023–1035 · Müller-Spitzer, Michaelis & Koplenig 2014 (OWID eye-tracking, 38
participants) · Fuertes-Olivera & Esandi-Baztan 2020, *Lexikos* 30: 152–185 ·
Lew, Grzelak & Leszkowicz 2013, *Lexikos* 23: 228–254 · Lew 2010, EURALEX ·
Nesi & Tan 2011, *IJL* 24(1): 79–96 · Dziemianko 2014, *IJL* 27(3): 259–279 ·
McCreary 2008, EURALEX · Wikimedia Research: Collapsed vs uncollapsed section
view · Hollender 2018 (Wikimedia sticky headers) · Nielsen 2006, 2008, 2009 ·
Loranger 2014 (NN/g, accordions) · Pernice 2019 (NN/g, layer-cake scanning) ·
Wang 2023 (NN/g, tables of contents) · OUP OED 2023 redesign factsheets ·
MediaWiki Reading/Web/Desktop Improvements (ToC, limiting content width,
2022-11 updates, Content Separation User Testing) · Vector 2022
`variables.less` · de Leon-Martinez et al., *Riding the Carousel*, IUI '26
(arXiv 2507.10135) · Loepp, *Frontiers in Big Data*, Aug 2023 · Runyon 2013 ·
Baymard, homepage carousels · W3C APG carousel pattern · Chrome 130
keyboard-focusable scrollers · Spotify Design & Branding Guidelines · Apple
HIG, Collections.
