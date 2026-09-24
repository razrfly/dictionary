defmodule DevilsDictionary.Quotations.Corpus do
  @moduledoc """
  `wikiquote-pd-v1`, the public-domain Wikiquote corpus (#174, build 6 of #158),
  once it is built: its source row, what seeding one line writes beyond the
  identity, and (on the Quotes shelf) how a page finds its lines.

  The manifest is built by `Quotations.Corpus.Build` and committed at
  `priv/quotes/manifests/wikiquote-pd-v1.json`. `Corpus.Seeder` seeds it the
  way it seeds the artworks corpora: each row is a `SourceIdentity.Entry` in
  the shape the live Wikiquote provider writes, `content/quotation` credited
  `authored_by` by QID. The one difference is the stable identifier. A live
  line's is `wikiquote_item`, a hash of the page, section and position, and
  that is a position **on today's page**. The corpus pins a revision, so a
  position it proposed could name a different line on the page a visit reads.
  The corpus's stable identifier is therefore the line's
  `quotation_fingerprint` (ADR 0003), the identifier a second source's copy
  folds on, and a corpus line and a live line with one wording are one
  subject whichever arrived first.

  ## What seeding a line writes (`seed_row/3`)

    * **a source record** under `wikiquote-pd-v1`, keyed by the fingerprint,
      whose payload is the manifest row. It is the entry's provenance, and
      what the evidence cites.
    * **the identity**, through `SourceIdentity.resolve/2`, with the author
      prepared from the manifest's own Wikidata facts (`Creators.classify/2`
      over `selection.authors`). No request is made at seed time.
    * **evidence** on the corpus's `authored_by`: one `:supports` row per
      check the build recorded (the Gutenberg text at its line, and the
      author's own Wikiquote page where it lists the line), each citing the
      record above. Added once.
    * **the badge**, on `content_items.metadata["provenance"]`, only when the
      item has none. An item another source already holds may have been
      through the verifier, whose pass is the item's and now counts this
      credit too. Its clock recomputes the badge; the corpus does not
      overwrite it.

  Nothing is refreshed and nothing is swept. The source record is referenced
  by evidence and by the item's revision, and cleanup never takes a record
  something durable stands on (`Discovery.purge_results/1`).
  """

  import Ecto.Query

  alias DevilsDictionary.Claims
  alias DevilsDictionary.Claims.{Assertion, AssertionEvidence, AssertionRevision, Predicate}
  alias DevilsDictionary.Corpus.SourceRecordRevision
  alias DevilsDictionary.Quotations.Badge
  alias DevilsDictionary.Registry.ContentItem
  alias DevilsDictionary.Repo
  alias DevilsDictionary.SourceIdentity
  alias DevilsDictionary.SourceIdentity.Creators
  alias DevilsDictionary.Sources
  alias DevilsDictionary.Sources.SourceRecord

  @slug "wikiquote-pd-v1"
  @manifest_path "priv/quotes/manifests/wikiquote-pd-v1.json"
  @dump_url "https://dumps.wikimedia.org/enwikiquote/20260901/"
  @license "CC BY-SA 4.0"
  @license_url "https://creativecommons.org/licenses/by-sa/4.0/"

  @external_resource @manifest_path

  # The committed manifest's own checksums, read at compile time: the source
  # row names the file it is, and recompiles when the file changes.
  @checksums (case File.read(@manifest_path) do
                {:ok, body} ->
                  manifest = Jason.decode!(body)

                  %{
                    "manifest_checksum" => manifest["checksum"],
                    "set_checksum" => manifest["set_checksum"],
                    "generated_at" => manifest["generated_at"],
                    "row_count" => manifest["row_count"]
                  }

                {:error, _} ->
                  %{}
              end)

  @doc "The corpus's source slug."
  def slug, do: @slug

  @doc "Where the committed manifest lives."
  def manifest_path, do: @manifest_path

  @doc """
  The source row (#174 design 2): 👑 tier, `access: :dump`, CC BY-SA 4.0, and
  the manifest checksum in its config. Appended to `Sources.Catalog.sources/0`.
  """
  def source_attrs do
    %{
      slug: @slug,
      name: "Wikiquote, public domain",
      tier: :aristocracy,
      kind: :corpus,
      access: :dump,
      license: @license,
      license_url: @license_url,
      homepage: "https://en.wikiquote.org/",
      logo: "/images/sources/wikiquote.png",
      url_template: "https://en.wikiquote.org/wiki/{title}",
      attribution: "Wikiquote contributors (CC BY-SA 4.0)",
      active: true,
      config:
        Map.merge(
          %{
            "mode" => "committed corpus; no request is made at seed or read time",
            "manifest" => @manifest_path,
            "dump_url" => @dump_url,
            "built_by" => "mix dd.quotes.corpus.build",
            "kept" => "Verified by build 5's checks against a pre-1931 Gutenberg text",
            "retention" => "durable; never refreshed, never swept"
          },
          @checksums
        )
    }
  end

  # ── seeding ───────────────────────────────────────────────────────────────

  @doc """
  What every row of one manifest shares: the source row, and each author's
  prepared outcome for `Creators`, read from the manifest's own facts.
  """
  def seed_context(manifest) do
    authors = get_in(manifest, ["selection", "authors"]) || %{}

    %{
      source: Sources.get_source_by_slug!(@slug),
      prepared:
        Map.new(authors, fn {qid, entity} -> {qid, Creators.classify(qid, %{qid => entity})} end),
      generated_at: manifest["generated_at"],
      manifest: manifest["manifest"]
    }
  end

  @doc """
  Seeds one row whose entry `Corpus.Seeder.entry/3` built. Returns the
  resolution.
  """
  def seed_row(entry, row, context) do
    {:ok, resolution} =
      Repo.transaction(fn ->
        {:ok, record} =
          Sources.upsert_record(context.source, %{
            external_id: row["fingerprint"],
            url: row["source_url"],
            raw: row
          })

        resolution =
          entry
          |> Map.merge(%{
            source_id: context.source.id,
            source_record_id: record.id,
            source_record_revision_id: record.current_revision.id
          })
          |> SourceIdentity.resolve(prepared: context.prepared)

        if resolution.state in [:matched, :newly_created] and is_integer(resolution.object_id) do
          evidence!(resolution.object_id, row, record.current_revision.id, context.source.id)
          provenance!(resolution.object_id, row, context)
        end

        resolution
      end)

    resolution
  end

  defp evidence!(content_id, row, record_revision_id, source_id) do
    revision =
      Repo.one(
        from r in AssertionRevision,
          join: a in Assertion,
          on: a.id == r.assertion_id and a.source_id == ^source_id,
          join: p in Predicate,
          on: p.id == r.predicate_id and p.key == "authored_by",
          where: r.subject_object_id == ^content_id and r.is_current,
          order_by: [desc: r.id],
          limit: 1
      )

    if revision do
      for check <- row["checks"] || [], check["role"] == "supports" do
        locator = String.slice(to_string(check["locator"]), 0, 255)

        held? =
          Repo.exists?(
            from e in AssertionEvidence,
              where:
                e.assertion_revision_id == ^revision.id and
                  e.source_record_revision_id == ^record_revision_id and e.locator == ^locator
          )

        unless held? do
          {:ok, _} =
            Claims.add_evidence(revision.id, %{
              evidence_role: :supports,
              source_record_revision_id: record_revision_id,
              locator: locator,
              attribution_text: attribution(check, row)
            })
        end
      end
    end
  end

  defp attribution(%{"kind" => "primary"}, row),
    do:
      "Project Gutenberg ##{row["gutenberg"]["ebook"]}, #{row["work_label"]} (#{row["work_year"]})"

  defp attribution(%{"source" => "wikiquote"}, row),
    do: "Wikiquote, #{row["author_label"]}'s own page"

  defp attribution(check, _row), do: check["source"]

  defp provenance!(content_id, row, context) do
    item = Repo.get!(ContentItem, content_id)

    if is_nil((item.metadata || %{})["provenance"]) do
      provenance = %{
        "badge" => row["badge"],
        "score" => row["score"],
        "agreements" => row["agreements"],
        "sources" => row["sources"],
        "computed_at" => context.generated_at,
        "verifier_version" => Badge.version(),
        "computed_by" => context.manifest
      }

      item
      |> ContentItem.changeset(%{
        metadata: Map.put(item.metadata || %{}, "provenance", provenance)
      })
      |> Repo.update!()
    end
  end

  # ── reading ───────────────────────────────────────────────────────────────

  @doc """
  The seeded rows whose concepts are among `qids`, as the manifest wrote them,
  with each row's `object_id` (the content item its fingerprint resolves to).
  Read from the corpus's own source records, so a page asks the registry for
  what was seeded and never reads the file.
  """
  def rows_for_concepts([]), do: []

  def rows_for_concepts(qids) when is_list(qids) do
    Repo.all(
      from r in SourceRecord,
        join: s in assoc(r, :source),
        join: rev in SourceRecordRevision,
        on: rev.source_record_id == r.id and rev.revision_key == r.content_hash,
        where:
          s.slug == @slug and s.active and
            fragment("? \\?| ?", rev.payload["concept_qids"], type(^qids, {:array, :string})),
        order_by: [asc: r.external_id],
        select: {rev.payload, r.id}
    )
    |> Enum.map(fn {row, _record_id} ->
      Map.put(
        row,
        "object_id",
        DevilsDictionary.Registry.by_external_id("quotation_fingerprint", row["fingerprint"])
      )
    end)
  end
end
