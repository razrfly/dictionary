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

## Upgrade existing Wikidata entries first

Run `mix dd.films.backfill --wikidata --limit 100` and continue with the printed
`--after` checkpoint. This scans a bounded batch of allowed Wikidata source records.
Legacy film records queue deduplicated jobs through the existing enrichment worker;
these jobs fetch the fields older projections discarded, then materialize them onto
the existing Wikidata identity. Current projections are replayed locally. Counts
separate queued, current, skipped and failed records; a malformed retained record is
reported without stopping the batch, and queued does not mean completed.

Wait for enrichment jobs to succeed, inspect failures/conflicts, then run the
CineGraph backfill above. Rerunning the Wikidata phase is safe. Completed refreshes
carry a projection-version marker so a successful negative crosswalk does not cause
endless refreshes. Requests use the existing Wikimedia timeout, retry and rate-limit
handling. The version participates in the source revision hash so an unchanged
upstream payload can still upgrade an older local projection without overwriting its
historical revision. Source records not classified as films are skipped; this is a
film migration, not a full Wikidata crawl or automatic title search.

If separate objects already exist, contradictory IDs enter reconciliation rather
than being silently merged. Missing crosswalks remain valid source-backed local films.

Film image projections record their source-record evidence. Public display checks
source activation, record visibility and output retirement. Legacy posters without
that marker must be supported by an allowed record with the exact same URL. Withdrawn
posters disappear without deleting the film or its connections. Connected meanings
use the existing cursor pagination so all public relationships remain reachable.
