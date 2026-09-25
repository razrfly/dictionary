defmodule DevilsDictionary.Examples.Community do
  @moduledoc """
  The `community` source (#181 build 2): where a claim people make here comes
  from, when no dictionary, graph or provider made it.

  Every claim has a source (`assertions.source_id`), and a hand-curated
  exemplar is nobody's import. So a nomination seeded from a manifest, the
  person it mints and the URLs it cites all name this row: `kind: :crowd`,
  `tier: :plebs`, `access: :user`. It is appended to `Sources.Catalog.sources/0`
  the way the quotation checkers' rows are, so a fresh database has it.

  ## A URL as evidence

  `assertion_evidence` must point at a revision (`assertion_evidence_has_target`
  is a CHECK), so a bare URL cannot be evidence. `cite!/2` stores one as a
  `source_records` row under this source, keyed by the URL's digest, whose one
  revision holds only `{url, attribution, observed_at}` — never the page's text.
  That is what keeps every news source's terms trivially satisfied: the
  Guardian's clause 6(g) forbids mining its articles, and a link with a
  citation is not one (#181 S2, S5).
  """

  alias DevilsDictionary.Sources

  @slug "community"

  @doc "The source's slug."
  def slug, do: @slug

  @doc "The catalog row. Appended to `Sources.Catalog.sources/0`."
  def source_attrs do
    %{
      slug: @slug,
      name: "Dictionary community",
      tier: :plebs,
      kind: :crowd,
      access: :user,
      license: "Contributions by named accounts; cited works keep their own terms",
      homepage: "/connections",
      url_template: "/connections/{external_id}",
      attribution: "Cited by people on this site, with a reason and evidence",
      active: true,
      config: %{
        "role" => "nominations, the people they mint, and the URLs they cite",
        "retention" => "durable; a citation is a URL and an attribution, never a body",
        "writers" => "Contributions.propose/6 (form, mix dd.exemplars.seed)"
      }
    }
  end

  @doc """
  The evidence target for one cited URL: the `source_records` row under
  `community` (found or created) and its current revision. Returns
  `%{source_record_revision_id: id}`, ready for `Contributions.propose/6`.
  """
  def cite!(url, attribution) when is_binary(url) do
    source = Sources.get_source_by_slug!(@slug)

    {:ok, record} =
      Sources.upsert_record(source, %{
        external_id: digest(url),
        url: url,
        raw: %{"url" => url, "attribution" => attribution}
      })

    %{source_record_revision_id: record.current_revision.id}
  end

  @doc "The stable id a cited URL is stored under."
  def digest(url), do: :sha256 |> :crypto.hash(url) |> Base.encode16(case: :lower)
end
