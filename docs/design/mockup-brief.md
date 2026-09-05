# Mockup Brief — The Devil's Dictionary, 21st-Century Edition

> Paste this whole brief to Claude (with the UI / design skill) and ask it to produce
> several distinct mockup directions. It is deliberately specific about *content* and
> *concept* and deliberately open about *visual execution*.

---

## The prompt

You are designing the core "definition page" for a reimagined **Devil's Dictionary** — Ambrose
Bierce's 1906 book of cynical, witty definitions, dragged into the age of TikTok, situationships,
and the performative male. Bierce defined *"DICTIONARY, n. A malevolent literary device for
cramping the growth of a language..."* We are keeping his voice and weaponizing it on modern words.

Produce **3–4 visually distinct mockup directions** for a single word's page. Deliver each as a
self-contained HTML file styled with Tailwind-style utility classes (this ships on Phoenix
LiveView + Tailwind v4, no component library — so plain HTML/CSS that we can port to HEEX). Make
them genuinely different from each other in layout and mood, not recolors of one idea. Use real
content (provided below) so the mockups feel alive, not lorem-ipsum.

### The central concept: a *hierarchy of knowledge*

Every word is defined three times, by three "classes," and the **visual styling of each tier is the
joke**. The styling *is* the argument about who gets to define our language.

| Tier | Who | Sources | Aesthetic direction (open to interpretation) |
|------|-----|---------|-----------------------------------------------|
| 👑 **Aristocracy of the Dead** | Dead intellectuals | Bierce, Wilde, Twain, Mencken | Gilded, serif, aged paper, engraved, museum-plaque reverence. The "real" definition. |
| 📚 **Middle Class** | Living institutions | Merriam-Webster, Oxford, Britannica | Clean, corporate, sans-serif, professional, a little bloodless. The "official" definition. |
| 📱 **The Plebs** | The crowd | Urban Dictionary, Reddit, X, TikTok comments | Chaotic, casual, emoji, screenshot energy, upvotes. The "real real" definition. |

The page should make a reader *feel* the descent (or ascent) through the classes as they scroll.
You decide whether that's a vertical stack, side-by-side columns, tabs, a toggle, etc.

### The new layer: community-suggested "evidence"

This is the part that makes it a 21st-century encyclopedia instead of just a book. Underneath the
definitions, users attach **related media that proves the word is alive in culture** — like an
encyclopedia "in popular culture" section, but crowdsourced and rankable. Treat these as first-class
"citations from the culture." Supported types:

- 🎵 **Song lyric** — an excerpt + artist/song, the line that captures the word
- 📺 **YouTube video** — a video essay, sketch, or clip (thumbnail + title + channel)
- 📸 **Instagram post / Reel** — an image or screenshot embodying the word
- 🎬 **TikTok** — a clip, a sound, a trend
- 🐦 **Tweet / X post** — a one-liner that nails it
- (leave room for: news headline, movie scene, meme image)

Each piece of evidence needs: a thumbnail/preview, who submitted it, a vote/agree count (does this
*really* capture the word?), and a way to add your own. Design this as a feed/gallery/wall — your
call — that feels like the culture talking back to the dictionary. The tension to play with: the
dead aristocrats up top in their gilded frames, the living internet shouting underneath.

### Page anatomy (use as a checklist, not a layout)

1. **Headword block** — the word, pronunciation, part of speech. This is the marquee. Make it
   beautiful. e.g. `situationship · /ˌsɪtʃ.u.ˈeɪ.ʃɪp/ · noun`
2. **The three tiers of definitions** — styled per the table above.
3. **Community evidence wall** — the suggested media, with submitter + votes + "add yours."
4. **Related words** — cross-links (synonyms, word forms, "see also"). e.g. situationship → talking
   stage, breadcrumbing, delulu.
5. **Contribute affordances** — "suggest a definition," "add evidence," subtly present, never spammy.

### Tone & brand

Cynical, literary, funny, a little mean — Bierce with a phone. Premium and editorial, *not* a
meme-dump. The Aristocracy tier should feel like it belongs in a leather-bound book; the Plebs tier
should feel like your group chat. The whole thing should look like something you'd screenshot.

---

## Real content to use in the mockups

Use these two words. Build at least one full mockup for **situationship** and one for
**performative**. You may polish/rewrite the Bierce-voice lines, and invent extra evidence items.

### Word 1 — `situationship` · noun · /ˌsɪtʃ.u.ˈeɪ.ʃɪp/

**👑 Aristocracy (write in Bierce's voice):**
> *SITUATIONSHIP, n.* A compact between two persons, each privately convinced the other is the more
> deeply ensnared; possessing all the obligations of courtship and all the security of the weather.

**📚 Middle Class (Merriam-Webster style):**
> A romantic or sexual relationship that is not considered to be formal or established.

**📱 Plebs (Urban Dictionary style, with votes):**
> "when ur basically dating but he'd combust before calling u his gf 💀 no title, no peace" — *▲ 4.2k*

**Evidence wall:**
- 🎵 SZA — *"I Hate U"* — "and if you wonder if I hate you (I do)" — submitted by @no_thoughts · 312 agree
- 🎬 TikTok — "POV: he says he's 'not ready for a label' but acts like your bf" — 1.1M likes
- 📺 YouTube — "The Rise of the Situationship (video essay)" — The Take · 480k views
- 🐦 "a situationship is just a relationship with commitment issues and a cooler name" — 22k likes
- 📸 Instagram — text post: "delulu is the solulu" reel — submitted by @softlaunch

**Related:** talking stage · breadcrumbing · soft launch · delulu · ghosting

### Word 2 — `performative` · adj · /pərˈfɔːr.mə.tɪv/

**👑 Aristocracy (write in Bierce's voice):**
> *PERFORMATIVE, adj.* Of virtue worn as a garment — conspicuous, removable, and chosen chiefly for
> the admiration of strangers.

**📚 Middle Class (Oxford style):**
> Relating to an action that expresses or performs an identity, esp. one undertaken for social
> approval rather than sincere conviction.

**📱 Plebs (Urban Dictionary style, with votes):**
> "carrying a tote bag, a matcha, and a Labubu to seem like a feminist. performative male behavior
> fr 🧋" — *▲ 8.7k*

**Evidence wall:**
- 🎬 TikTok — "Performative Male Contest in [city] (matcha, tote bag, Clairo vinyl)" — 3.4M likes
- 📺 YouTube — "How to spot a performative male" — 920k views
- 🎵 Clairo — *"Bags"* — submitted by @itgirl · 201 agree
- 📸 Instagram — carousel: "wired headphones + Sally Rooney paperback" — @beigecat
- 🐦 "he reads feminist theory to text back slower" — 15k likes

**Related:** performative male · virtue signaling · pick-me · aesthetic · authenticity

---

## Deliverables

- 3–4 separate HTML mockups, each a distinct direction. Name them by their concept
  (e.g. `01-illuminated-manuscript.html`, `02-feed-first.html`, `03-museum-plaque.html`).
- A short note per mockup: the idea in one sentence, and which tier/evidence treatment you're proud of.
- Keep it portable to Phoenix HEEX + Tailwind v4 (utility classes, no JS framework, no daisyUI).
- Optimize for "would someone screenshot this and send it to the group chat?"
