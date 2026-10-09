defmodule DevilsDictionary.Routing.LaunchManifestGenerationTest do
  @moduledoc """
  The committed launch manifest (#237 C2): `priv/routing/launch-manifest.json`
  is the standing review rule's, generated from #224's candidate launch
  manifest (`manifest-rev1.json`, SHA-256 `12384745…`), never written by
  hand. This test derives it again from the same files — the backfill
  manifest, its population, the committed rule — and requires the committed
  file to be exactly what the rule makes: bound to both digests, every page
  entry the rule's, nothing the rule deferred, and every lexical entry tied
  to a page entry. The ledger half (each page holds that canonical; the
  reviewer is a reviewer account) is `LaunchManifest.validate/2`'s, checked
  when the file is generated and again by every publication.
  """
  use ExUnit.Case, async: true

  alias DevilsDictionary.Routing.{AuditSnapshot, LaunchManifest, ReviewRule}

  @fixtures Path.expand("../../fixtures/routing/cp4-224", __DIR__)
  @population Path.expand("../../../docs/routing/stage-2/candidates.json", __DIR__)
  @launch Path.expand("../../../priv/routing/launch-manifest.json", __DIR__)

  @from_sha256 "12384745ff3b34bc2ef793e2a3f5e5e33a28cdd12dc564be0767873faee3fb6e"

  setup_all do
    from_bytes = File.read!(Path.join(@fixtures, "manifest-rev1.json"))
    population_bytes = File.read!(@population)
    owner = @fixtures |> Path.join("reviews-owner.json") |> File.read!() |> Jason.decode!()
    {:ok, rule} = ReviewRule.read(ReviewRule.path())

    from = %{
      doc: Jason.decode!(from_bytes),
      sha256: AuditSnapshot.digest(from_bytes),
      file: "manifest-rev1.json"
    }

    population = %{
      doc: Jason.decode!(population_bytes),
      sha256: AuditSnapshot.digest(population_bytes)
    }

    %{
      from: from,
      population: population,
      rule: rule,
      owner: Map.new(owner["reviews"], &{&1["object_id"], &1}),
      signer: hd(owner["reviews"])["reviewer"]
    }
  end

  defp plain(value), do: value |> Jason.encode!() |> Jason.decode!()

  test "the rule makes the owner's 124 pages from #224's candidate launch manifest", ctx do
    assert ctx.from.sha256 == @from_sha256
    assert get_in(ctx.from.doc, ["inputs", "population_sha256"]) == ctx.population.sha256

    derived =
      ctx.from
      |> LaunchManifest.derive(ctx.population, %{sha256: ctx.rule.sha256, signer: ctx.signer})
      |> plain()

    assert length(derived["entries"]) == 124
    assert derived["pending"] == []
    assert length(derived["deferred"]) == 46

    assert Enum.frequencies_by(derived["entries"], & &1["kind"]) == %{
             "subject" => 122,
             "edition" => 2
           }

    for entry <- derived["entries"] do
      review = ctx.owner[entry["object_id"]]
      assert review["action"] == "confirm"
      assert {entry["path"], entry["family"]} == {review["path"], review["family"]}
      assert entry["clause"] == "standing_decision"
      assert entry["reviewer"] == ctx.signer
      assert entry["evidence_fingerprint"] == review["evidence_fingerprint"]
    end

    deferred = Enum.filter(derived["deferred"], &(&1["action"] == "defer"))

    assert Enum.sort(Enum.map(deferred, & &1["object_id"])) ==
             Enum.sort(for {id, %{"action" => "defer"}} <- ctx.owner, do: id)
  end

  test "the committed launch manifest is exactly the rule's, bound to both digests", ctx do
    assert {:ok, manifest} = LaunchManifest.read(@launch)
    doc = manifest.doc

    assert doc["from"]["sha256"] == @from_sha256
    assert doc["from"]["run_key"] == ctx.from.doc["run_key"]
    assert doc["population"]["sha256"] == ctx.population.sha256
    assert doc["rule"]["sha256"] == ctx.rule.sha256
    assert manifest.rule_sha256 == ctx.rule.sha256

    # Signed: the committed rule names the signer the manifest names.
    assert %{"signer" => signer} = ctx.rule.signature
    assert doc["rule"]["signer"] == signer

    derived =
      ctx.from
      |> LaunchManifest.derive(ctx.population, %{sha256: ctx.rule.sha256, signer: signer})
      |> plain()

    pages = Enum.reject(doc["entries"], &(&1["kind"] == "lexical"))
    assert pages == derived["entries"]
    assert doc["pending"] == derived["pending"]
    assert doc["deferred"] == derived["deferred"]

    # D1: each lexical entry is an On page tied to the pages it was listed for.
    page_ids = MapSet.new(pages, & &1["page_id"])

    for entry <- manifest.lexical do
      assert {:ok, %{namespace: "on"}} = DevilsDictionary.Routing.Address.parse(entry["path"])
      assert entry["clause"] == "index_lexical"
      assert entry["reviewer"] == signer
      assert entry["subject_page_ids"] != []
      assert Enum.all?(entry["subject_page_ids"], &MapSet.member?(page_ids, &1))
      assert entry["lexeme_ids"] != []
    end

    assert doc["counts"]["pages"] == 124
    assert doc["counts"]["lexical"] == length(manifest.lexical)
  end
end
