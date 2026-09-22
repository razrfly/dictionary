# Source marks

The mark a source's badge draws (#152 Phase 4): one file per source under
`priv/static/images/sources/`, named by slug, referenced from the row's `logo`
and declared in the provider's `source_attrs/0` (or the catalog's entry). A
local asset and never a hotlink, for the reason the licence marks are: a
provider's server does not decide what our page shows, and every reader's
address in their logs to draw our own chrome is a cost we do not pay.

Each is the mark the source itself publishes to identify itself — the touch
icon its own site ships, or its logo as Wikimedia Commons holds it — used
nominatively, to say whose content sits beside it, at a size (20–28 px) no
guideline reads as an endorsement. Rasters are fitted into a 128 px square and
padded white (`sips`), which is what a round badge crops; the two authors are
portraits, since a 1755 lexicographer has no brand kit. Fetched 2026-09-22.

| Slug | File | Taken from | Terms |
|---|---|---|---|
| `wikipedia` | `wikipedia.png` | Commons `File:Wikipedia-logo-v2.svg`, rendered at 128 px | CC BY-SA 3.0; Wikimedia trademark, used to refer to and link to the site (Trademark Policy §3) |
| `wiktionary` | `wiktionary.png` | Commons `File:Wiktionary-logo.svg` | CC BY-SA 3.0; as above |
| `wikidata` | `wikidata.png` | Commons `File:Wikidata-logo.svg` | Public domain; Wikimedia trademark, as above |
| `commons` | `commons.png` | Commons `File:Commons-logo.svg` | CC BY-SA 3.0; as above |
| `johnson` | `johnson.png` | Commons `File:Samuel Johnson by Joshua Reynolds.jpg`, cropped to the face | Public domain (Reynolds, c. 1772) |
| `bierce` | `bierce.png` | Commons `File:Ambrose Bierce portre.jpg` | Public domain |
| `wordnet` | `wordnet.png` | `https://en-word.net/assets/favicon-*.ico`, 64 px frame | Open English WordNet's own site icon; project CC BY 4.0 |
| `met` | `met.png` | Commons `File:The Metropolitan Museum of Art Logo.svg` | Public domain (text logo); Met trademark, nominative |
| `pexels` | `pexels.png` | Commons `File:Pexels logo (2024).svg` | Public domain (text logo); Pexels trademark, nominative — their icon file returns 403 to non-browsers |
| `unsplash` | `unsplash.png` | `https://unsplash.com/apple-touch-icon.png` | Unsplash trademark, nominative; the credit link the API terms require is per item and unchanged |
| `openverse` | `openverse.svg` | `https://openverse.org/openverse-logo.svg` | Openverse (WordPress) mark, nominative |
| `open-library` | `open-library.png` | `https://openlibrary.org/static/images/openlibrary-192x192.png` | Internet Archive mark, nominative |
| `guardian` | `guardian.png` | `https://assets.guim.co.uk/static/frontend/icons/homescreen/apple-touch-icon-512.png` | Guardian mark, nominative. The *Powered by* lockup clause 6(b)(vi) requires is a separate obligation and stays on the shelf |
| `giphy` | `giphy.png` | `https://giphy.com/static/img/icons/apple-touch-icon-180px.png` | GIPHY mark, nominative; the *Powered by GIPHY* lockup stays on the shelf |
| `spotify` | `spotify.svg` | The icon path of the shipped `spotify-full-logo-black.svg` (Spotify's own file, #143), alone and unaltered | Spotify Branding Guidelines allow the icon on its own; it is drawn black on white at the badge's size. The full logo the Developer Policy asks for stays on the shelf |
| `bing-news` | `bing-news.svg` | `https://www.bing.com/sa/simg/favicon-trans-bg-blue-mg.svg` | Microsoft mark, nominative |
| `urban-dictionary` | `urban-dictionary.png` | `https://www.urbandictionary.com/apple-touch-icon.png` | Urban Dictionary mark, nominative, under the permission the source row records |
| `artsy` | `artsy.png` | `https://d1s2w0upia4e9w.cloudfront.net/images/apple-touch-icon.png` (artsy.net) | Artsy mark, nominative; the source is retired and the badge is for its record |
| `cinegraph` | `cinegraph.svg` | `https://cinegraph.org/favicon.ico` (a white glyph on transparency), embedded in an SVG on its own dark disc so it reads on the light badge | The sibling project's own icon |
| `poetrydb` | — | poetrydb.org publishes no icon (its `favicon.ico` is a JSON error) | Monogram |

A source with no file draws its monogram; a `logo` that is not a local path
draws nothing (`SourceBadge.logo/1`). Dark mode shows the same file on the
badge's white disc, the way a favicon shows in a dark browser tab: none of
these marks has a dark variant a badge could honour, and inverting one would
alter it, which every guideline above forbids.
