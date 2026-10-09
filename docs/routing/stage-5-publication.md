# Routing Stage 5: publication behind a switch, metadata, and the release

**Status:** implemented and released on the owner's working installation on 9 October 2026 under [#237](https://github.com/razrfly/dictionary/issues/237), the last issue of [#194](https://github.com/razrfly/dictionary/issues/194). [ADR 0004](../adr/0004-public-routing.md) sections 6, 7 and 8 (step 6) are the contract. The pull requests are [#248](https://github.com/razrfly/dictionary/pull/248) (a word page the crawl found failing), [#249](https://github.com/razrfly/dictionary/pull/249) (this record), [#242](https://github.com/razrfly/dictionary/pull/242) (the standing review rule), [#243](https://github.com/razrfly/dictionary/pull/243) (publication), [#244](https://github.com/razrfly/dictionary/pull/244) (the launch manifest, the switch and the published host), [#246](https://github.com/razrfly/dictionary/pull/246) (metadata, robots and sitemaps), [#247](https://github.com/razrfly/dictionary/pull/247) (what the published host shows through the tunnel) and [#245](https://github.com/razrfly/dictionary/pull/245) (the reviewer's tool). Each was audited independently and checked again at its final head before it merged.

## The owner's rule: no human decides a record

On 8 October 2026 the owner set the rule this stage is built on: no human reviews rows again. The owner signs one **standing review rule** once (`priv/routing/review-rule.json`, digest `1564626c…e46883`, signed 2026-10-09T15:48:23Z, recorded in `review_rule_signatures` on the working database). Under it the backfill keeps every decision the owner made in #224 (124 confirmations and 5 deferrals, read back from the ledger), confirms what the rule's clauses can decide from the evidence, and defers the rest, visibly. From the evidence alone it reproduces 96 of the owner's confirmations and all 5 of the owner's deferrals, and it never confirms a record the owner deferred. On a widened population of 571 records on a disposable copy of the corpus it allocated 420, deferred 109 and left 42 not addressed, with nobody touching a row ([the backfill under the rule](stage-2/backfill.md#under-the-standing-review-rule-237)). The rule, its clauses and its readability floor are recorded with the backfill ([under the standing review rule](stage-2/backfill.md#under-the-standing-review-rule-237)). A human publishes only as an override, recorded as such on every receipt.

## Publication: the record and the eight gates (C1)

A page is published only through `Routing.Publications.publish/3`, which checks ADR §7's eight gates against the record at the moment of publishing and refuses per page, never rolling back the batch:

| gate | passes when |
|---|---|
| `identity` | the page is active, and its registry object is active: not merged, split or retired |
| `decision` | the object's current classification decision is `mapped` to the family of the page's address (an edition's is `works`), the evaluator's or a standing override |
| `canonical` | the page holds a canonical address, it is the one the manifest names, and the resolver serves the page there |
| `content` | the page renders at least one section the entity actually has (a biography paragraph, a work, a definition, a quotation, an edition, an edition's contents) whose text may be shown; a label and an imported description alone fail |
| `display` | every body the page renders passes `Claims.Visibility` |
| `approval` | the page is in the manifest under a reviewer's name; under the standing rule, the manifest was made under that signed rule, the reviewer is its signer, and a confirming clause decided the record |
| `metadata` | a title, the canonical address and a description are derivable (`Routing.PageMetadata`) |
| `integrity` | the routing schema is present, the page and every address it serves resolve without corrupt state, and it has exactly one canonical |

A page that passes gets a receipt in `page_publications`: the manifest's digest, the rule's digest, the eight gates as found, the human actor and the reason. Its `publication_state` becomes `published` in the same transaction, and a trigger refuses the change without the receipt. The table is append-only. Publishing is idempotent. `withdraw/3` is a reviewer's reverse: a withdrawn page answers 404 publicly (410 is only for retirement) and stays withdrawn until a human republishes it with a reason. Publishing moves no address and writes no `route_changes` row.

## The launch manifest (C2)

`priv/routing/launch-manifest.json` is what the application publishes from. The signed rule generates it from #224's candidate manifest and its population, reading only, and nobody writes it by hand:

```
DD_NO_OBAN=1 mix dd.routing.publish --rule priv/routing/review-rule.json \
  --from test/fixtures/routing/cp4-224/manifest-rev1.json \
  --population docs/routing/stage-2/candidates.json \
  --write-manifest priv/routing/launch-manifest.json
```

| | |
|---|---|
| SHA-256 | `939e1aac24e068831acedaafee874f5d5048a829c2ad8d6f9421231490ee70ba` |
| Made from | `manifest-rev1.json`, `12384745…`, run `9639fc28…` |
| Page entries | 124, each a `standing_decision` of the owner's |
| Lexical entries (D1) | 56 On pages whose words refer to a confirmed subject |
| Deferred | 46: the owner's 5 and 41 records #224 did not address |

`LaunchManifest.read/1` checks its shape, `validate/2` checks every page entry against the ledger and the accounts, and `bound_to_rule/1` refuses a manifest that names the rule but is not the rule's: every page entry must be an allocation of the run it names, and the lexical entries must be exactly the rule's derivation from the corpus. `mix dd.routing.publish --manifest priv/routing/launch-manifest.json [--dry-run] [--receipts OUT]` publishes every entry that passes the gates, prints each refusal with its gate and reason, and is idempotent.

## The launch switch and the published host (C3, C7)

**The switch (D5).** `config :devils_dictionary, :public_routing` is `false` by default and pinned off in production. It is on only on the published host. Off, the resolver withholds every page in public mode: the eight family routes answer 404, public links fall back, the sitemap index is empty with `noindex`, and robots.txt disallows the families. The ledger is untouched either way, and internal reading ignores the switch. `DD_PUBLIC_ROUTING=off` is the rollback, and any value but `on` or `off` refuses to boot.

**The published host (D2).** The owner's development server becomes the published host when its launch script sets `DD_PUBLISHED_HOST` (`wordhoard.eu.ngrok.io`, served through the ngrok tunnel to `127.0.0.1:4007`). Then:

- it reads publicly for everyone; only an authenticated reviewer or contributor reads internally, drafts included, whatever development configures;
- its canonical URLs, sitemaps and JSON-LD name `https://wordhoard.eu.ngrok.io`;
- it requires its own `DD_SECRET_KEY_BASE` (at least 64 bytes, kept in a file outside the repository that only the owner can read), so nobody can sign its sessions or LiveView tokens with the development secret in `config/dev.exs`;
- it is compiled without the code reloader, the repository check and the debug error pages (`config/dev.exs`), so no stack trace, route table, compile error or "run migrations" action reaches the tunnel;
- it injects no live reloader, and its sockets accept only its own pages' origin and the owner's machine.

**What the tunnel reaches.** `DevilsDictionaryWeb.ProxyGuard` runs after the static files (public assets only), the dashboard's request logger, the request id and telemetry, and before the parsers, the session and the router. A request came through a proxy when it carries `X-Forwarded-For`, `Forwarded`, `X-Forwarded-Host` or `X-Forwarded-Proto`, or when its peer is not the loopback; ngrok always sets the first. On the published host such a request gets 404 for every operator surface: `/dev/*` (the mailbox and the dashboard), `/kit`, `/ops/*`, and the retired `/s/*`, `/health` and `/admin/*`. The owner still reaches all of them on the machine itself. A server that reads drafts and is not the published host answers 503 to every proxied request that reaches the guard. That server is the owner's ordinary development build, though, whose debug pages, live reloader, code reloader and repository check answer before the guard: a pending migration or a compile error in the checkout would still show through the tunnel. Keep the tunnel off a server that is not the published host. The endpoint dispatches its sockets before any plug, so the guard's rule is applied there too:

- `DevilsDictionaryWeb.LiveSocket` refuses a proxied socket on a draft-reading server that is not the published host;
- the operator LiveViews mount in their own live sessions under `on_mount({ProxyGuard, :operator})`, so a reader page cannot live-navigate to them without a request, and a proxied socket that reaches one on the published host is not mounted;
- `DevilsDictionaryWeb.LiveReloadSocket` answers only the owner's machine, on every server.

**Links on the published host.** In public reading there, a subject is linked only at an address the host serves. Every other subject is named as text: `Routing.Links` returns no path, `Kit.subject_link/1` renders a `<span>`, and nothing renders `<a href="#">`. The exact-identity route `/entities/:id/:slug` answers 404 there for an entity whose subject or edition page the host does not serve (a draft, a withdrawn page, any page while the switch is off), and a family address whose page's identity was merged into such a survivor is 404 as well. An entity with no page, or whose page is served, still reads at its identity. The footer's operations links are hidden there. Off the published host, and in internal reading on it, links and the identity route behave as #219 built them.

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

## The reviewer's tool (Part B, C9)

`mix dd.routing.route` performs one of the ledger's six operations (move, merge, split, retire, restore, rollback) under a named reviewer with a reason, and prints the launch switch it reads under, the resolver's answers before and after, and every row it wrote. It is recorded beside the Stage 1 record ([the reviewer's tool](stage-1-foundation.md#the-reviewers-tool)). C9's proof ran on a restored copy of the step-0 bundle, never on the working corpus, as the owner decided (#237, 9 October 2026).

## The release on the working installation (C6)

9 October 2026, from `main` at `5ffd551` (after #247), on `devils_dictionary_v2`, the owner's working corpus on port 5434. Every step is logged in the private evidence (`private/2026-10-09-stage5/`, which is `private/2026-10-09-237/`) by `release/s237-release.sh`. Every request of the HTTP table is kept with its response headers and body, and in its second run (`on4`, `off2`, `on5`) with the request's own headers too.

**Publication.** The receipts are the only rows the release wrote.

| Step | Result | Write counters (insert / update / delete) |
|---|---|---|
| Dry run | 114 would publish, 10 refused | 31,131,458 / 15,623,395 / 2,480,380, unchanged |
| Publish | 114 published, 10 refused | +114 / +114 / 0: the receipts and the pages' state |
| Publish again | 0 published, 114 unchanged, 10 refused | unchanged |

`route_changes` stayed at 248 rows and `public_paths` at 124, with the same content digest before and after. The ten refusals are recorded, and no gate was relaxed:

| Page | Address | Gate |
|---|---|---|
| 2 | `/works/the-devils-dictionary-gutenberg-972` | metadata: no description can be derived |
| 3 | `/works/johnsons-dictionary-1755-leme-transcription` | metadata |
| 15 | `/works/crocodile-tears-novel` | content: a label and an imported description alone |
| 107 | `/events/apollo-11` | content |
| 108 | `/works/the-parsonage-garden-at-nuenen` | content and metadata |
| 110 | `/works/the-devils-dictionary` | metadata |
| 135 | `/nature/felis-catus` | content |
| 162 | `/nature/laris` | content |
| 229 | `/places/warsaw` | content |
| 230 | `/organizations/wikimedia-foundation` | content |

**The published host.** The server's launch script (`~/Library/Application Support/dictionary/phx-4007.sh`, outside the repository) now sets `DD_PUBLISHED_HOST=wordhoard.eu.ngrok.io`, `DD_PUBLIC_ROUTING=on`, `DD_SECRET_KEY_BASE` from a file only the owner can read, `DD_NO_OBAN=1` and `MIX_BUILD_ROOT` (the checkout's ignored `_build/published`). It refuses to start while `mix ecto.migrations` reports a migration pending (if that command itself fails, it starts). Its LaunchAgent was restarted, and the server answered 24 seconds later. The original script is kept beside it as `phx-4007.sh.before-237`. `DD_NO_OBAN=1` keeps the queues and cron off on the working database; the owner can remove it to run them again.

**The HTTP table**, through `https://wordhoard.eu.ngrok.io` with the switch on, and the same requests after the rollback turned it off. With the switch on again, every answer was identical to the first column. The sequence was run twice, with the same answers: first on `5ffd551`, then (`on4`, `off2`, `on5`) on `85e180b`, after #248.

| Request | Switch on | Switch off |
|---|---|---|
| `GET /people/ambrose-bierce` | 200, one canonical (`https://wordhoard.eu.ngrok.io/people/ambrose-bierce`), indexable | 404 |
| `GET /works/mona-lisa` | 200, one canonical, indexable | 404 |
| `GET /concepts/love` | 200, one canonical, indexable | 404 |
| `GET /nature/mars` | 200, one canonical, indexable | 404 |
| `HEAD` of the four | 200 | 404 |
| `GET /nature/Mars`, `/nature/mars/` | 301 to `/nature/mars` | 404 |
| `GET /places/warsaw`, `/works/the-devils-dictionary` (drafts in the population) | 404, noindex | 404 |
| `GET /people/nobody-at-all-237` (not in the population) | 404, noindex | 404 |
| `GET /people/a%2Fb` (malformed) | 400 | 400 |
| `GET /on/love`, `/on/bierce` (listed lexical entries, D1) | 200, indexable | 200 |
| `GET /on/the` (not listed) | 200, noindex | 200 |
| `GET /entities/1/ambrose-bierce` | 200, noindex, canonical `/people/ambrose-bierce` | 404 |
| `GET /dev/mailbox`, `/ops/health`, `/kit` | 404 | 404 |
| `GET /sitemap.xml` | the index, naming `subjects-1.xml` | an empty index, `noindex` |

`/people/%zz` never reaches the server: ngrok's edge answers it 400 itself over HTTP/1.1 and refuses it over HTTP/2. The application answers it 400 on the loopback.

The same drafts read internally, through the same endpoint and database in the development configuration (dispatched in-process, so no session row was written): 200 with the draft mark and noindex.

**Sitemaps and robots.** `/sitemap.xml` names one sitemap, which lists 114 URLs, exactly the published canonicals in the ledger. Both files are well-formed XML and carry `X-Robots-Tag: noindex`. robots.txt allows the eight families and 51 of the manifest's 56 On pages; the other five rest only on refused pages. Of the 51, 49 are indexable: `/on/everest` and `/on/humans` serve noindex, because their canonical is their headword's slug (`/on/mount-everest`, `/on/human`), not the listed spelling. It disallows every operator prefix as a path and everything under it, every family's query variants and `/*?`, and names the sitemap. With the switch off it disallows the families and names no sitemap.

**JSON-LD.** On eight live pages (a person, a work, a concept, a nature subject, an event, a place, an organization and an On page) every block parses, names `https://schema.org`, and uses only properties schema.org defines for its type: `WebPage` with `about` the subject node, typed `Person`, `CreativeWork`, `Thing`, `Event`, `Place` or `Organization` by family. `json_ld_test.exs` holds the same rules offline. The Schema.org validator's own run (`https://validator.schema.org/#url=https%3A%2F%2Fwordhoard.eu.ngrok.io%2Fpeople%2Fambrose-bierce`) is one click for the owner.

**Rollback.** `DD_PUBLIC_ROUTING=off` in the launch script and a restart: every family address answered 404, the identity route of a published subject 404, the sitemap index was empty, and robots.txt disallowed the families. The ledger was unchanged: 124 pages, 114 published, 124 addresses, 248 route changes, 114 receipts, one signing, and the same address digest before the release, after it, while off and on again. Switched back on, the HTTP table was identical, field for field.

**The crawl.** Every link on every published page, fetched through the tunnel, and every page it links fetched once in turn:

| Crawl | Published pages | Distinct links | Answers | `/entities/`, `#`, operator link or draft mark |
|---|---|---|---|---|
| Paced, on `5ffd551` | 114, all 200 | 527 | 496 × 200, 31 × 500 (24 exact words, 7 On pages) | none (its file lists `/connections/` links, flagged by a crawler that matched `/connect` as a prefix, since corrected) |
| Final, on `85e180b` | 114, all 200 | 524 | 524 × 200 | none |

The 500s were an older defect the crawl reached: a word with candidate subjects but no primary concept crashed its exact-word and On pages. [#248](https://github.com/razrfly/dictionary/pull/248) fixed it, and its audit found a concept with no Wikidata item crashing the provenance drawer, fixed there too; the server was restarted on it before the final crawl. An earlier unpaced crawl met ngrok's edge rate limit (390 of its fetches failed), so the crawler fetches one address at a time with a pause and retries. Two published pages the final crawl could not fetch through the edge were fetched again: 200, with 67 links, all 200 and none of the four.

Every response the tunnel passed from the server carried `X-Robots-Tag: noindex, nofollow`, added by ngrok's edge: the application sends no such header with a page, as a request on the loopback shows. A crawler that obeys the header indexes nothing through this tunnel, whatever the pages say. Whether an ngrok setting or a domain of the owner's own lifts it is for the owner to decide.

## Rollback

- **Turn the public routes off.** Set `DD_PUBLIC_ROUTING=off` in the server's launch script and restart its LaunchAgent. The families answer 404, the sitemap index is empty, the ledger is untouched. Set it back to `on` and the same answers return. The release proved both.
- **Take one page down.** `Routing.Publications.withdraw/3`, a reviewer's act with a reason, recorded as a receipt: the page answers 404 publicly.
- **Stop serving the public.** Boot the server's LaunchAgent out; the tunnel answers 502. Do not restart it without `DD_PUBLISHED_HOST` while the tunnel runs: its guard answers 503 to what reaches it, but that development build's debug pages answer first.
- **Restore the corpus.** The bundle `2026-10-09-v2-released` (`/Volumes/LLM Models/dictionary/bundles/`, on the same volume as the database, with no second copy yet), taken after the release and verified (MANIFEST `8247e0c98a50e2e43e11aacdd8a7ebbdc1aaba7ee968992171fc49ab5fbf1444`), is the restore point, with `docs/routing/recovery.md`'s procedure. It holds the owner's signing and the 114 receipts. The step-0 bundle (`c3a842e9…7f6029`) predates both and would drop them. `page_publications` and `review_rule_signatures` are durable tables: a restore carries them, and the schema's down migrations refuse while they hold rows.

## Known limits

- **The published host is a development server** reached through a tunnel, not a production deployment. Production keeps the switch pinned off and reads none of the published host's variables; a production launch is its own decision.
- **`--actor` is asserted, not authenticated** in `mix dd.routing.route`, and a publication's human actor is the rule's signer by configuration. Anyone with a shell and the database can name a reviewer.
- **Unpublished subjects are named on public pages.** On the published host an unpublished subject appears as text, and an On page's Subjects card still says "Not yet public", names its decided family and shows its one-line registry description, as #219 designed. A source page lists its own entries, including an article about a subject whose page is a draft. Neither is a draft mark, a link or the draft page itself; whether either belongs on public pages is the owner's to decide.
- **A registry merge after launch** can join a published identity to one whose page is a draft or withdrawn. The published host then withholds both, at their identities and at the retired page's address, but nothing refuses the registry merge itself, and the links and the sitemap still name the retired page's address, which then answers 404 until the ledger merges or retires the page (`mix dd.routing.route`).
- **Event pages** are valid schema.org Events but carry no `startDate` or `location`, which Google's Event rich results require.
- **Withdrawal has no task.** `Routing.Publications.withdraw/3` is a reviewer's act from `iex` or code; `mix dd.routing.publish` publishes only.
- **Registration is open on the published host.** `/users/register` is reachable through the tunnel and creates an account on the working database, as it did before #237. The mailbox that would confirm it is not reachable there.
- **A word's thing drawer** keys its link rows on the Wikidata QID, so two linked things with no QID share a row id, and two at the same confidence show as one (#248's final check, N-4). No page fails for it; the fix is to key on the object id where there is no QID.
