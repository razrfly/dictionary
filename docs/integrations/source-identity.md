# Source identity adapters

Dictionary keeps source ingestion, durable identity, discovery relevance and
editorial interpretation as separate layers. An adapter may propose a durable
object through `DevilsDictionary.SourceIdentity.Adapter`; the shared resolver,
not the adapter, decides whether that proposal matches or creates an object.

## Required proposal fields

An eligible durable proposal declares:

- the source slug and source-record provenance;
- `object_kind` and the registry subtype (`entity_kind`, plus `work_kind` for
  works);
- one stable, namespaced source identifier;
- every exact cross-source identifier supported by that source record;
- a display label and optional description, year, language and metadata;
- explicit eligibility and retention decisions; and
- optional relationships to independently identified objects, such as an
  author or an original artwork.

The resolver only matches verified exact identifiers. Titles, years, keyword
matches and image similarity are never identity evidence. A source record whose
identifiers point to different objects, assert two exclusive values in one
namespace, or contradict the held object subtype produces an open
`external_identifier_conflict` reconciliation case and no automatic link.

Identifier values must already reflect the source adapter's rank and validity
policy. For Wikidata that means preferred statements replace normal statements,
deprecated statements are ignored, TMDb movie identifiers are positive decimal
IDs and IMDb title identifiers have the `tt` title form.

## Current implementation

CineGraph discovery results create or reuse film works from TMDb movie IDs and,
when supplied, IMDb title IDs. Wikidata film records add the Wikidata QID and
their exact P4947/P345 crosswalks. Either source may arrive first; both paths
converge on the same registry object and keep the original object ID and local
URL.

The same proposal shape represents artwork, reproductions, quotations and
creator relationships. Issue #93 intentionally implements live ingestion only
for films. Artwork and quotation fixtures verify that future adapters can reuse
the contract without treating a reproduction as its original or uncredited
wording as a durable work.

Discovery results remain provider cache rows. Resolution never turns a keyword
match into an `illustrates` claim. A film page presents automatic discovery
appearances separately from attributed, reviewable meaning connections.

## Backfilling retained CineGraph rows

The backfill is local, bounded and resumable; it does not call CineGraph and
does not merge or delete objects:

```console
mix dd.films.backfill --limit 100
mix dd.films.backfill --limit 100 --after 4200
```

The report separates matched, newly created, insufficient-evidence and
conflicting-identifier outcomes. Use the printed checkpoint for the next batch.
Rerunning a batch is safe because the same exact-identifier resolver handles
both live ingestion and backfill.
