# ADR 0002 — bounded general-entity selection

Status: accepted for issue #84 checkpoint 2. Broader providers, exhaustive
property coverage and deployment remain in #72.

## Decision

Population selection is independent of entity kind. A scope selects exactly its
member lexemes. Evidence outside a scope is processed only through an explicit,
bounded selection:

- the linker accepts positive lexeme, target-entity or source-record IDs, with
  at most 500 IDs total, and runs only identifier-backed rungs;
- Wikidata accepts at most 100 exact QIDs; it defaults to 500 requested entities,
  10 HTTP requests and two relationship tiers, and caps explicit overrides at
  5,000 entities, 100 requests and 30 tiers;
- a missing scope or empty selection is an error, never a whole-table crawl;
- selected Wikidata materialization is restricted to records visited by that
  run. Reruns skip stored records unless `refresh` is requested.

This preserves the distinction between population and evidence: Ambrose Bierce
does not need to become an Animals member for a source-published QID to connect
him, and a work with the same quality of identifier follows the same rule.
Title/name heuristics remain scope-only and never infer a person identity.

## Three source policies

### 1. Facts retained from Wikidata

The stored source snapshot retains the item QID; English and multilingual
labels; English descriptions and aliases; the English Wikipedia sitelink; and
the declared property whitelist in `Wikidata.kept_properties/0`. Statements in
that whitelist retain mainsnak, rank and statement type. The content hash is
computed from the fetched payload before trimming.

Properties outside the whitelist, qualifiers and references are intentionally
omitted from the stored operational record. They are not recoverable from that
trimmed row. Test fixtures may retain a fuller captured response. This adapter
therefore does not claim archival completeness, and neither do the other five
adapters as a group.

### 2. Facts projected into registry objects and claims

- P225 projects an entity as a taxon and supplies scientific name, rank and
  common names.
- Recognized P31 classes sharpen the no-opinion `concept` kind to person, work,
  organization, place or event. The P31/P279 IDs also remain in projected
  metadata so the classification is inspectable.
- P171, P279 and P31 project to typed relationship claims; P13176 supplies the
  everyday-concept to taxon-item bridge.
- Labels, descriptions, aliases, English Wikipedia title, image metadata,
  WordNet ILI and selected catalog IDs project to their established fields.

The verified QID resolves to an existing registry object before insert. A
sharper kind therefore updates that same object ID and preserves its names,
claims and other attachments. A locally created object without any QID remains
valid. Identical labels are never identity keys.

### 3. Related entities fetched next

A normal scoped biology pass follows only P171 and P13176, preserving its
existing taxonomy closure behavior. An explicit general-entity pass also
follows P31 and P279 so class relationships can resolve, but only within the
declared request, entity and depth budgets. Stopped walks report `truncated` and
`unresolved_references`; unresolved relationship targets are counted rather
than guessed or silently created.

Source-record revisions, materialized-output ownership and assertion provenance
remain attached to the exact records that were visited. A partial selected run
cannot reconcile outputs owned by records outside its selection.

## Consequences

The backbone can ingest and classify a small mixed-kind sample without adding
it to a lexical scope or touching unrelated stale source records. It is still a
deliberately narrow projection. Adding richer properties, preserving full
Wikidata statement evidence, or crawling provider graphs is separate #72 work.
