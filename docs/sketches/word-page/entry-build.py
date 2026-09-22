#!/usr/bin/env python3
"""Emits the #156 entry-band sketches into docs/sketches/word-page/.

Every item is real and captured on 2026-09-22 from discovery_results on
devils_dictionary_v2 (love), the Bierce and Urban Dictionary sources, and the
Commons files the app links. Nothing is invented; a slot that has nothing is
drawn empty and says so.
"""
import os, sys

OUT = sys.argv[1]
IMG = "../../../priv/static/images"

# ---------------------------------------------------------------- content
BIERCE_LOVE = "A temporary insanity curable by marriage or by removal of the patient from the influences under which he incurred the disorder."
BIERCE_LOVE_REST = " This disease, like caries and many other ailments, is prevalent only among civilized races living under artificial conditions; barbarous nations breathing pure air and eating simple food enjoy immunity from its ravages. It is sometimes fatal, but more frequently to the physician than to the patient."
BIERCE_NEPOTISM = "Appointing your grandmother to office for the good of the party."
URBAN_LOVE = "People confuses “love” with “want”. When you fall in love with someone. You actually fall in “want”. That felling is not love."
URBAN_RIZZ = "Another word for spitting game / how good you are with pulling and sustaining bitches."

GERARD = "https://commons.wikimedia.org/wiki/Special:FilePath/Gerard_FrancoisPascalSimon-Cupid_Psyche_end.jpg?width=800"
DICKSEE = "https://commons.wikimedia.org/wiki/Special:FilePath/DickseeRomeoandJuliet.jpg?width=800"
BOUGUEREAU = "https://commons.wikimedia.org/wiki/Special:FilePath/William-Adolphe_Bouguereau_-_The_abduction_of_Psyche,_1895.jpg?width=800"
INGRES = "https://commons.wikimedia.org/wiki/Special:FilePath/Ingres_antiochus_and_stratonice.jpg?width=800"
POSTER = "https://image.tmdb.org/t/p/w342/iy4O9s3GyUoZqudsfFLuVSXLbgT.jpg"
COVER_COLE = "https://i.scdn.co/image/ab67616d00001e022cc2323c681b3f84cdc8379a"
COVER_LAMAR = "https://i.scdn.co/image/ab67616d00001e028b52c6b9bc4e43d873869699"
COVER_RIHANNA = "https://i.scdn.co/image/ab67616d00001e026be9bac15995f089579074de"
G = "https://media1.giphy.com/media/v1.Y2lkPTAyZWYyMzRkOWR1dXoya3dmcHhxam9yMG83Y2x2cXUxbmF1a3Z2d2QzYTVsMzVndyZlcD12MV9naWZzX3NlYXJjaCZjdD1n/"
GIF1 = G + "7W1rgKAxlDe3m/200w_s.gif"
GIF2 = G + "y2tJSADGWSGx5v9KR7/200w_s.gif"
GIF3 = "https://media2.giphy.com/media/v1.Y2lkPTAyZWYyMzRkOWR1dXoya3dmcHhxam9yMG83Y2x2cXUxbmF1a3Z2d2QzYTVsMzVndyZlcD12MV9naWZzX3NlYXJjaCZjdD1n/FRzg3omGn8C5ZYeafu/200w_s.gif"

# ---------------------------------------------------------------- atoms
def badge(initials, tier="middle", logo=None, extra=""):
    ring = {"aristocracy": "ring-amber-700/40 text-amber-800 dark:ring-amber-400/40 dark:text-amber-300",
            "middle": "ring-mist-950/15 text-mist-700 dark:ring-white/20 dark:text-mist-300",
            "plebs": "ring-mist-950/15 text-mist-500 dark:ring-white/20 dark:text-mist-400"}[tier]
    inner = f'<img src="{logo}" alt="" class="size-full object-cover" />' if logo else f'<span aria-hidden="true">{initials}</span>'
    return (f'<span class="inline-flex size-5 shrink-0 items-center justify-center overflow-hidden rounded-full bg-mist-100 '
            f'font-sans text-[0.625rem] font-semibold tracking-wide ring-1 ring-inset {ring} dark:bg-mist-900 {extra}">{inner}</span>')

GLYPH = {"aristocracy": "👑", "middle": "📚", "plebs": "📱"}
TIER_TEXT = {"aristocracy": "text-amber-700 dark:text-amber-400",
             "middle": "text-mist-700 dark:text-mist-400",
             "plebs": "text-mist-500 dark:text-mist-500"}

def glyph(tier):
    return f'<span aria-hidden="true" class="mr-1">{GLYPH[tier]}</span>'

def img(src, alt="", cls=""):
    return f'<img src="{src}" alt="{alt}" loading="lazy" class="size-full object-cover {cls}" />'

def frame(inner, aspect="aspect-square", extra=""):
    return (f'<div class="{aspect} overflow-hidden rounded-[min(1vw,12px)] bg-mist-950/5 outline-1 -outline-offset-1 '
            f'outline-black/5 dark:bg-white/5 dark:outline-white/10 {extra}">{inner}</div>')

def reason(text):
    return f'<p class="mt-1 text-base/6 text-mist-400 sm:text-sm/6">{text}</p>'

def meta(text):
    return f'<p class="text-base/6 text-mist-500 sm:text-sm/6">{text}</p>'

def title(text):
    return f'<p class="text-base/6 font-medium text-mist-950 sm:text-sm/6 dark:text-white">{text}</p>'

def shelf_link(label, tier, href):
    return (f'<a href="{href}" class="mt-1 inline-flex items-center gap-1 text-base/6 {TIER_TEXT[tier]} hover:underline sm:text-sm/6">'
            f'{glyph(tier)}{label}<span aria-hidden="true">↓</span></a>')

# Tiles. Each is a <li> for a grid; `tall` variants for the mosaic.
def tile_artwork(src=GERARD, name="Cupid and Psyche", year="1798", who="François Gérard", aspect="aspect-square"):
    return f'''<li class="flex min-w-0 gap-4 sm:flex-col sm:gap-2">
  <div class="w-28 shrink-0 sm:w-auto">{frame(img(src, alt=""), aspect)}</div>
  <div class="min-w-0">{title(name)}{meta(f"{year} · {who}")}{reason("Matched on an identifier, not by search.")}{shelf_link("Artworks", "middle", "#in-culture")}</div>
</li>'''

def tile_poem(line="Where Love throbs out in blissful sleep,", poem="I Have a Rendezvous With Death", who="Alan Seeger", year="1916"):
    return f'''<li class="flex min-w-0 flex-col gap-2">
  <div class="flex flex-col justify-between gap-6 rounded-[min(1vw,12px)] bg-mist-950/2.5 p-4 sm:aspect-square sm:gap-0 dark:bg-white/5">
    <p class="relative font-display text-2xl/8 text-mist-950 text-pretty before:absolute before:inline before:-translate-x-full before:content-['\\201C'] after:inline after:content-['\\201D'] sm:text-[1.625rem]/8 dark:text-white">{line}</p>
    <p class="text-base/6 text-mist-500 sm:text-sm/6">{who}</p>
  </div>
  <div class="min-w-0">{title(poem)}{meta(f"{year} · Poem")}{reason("Uses “love” at a line of the poem.")}{shelf_link("Texts", "middle", "#in-culture")}</div>
</li>'''

def tile_gif(src=GIF1, name="A GIF for “love”"):
    return f'''<li class="flex min-w-0 gap-4 sm:flex-col sm:gap-2">
  <a href="#in-culture" class="group/gif block w-28 shrink-0 sm:w-auto">
    {frame(img(src) + '<span class="absolute inset-x-0 bottom-0 flex items-end p-2"><span class="rounded-md bg-mist-950/70 px-2 py-0.5 text-base/6 font-medium text-white sm:text-sm/6">Play</span></span>', extra="relative")}
  </a>
  <div class="min-w-0">{title(name)}{meta("GIF")}{reason("Search result for “love”, not a reviewed interpretation.")}{shelf_link("GIFs", "plebs", "#in-culture")}</div>
</li>'''

def tile_track(src=COVER_COLE, name="Love", who="Keyshia Cole", year="2005"):
    return f'''<li class="flex min-w-0 gap-4 sm:flex-col sm:gap-2">
  <div class="w-28 shrink-0 sm:w-auto">{frame(img(src, alt=""))}</div>
  <div class="min-w-0">{title(name)}{meta(f"{year} · Track · {who}")}{reason("Search result for “love” in the catalogue.")}{shelf_link("Music", "middle", "#in-culture")}</div>
</li>'''

def tile_headline(head="‘My Husband Is in Love With His Valet’: Takeaways From Charles Spencer’s Memoir", masthead="The New York Times", date="21 September 2026", via="Bing News", line=None):
    quoted = line or head
    return f'''<li class="flex min-w-0 flex-col gap-2">
  <div class="flex flex-col justify-between gap-6 rounded-[min(1vw,12px)] bg-mist-950/2.5 p-4 sm:aspect-square sm:gap-0 dark:bg-white/5">
    <p class="text-lg/7 font-medium text-mist-950 text-pretty sm:text-base/6 dark:text-white">{quoted}</p>
    <p class="text-base/6 text-mist-500 sm:text-sm/6">{masthead} · {date}</p>
  </div>
  <div class="min-w-0">{title("News")}{meta(f"via {via}")}{reason("Uses “love” in a headline, on a day.")}{shelf_link("News", "plebs", "#in-culture")}</div>
</li>'''

def tile_thing():
    return f'''<li class="flex min-w-0 gap-4 sm:flex-col sm:gap-2">
  <div class="w-28 shrink-0 sm:w-auto">{frame(img(DICKSEE, alt=""))}</div>
  <div class="min-w-0">{title("love")}{meta("strong, positive emotion based on affection")}{reason("The concept this word names. Wikidata Q316.")}{shelf_link("The thing", "middle", "#thing")}</div>
</li>'''

def tile_film():
    return f'''<li class="flex min-w-0 gap-4 sm:flex-col sm:gap-2">
  <div class="w-28 shrink-0 sm:w-auto">{frame(img(POSTER, alt=""))}</div>
  <div class="min-w-0">{title("Love and War")}{meta("2027 · Film")}{reason("Matched on an identifier, not by search.")}{shelf_link("Films", "middle", "#in-culture")}</div>
</li>'''

def tile_empty(label="Waiting for the shelves"):
    return f'''<li class="min-w-0">
  <div class="flex items-center justify-center rounded-[min(1vw,12px)] border border-dashed py-8 sm:aspect-square sm:py-0 border-mist-950/15 p-4 text-center text-base/6 text-mist-400 sm:text-sm/6 dark:border-white/15">{label}</div>
</li>'''

def marks(*names):
    """One mark per surface, only for a source whose item is on the band."""
    out = []
    for n in names:
        if n == "giphy":
            out.append(f'<img src="{IMG}/giphy-powered-by.png" alt="Powered by GIPHY" class="h-4 w-auto" />')
        if n == "spotify":
            out.append(f'<img src="{IMG}/spotify-full-logo-black.svg" alt="Spotify" class="h-5 w-auto dark:hidden" /><img src="{IMG}/spotify-full-logo-white.svg" alt="Spotify" class="h-5 w-auto not-dark:hidden" />')
        if n == "guardian":
            out.append(f'<img src="{IMG}/guardian-powered-by.png" alt="Powered by The Guardian" class="h-5 w-auto dark:hidden" /><img src="{IMG}/guardian-powered-by-dark.png" alt="Powered by The Guardian" class="h-5 w-auto not-dark:hidden" />')
    return "".join(f'<span class="inline-flex items-center">{m}</span>' for m in out)

def byline(note, *mark_names):
    m = marks(*mark_names)
    return f'''<div class="mt-5 flex flex-wrap items-center justify-between gap-x-6 gap-y-2 border-t border-mist-950/10 pt-3 dark:border-white/10">
  <p class="text-base/6 text-mist-500 sm:text-sm/6">{note}</p>
  <div class="flex items-center gap-4">{m}</div>
</div>'''

def lead_quote(text, who, work, year, tier="aristocracy", card="#card-bierce", size="text-3xl/10 sm:text-4xl/11"):
    """The lead: a quotation of the original, with the source as its caption."""
    ini = "".join(w[0] for w in who.split()[:2])
    return f'''<figure id="entry-lead" class="max-w-[42rem]">
  <blockquote class="relative font-display {size} text-mist-950 text-pretty before:absolute before:inline before:-translate-x-full before:content-['\\201C'] after:inline after:content-['\\201D'] dark:text-white">{text}</blockquote>
  <figcaption class="mt-4 flex flex-wrap items-center gap-x-3 gap-y-1 text-base/7 sm:text-sm/7">
    <span class="inline-flex items-center gap-2 {TIER_TEXT[tier]}">{badge(ini, tier)}{glyph(tier)}{who}</span>
    <span class="text-mist-500">{work}{(" · " + year) if year else ""}</span>
    <a href="{card}" class="text-mist-500 underline underline-offset-4 hover:text-mist-950 dark:hover:text-white">Read the entry <span aria-hidden="true">↓</span></a>
  </figcaption>
</figure>'''

# ---------------------------------------------------------------- chrome
HEAD = '''<!DOCTYPE html>
<html lang="en" data-theme="light" data-theme-source="user">
  <head>
    <meta charset="utf-8" />
    <meta name="viewport" content="width=device-width, initial-scale=1" />
    <title>wordhoard · {word} · {title}</title>
    <link rel="preconnect" href="https://fonts.googleapis.com" />
    <link rel="preconnect" href="https://fonts.gstatic.com" crossorigin />
    <link href="https://fonts.googleapis.com/css2?family=Instrument+Serif:ital@0;1&display=swap" rel="stylesheet" />
    <link href="https://fonts.googleapis.com/css2?family=Inter:ital,opsz,wght@0,14..32,100..900;1,14..32,100..900&display=swap" rel="stylesheet" />
    <link rel="stylesheet" href="./sketch.css" />
    <script>
      (() => {{
        const q = new URLSearchParams(location.search).get("theme");
        const system = () => matchMedia("(prefers-color-scheme: dark)").matches ? "dark" : "light";
        document.documentElement.setAttribute("data-theme", q || system());
      }})();
    </script>
  </head>
  <body class="font-sans text-mist-950 antialiased dark:text-white">
    <nav id="account-navigation" aria-label="Account" class="relative z-20 border-b border-mist-950/5 bg-mist-100 dark:border-white/10 dark:bg-mist-950">
      <div class="mx-auto flex h-10 max-w-7xl items-center justify-end gap-5 px-6 text-sm/6 text-mist-600 lg:px-10 dark:text-mist-400">
        <a href="#" class="font-medium text-mist-950 hover:underline dark:text-white">Register</a>
        <a href="#" class="font-medium text-mist-950 hover:underline dark:text-white">Log in</a>
      </div>
    </nav>
    <header class="sticky top-0 z-10 bg-mist-100 dark:bg-mist-950">
      <nav>
        <div class="mx-auto flex h-(--scroll-padding-top) max-w-7xl items-center gap-4 px-6 lg:px-10">
          <div class="flex flex-1 items-center gap-12"><a href="./entry.html" class="font-display text-2xl/8 text-mist-950 dark:text-white">wordhoard</a></div>
          <div class="flex flex-1 items-center justify-end gap-4">
            <div class="relative flex flex-row items-center rounded-full bg-mist-950/10 dark:bg-white/10">
              <div class="absolute left-0 h-full w-1/3 rounded-full bg-white transition-[left] [[data-theme=dark]_&]:left-2/3 [[data-theme=light]_&]:left-1/3 dark:bg-mist-700"></div>
              <span class="flex w-1/3 p-2"><span class="size-4 opacity-75 hero-computer-desktop-micro"></span></span>
              <span class="flex w-1/3 p-2"><span class="size-4 opacity-75 hero-sun-micro"></span></span>
              <span class="flex w-1/3 p-2"><span class="size-4 opacity-75 hero-moon-micro"></span></span>
            </div>
          </div>
        </div>
      </nav>
    </header>
    <div id="sketch-note" class="border-b border-amber-600/30 bg-amber-50/60 dark:bg-amber-950/20">
      <div class="mx-auto w-full max-w-2xl px-6 py-2 text-sm/6 text-amber-800 md:max-w-3xl lg:max-w-7xl lg:px-10 dark:text-amber-300">
        Sketch, not the app · #156 · {note} · <a href="./entry.html" class="underline underline-offset-4">all variants</a> · <a href="?theme=dark" class="underline underline-offset-4">dark</a> · <a href="?theme=light" class="underline underline-offset-4">light</a>
      </div>
    </div>
    <main class="isolate overflow-clip"><div class="mx-auto w-full max-w-2xl px-6 pb-10 md:max-w-3xl lg:max-w-7xl lg:px-10">
'''

FOOT = '''
    </div></main>
  </body>
</html>
'''

def skeleton(word, prons, pos, quick, stats, origin, sources, band, defs, plaque="", related=True):
    src_rows = "".join(
        f'<li class="flex flex-wrap items-baseline justify-between gap-x-2"><a href="#card-{slug}" class="truncate {TIER_TEXT[tier]} hover:underline">{badge(ini, tier, extra="mr-1.5 align-[-0.3em]")}{name}</a><span class="shrink-0 text-mist-400">{parts}</span></li>'
        for slug, tier, ini, name, parts in sources)
    stat_tiles = "".join(
        f'<div class="{"pr-4" if i == 0 else "border-l border-mist-950/10 pl-4 dark:border-white/10"}"><p class="font-display text-3xl tabular-nums text-mist-950 dark:text-white">{n}</p><p class="text-base/6 text-mist-500 sm:text-sm/6">{label}</p></div>'
        for i, (n, label) in enumerate(stats))
    rel = '''<div class="mt-5 border-t border-mist-950/10 pt-4 max-lg:hidden dark:border-white/10">
    <h2 class="text-base/8 font-medium text-mist-950 dark:text-white">Related words</h2>
    <dl class="mt-1 space-y-1 text-base/7 sm:text-sm/7">
      <div class="flex gap-3"><dt class="w-16 shrink-0 text-mist-400">similar</dt><dd class="text-mist-700 dark:text-mist-300">adore · cherish · care for · fancy · dote on <span class="text-mist-400">+4</span></dd></div>
      <div class="flex gap-3"><dt class="w-16 shrink-0 text-mist-400">opposite</dt><dd class="text-mist-700 dark:text-mist-300">hate · despise · fear</dd></div>
      <div class="flex gap-3"><dt class="w-16 shrink-0 text-mist-400">family</dt><dd class="text-mist-700 dark:text-mist-300">lovable · lover · beloved · loveless <span class="text-mist-400">+278</span></dd></div>
    </dl>
  </div>''' if related else ""
    # The app's own grid (#131 Phase 2): the column spans both rows so row one
    # is exactly the headword's height. On a phone the column wrapper is
    # `display: contents`, so the band and the definitions become siblings of
    # the headword and the facts, and `order-*` puts the band straight after
    # the word — before the origin and the source list, as #156 asks.
    return f'''<div class="flex flex-col pt-8 lg:grid lg:grid-cols-[22.5rem_minmax(0,1fr)] lg:grid-rows-[auto_1fr] lg:gap-x-12">
<div id="headword" class="order-1 lg:col-start-1 lg:row-start-1">
  <h1 class="font-display text-5xl text-mist-950 sm:text-6xl dark:text-white">{word}</h1>
  <p class="mt-2 flex flex-wrap items-baseline gap-x-3 gap-y-1 text-lg/7 text-mist-500 sm:text-base/7">{prons}</p>
  <p class="mt-1 text-base/7 text-mist-500 sm:text-sm/7">{pos}</p>
  {f'<p class="mt-3 text-base/7 text-mist-950 sm:text-sm/7 dark:text-white">{quick} <span class="text-mist-400">Wikidata</span></p>' if quick else ""}
  {plaque}
</div>
<div class="max-lg:contents lg:col-start-2 lg:row-span-2 lg:row-start-1 lg:min-w-0 lg:max-w-[47rem]">
  <div class="order-2 max-lg:mt-8">{band}</div>
  <div class="order-4 mt-8 lg:mt-10">{defs}</div>
</div>
<div id="facts" class="order-3 max-lg:mt-8 lg:col-start-1 lg:row-start-2">
  <div class="flex border-t border-mist-950/10 pt-4 dark:border-white/10">{stat_tiles}</div>
  <div class="mt-5 border-t border-mist-950/10 pt-4 dark:border-white/10">
    <h2 class="text-base/8 font-medium text-mist-950 dark:text-white">Sound, forms and origin</h2>
    <p class="mt-1 text-base/7 text-mist-700 text-pretty sm:text-sm/7 dark:text-mist-400">{origin}</p>
  </div>
  <nav aria-label="Sources" class="mt-5 border-t border-mist-950/10 pt-4 dark:border-white/10">
    <p class="text-base/8 font-medium text-mist-950 dark:text-white">Defined here by {len(sources)} sources</p>
    <ul role="list" class="mt-2 space-y-1 text-base/7 sm:text-sm/7">{src_rows}</ul>
  </nav>
  {rel}
</div>
</div>'''


LOVE_RAIL = dict(
    word="love",
    prons='<span class="font-mono">[ˈlɐv]</span><span class="font-mono">[ˈlʌv]</span><span class="font-mono">/ˈlʌv/</span><a href="#" class="underline underline-offset-4">+9 variants</a>',
    pos="noun · verb · name",
    quick="strong, positive emotion based on affection",
    stats=[("5", "sources"), ("43", "senses")],
    origin="From Middle English <em>love</em>, from Old English <em>lufu</em>, from Proto-West Germanic <em>*lubu</em>, from Proto-Germanic <em>*lubō</em>, ultimately from Proto-Indo-European <em>*lewbʰ-</em>, to care, desire, love.",
    sources=[("johnson-noun", "aristocracy", "SJ", "Samuel Johnson", "noun · verb"),
             ("bierce", "aristocracy", "AB", "Ambrose Bierce", "noun"),
             ("wordnet-noun", "middle", "WN", "Open English WordNet 2025", "noun · verb"),
             ("wiktionary-noun", "middle", "Wk", "Wiktionary (English)", "noun · verb · name"),
             ("wikipedia", "middle", "W", "Wikipedia (English)", "article")])

def definitions(open_row="wordnet", rows=None):
    rows = rows or [
        ("johnson-noun", "aristocracy", "SJ", "Samuel Johnson", "18th century · 1755 · noun · 4,727 characters", "1. The passion between the sexes. Hearken to the birds love-learned song, The dewie leaves among! Spenser's Epithalam."),
        ("bierce", "aristocracy", "AB", "Ambrose Bierce", "20th century · 1911 · noun · 484 characters", BIERCE_LOVE),
        ("wordnet", "middle", "WN", "Open English WordNet 2025", "2025 · noun · 6 senses", "any object of warm affection or devotion"),
        ("wiktionary-noun", "middle", "Wk", "Wiktionary (English) via Kaikki", "2026 · noun · 19 senses", "A deep caring for the existence of another."),
    ]
    out = []
    for slug, tier, ini, name, m, opening in rows:
        is_open = slug == open_row
        body = ""
        if is_open and slug == "wordnet":
            body = '''<div class="pb-5 text-base/7 sm:text-sm/7"><ul role="list" class="mt-2 space-y-3">
  <li><p class="text-mist-950 dark:text-white">any object of warm affection or devotion</p><p class="mt-1 text-mist-500"><span class="text-mist-400">broader</span> object · content · cognition · psychological feature</p></li>
  <li><p class="text-mist-950 dark:text-white">a deep feeling of sexual desire and attraction</p><p class="mt-1 text-mist-500"><span class="text-mist-400">broader</span> sexual desire · desire · feeling · state</p></li>
  <li><p class="text-mist-950 dark:text-white">a strong positive emotion of regard and affection</p><p class="mt-1 text-mist-500"><span class="text-mist-400">narrower</span> adoration · agape · amorousness · ardor · benevolence · devotedness · loyalty</p></li>
</ul><p class="mt-3 text-mist-500 underline underline-offset-4">3 more from this source · 3 senses</p></div>'''
        elif is_open:
            body = f'<div class="pb-5 text-base/7 text-mist-700 sm:text-sm/7 dark:text-mist-400"><p class="max-w-[68ch]">{opening}{BIERCE_LOVE_REST if slug == "bierce" else ""}</p></div>'
        out.append(f'''<details id="card-{slug}" name="sources" class="group/row" {"open" if is_open else ""}>
  <summary class="flex cursor-pointer list-none items-start justify-between gap-4 py-4 [&::-webkit-details-marker]:hidden">
    <div class="min-w-0 flex-1">
      <h3 class="text-base/7 font-medium {TIER_TEXT[tier]}">{badge(ini, tier, extra="mr-1.5 align-[-0.3em]")}{name}</h3>
      <p class="mt-0.5 text-base/6 tabular-nums text-mist-500 sm:text-sm/6">{m}</p>
      <p class="mt-1 line-clamp-1 max-w-[47rem] text-base/7 text-mist-500 group-open/row:hidden sm:text-sm/7">{opening}</p>
    </div>
    <span class="relative size-4 h-lh shrink-0 text-mist-400"><span class="absolute top-1/2 left-0 h-px w-4 -translate-y-1/2 bg-current"></span><span class="absolute top-1/2 left-0 h-px w-4 -translate-y-1/2 rotate-90 bg-current group-open/row:hidden"></span></span>
  </summary>{body}</details>''')
    return f'''<section id="definitions">
  <div class="sticky top-(--scroll-padding-top) z-8 flex flex-wrap items-baseline justify-between gap-x-4 gap-y-1 rounded-t-2xl bg-mist-100/95 px-5 py-3 backdrop-blur dark:bg-mist-950/95">
    <h2 class="font-display text-xl text-mist-950 dark:text-white">Definitions</h2>
    <p class="text-base/7 text-mist-500 sm:text-sm/7">5 sources · 9 entries · one open at a time</p>
  </div>
  <div class="rounded-b-2xl bg-mist-950/2.5 px-5 pb-1 dark:bg-white/5"><div class="divide-y divide-mist-950/10 dark:divide-white/10">{"".join(out)}</div></div>
</section>
<section id="in-culture" class="mt-8 rounded-2xl border border-dashed border-mist-950/15 p-5 text-base/7 text-mist-500 sm:text-sm/7 dark:border-white/15">
  <p><span class="font-display text-xl text-mist-950 dark:text-white">Out in the world</span> · 78 things · every match says why it is here</p>
  <p class="mt-1">Unchanged below this line: Films · Artworks · Texts · Images · GIFs · Music · News, then <span id="thing">the thing</span>, exactly as the page renders them today. Every tile above links down into these shelves.</p>
</section>'''

def page(name, word, title, note, band, defs, rail_kwargs=None, plaque="", related=True):
    rk = dict(LOVE_RAIL) if rail_kwargs is None else rail_kwargs
    html = HEAD.format(word=word, title=title, note=note) + skeleton(band=band, defs=defs, plaque=plaque, related=related, **rk) + FOOT
    with open(os.path.join(OUT, name), "w") as f:
        f.write(html)
    print("wrote", name)

# ---------------------------------------------------------------- V1 epigraph + three tiles
def band_v1(lead, tiles, note, *mark_names, label=None):
    lab = f'<p class="mb-3 text-base/6 text-mist-400 sm:text-sm/6">{label}</p>' if label else ""
    cols = "grid-cols-1 sm:grid-cols-3"
    return f'''<section id="entry" aria-label="The entry">
  {lab}
  {lead}
  <ul role="list" class="mt-8 grid {cols} gap-6 sm:gap-5">{"".join(tiles)}</ul>
  {byline(note, *mark_names)}
</section>'''

V1_LEAD = lead_quote(BIERCE_LOVE, "Ambrose Bierce", "The Devil’s Dictionary", "1911")
page("entry-v1-epigraph-love.html", "love", "entry · V1 epigraph", "V1 — the epigraph and three tiles: one voice quoted, then a picture, a line and the crowd, one tile per tier",
     band_v1(V1_LEAD, [tile_artwork(), tile_poem(), tile_gif()], "Today’s entry · three sources, three tiers · a different pick tomorrow", "giphy"), definitions())

# ---------------------------------------------------------------- V2 plaque in the rail, a wall in the column
PLAQUE = f'''<figure id="entry-lead" class="mt-5 border-y border-amber-700/30 py-4 dark:border-amber-400/30">
  <blockquote class="relative font-display text-2xl/8 text-mist-950 text-pretty before:absolute before:inline before:-translate-x-full before:content-['\\201C'] after:inline after:content-['\\201D'] dark:text-white">{BIERCE_LOVE}</blockquote>
  <figcaption class="mt-3 flex flex-wrap items-center gap-x-3 gap-y-1 text-base/7 sm:text-sm/7">
    <span class="inline-flex items-center gap-2 text-amber-700 dark:text-amber-400">{badge("AB", "aristocracy")}{glyph("aristocracy")}Ambrose Bierce</span>
    <span class="text-mist-500">1911</span>
    <a href="#card-bierce" class="text-mist-500 underline underline-offset-4 hover:text-mist-950 dark:hover:text-white">Read the entry <span aria-hidden="true">↓</span></a>
  </figcaption>
</figure>'''

def band_v2():
    return f'''<section id="entry" aria-label="The entry">
  <div class="flex flex-wrap items-baseline justify-between gap-x-4 gap-y-1">
    <h2 class="font-display text-xl text-mist-950 dark:text-white">Out in the world, today</h2>
    <p class="text-base/7 text-mist-500 sm:text-sm/7">four of 78 · a painting, a poem, a song, the press</p>
  </div>
  <ul role="list" class="mt-4 grid grid-cols-1 gap-6 sm:grid-cols-2 sm:gap-5">{tile_artwork()}{tile_poem()}{tile_track()}{tile_headline()}</ul>
  {byline("Picked by tier and by kind, not by ranking · the shelves below hold the rest", "spotify")}
</section>'''

page("entry-v2-plaque-love.html", "love", "entry · V2 plaque", "V2 — the plaque: Bierce in the rail beside the word, a two-by-two wall in the column", band_v2(), definitions(), plaque=PLAQUE)

# ---------------------------------------------------------------- V3 mosaic
def band_v3():
    return f'''<section id="entry" aria-label="The entry">
  <div class="grid grid-cols-1 gap-3 sm:grid-cols-12 sm:gap-4">
    <!-- the picture: identity-matched, so it can carry the caption on itself -->
    <figure class="relative overflow-hidden rounded-[min(1.5vw,16px)] outline-1 -outline-offset-1 outline-black/5 sm:col-span-7 sm:row-span-2 dark:outline-white/10">
      <div class="aspect-[4/5] bg-mist-950/5 sm:aspect-auto sm:h-full dark:bg-white/5">{img(GERARD)}</div>
      <figcaption class="absolute inset-x-0 bottom-0 bg-linear-to-t from-mist-950/80 to-mist-950/0 px-4 pt-12 pb-3 text-white">
        <p class="text-lg/7 font-medium sm:text-base/6">Cupid and Psyche</p>
        <p class="text-base/6 text-white/80 sm:text-sm/6">1798 · François Gérard · {GLYPH["middle"]} Artworks · matched on an identifier</p>
      </figcaption>
    </figure>
    <!-- the voice: the aristocracy in its frame -->
    <figure class="flex flex-col justify-between rounded-[min(1.5vw,16px)] border border-amber-700/30 p-5 sm:col-span-5 dark:border-amber-400/30">
      <blockquote class="relative font-display text-2xl/8 text-mist-950 text-pretty before:absolute before:inline before:-translate-x-full before:content-['\\201C'] after:inline after:content-['\\201D'] sm:text-[1.75rem]/9 dark:text-white">{BIERCE_LOVE}</blockquote>
      <figcaption class="mt-4 flex flex-wrap items-center gap-x-3 gap-y-1 text-base/7 sm:text-sm/7">
        <span class="inline-flex items-center gap-2 text-amber-700 dark:text-amber-400">{badge("AB", "aristocracy")}{glyph("aristocracy")}Ambrose Bierce</span>
        <span class="text-mist-500">The Devil’s Dictionary · 1911</span>
        <a href="#card-bierce" class="text-mist-500 underline underline-offset-4 hover:text-mist-950 dark:hover:text-white">Read the entry <span aria-hidden="true">↓</span></a>
      </figcaption>
    </figure>
    <!-- the crowd and the catalogue, small -->
    <div class="grid grid-cols-2 gap-3 sm:col-span-5 sm:gap-4">
      <a href="#in-culture" class="group/gif -rotate-1 rounded-[min(1vw,12px)] border border-dashed border-mist-950/20 p-2 dark:border-white/20">
        {frame(img(GIF1) + '<span class="absolute inset-x-0 bottom-0 flex items-end p-2"><span class="rounded-md bg-mist-950/70 px-2 py-0.5 text-base/6 font-medium text-white sm:text-sm/6">Play</span></span>', extra="relative")}
        <p class="mt-2 text-base/6 font-medium text-mist-950 sm:text-sm/6 dark:text-white">A GIF for “love”</p>
        <p class="text-base/6 text-mist-500 sm:text-sm/6">{GLYPH["plebs"]} GIFs · a search result</p>
      </a>
      <a href="#in-culture" class="rounded-[min(1vw,12px)] p-2">
        {frame(img(COVER_COLE))}
        <p class="mt-2 text-base/6 font-medium text-mist-950 sm:text-sm/6 dark:text-white">Love</p>
        <p class="text-base/6 text-mist-500 sm:text-sm/6">2005 · Keyshia Cole · {GLYPH["middle"]} Music</p>
      </a>
    </div>
    <!-- the line and the day: text-first, ruled -->
    <div class="grid grid-cols-1 divide-y divide-mist-950/10 rounded-[min(1.5vw,16px)] bg-mist-950/2.5 sm:col-span-12 sm:grid-cols-2 sm:divide-x sm:divide-y-0 dark:divide-white/10 dark:bg-white/5">
      <a href="#in-culture" class="p-5 sm:pr-6">
        <p class="relative font-display text-2xl/8 text-mist-950 text-pretty before:absolute before:inline before:-translate-x-full before:content-['\\201C'] after:inline after:content-['\\201D'] dark:text-white">Where Love throbs out in blissful sleep,</p>
        <p class="mt-2 text-base/6 text-mist-500 sm:text-sm/6"><span class="text-mist-950 dark:text-white">I Have a Rendezvous With Death</span> · Alan Seeger · 1916 · {GLYPH["middle"]} Texts · uses “love” at a line</p>
      </a>
      <a href="#in-culture" class="p-5 sm:pl-6">
        <p class="text-lg/7 font-medium text-mist-950 text-pretty sm:text-base/6 dark:text-white">‘My Husband Is in Love With His Valet’: Takeaways From Charles Spencer’s Memoir</p>
        <p class="mt-2 text-base/6 text-mist-500 sm:text-sm/6">The New York Times · 21 September 2026 · via Bing News · {GLYPH["plebs"]} News · in a headline, on a day</p>
      </a>
    </div>
  </div>
  {byline("Six things from six sources across three tiers · the page rearranges tomorrow, never while you read", "giphy", "spotify")}
</section>'''

page("entry-v3-mosaic-love.html", "love", "entry · V3 mosaic", "V3 — the mosaic: one big picture, the voice in its frame, the crowd tilted, the line and the day ruled beneath", band_v3(), definitions())

# ---------------------------------------------------------------- V4 broadsheet
def band_v4():
    return f'''<section id="entry" aria-label="The entry">
  <div class="grid grid-cols-1 gap-8 lg:grid-cols-5 lg:gap-10">
    <div class="min-w-0 lg:col-span-3">
      <p class="text-base/7 text-amber-700 sm:text-sm/7 dark:text-amber-400">{badge("AB", "aristocracy", extra="mr-1.5 align-[-0.3em]")}{glyph("aristocracy")}Ambrose Bierce · The Devil’s Dictionary · 1911</p>
      <p class="mt-3 font-display text-2xl/9 text-mist-950 text-pretty first-letter:float-left first-letter:mr-2 first-letter:font-display first-letter:text-7xl/12 first-letter:text-amber-700 dark:text-white dark:first-letter:text-amber-400">{BIERCE_LOVE}{BIERCE_LOVE_REST}</p>
      <p class="mt-3 text-base/7 sm:text-sm/7"><a href="#card-bierce" class="text-mist-500 underline underline-offset-4 hover:text-mist-950 dark:hover:text-white">The entry, in the Definitions <span aria-hidden="true">↓</span></a></p>
    </div>
    <figure class="min-w-0 lg:col-span-2">
      {frame(img(GERARD), aspect="aspect-[4/5]", extra="rounded-[min(1vw,12px)]")}
      <figcaption class="mt-3 text-base/6 text-mist-500 sm:text-sm/6"><span class="text-mist-950 dark:text-white">Plate I.</span> Cupid and Psyche, François Gérard, 1798. {GLYPH["middle"]} <a href="#in-culture" class="underline underline-offset-4">Artworks</a> · matched on an identifier, not by search.</figcaption>
    </figure>
  </div>

  <div class="mt-10 border-t border-mist-950/10 pt-6 dark:border-white/10">
    <div class="flex flex-wrap items-baseline justify-between gap-x-4 gap-y-1">
      <h2 class="font-display text-xl text-mist-950 dark:text-white">Out in the world</h2>
      <p class="text-base/7 text-mist-500 sm:text-sm/7">22 September 2026 · three of 78</p>
    </div>
    <div class="mt-4 grid grid-cols-1 divide-y divide-mist-950/10 sm:grid-cols-3 sm:divide-x sm:divide-y-0 dark:divide-white/10">
      <a href="#in-culture" class="py-4 sm:py-0 sm:pr-6">
        <p class="text-base/6 text-mist-400 sm:text-sm/6">{GLYPH["middle"]} In verse</p>
        <p class="relative mt-2 font-display text-2xl/8 text-mist-950 text-pretty before:absolute before:inline before:-translate-x-full before:content-['\\201C'] after:inline after:content-['\\201D'] dark:text-white">Where Love throbs out in blissful sleep,</p>
        <p class="mt-2 text-base/6 text-mist-500 sm:text-sm/6"><span class="text-mist-950 dark:text-white">I Have a Rendezvous With Death</span> · Alan Seeger, 1916 · uses “love” at a line</p>
      </a>
      <a href="#in-culture" class="py-4 sm:px-6 sm:py-0">
        <p class="text-base/6 text-mist-400 sm:text-sm/6">{GLYPH["plebs"]} In the press</p>
        <p class="mt-2 text-lg/7 font-medium text-mist-950 text-pretty sm:text-base/6 dark:text-white">‘My Husband Is in Love With His Valet’: Takeaways From Charles Spencer’s Memoir</p>
        <p class="mt-2 text-base/6 text-mist-500 sm:text-sm/6">The New York Times · 21 September 2026 · via Bing News · in a headline, on a day</p>
      </a>
      <a href="#in-culture" class="flex gap-4 py-4 sm:block sm:py-0 sm:pl-6">
        <div class="min-w-0">
          <p class="text-base/6 text-mist-400 sm:text-sm/6">{GLYPH["middle"]} On the air</p>
          <div class="mt-2 flex items-start gap-3">
            <div class="size-16 shrink-0 overflow-hidden rounded-[min(0.5vw,8px)] outline-1 -outline-offset-1 outline-black/5 dark:outline-white/10">{img(COVER_COLE)}</div>
            <div class="min-w-0">
              <p class="text-lg/7 font-medium text-mist-950 sm:text-base/6 dark:text-white">Love</p>
              <p class="text-base/6 text-mist-500 sm:text-sm/6">Keyshia Cole · 2005 · a search of the catalogue</p>
            </div>
          </div>
        </div>
      </a>
    </div>
  </div>

  <div class="mt-8 border-t border-mist-950/10 pt-6 dark:border-white/10">
    <p class="text-base/6 text-mist-400 sm:text-sm/6">{GLYPH["plebs"]} From the crowd</p>
    <div class="mt-3 flex flex-col gap-4 sm:flex-row sm:items-start sm:gap-6">
      <a href="#in-culture" class="w-32 shrink-0 -rotate-1">
        {frame(img(GIF1) + '<span class="absolute inset-x-0 bottom-0 flex items-end p-2"><span class="rounded-md bg-mist-950/70 px-2 py-0.5 text-base/6 font-medium text-white sm:text-sm/6">Play</span></span>', extra="relative")}
        <p class="mt-1 text-base/6 text-mist-500 sm:text-sm/6">A GIF for “love” · GIPHY</p>
      </a>
      <div class="min-w-0 max-w-[40rem] rounded-2xl rounded-tl-sm bg-mist-950/5 px-4 py-3 dark:bg-white/10">
        <p class="text-base/7 text-mist-950 sm:text-sm/7 dark:text-white">{URBAN_LOVE}</p>
        <p class="mt-1 text-base/6 text-mist-500 sm:text-sm/6">Urban Dictionary · Mean Little · 2021 · fetched by your browser, stored nowhere · <a href="#" class="underline underline-offset-4">the Crowd card <span aria-hidden="true">↓</span></a></p>
      </div>
    </div>
  </div>
  {byline("The dead, the institutions, the crowd: each in its own type", "giphy", "spotify")}
</section>'''

page("entry-v4-broadsheet-love.html", "love", "entry · V4 broadsheet", "V4 — the broadsheet: a drop-cap lead and a plate, a ruled strip for the day, the crowd in its own register", band_v4(), definitions())

# ---------------------------------------------------------------- rotation: V1 across three days
def day(label, tiles, note, *m):
    return band_v1(V1_LEAD, tiles, note, *m, label=label)

rot = f'''<div class="space-y-14">
{day("Monday 21 September", [tile_artwork(), tile_poem(), tile_gif()], "Gérard · Seeger · GIPHY", "giphy")}
{day("Tuesday 22 September", [tile_film(), tile_poem("Love, while the sweet thing laughs and lies,", "Étude Réaliste", "Algernon Charles Swinburne", "1866"), tile_headline("Klopp, Xavi, Zidane, Mancini: big nations ready to unleash bigger dogs", "The Guardian", "22 September 2026", "The Guardian", line="She went to Anfield and fell in love with it.")], "CineGraph · Swinburne · The Guardian", "guardian")}
{day("Wednesday 23 September", [tile_artwork(BOUGUEREAU, "The Abduction of Psyche", "1895", "William-Adolphe Bouguereau"), tile_poem("Love, strong as death, the poet led", "Ode on St Cecilia’s Day", "Alexander Pope", "1713"), tile_gif(GIF2, "Another GIF for “love”")], "Bouguereau · Pope · GIPHY", "giphy")}
<div class="rounded-2xl bg-mist-950/2.5 p-5 text-base/7 text-mist-700 sm:text-sm/7 dark:bg-white/5 dark:text-mist-300">
  <p class="font-medium text-mist-950 dark:text-white">What rotates and what does not.</p>
  <p class="mt-2 text-pretty">The lead never rotates: Bierce wrote one entry and it is the entry. The tiles rotate <em>within a kind</em> among candidates that tie on evidence and tier — six catalogue paintings, ten attested poem lines, twelve GIFs, seventeen headlines — seeded by the word and the date, so a page is the same all day and different tomorrow. The tier rule runs first, so every day still shows the dead, the institutions and the crowd. Tuesday’s crowd slot went to a headline because the Guardian’s attestation outranks a GIF’s search; that is decision 7 in #156, shown both ways here.</p>
</div>
</div>'''
page("entry-rotation-love.html", "love", "entry · rotation", "V1 on three consecutive days: the same word, the same rules, a different pick", rot, definitions())

# ---------------------------------------------------------------- the words: nepotism, rizz, topographagnosia
NEP_RAIL = dict(
    word="nepotism",
    prons='<span class="font-mono">/ˈnɛpətɪzəm/</span>',
    pos="noun", quick=None,
    stats=[("4", "sources"), ("5", "senses")],
    origin="From Latin <em>nepōs</em>, nephew, grandson, via French <em>népotisme</em> (1660s), from the practice of popes granting favours to their “nephews”.",
    sources=[("johnson", "aristocracy", "SJ", "Samuel Johnson", "noun"),
             ("bierce", "aristocracy", "AB", "Ambrose Bierce", "noun"),
             ("wordnet", "middle", "WN", "Open English WordNet 2025", "noun"),
             ("wiktionary", "middle", "Wk", "Wiktionary (English)", "noun")])
RIZZ_RAIL = dict(
    word="rizz",
    prons='<span class="font-mono">/rɪz/</span>',
    pos="noun · verb", quick=None,
    stats=[("1", "source"), ("2", "senses")],
    origin="Clipped from <em>charisma</em>; popularised on Twitch and YouTube by Kai Cenat, 2021. Oxford’s word of the year, 2023.",
    sources=[("wiktionary", "middle", "Wk", "Wiktionary (English)", "noun · verb")])
TOPO_RAIL = dict(
    word="topographagnosia",
    prons='<span class="font-mono">/ˌtɒpəɡrafaɡˈnəʊzɪə/</span>',
    pos="noun", quick=None,
    stats=[("1", "source"), ("1", "sense")],
    origin="From <em>topography</em> and <em>agnosia</em>: the inability to find one’s way about.",
    sources=[("wiktionary", "middle", "Wk", "Wiktionary (English)", "noun")])

def tile_book():
    return f'''<li class="flex min-w-0 flex-col gap-2">
  <div class="flex flex-col justify-between gap-6 rounded-[min(1vw,12px)] bg-mist-950/2.5 p-4 sm:aspect-square sm:gap-0 dark:bg-white/5">
    <p class="relative font-display text-2xl/8 text-mist-950 text-pretty before:absolute before:inline before:-translate-x-full before:content-['\\201C'] after:inline after:content-['\\201D'] sm:text-[1.5rem]/8 dark:text-white">Another term, nepotism, will be important throughout this book. What is nepotism?</p>
    <p class="text-base/6 text-mist-500 sm:text-sm/6">Stephen T. Asma</p>
  </div>
  <div class="min-w-0">{title("Against Fairness")}{meta("2012 · Book")}{reason("Uses “nepotism” on a page of the book.")}{shelf_link("Texts", "middle", "#in-culture")}</div>
</li>'''

def small_defs(rows, open_row):
    return definitions(open_row=open_row, rows=rows)

# nepotism: lead only + one tile
nep_body = band_v1(lead_quote(BIERCE_NEPOTISM, "Ambrose Bierce", "The Devil’s Dictionary", "1911"),
                   [tile_book()], "One tile: nothing on this page is a picture the rule admits, and no shelf holds a 📱 item with evidence · the band says nothing about the two empty slots")
nep_defs = small_defs([("johnson", "aristocracy", "SJ", "Samuel Johnson", "18th century · 1755 · noun · 96 characters", "Fondness for nephews."),
                ("bierce", "aristocracy", "AB", "Ambrose Bierce", "20th century · 1911 · noun · 77 characters", BIERCE_NEPOTISM),
                ("wordnet", "middle", "WN", "Open English WordNet 2025", "2025 · noun · 1 sense", "favoritism shown to relatives or close friends by those in power"),
                ("wiktionary", "middle", "Wk", "Wiktionary (English) via Kaikki", "2026 · noun · 2 senses", "The favoring of relatives or personal friends because of their relationship rather than because of their abilities.")], "wordnet")
page("entry-words-nepotism.html", "nepotism", "entry · nepotism", "The honest cases — nepotism: Bierce whole in 77 characters, one tile, two slots collapsed", nep_body, nep_defs, rail_kwargs=NEP_RAIL, related=False)

# rizz: the inverted band. Urban Dictionary leads, tiles are still arriving.
rizz_lead = lead_quote(URBAN_RIZZ, "Urban Dictionary", "bro got no rizz · fetched by your browser, stored nowhere", "2022", tier="plebs", card="#crowd", size="text-2xl/9 sm:text-3xl/10")
rizz_body = band_v1(rizz_lead, [tile_empty("The picture, when a shelf answers"), tile_empty("The line"), tile_empty("The sound")],
                    "The inverted band: neither dead man met this word, so the crowd leads · the slots fill as the shelves report, and once they have settled nothing moves")
rizz_defs = small_defs([("wiktionary", "middle", "Wk", "Wiktionary (English) via Kaikki", "2026 · noun · 2 senses", "(slang) One's ability to seduce or charm a potential romantic partner.")], "wiktionary")
page("entry-words-rizz.html", "rizz", "entry · rizz", "The honest cases — rizz: the crowd leads, the tiles are the loading state, drawn as the reader sees it before the shelves answer", rizz_body, rizz_defs, rail_kwargs=RIZZ_RAIL, related=False)

# topographagnosia: no band at all
topo_body = '''<p class="rounded-2xl border border-dashed border-mist-950/15 p-5 text-base/7 text-mist-500 sm:text-sm/7 dark:border-white/15">No band. No aristocrat wrote this entry, Urban Dictionary has nothing, and every shelf is empty (#143 measured it). The page opens on the Definitions, as it does today. This box is the sketch pointing at the absence; the app draws nothing here.</p>'''
topo_defs = small_defs([("wiktionary", "middle", "Wk", "Wiktionary (English) via Kaikki", "2026 · noun · 1 sense", "The inability to orient oneself in one's surroundings.")], "wiktionary")
page("entry-words-topographagnosia.html", "topographagnosia", "entry · topographagnosia", "The honest cases — topographagnosia: nothing to show, so nothing is shown", topo_body, topo_defs, rail_kwargs=TOPO_RAIL, related=False)

# ---------------------------------------------------------------- contact sheet
index = HEAD.format(word="entry", title="contact sheet", note="the contact sheet for #156 Phase 0") + '''<div class="pt-8">
  <h1 class="font-display text-5xl text-mist-950 sm:text-6xl dark:text-white">The entry</h1>
  <p class="mt-4 max-w-[60ch] text-lg/8 text-mist-700 text-pretty sm:text-base/7 dark:text-mist-300">Four ways to put one voice and a few well-chosen things above the Definitions on <em>love</em>, built on what the page fetched on 22 September 2026, plus what each design does on three words that test it. The cards and the shelves beneath are unchanged in every one. Add <code>?theme=dark</code> to any page.</p>

  <h2 class="mt-12 font-display text-2xl text-mist-950 dark:text-white">Four variants, one word</h2>
  <ul role="list" class="mt-4 grid grid-cols-1 gap-x-10 gap-y-8 sm:grid-cols-2">
    <li><a href="./entry-v1-epigraph-love.html" class="text-lg/7 font-medium text-mist-950 underline underline-offset-4 sm:text-base/7 dark:text-white">V1 · The epigraph</a><p class="mt-1 text-base/7 text-mist-600 text-pretty sm:text-sm/7 dark:text-mist-400">Bierce quoted large, then three square tiles: a painting, a line of verse, a GIF. One tile per kind and one per tier. The smallest change to the page and the recommended one in #156.</p></li>
    <li><a href="./entry-v2-plaque-love.html" class="text-lg/7 font-medium text-mist-950 underline underline-offset-4 sm:text-base/7 dark:text-white">V2 · The plaque</a><p class="mt-1 text-base/7 text-mist-600 text-pretty sm:text-sm/7 dark:text-mist-400">Bierce in the rail directly under the word, ruled in amber like a museum label, and a two-by-two wall in the column: painting, poem, track, headline. The quotation sits beside what it defines; the column is all pictures and lines.</p></li>
    <li><a href="./entry-v3-mosaic-love.html" class="text-lg/7 font-medium text-mist-950 underline underline-offset-4 sm:text-base/7 dark:text-white">V3 · The mosaic</a><p class="mt-1 text-base/7 text-mist-600 text-pretty sm:text-sm/7 dark:text-mist-400">One big picture with its caption on it, the voice in an amber frame, the GIF tilted like a sticker, a track beside it, and the poem line and the day’s headline ruled beneath. The tiers are visible as three treatments. The most magazine of the four.</p></li>
    <li><a href="./entry-v4-broadsheet-love.html" class="text-lg/7 font-medium text-mist-950 underline underline-offset-4 sm:text-base/7 dark:text-white">V4 · The broadsheet</a><p class="mt-1 text-base/7 text-mist-600 text-pretty sm:text-sm/7 dark:text-mist-400">Bierce as a drop-cap lead paragraph, whole; the painting as Plate I with a museum caption; a three-column ruled strip for verse, press and air; and the crowd at the bottom in its own register, a GIF and an Urban Dictionary line in a chat bubble. The most encyclopedia of the four, and the tallest.</p></li>
  </ul>

  <h2 class="mt-12 font-display text-2xl text-mist-950 dark:text-white">Different every so often</h2>
  <ul role="list" class="mt-4 grid grid-cols-1 gap-x-10 gap-y-8 sm:grid-cols-2">
    <li><a href="./entry-rotation-love.html" class="text-lg/7 font-medium text-mist-950 underline underline-offset-4 sm:text-base/7 dark:text-white">V1 on three consecutive days</a><p class="mt-1 text-base/7 text-mist-600 text-pretty sm:text-sm/7 dark:text-mist-400">The same word and the same rules, seeded by the date: Gérard, Seeger and a GIF; then a film poster, Swinburne and a Guardian headline; then Bouguereau, Pope and another GIF. Every day keeps all three tiers. The lead never moves.</p></li>
  </ul>

  <h2 class="mt-12 font-display text-2xl text-mist-950 dark:text-white">The honest cases</h2>
  <ul role="list" class="mt-4 grid grid-cols-1 gap-x-10 gap-y-8 sm:grid-cols-3">
    <li><a href="./entry-words-nepotism.html" class="text-lg/7 font-medium text-mist-950 underline underline-offset-4 sm:text-base/7 dark:text-white">nepotism</a><p class="mt-1 text-base/7 text-mist-600 text-pretty sm:text-sm/7 dark:text-mist-400">Bierce in 77 characters, whole. One tile, a book that uses the word. No stock photograph, so the picture slot collapses rather than lying.</p></li>
    <li><a href="./entry-words-rizz.html" class="text-lg/7 font-medium text-mist-950 underline underline-offset-4 sm:text-base/7 dark:text-white">rizz</a><p class="mt-1 text-base/7 text-mist-600 text-pretty sm:text-sm/7 dark:text-mist-400">Neither dead man met the word, so the crowd leads. The tiles are drawn in their loading state: the band fills as the shelves answer and never rearranges afterwards.</p></li>
    <li><a href="./entry-words-topographagnosia.html" class="text-lg/7 font-medium text-mist-950 underline underline-offset-4 sm:text-base/7 dark:text-white">topographagnosia</a><p class="mt-1 text-base/7 text-mist-600 text-pretty sm:text-sm/7 dark:text-mist-400">Nothing anywhere, so no band. The page opens on the Definitions exactly as it does today.</p></li>
  </ul>

  <h2 class="mt-12 font-display text-2xl text-mist-950 dark:text-white">What every variant keeps</h2>
  <ul role="list" class="mt-4 max-w-[60ch] list-disc space-y-2 pl-5 text-base/7 text-mist-700 sm:text-sm/7 dark:text-mist-300">
    <li>Every tile says why it is here in one sentence and links <em>down</em> to its shelf, never out.</li>
    <li>A source whose mark is a condition of use shows it once, in the band’s byline, only when its item is on the band.</li>
    <li>The Definitions slab is untouched: the same rows, the same WordNet row open, the same ids.</li>
    <li>Nothing is rewritten. Bierce is quoted; a poem is quoted at its matched line; a headline is a headline.</li>
    <li>The rail is the rail. Only V2 puts anything in it, and only the quotation.</li>
  </ul>
</div>''' + FOOT
with open(os.path.join(OUT, "entry.html"), "w") as f:
    f.write(index)
print("wrote entry.html")
