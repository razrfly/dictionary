# Historical draft — preserved 26 September 2026

This is retained research, not an implementation instruction or current product policy. This unmerged editorial guide predates the routing policy and curation plans. Its routing, CineGraph identity and editorial-order statements are superseded where they conflict with current code and the current design. Local links have been adjusted for the archive location. Use [the current README](../../../README.md), [routing ADR 0004](../../adr/0004-public-routing.md), and curation issues [#193](https://github.com/razrfly/dictionary/issues/193) / [#196](https://github.com/razrfly/dictionary/issues/196) for current direction. The draft text follows; only local link destinations have been adjusted.

---

# Encyclopedia model and editorial composition

The intended reader experience is an encyclopedia: look up *nepotism* or
*mountain* and get an appropriate entry assembled from useful, attributed
material. Different subjects should support different combinations of
definitions, explanations, historical commentary and cultural examples. This
does not require every source to appear forever, or Bierce and Johnson to lead
every entry.

The backend already separates identities, source material and relationships.
The reader currently assembles those records with fixed rules. **Per-entry
editorial selection of sections, items, roles and prominence is future work.**
Keeping these statements separate is essential: a sound identity model makes
editorial evolution possible; it does not implement that evolution by itself.

Discussion and follow-up scope: [issue #96](https://github.com/razrfly/dictionary/issues/96).

Verified against checkout `67be21a`, 12 September 2026. This is a code and
documentation review, not an inspection of the database records for the examples
below. Provider availability and imported coverage depend on configuration and
data. No application behavior is changed by this guide.

## Start here: terms that mean different things

| Term | Meaning in this project |
| --- | --- |
| Object | A durable local identity in `objects`, with kind `lexeme`, `sense`, `entity` or `content`. It has a typed record containing its domain fields. |
| Lexeme | A word identified by language, exact lemma and part of speech. `mountain` as an English noun is a lexical identity, not the mountain concept or a particular mountain. |
| Sense | A source-specific meaning attached to a lexeme, with its own identity and revisions. Different sources' meanings are not automatically one shared meaning. |
| Entity | A subject: person, organization, concept, event, work, edition, place, artifact, taxon or other. There is no `word` entity subtype; words are lexemes. |
| Content | An addressable piece of source material, such as an authored definition or encyclopedia article, with revisioned text. Content about a subject is distinct from that subject. |
| Assertion / connection | A typed, attributed relationship between objects, with revisions, lifecycle and review information. `defines`, `about`, `authored_by` and `published_in` express different roles. |
| Source record | An observation from a provider, with provenance and immutable payload revisions. It is neither the subject itself nor necessarily the text shown on the page. |
| External identifier | A namespaced provider identifier associated with a local object. A verified QID can identify an existing entity; a matching name alone cannot. |
| Aggregate page | A reader view assembled from several records. Both word and entity pages aggregate. An aggregate is not necessarily another stored object. |
| Editorial composition | Choosing what belongs on a particular entry, what role it plays and how prominently it appears. The flexible per-entry system described here is intended, not implemented. |
| Discovery | Provider results found using a term or mapping. A result can be useful to browse without being a reviewed example of a specific meaning. |

“Entry” is useful reader language, but can mean a whole encyclopedia page or a
single imported dictionary entry. Use “reader entry” and “source content” when
that distinction matters. “Canonical” in a route means an identity-bearing
address; it does not mean an editorially authoritative definition.

## Routes identify the starting point, not the number of sources

| Route | What it selects | What the reader gets today |
| --- | --- | --- |
| `/define/:slug` | A lexical lookup/resolver; it can match multiple lexemes and distinguish ambiguous lemmas. | `WordLive` and `WordPage` assemble source senses, content and linked subject information, or offer disambiguation/missing-word states. |
| `/words/:id/:slug` | A particular lexeme by local object ID. | The same `WordLive` and `WordPage` assembly, scoped initially to that lexeme. It remains an aggregate, not a single-source record. |
| `/entities/:id/:slug` | A subject by local object ID. | `EntityLive` and `EntityPage` aggregate its available content and relationships, with independently paged sections. |
| `/evidence/content/:id` | One content object. | Its source material and evidence context. |
| `/evidence/sense/:id` | One source sense. | Its meaning and evidence context. |
| `/evidence/source-record/:id` | One source record. | The underlying provenance record. |
| `/connections/:id` | One assertion. | Endpoints, evidence, review state and history. |
| `/sources/:slug` | A source. | Source identity, license and attribution; coverage when a population is requested. |

Calling **define the editorialized aggregate experience** is a valid product
framing. Today it is not a separate editorial object or page type from words.
The distinction is lookup versus an identified lexeme, not aggregate versus
individual definition. A resolver can collect parts of speech; the canonical
word route supplies one lexeme, so their contents need not be identical.

Slugs are readable labels, not stable identity. The exact lexical key preserves
case and punctuation; a lossy slug must not collapse `C++` into `c`. Word routes
correct a stale slug using the ID. The current missing-ID behavior falls back
to lexical lookup, so a syntactically valid word URL is not proof that its ID
resolved.

[ADR 0001](../../adr/0001-encyclopedia-model.md) describes unambiguous resolver
redirects as the decision. The current router and LiveView render resolved
lookups directly at `/define`; do not infer an automatic redirect from that ADR
sentence. Its durable-ID principle still applies. No route rename or
concept-centered routing redesign has been agreed in this discussion.

## Source material keeps its own structure

| Source | Current modeling and consequence |
| --- | --- |
| Johnson | Authored definition content, linked to words and its author/publication. Numbered senses can remain inside rendered prose blocks; they are not automatically separate registry sense objects. |
| Bierce | Authored definition content, including prose/verse treatment, with author, work and edition relationships. Satire remains attributable source material. |
| WordNet | Separate source senses grouped by synset, with lexical relations and sense-aware hierarchy traversal. Its stable source keys have an explicit identity policy. |
| Wiktionary | Separate source senses, etymological and lexical information. Positional source keys do not become durable sense identity; reconciliation handles changed/reordered meanings. |
| Wikidata | Entities, supported external identifiers and a deliberately bounded projection of properties and relationships. It supplies subject information, not a replacement dictionary definition. |
| Wikipedia | Article content about entities. Content about the word page's selected linked entity can appear on that word page as well as in the entity's content view. |

A source can number meanings without the importer making each number an
addressable sense. Conversely, two source senses can describe similar meanings
without being merged. Editorial selection must respect the granularity that
actually exists. Selecting a Johnson passage as an independently addressable
item would need a deliberate passage/identity design if the current content
object is too coarse.

The core relationships can be read as ordinary sentences:

```text
definition content --defines--> lexeme or sense
definition content --authored_by--> person
definition content --published_in--> edition
edition --edition_of--> work
work --authored_by--> person
article content --about--> entity
```

The person who authored a definition and the subject of a biography can be the
same entity ID. The authored text, the author, the work and the edition remain
different objects. There is no requirement that every entity have all these
roles or that every provider supply all this information.

## How the current reader assembles an entry

`WordLive` resolves the request, passes the selected lexemes to `WordPage.build/2`,
then prepares discovery separately. The builder:

1. Collects source senses for those lexemes and selects a primary linked entity
   for the subject panel and related content. It does not compose every entity
   potentially named by the term into one article.
2. Reads active current content connected by `defines` to the lexemes/senses,
   or by `about` to that primary entity; deduplicates content by ID and attaches
   author information.
3. Groups senses and authored content into source cards. The card order is
   fixed: source tier, then year, part-of-speech rank and source slug. Tier rank
   currently puts `aristocracy` before `middle` before `plebs`. This is a display
   policy, not a stored per-entry judgment of the best explanation.
4. Places sense-scoped lexical relations under the appropriate sense and
   broader lexical relations in the part-of-speech related-word groups. WordNet
   chains follow sense/synset structure rather than mixing all meanings of an
   intermediate word.
5. Applies presentation limits, grouping, rendered Markdown, provenance and
   navigation data. The interface is already selective in these mechanical
   ways; it is not an unlimited raw dump, and it is not yet flexible editorial
   composition.

`EntityPage` asks different relationship questions of one entity ID. A person's
page can show biography content, works and definitions authored; a work can
show editions; an edition can show contents. It also shows other incoming and
outgoing connections. Sections are conditional on available data, public claim
visibility and pagination. An entity page is therefore an aggregate too.

The deterministic choice of a source observation for a content display
projection is another distinct policy. ADR 0001's completion correction explains
why shared publication identity does not make every archived observation
interchangeable. Choosing a reproducible source text is not the same task as
choosing its prominence on a reader entry.

## Discovery and the latest identity boundary

At this checkout, automatic word-page discovery chooses a lexeme target and
uses its term and language. The relevance marker is `term`, or `term_unverified`
when the resolver page contains multiple lexemes. These are discovery labels,
not proof that the results illustrate a selected sense.

CineGraph resolves exact normalized keyword names and fetches films associated
with those provider keywords. It retains normalized previews, match details,
source references and `tmdb_movie` identifiers. Persistence can attach an
**already existing** object found through a verified external identifier; it
does not yet create a local film entity for each unmatched result. A nullable
`object_id` in a discovery result is not a completed shared-identity integration.

GIPHY currently searches directly in the browser and keeps results transient.
It does not ingest a durable GIF catalog or automatically create local GIF
entities. See the [GIPHY integration guide](../../integrations/giphy.md) for delivery,
attribution and cache settings. Film refresh scheduling and GIPHY's transient
display are provider policies; neither determines what a reviewed conceptual
example means.

[Issue #93](https://github.com/razrfly/dictionary/issues/93) specifies the next
film-first shared identity and navigation work, including supported cross-source
identifiers, eligible local entry creation and conflicts. Its live identifier
probe demonstrates available inputs, not implementation of the local resolver.
That work is not present at this guide's baseline. Recheck the implementation
when #93 lands, and update this section without conflating durable film identity
with editorial relevance. A clickable film entry can still be reached from an
unreviewed keyword match.

## Worked examples: one model, different compositions

These are illustrative traces and possible editorial outcomes, not claims
about existing `nepotism` or `mountain` records.

**Nepotism.** A lookup starts with the word's lexeme(s). If available, WordNet
and Wiktionary senses remain distinct; Johnson or Bierce text is authored
content. An article about a linked concept may add explanation. A future reader
entry might lead with a clear modern explanation, use historical commentary
lower down, and show a small selection of well-supported examples. Another
editorial choice might omit the historical material from the default view
while keeping it accessible. A claim that a person or event exemplifies nepotism
needs its own exact target, attribution, rationale and evidence. Finding the
same word in a provider search does not establish that claim.

**Mountain.** The word, the general landform concept, a particular mountain,
and a film about mountaineering are different identities. A future entry might
prioritize geographical explanation, illustrations and related landforms. It
need not use the same section mix or historical source prominence as nepotism.
A CineGraph film matched to the keyword “mountain” is a discovery candidate;
the match is not automatically an explanation of the landform or a reviewed
example of one lexical sense. A reaction GIF is likewise not conceptual
evidence merely because its search term matches.

**Ambrose Bierce.** One person identity can be the endpoint of both the
biography's `about` assertion and a definition's `authored_by` assertion. Readers
can approach him as a subject, an author or through a work. Rearranging his
definition on another entry need not create a new person or rewrite the text's
provenance. The same reasoning applies to Samuel Johnson.

## What can evolve, and what must remain accountable

The existing registry, typed relationships, source revisions, ownership and
identity reconciliation provide the foundation for presentation changes.
Source refresh can retire withdrawn support without deleting identities out
from under attachments. Local entities do not need QIDs to exist; supported
external identifiers can be added later. Bounded import selection is separate
from entity kind, as [ADR 0002](../../adr/0002-bounded-general-entity-selection.md)
explains. Its trimmed operational snapshots are not complete source archives.

The desired editorial layer should be able to choose sections, select items,
assign roles such as explanation or historical commentary, and vary prominence
per entry. Source provenance should survive those choices. Hiding a source in
the default composition should not erase it, merge it with another source, or
claim that an editor authored its definition. A featured item must still obey
withdrawal and visibility rules.

Existing assertion review is not proof that section composition, passage
selection or per-entry ordering is implemented. Future work must decide:

- What a composition targets: a lexeme, source sense, entity, a grouping of
  these, or another explicitly designed editorial identity.
- Which item granularities can be selected, and whether excerpts need stable
  passage references.
- How default rules and per-entry overrides interact, including empty entries,
  alternate meanings and access to omitted source material.
- Who can edit/review compositions, how decisions are versioned, and how source
  changes, identity reconciliation and withdrawal affect selections.
- Whether any route changes improve the reader experience. Concept-centered
  routing was a proposal, not an accepted requirement; neither a new editorial
  object schema nor a route rename is settled.

These are design choices to resolve through focused follow-ups, not reasons to
replace the registry or permanently freeze the current source order.

## Documentation map and code references

The root [README](../../../README.md) is the living project record, but contains
dated milestones and historical schema sketches. Its “not Wikipedia” statement
describes source storage/authorship limits, not a prohibition on an
encyclopedia-like reader experience. “Every word, every source” should not be
read as requiring every source card in every future default entry.

| Existing documentation | How to use it |
| --- | --- |
| [ADR 0001](../../adr/0001-encyclopedia-model.md), [ADR 0002](../../adr/0002-bounded-general-entity-selection.md) | Accepted identity/assertion and bounded-selection decisions. Read completion amendments as well as initial decisions. |
| [Rebuild completion](../../rebuild/completion-2026-09-09.md), [connection reliability](../../rebuild/issue-84-connection-reliability-2026-09-11.md) | Implementation evidence and limitations for the current foundation. |
| [Map README](../../map/README.md) | Earlier product-layer explanation and nepotism trace. Its old table names are historical; use the registry model above for current implementation. |
| [Gate 0 README](../../spikes/2026-09-gate0/README.md), [rebuild W1 README](../../rebuild/w1-2026-09-10/README.md) | Dated experiments and validation evidence. |
| [Mobile README](../../mobile/README.md), [sketches README](../../sketches/README.md), [audit reports](../../audits/2026-09-11-mvp-closeout/README.md) | Specific historical checks and retired sketches, not current composition specifications. |
| [GIPHY guide](../../integrations/giphy.md), [discovery handoff](../../discovery/issue-88-handoff-2026-09-12.md) | Provider behavior and discovery delivery context; verify older snapshots against current code. |

Implementation reading order: [registry schemas](../../../lib/devils_dictionary/registry/),
[lexical lookup](../../../lib/devils_dictionary/lexicon.ex),
[router](../../../lib/devils_dictionary_web/router.ex),
[WordLive](../../../lib/devils_dictionary_web/live/word_live.ex),
[WordPage](../../../lib/devils_dictionary/lexicon/word_page.ex),
[EntityPage](../../../lib/devils_dictionary/encyclopedia/entity_page.ex),
[source adapters](../../../lib/devils_dictionary/absorb/sources/), then
[discovery](../../../lib/devils_dictionary/discovery.ex).

Related product work: [#64 vision](https://github.com/razrfly/dictionary/issues/64),
[#66 reader design](https://github.com/razrfly/dictionary/issues/66),
[#85 curated culture](https://github.com/razrfly/dictionary/issues/85) and
[#93 shared provider identities](https://github.com/razrfly/dictionary/issues/93).
Their older proposals and unchecked acceptance criteria are not evidence that
the corresponding functionality is already implemented.
