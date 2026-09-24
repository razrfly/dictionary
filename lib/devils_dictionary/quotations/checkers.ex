defmodule DevilsDictionary.Quotations.Checkers do
  @moduledoc """
  The sources the quotation verifier checks against (#158 build 5), as source
  rows, so every record a check fetches has provenance and every request a
  budget.

  Five rows, two of them live. Which is which was decided by the spike's
  measurements (`docs/integrations/verifier.md`), not by preference:

    * **gutenberg** — live. A text Wikidata says the credited author wrote
      (`P50` + `P2034`), fetched once and cached.
    * **wikisource** — inactive: 0 of 3 test lines had a hit attributable to
      the credited author.
    * **internet-archive** — inactive: its items carry no identifier that ties
      a text to an author, so a hit could only count by matching a name.
    * **quote-investigator** — inactive until its author answers the
      permission email (#158 open question 3); titles and links only, ever.
    * **google-books** — inactive until a key is configured; snippets are never
      stored, only the volume id and the fact of a match.

  Wikiquote's author pages and *Misquotations* are checked through the
  `wikiquote` source row the discovery provider already owns, and Wikidata's
  answers through `wikidata`'s: one budget per host, however many callers.
  """

  @doc "The checker rows `Sources.Catalog` seeds beside the providers'."
  def source_catalog do
    [
      %{
        slug: "gutenberg",
        name: "Project Gutenberg",
        tier: :aristocracy,
        kind: :corpus,
        access: :static,
        license: "Public domain in the USA (Project Gutenberg License for the files)",
        license_url: "https://www.gutenberg.org/policy/license.html",
        homepage: "https://www.gutenberg.org/",
        url_template: "https://www.gutenberg.org/ebooks/{external_id}",
        attribution: "Project Gutenberg",
        active: true,
        config: %{
          "role" => "verification",
          "text_url" => "https://www.gutenberg.org/cache/epub/{id}/pg{id}.txt",
          "route" => "author QID -> Wikidata P50 + P2034 -> ebook text"
        }
      },
      inactive(
        "wikisource",
        "Wikisource",
        "CC BY-SA 4.0",
        "https://en.wikisource.org/",
        "https://en.wikisource.org/wiki/{external_id}",
        "measured out: 0 of 3 test lines had a hit attributable to the credited author (docs/integrations/verifier.md)"
      ),
      inactive(
        "internet-archive",
        "Internet Archive",
        "Per item",
        "https://archive.org/",
        "https://archive.org/details/{external_id}",
        "measured out: items carry no identifier tying a text to an author; a hit could only count by name"
      ),
      inactive(
        "quote-investigator",
        "Quote Investigator",
        "All rights reserved; titles and links only, by permission",
        "https://quoteinvestigator.com/",
        "https://quoteinvestigator.com/?p={external_id}",
        "waiting for the permission email to be answered (#158 open question 3)"
      ),
      inactive(
        "google-books",
        "Google Books",
        "Snippets are never stored: the volume id and the fact of a match only",
        "https://books.google.com/",
        "https://books.google.com/books?id={external_id}",
        "waiting for an API key (#158 open question 2)"
      )
    ]
  end

  defp inactive(slug, name, license, homepage, url_template, reason) do
    %{
      slug: slug,
      name: name,
      tier: :middle,
      kind: :corpus,
      access: :api,
      license: license,
      homepage: homepage,
      url_template: url_template,
      attribution: name,
      active: false,
      config: %{"role" => "verification", "inactive_because" => reason}
    }
  end

  @doc "Every checker slug, live or not, in the operator's order."
  def slugs, do: Enum.map(source_catalog(), & &1.slug)
end
