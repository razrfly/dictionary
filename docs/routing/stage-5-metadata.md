# Routing Stage 5: metadata, robots and sitemaps

**Status:** implemented 9 October 2026 for [#237](https://github.com/razrfly/dictionary/issues/237) (work steps 4 and 5, closing criteria C4 and C5), on the branch that stacks on the launch switch and the launch manifest. This section is written to be folded into `stage-5-publication.md` when that record is made; until then it stands alone. [ADR 0004](../adr/0004-public-routing.md) sections 6 and 7 are the contract.

## Metadata, robots and sitemaps

### The head of a reader page

Every reader LiveView sets a `:head` assign in `handle_params/3`, so the initial response and every live navigation (a `push_navigate` or a `push_patch`) compute it again. `DevilsDictionaryWeb.Head` builds it, one builder per role; the root layout renders it for the initial response, and the `PageHead` hook (`assets/js/page_head.mjs`), mounted on a hidden element the application layout renders inside every LiveView, applies it to `document.title`, the canonical link, the robots and description metas and the JSON-LD after a navigation. A LiveView that sets no head is noindex with no canonical, from both.

| Role | `<title>` | canonical | indexable |
|---|---|---|---|
| subject or edition page at its address | label and family: `Voltaire · People` | the allocated address on the published host | only published, active, at the canonical spelled exactly, in public mode with the switch on, and with no query string |
| split page (a choice) | `Several subjects` | its own address | never |
| `/on/:slug` | `On mars` | `/on/<headword slug>`, so `/on/Mars` names `/on/mars` | only as a lexical entry of the launch manifest (D1) whose subject page is published, at the listed spelling, publicly, with no query string |
| `/words/:id/:slug` | lemma and part of speech: `oyster · noun` | its own | never (D1) |
| `/entities/:id/:slug` | the label | the subject's address where the public is served one, else its own | never |
| `/evidence/<kind>/:id` | the revision: `Voltaire · revision 42` | its own | never |
| `/` and `/?q=` | the site's default | `/` | never: search is a lookup variant |
| a page that is not there (404, 410, 400) | what it says | none | never |

Every title carries the site suffix. The description is the page's first displayable sentence (`Routing.PageMetadata`): the subject's own description, else the first sentence of its first displayable biography paragraph or definition; a word page's first card; an overview's body; never text the page withholds. An indexable page carries no robots meta at all; everything else carries `<meta name="robots" content="noindex">` and still answers 200 where it would anyway, so a crawler can read the instruction. Any query string makes a page a noindex variant of its canonical: a section cursor, a trail, a provenance drawer, `?demo`, `?opening`, `?from`.

The noindex surfaces are enumerated once, in `DevilsDictionaryWeb.Indexing`. `surface/1` names the surface a router path belongs to, and a test holds every route the router serves to that list. `subject?/4` and `lexical?/3` are the two exceptions, and the only two.

### The JSON-LD (D4)

`Routing.JsonLd` emits a `WebPage` node (`@id` is the canonical plus `#page`, with `url`, `name`, `description`, `inLanguage`, `dateModified` from the sitemap's `lastmod`) and, for a subject page, a separate subject node (`#subject`) the page is `about`. The subject is typed only by the family of its allocated address, which the ledger gave it on a `mapped` decision: `Person`, `Organization`, `Place`, `Event`, `CreativeWork`, and `Thing` for Concepts, Nature and Subjects. A `Thing` carries an `additionalType` naming the Wikidata class the classification matched, only where the record says which class that was: the entity's own recorded classes (`metadata.wikidata_instance_of`) that are anchors of a rule the current decision names, or a rule's sole anchor, and only while that decision maps the subject to the page's own family. Where the rule has several anchors and the entity records no class, or a later decision names another family than the page's (a reclassification not yet moved), no additional type is claimed. A human's or the standing rule's confirmation records `editorial_override` as its rule, which anchors on nothing, so a confirmed page claims none. `sameAs` names verified external identifiers only, today the Wikidata item. Nothing is ever `schema:Nature` or `DefinedTerm`. The document is encoded HTML-safe, so no text in it can close the script element. Other reader pages carry the `WebPage` node alone.

### robots.txt

`DevilsDictionaryWeb.RobotsController` generates `/robots.txt` on every request; the static template is gone. With the switch on, the eight families are allowed by name, and so is each On page the launch manifest lists as a lexical entry while a subject page it was listed for is published; a family page's query variants are disallowed (`/<family>/*?`, longer than the family's Allow); and the sitemap index is named. With the switch off (D5), the eight families are disallowed and no sitemap is named. In both states the surfaces that are not for reading are disallowed: every reserved prefix of the namespace registry that is neither a reader's route nor a static asset (`ops`, `evidence`, `connections`, `connect`, `reconciliation`, `users`, `admin`, `health`, `s`, `kit`, `dev`, `live`, `phoenix`, `api`), and `search`, each as the path itself and everything under it (`Disallow: /ops$` and `Disallow: /ops/`), never as a bare prefix, which would keep crawlers from every path that starts with the same letters (`/s` from `/sources/` and `/sitemap.xml`); and every query variant (`/*?`). The assets a page renders with (`/assets/`, `/fonts/`, `/images/`) are allowed by name, because a longer rule wins over `/*?` and a digested production build serves them with a version query. Reader surfaces that are noindex (an unlisted On page, an exact word, the exact-identity route, a source page) are not disallowed: the crawler must fetch them to read the instruction.

The tests read the generated file as a crawler does (RFC 9309: the longest matching rule wins, an Allow wins a tie, `*` is any run of characters, `$` ends the path) against a list of URLs in both states of the switch, not line by line.

### The sitemaps

`/sitemap.xml` is a sitemap index naming `/sitemaps/subjects-N.xml`. `Routing.Sitemaps` builds them from `pages` where `publication_state = published`, the page is active, its role is subject or edition, and its canonical path, in byte order; nothing else is listed, not a draft, a withdrawn page, a retired page, an overview or an On page. Each sitemap holds at most 50,000 URLs and 50 MB uncompressed, whichever comes first; the split is pure (`chunk/2`) and unit-tested at small limits. `lastmod` is when the page's content last changed: the newest of its own current revision and the current revisions of the articles about its subject, or, where nothing dates its content, when it was published. A classification decision, a touched entity row or any other audit write never moves it.

The sitemaps are cached in the node, keyed by the newest publication receipt (`Routing.Publications.generation/0`), the newest ledger row, the newest page, content and assertion revisions (what `lastmod` reads), the switch and the origin, so a publish, a withdrawal, a move, a retirement or a changed article changes them at the next request. Every sitemap response says `noindex` in `X-Robots-Tag`. With the switch off the index is empty, still valid XML, and no sitemap exists; on again, the same answers return. The published host (`DD_PUBLISHED_HOST`) is the origin of every URL in the index, the sitemaps, the canonicals and the JSON-LD.

The lexical On entries the manifest lists are indexable but not in a sitemap: C5 asks for the sitemap to equal the set of published canonicals, and an On page is not a published page. They are reached from the subject pages' own On links.

### Tests

`test/devils_dictionary_web/head_test.exs` asserts the head of the initial response per role and the assigns and the hook element after live navigation. `indexing_test.exs` holds every router route to the enumeration and tests the two exceptions. `controllers/robots_controller_test.exs` reads the file as a crawler does in both states of the switch; `controllers/sitemap_controller_test.exs` covers both states, the cache per receipt, per route change and per content change, and the sitemap against the ledger's own set of published canonicals. `test/devils_dictionary/routing/sitemaps_test.exs` unit-tests the split and `lastmod`; `json_ld_test.exs` the typing, `sameAs`, `additionalType` and the encoding.
