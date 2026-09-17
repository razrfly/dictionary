defmodule DevilsDictionary.Artworks.Corpus.Conformance do
  @moduledoc """
  One suite every committed corpus manifest passes (K6 of #109).

  A corpus is the second archetype: not a provider answering a page live, but a
  checksummed file in `priv/artworks/manifests/` seeded onto the registry. Its
  failure modes are different from a provider's and just as worth asserting —
  a file edited without its checksum, a seed that mints a second identity for a
  row it already holds, a title longer than `entities.preferred_label` can
  hold, and a depicted QID that never reaches the page it was collected for.

  ## Using it

      defmodule DevilsDictionary.Artworks.Corpus.Conformance.MetHighlightsTest do
        use DevilsDictionary.Artworks.Corpus.Conformance,
          manifest: "priv/artworks/manifests/met-highlights-v1.json"
      end

  The whole file is verified — checksum, row count, kind — and a bounded slice
  of it is seeded, twice, because a committed corpus is 1,644 rows and the
  assertions are about the rule rather than about the volume.
  """

  @doc "Where committed corpus manifests live, relative to the project root."
  def dir, do: "priv/artworks/manifests"

  @doc """
  Every corpus manifest on disk — the ones `Corpus.Manifest` can read.

  `priv/artworks/manifests/` also holds the Artsy pilot's import manifests
  (`DevilsDictionary.Artworks.Manifest`, `schema_version` 2), which are a
  resumable import state keyed on `qid` + `artsy_artwork_slug` and carry
  `candidates` rather than `rows`. They are a different file format in a shared
  directory, and `Corpus.Manifest.corpus_manifest?/1` is how the two are told
  apart.
  """
  def paths do
    dir()
    |> Path.join("*.json")
    |> Path.wildcard()
    |> Enum.filter(&DevilsDictionary.Artworks.Corpus.Manifest.corpus_manifest?/1)
    |> Enum.sort()
  end

  # Enough rows to prove the rule without seeding 1,644 of them in every test.
  @slice 25

  @doc "How many rows of a committed manifest the suite seeds."
  def slice, do: @slice

  defmacro __using__(opts) do
    path = Keyword.fetch!(opts, :manifest)

    quote do
      use DevilsDictionary.DataCase, async: false

      import Ecto.Query
      import DevilsDictionary.WordFixtures

      alias DevilsDictionary.Artworks
      alias DevilsDictionary.Artworks.Corpus.{Manifest, Seeder}
      alias DevilsDictionary.Claims
      alias DevilsDictionary.Discovery.MatchReason
      alias DevilsDictionary.Registry
      alias DevilsDictionary.Registry.{Entity, Object, WorkDetails}
      alias DevilsDictionary.Repo

      @path unquote(path)
      @slice DevilsDictionary.Artworks.Corpus.Conformance.slice()

      @moduletag :conformance

      setup do
        catalog = DevilsDictionary.Fixtures.seed_catalog!()
        %{sources: catalog.sources, manifest: Manifest.load!(@path)}
      end

      describe "#{Path.basename(unquote(path))} — the file" do
        test "verifies against its own committed checksum", %{manifest: manifest} do
          assert manifest["checksum"] ==
                   Manifest.checksum(Map.delete(manifest, "checksum"))

          assert manifest["row_count"] == length(manifest["rows"])
          assert manifest["kind"] in Manifest.kinds()
          assert manifest["identity"] == Manifest.identity_field(manifest["kind"])
          assert Manifest.corpus_manifest?(@path)
        end

        test "identifies every row, exactly once", %{manifest: manifest} do
          field = manifest["identity"]
          identities = Enum.map(manifest["rows"], &Map.fetch!(&1, field))

          assert Enum.all?(identities, &(is_binary(&1) and String.trim(&1) != ""))
          assert length(Enum.uniq(identities)) == length(identities)
        end

        test "refuses a row edited without its checksum", %{manifest: manifest} do
          tampered =
            Map.update!(manifest, "rows", fn [first | rest] ->
              [Map.put(first, "title", "An edit nobody re-checksummed") | rest]
            end)

          path = write(tampered)

          assert_raise ArgumentError, ~r/checksum mismatch/, fn -> Manifest.load!(path) end
        end

        test "refuses a kind the seeder has no entry for", %{manifest: manifest} do
          path =
            manifest
            |> Map.put("kind", "a-corpus-nobody-wrote")
            |> Map.delete("checksum")
            |> then(&Map.put(&1, "checksum", Manifest.checksum(&1)))
            |> write()

          assert_raise ArgumentError, ~r/unsupported artwork corpus manifest/, fn ->
            Manifest.load!(path)
          end
        end

        defp write(manifest) do
          path =
            Path.join(
              System.tmp_dir!(),
              "corpus-conformance-#{System.unique_integer([:positive])}.json"
            )

          File.write!(path, Jason.encode!(manifest))
          on_exit(fn -> File.rm(path) end)
          path
        end
      end

      describe "#{Path.basename(unquote(path))} — the seed" do
        test "is idempotent: a second run matches every row and mints nothing",
             %{manifest: manifest} do
          assert {:ok, first} = Seeder.run(manifest, limit: @slice)
          assert first.rows == @slice
          assert first.newly_created + first.matched == @slice
          assert first.invalid == 0, "invalid rows: #{inspect(first.invalid_reasons)}"

          objects = Repo.aggregate(Object, :count)
          artworks = artwork_count()

          assert {:ok, again} = Seeder.run(manifest, limit: @slice)
          assert again.matched == @slice
          assert again.newly_created == 0
          assert Repo.aggregate(Object, :count) == objects
          assert artwork_count() == artworks
        end

        test "a dry run counts what it would seed and writes nothing", %{manifest: manifest} do
          assert {:ok, summary} = Seeder.run(manifest, limit: @slice, dry_run: true)
          assert summary.would_seed == @slice
          assert artwork_count() == 0
        end

        test "every label fits entities.preferred_label, cutting the ones that do not",
             %{manifest: manifest} do
          assert {:ok, _summary} = Seeder.run(manifest, limit: @slice)

          labels =
            Repo.all(
              from entity in Entity,
                join: details in WorkDetails,
                on: details.entity_id == entity.object_id and details.work_kind == "artwork",
                select: entity.preferred_label
            )

          assert labels != []

          for label <- labels do
            assert String.length(label) <= 255
          end

          # Postgres counts characters, not bytes, and the Met's highlight
          # titles reach the column's width — 16 of 1,644 exceed it. The row is
          # kept and the label is cut, never dropped.
          long = String.duplicate("é", 300)
          row = manifest["rows"] |> List.last() |> Map.put("title", long)

          assert {:ok, summary} = Seeder.run(%{manifest | "rows" => [row]})
          assert summary.invalid == 0

          identity = Map.fetch!(row, manifest["identity"])
          namespace = namespace(manifest["kind"])
          object_id = Registry.by_external_id(namespace, identity)

          assert String.length(Repo.get!(Entity, object_id).preferred_label) == 255
        end

        test "a depicted QID reaches the page whose meaning refers to it", context do
          manifest = context.manifest

          row =
            Enum.find(manifest["rows"], fn row ->
              row |> depicted() |> Enum.any?()
            end)

          assert row, "#{@path} records no depicted QIDs, so nothing could ever match a page"

          %{"qid" => qid, "term" => term} = row |> depicted() |> List.first()

          assert {:ok, _summary} = Seeder.run(%{manifest | "rows" => [row]})

          # The other half of the round trip: the encyclopedia says this meaning
          # refers to the same QID. Identity, not text (D11).
          word = word!(context, "conformance-subject", ~w(wordnet))
          sense = sense!(context, word, "wordnet")
          entity = concept!(qid, term || "the depicted concept")
          {:ok, _} = Claims.assert(sense.object_id, "refers_to", entity.object_id, %{})

          identity = Map.fetch!(row, manifest["identity"])
          object_id = Registry.by_external_id(namespace(manifest["kind"]), identity)

          items = Artworks.shelf_items([word.object_id])

          assert item = Enum.find(items, &(&1.object_id == object_id))
          assert [%MatchReason{} = reason | _] = item.match_reasons
          assert reason.kind == :depiction
          assert reason.identifier == qid
          assert MatchReason.describe(reason) =~ qid
          assert item.preview_metadata["content_type"] == "artwork"
        end

        defp depicted(row) do
          (row["tags"] || row["depicts"] || [])
          |> Enum.filter(&(is_map(&1) and is_binary(&1["qid"])))
        end

        defp namespace("met-highlights"), do: "met_object_id"
        defp namespace("wikidata-famous"), do: "wikidata"

        defp artwork_count do
          Repo.aggregate(from(d in WorkDetails, where: d.work_kind == "artwork"), :count)
        end
      end
    end
  end
end
