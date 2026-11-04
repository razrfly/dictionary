#!/usr/bin/env python3
"""Builds the #309 curated-page sketches from content.json.

    python3 -I docs/sketches/curated-page/build.py docs/sketches/curated-page
    ./docs/sketches/curated-page/build.sh        # then the stylesheet

One HTML file per page. Each is the whole document at every width: the phone
reads it top to bottom; at `lg` the same document sits in two columns, the
column holding the masthead, the lead, the news and the four sections, the
rail beside it holding the editor's take and the related words. Nothing moves
between sizes and nothing is desktop-only.

Every word on these pages is one of three things: a fixed label from the D1
table (#309, c6637566629), a record quoted as the page quotes it, or the
editor's stored reason. A provider's payload (a shelf item's title, creator,
image or credit) is a labelled placeholder; see capture.exs.
"""

import html
import json
import sys
from datetime import datetime
from pathlib import Path

out = Path(sys.argv[1] if len(sys.argv) > 1 else Path(__file__).parent)
content = json.loads((out / "content.json").read_text())
pages = {p["slug"]: p for p in content["pages"]}

e = html.escape

# ── fixed vocabulary (D1) ─────────────────────────────────────────────────

SECTIONS = [
    ("definitions", "Definitions", ["definitions"]),
    ("quotations", "Quotations", ["quotes"]),
    ("examples", "Examples", ["examples"]),
    ("culture", "In culture", ["images", "films", "music", "books", "poems"]),
]
KIND = {"images": "Image", "films": "Film", "music": "Music", "books": "Book", "poems": "Poem", "news": "Headline", "quotes": "Quotation"}
REGISTER = {"satire": "Satire", "definition": "Sourced definition", "quotation": "Sourced quotation"}
PERSONA_SENTENCE = {
    "Voltaire": "Looks for sourced material that tests a confident claim against its consequences.",
    "Hitchens": "Looks for sourced material whose own evidence tests whether the word fits a real case.",
    "Bierce": "Looks for sourced material that sets a professed principle beside the interest behind it.",
}
PERSONA_DISCLOSURE = {
    "Voltaire": "An AI selection lens inspired by Voltaire; not his voice or an assertion of his opinions about modern events.",
}
WITHHELD_WHOLE = {
    "configuration_changed": "its curation configuration has changed since it was published",
    "scope_changed": "the words it was made for have changed",
    "approval_withdrawn": "its approval was withdrawn",
    "composition_retired": "its composition was retired",
}


def when(iso, clock=True):
    t = datetime.fromisoformat(iso.replace("Z", "+00:00"))
    day = f"{t.day} {t:%B %Y}"
    return f"{day}, {t:%H:%M} UTC" if clock else day


def persona_name(label):
    return label.replace("Inspired by ", "")


def cut(text, chars):
    """The stored reason, and the mark when it stops at the cap mid-sentence."""
    mark = chars == 100 and not text.rstrip().endswith((".", "!", "?", "…"))
    return mark


# ── pieces ────────────────────────────────────────────────────────────────

LINK = "rounded-sm underline decoration-mist-950/30 underline-offset-4 hover:decoration-current focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-mist-950 dark:decoration-white/30 dark:focus-visible:outline-white"
MUTED = "text-mist-600 dark:text-mist-400"


def mark(name, size="size-7 text-base"):
    return (
        f'<span aria-hidden="true" class="inline-flex {size} shrink-0 items-center justify-center rounded-full '
        f'bg-amber-100 font-display text-amber-900 dark:bg-amber-400/15 dark:text-amber-200">{e(name[0])}</span>'
    )


def chip(text, satire=False):
    tone = (
        "bg-amber-100 text-amber-900 dark:bg-amber-400/15 dark:text-amber-200"
        if satire
        else "bg-mist-950/5 text-mist-700 dark:bg-white/10 dark:text-mist-300"
    )
    return f'<span class="rounded-full px-2.5 py-0.5 text-sm/6 {tone}">{e(text)}</span>'


def reason(persona, label, text, chars, id_):
    cut_mark = (
        f' <span class="{MUTED}">· cut at 100 characters</span>' if cut(text, chars) else ""
    )
    return f"""
      <p id="{id_}" class="flex gap-3 text-base/7">
        {mark(persona, "mt-0.5 size-6 text-sm")}
        <span class="min-w-0 text-pretty text-mist-800 dark:text-mist-200"><span class="font-semibold text-mist-950 dark:text-white">{e(label)}</span> “{e(text)}”{cut_mark}</span>
      </p>"""


def disclosure(id_, rows):
    items = "".join(
        f'<div><dt class="inline font-medium text-mist-950 dark:text-white">{e(k)}</dt> <dd class="inline text-mist-700 dark:text-mist-300">{v}</dd></div>'
        for k, v in rows
    )
    return f"""
      <details id="{id_}" class="group/why">
        <summary class="flex min-h-11 w-fit cursor-pointer list-none items-center gap-2 rounded-sm text-base/7 {MUTED} hover:text-mist-950 focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-mist-950 sm:min-h-9 dark:hover:text-white dark:focus-visible:outline-white [&amp;::-webkit-details-marker]:hidden">
          <span class="underline decoration-mist-950/20 underline-offset-4 dark:decoration-white/20">Record and evidence</span>
          <span class="hero-chevron-down-mini size-5 text-mist-400 group-open/why:rotate-180"></span>
        </summary>
        <dl class="mt-2 flex flex-col gap-2 border-l-2 border-mist-950/10 pl-4 text-base/6 dark:border-white/10">{items}</dl>
      </details>"""


def credits(cs):
    if not cs:
        return ""
    parts = "".join(
        f'<div class="inline after:mx-1.5 after:content-[\'·\'] last:after:content-none"><dt class="inline font-medium text-mist-700 dark:text-mist-300">{e(c["label"])}</dt> <dd class="inline break-words">{e(c["text"])}</dd></div>'
        for c in cs
    )
    return f'<dl class="text-base/6 {MUTED}">{parts}</dl>'


def placeholder(kind, source, size="text-xl/7"):
    # One line, marked as a placeholder; the sketch note says why once.
    noun = {"news": "headline", "quotes": "quotation", "images": "image title"}.get(kind, "title")
    return f'<p class="font-display {size} text-mist-400 italic dark:text-mist-500">[the {e(noun)} as {e(source)} gives it]</p>'


def receipt_rows(page, it):
    rows = [("Exact record", f'<a href="#" class="{LINK}">the choice on the receipt</a>')]
    if it.get("observed_at"):
        rows.insert(0, ("Found", e(when(it["observed_at"]))))
        rows.insert(1, ("Shown until", e(when(it["expires_at"], clock=False))))
    rows.insert(0, ("Meaning", e(f"{page['headword']['lemma']}, {page['headword']['parts'][0]}")))
    return rows


def item_html(page, persona, it, idx):
    id_ = f"curated-item-{it['position']}"
    shelf = it.get("shelf_kind") or it["section"]
    if it["kind"] == "shelf" and shelf == "news":
        body = f'<p class="text-base/6 font-medium text-mist-700 dark:text-mist-300">Headline <span class="font-normal {MUTED}">· {e(it["source"])} · {e(when(it["observed_at"], clock=False))}</span></p>{placeholder("news", it["source"], "text-2xl/8")}'
    elif it["kind"] == "shelf" and shelf in KIND and shelf != "quotes":
        when_found = when(it["observed_at"], clock=False)
        head = f'<p class="text-base/6 font-medium text-mist-700 dark:text-mist-300">{KIND[shelf]} <span class="font-normal {MUTED}">· {e(it["source"])} · found {e(when_found)}</span></p>'
        frame = ""
        if shelf == "images":
            frame = f'<div aria-hidden="true" class="aspect-[4/3] w-full max-w-60 rounded-lg bg-mist-950/5 outline-1 -outline-offset-1 outline-black/5 dark:bg-white/5 dark:outline-white/10"></div>'
        body = f"{head}{frame}{placeholder(shelf, it['source'])}"
    elif it["kind"] == "shelf" and shelf == "quotes":
        body = f'<p class="text-base/6 font-medium text-mist-700 dark:text-mist-300">Quotation <span class="font-normal {MUTED}">· {e(it["source"])} · found {e(when(it["observed_at"], clock=False))}</span></p>{placeholder("quotes", it["source"], "text-2xl/8")}'
    elif it["kind"] == "quotation":
        body = f"""
        <figure class="flex flex-col gap-2">
          <blockquote class="font-display text-2xl/8 text-pretty text-mist-950 dark:text-white"><p class="relative before:absolute before:-translate-x-full before:content-['\\201C'] after:content-['\\201D']">{e(it["text"])}</p></blockquote>
          <figcaption class="text-base/6 text-pretty {MUTED}">{e(it.get("citation") or "")}</figcaption>
        </figure>{credits(it.get("credits"))}"""
    elif it["kind"] == "definition":
        meta = " · ".join(x for x in [it.get("creator"), it.get("date") or "undated"] if x)
        body = f"""
        <figure class="flex flex-col gap-2">
          <blockquote class="font-display text-2xl/8 text-pretty text-mist-950 dark:text-white"><p class="relative before:absolute before:-translate-x-full before:content-['\\201C'] after:content-['\\201D']">{e(it["text"])}</p></blockquote>
          <figcaption class="flex flex-wrap items-center gap-x-3 gap-y-1 text-base/6 {MUTED}">{chip("Sourced definition")}<span>{e(meta)}</span></figcaption>
        </figure>{credits(it.get("credits"))}"""
    elif it["kind"] == "artwork":
        body = f'<p class="text-base/6 font-medium text-mist-700 dark:text-mist-300">Image <span class="font-normal {MUTED}">· {e(it["source"])}</span></p><p class="font-display text-xl/7 text-pretty">{e(it["title"])}</p><p class="text-base/6 {MUTED}">{e(it.get("creator") or "")} · {e(it.get("date") or "undated")}</p>{credits(it.get("credits"))}'
    else:
        body = f'<p class="text-base/6 font-medium text-mist-700 dark:text-mist-300">Example</p><p class="font-display text-xl/7 text-pretty">{e(it.get("title") or "A linked claim")}</p>'

    return f"""
    <li id="{id_}" class="flex min-w-0 flex-col gap-3 py-6 first:pt-0 last:pb-0">
      {body}
      {reason(persona, "Why it’s here", it["reason"], it["reason_chars"], id_ + "-reason")}
      {disclosure(id_ + "-record", receipt_rows(page, it))}
    </li>"""


def section(page, persona, key, title, items, extra=""):
    lis = "".join(item_html(page, persona, it, i) for i, it in enumerate(items))
    return f"""
  <section id="curated-{key}" aria-labelledby="curated-{key}-heading" class="flex flex-col gap-5 border-t border-mist-950/10 py-8 dark:border-white/10">
    <h2 id="curated-{key}-heading" class="font-display text-3xl/9 tracking-tight">{e(title)}</h2>{extra}
    <ul role="list" class="flex flex-col divide-y divide-mist-950/10 dark:divide-white/10">{lis}</ul>
  </section>"""


def switch(lemma):
    return f"""
    <nav id="entry-views" aria-label="Entry views" class="grid grid-cols-2 rounded-xl bg-mist-950/5 p-1 text-base/5 sm:w-fit sm:text-sm/5 dark:bg-white/10">
      <a href="#" aria-current="page" class="flex min-h-11 items-center justify-center rounded-lg bg-white px-3 py-2 text-center font-medium text-mist-950 shadow-xs dark:bg-mist-700 dark:text-white">This editor’s selection</a>
      <a href="#" class="flex min-h-11 items-center justify-center rounded-lg px-3 py-2 text-center text-mist-700 hover:text-mist-950 dark:text-mist-300 dark:hover:text-white">Everything this page holds</a>
    </nav>"""


def masthead(page, byline):
    h = page["headword"]
    sub = " · ".join(x for x in [h.get("pronunciation") and f'<span class="font-mono">{e(h["pronunciation"])}</span>', e(" · ".join(h["parts"]))] if x)
    return f"""
  <header id="curated-masthead" class="flex flex-col gap-5 pb-6">
    {switch(h["lemma"])}
    <div>
      <p id="on-title" class="mb-1 text-base/7 font-semibold text-mist-700 dark:text-mist-400">On {e(h["lemma"])}</p>
      <h1 class="font-display text-5xl/none tracking-tight text-mist-950 sm:text-6xl/none dark:text-white">{e(h["lemma"])}</h1>
      <p class="mt-2 text-lg/7 text-mist-500">{sub}</p>
    </div>
    {byline}
  </header>"""


def byline(page):
    v = page["version"]
    name = persona_name(v["persona"])
    return f"""
    <div id="curated-byline" class="flex gap-3 text-base/7">
      {mark(name, "mt-0.5 size-7 text-base")}
      <div class="flex min-w-0 flex-col items-start gap-2">
        <p class="text-pretty">Selected by an AI editor inspired by <a href="#" class="font-medium {LINK}">{e(name)}</a></p>
        <span id="curated-status" class="rounded-full bg-amber-100 px-3 py-0.5 text-sm/6 font-medium text-amber-900 dark:bg-amber-400/15 dark:text-amber-200">AI-selected · not reviewed by a person</span>
        <p class="{MUTED}">{e(when(v["published_at"], clock=False))} · version {v["number"]}</p>
        <a href="#" class="-mt-2 flex min-h-11 items-center {LINK}">How this page was curated →</a>
      </div>
    </div>"""


def lead(page, persona):
    l = page["lead"]
    meta = " · ".join(e(str(x)) for x in [l.get("work"), l.get("year")] if x)
    author_tone = "text-amber-700 dark:text-amber-400" if l["register"] == "satire" else "text-mist-700 dark:text-mist-300"
    return f"""
  <section id="curated-lead" aria-labelledby="curated-lead-heading" class="flex flex-col gap-4 border-t border-mist-950/10 pt-6 pb-8 dark:border-white/10">
    <div class="flex flex-wrap items-center gap-3">
      <h2 id="curated-lead-heading" class="text-base/7 font-semibold text-mist-700 dark:text-mist-300">Leading definition</h2>
      {chip(REGISTER[l["register"]], satire=l["register"] == "satire")}
    </div>
    <figure class="flex max-w-[44rem] flex-col gap-3">
      <blockquote class="font-display text-4xl/11 text-pretty text-mist-950 dark:text-white"><p class="relative before:absolute before:-translate-x-full before:content-['\\201C'] after:content-['\\201D']">{e(l["text"])}</p></blockquote>
      <figcaption class="text-base/7"><span class="font-medium {author_tone}">{e(l["author"])}</span>{(' · <cite class="' + MUTED + '">' + meta + "</cite>") if meta else ""}</figcaption>
    </figure>
    {credits(l.get("credits"))}
    {reason(persona, "Why it leads", l["reason"], len(l["reason"]), "curated-lead-reason")}
    {disclosure("curated-lead-record", [("Meaning", e(page["headword"]["lemma"] + ", " + page["headword"]["parts"][0])), ("Kind of text", e(REGISTER[l["register"]] + ", quoted exactly.")), ("Content date", e(str(l.get("year") or "undated"))), ("Exact record", f'<a href="#" class="{LINK}">the choice on the receipt</a>')])}
  </section>"""


def news(page, persona, it):
    label = f"Headlines change. Found {when(it['observed_at'])}; shown until {when(it['expires_at'], clock=False)}."
    extra = f'\n    <p id="curated-news-label" class="-mt-2 text-base/6 text-pretty {MUTED}">{e(label)}</p>'
    return section(page, persona, "news", "In the news", [it], extra)


def editor(page, persona, chose, withheld=0):
    h = page["holdings"]
    held = f"entries from {h['dictionaries']} dictionaries, {h['senses']} senses"
    chosen = f" The editor chose {chose}." if chose else ""
    held_line = f", and {withheld} are withheld" if withheld else ""
    return f"""
    <section id="curated-editor" aria-labelledby="curated-editor-heading" class="flex flex-col gap-4 border-t border-mist-950/10 py-8 lg:border-t-0 lg:pt-0 dark:border-white/10">
      <h2 id="curated-editor-heading" class="font-display text-3xl/9 tracking-tight">The editor</h2>
      <p class="flex items-center gap-3 text-base/7 font-medium">{mark(persona)}An AI editor inspired by {e(persona)}</p>
      <p class="text-lg/7 text-pretty">{e(PERSONA_SENTENCE[persona])}</p>
      <p class="text-base/6 text-pretty {MUTED}">“{e(PERSONA_DISCLOSURE[persona])}”</p>
      <p class="text-base/7 text-pretty">This page holds {e(held)}, their quotations, and what discovery found for {e(page['headword']['lemma'])}.{e(chosen)}{e(held_line)}</p>
      <a href="#" class="flex min-h-11 w-fit items-center font-medium {LINK}">Everything this page holds →</a>
    </section>"""


def related(page):
    words = "".join(
        f'<li><a href="#" class="flex min-h-11 items-center rounded-full bg-mist-950/5 px-3 text-base/6 hover:bg-mist-950/10 sm:min-h-8 dark:bg-white/10 dark:hover:bg-white/15">{e(w)}</a></li>'
        for w in page["related"]
    )
    return f"""
    <section id="curated-related" aria-labelledby="curated-related-heading" class="flex flex-col gap-4 border-t border-mist-950/10 py-8 dark:border-white/10">
      <h2 id="curated-related-heading" class="font-display text-3xl/9 tracking-tight">Related words</h2>
      <ul role="list" class="flex flex-wrap gap-2">{words}</ul>
    </section>"""


def provenance(page, extra=""):
    v = page["version"]
    earlier = ", ".join(f'<a href="#" class="{LINK}">{n}</a>' for n in v["earlier"])
    return f"""
  <footer id="curated-provenance" class="flex flex-col gap-3 border-t border-mist-950/10 pt-8 text-base/7 {MUTED} dark:border-white/10">
    <h2 class="font-semibold text-mist-950 dark:text-white">About this version</h2>
    <p class="text-pretty">Version {v["number"]} · published {e(when(v["published_at"]))} · instruction <span class="font-mono text-sm">{e(v["instruction"])}</span> · model <span class="font-mono text-sm">{e(v["model"])}</span> · configuration version {v["configuration_version"]}</p>{extra}
    <p class="flex flex-wrap items-center gap-x-5"><a href="#" class="flex min-h-11 items-center {LINK}">How this page was curated →</a><span>Earlier versions: {earlier}</span></p>
  </footer>"""


def shell(title, note, body):
    return f"""<!DOCTYPE html>
<html lang="en" data-theme="light" data-theme-source="user">
  <head>
    <meta charset="utf-8" />
    <meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover" />
    <title>{e(title)} · curated-page sketch (#309)</title>
    <link rel="preconnect" href="https://fonts.googleapis.com" />
    <link rel="preconnect" href="https://fonts.gstatic.com" crossorigin />
    <link href="https://fonts.googleapis.com/css2?family=Instrument+Serif:ital@0;1&amp;display=swap" rel="stylesheet" />
    <link href="https://fonts.googleapis.com/css2?family=Inter:ital,opsz,wght@0,14..32,100..900;1,14..32,100..900&amp;display=swap" rel="stylesheet" />
    <link rel="stylesheet" href="./sketch.css" />
    <script>
      // The app's theme bootstrap (root.html.heex) minus the toggle; ?theme=dark shows the dark page from disk.
      (() => {{
        const q = new URLSearchParams(location.search).get("theme");
        const system = () => matchMedia("(prefers-color-scheme: dark)").matches ? "dark" : "light";
        document.documentElement.setAttribute("data-theme", q || system());
      }})();
    </script>
  </head>
  <body class="bg-mist-100 font-sans text-mist-950 antialiased dark:bg-mist-950 dark:text-white">
    <nav aria-label="Account" class="border-b border-mist-950/5 dark:border-white/10">
      <div class="mx-auto flex h-10 max-w-7xl items-center justify-end gap-5 px-6 text-sm/6 lg:px-10">
        <a href="#" class="font-medium hover:underline">Register</a><a href="#" class="font-medium hover:underline">Log in</a>
      </div>
    </nav>
    <header class="bg-mist-100 dark:bg-mist-950">
      <div class="mx-auto flex h-16 max-w-7xl items-center justify-between px-6 lg:px-10">
        <a href="#" class="font-display text-2xl/8">wordhoard</a>
        <div class="flex items-center rounded-full bg-mist-950/10 dark:bg-white/10">
          <span class="flex p-2"><span class="hero-computer-desktop-micro size-4 opacity-75"></span></span>
          <span class="flex rounded-full bg-white p-2 dark:bg-transparent"><span class="hero-sun-micro size-4 opacity-75"></span></span>
          <span class="flex rounded-full p-2 dark:bg-mist-700"><span class="hero-moon-micro size-4 opacity-75"></span></span>
        </div>
      </div>
    </header>
    <div id="sketch-note" class="border-y border-amber-600/30 bg-amber-50/60 dark:bg-amber-950/20">
      <p class="mx-auto max-w-7xl px-6 py-2 text-sm/6 text-pretty text-amber-800 lg:px-10 dark:text-amber-300">{note}</p>
    </div>
    <main class="mx-auto w-full max-w-2xl px-6 pt-8 pb-16 lg:max-w-6xl lg:px-10">
      <article id="curated-page">{body}
      </article>
    </main>
  </body>
</html>
"""


PLACEHOLDER_NOTE = "[Bracketed] items are placeholders for provider data."


def full_entry(slug):
    page = pages[slug]
    persona = persona_name(page["version"]["persona"])
    items = page["items"]
    news_items = [it for it in items if (it.get("shelf_kind") or it["section"]) == "news"]
    body = masthead(page, byline(page))
    column = lead(page, persona)
    for it in news_items:
        column += news(page, persona, it)
    for key, title, kinds in SECTIONS:
        chosen = [it for it in items if (it.get("shelf_kind") or it["section"]) in kinds]
        chosen.sort(key=lambda it: (kinds.index(it.get("shelf_kind") or it["section"]), it["position"]))
        if chosen:
            column += section(page, persona, key, title, chosen)
    rail = editor(page, persona, len(items) + 1, len(page.get("withheld") or [])) + related(page)
    body += f"""
  <div class="lg:grid lg:grid-cols-[minmax(0,1fr)_20rem] lg:gap-x-16">
    <div id="curated-column" class="min-w-0">{column}
    </div>
    <aside id="curated-rail" aria-label="The editor and related words" class="min-w-0 lg:border-t lg:border-mist-950/10 lg:pt-8 dark:lg:border-white/10">{rail}
    </aside>
  </div>{provenance(page)}"""
    v = page["version"]
    state = (
        f" Today it is withheld as a whole: {WITHHELD_WHOLE[page['state']['reasons'][0]]}."
        if page["state"]["kind"] == "withheld_whole"
        else ""
    )
    note = f"Sketch, not the app · #309 D2 · {e(slug)} version {v['number']}. {PLACEHOLDER_NOTE}"
    return shell(slug, note, body)


def assessed_line(page, persona, assessment, lead_in):
    return f"""
    <p class="flex gap-3 text-base/7 text-pretty">{mark(persona, "mt-0.5 size-6 text-sm")}<span>{e(lead_in)} {e(when(assessment["assessed_at"]))} and chose not to select:</span></p>
    <blockquote id="curated-state-reason" class="ml-9 border-l-2 border-mist-950/10 pl-4 text-base/7 dark:border-white/10">
      <p class="text-mist-400 italic dark:text-mist-500">“the editor’s stored reason, {assessment["reason_chars"]} characters, attempt {assessment["attempt"]}”</p>
      <p class="text-sm/6 text-mist-500">Placeholder in this sketch: the built page shows the stored text. <span class="{MUTED}">· cut at 100 characters</span></p>
    </blockquote>"""


def holdings_block(page):
    h = page["holdings"]
    return f"""
    <p class="text-base/7 text-pretty">This page holds entries from {h["dictionaries"]} dictionaries, {h["senses"]} senses, their quotations, and what discovery found for {e(page["headword"]["lemma"])}.</p>
    <a href="#" class="flex min-h-12 w-full items-center justify-center rounded-xl bg-mist-950 px-4 text-base/6 font-medium text-white sm:w-fit dark:bg-white dark:text-mist-950">Everything this page holds →</a>"""


def abstained(slug):
    page = pages[slug]
    persona = "Voltaire"
    a = page["state"]
    body = masthead(page, "")
    body += f"""
  <section id="curated-state" aria-labelledby="curated-state-heading" class="flex flex-col gap-4 border-t border-mist-950/10 py-8 dark:border-white/10">
    <h2 id="curated-state-heading" class="font-display text-3xl/9 tracking-tight text-pretty">No selection is published for {e(page["headword"]["lemma"])}.</h2>
    {assessed_line(page, persona, a, f"The AI editor inspired by {persona} last assessed it on")}
    {holdings_block(page)}
  </section>{related(page)}
  <footer id="curated-provenance" class="flex flex-col gap-2 border-t border-mist-950/10 pt-8 text-base/7 {MUTED} dark:border-white/10">
    <h2 class="font-semibold text-mist-950 dark:text-white">About this assessment</h2>
    <p class="text-pretty">Assessed {e(when(a["assessed_at"]))} · instruction <span class="font-mono text-sm">voltaire-whole-entry-v7</span> · configuration version 9 · nothing has been published for this word</p>
  </footer>"""
    note = f"Sketch, not the app · #309 D2 · the abstained state: {e(slug)} (composition 10), assessed and never published."
    return shell(slug, note, body)


def withheld_whole(slug):
    page = pages[slug]
    v = page["version"]
    persona = persona_name(v["persona"])
    a = page["assessment"]
    reason_text = WITHHELD_WHOLE[page["state"]["reasons"][0]]
    body = masthead(page, "")
    body += f"""
  <section id="curated-state" aria-labelledby="curated-state-heading" class="flex flex-col gap-4 border-t border-mist-950/10 py-8 dark:border-white/10">
    <h2 id="curated-state-heading" class="font-display text-3xl/9 tracking-tight text-pretty">A selection published on {e(when(v["published_at"], clock=False))} is not shown.</h2>
    <p class="text-lg/7 text-pretty">{e(reason_text[0].upper() + reason_text[1:])}. Nothing was put in its place.</p>
    {assessed_line(page, persona, a, f"The AI editor inspired by {persona} last assessed {page['headword']['lemma']} under the new configuration on")}
    {holdings_block(page)}
  </section>{related(page)}{provenance(page, f'<p class="text-pretty">Withheld as a whole since 3 November 2026, 15:18 UTC, when configuration version 9 was activated.</p>')}"""
    note = f"Sketch, not the app · #309 D2 · withheld as a whole: {e(slug)} version {v['number']} (record {v['record']}), the state of four of the nine published pages today."
    return shell(slug, note, body)


files = {
    "nepotism.html": full_entry("nepotism"),
    "truth.html": full_entry("truth"),
    "love.html": full_entry("love"),
    "bestiality-abstained.html": abstained("bestiality"),
    "greed-withheld.html": withheld_whole("greed"),
}

index_rows = "".join(
    f'<li class="flex flex-wrap items-baseline gap-x-4 py-3"><a href="./{name}" class="font-medium {LINK}">{name}</a><a href="./{name}?theme=dark" class="{LINK} {MUTED}">dark</a></li>'
    for name in files
)
files["index.html"] = shell(
    "contact sheet",
    "Sketch, not the app · #309 D2 · the curated page as its own article, phone first.",
    f"""
  <h1 class="font-display text-5xl/none">Curated page sketches</h1>
  <p class="mt-4 max-w-2xl text-base/7 text-pretty {MUTED}">Open each at 375 px first, then at 1280 px; add <code>?theme=dark</code> for the dark page. Content captured {e(content["captured_from"])}.</p>
  <ul role="list" class="mt-6 divide-y divide-mist-950/10 dark:divide-white/10">{index_rows}</ul>""",
)

for name, text in files.items():
    (out / name).write_text(text)
    print("wrote", out / name)
