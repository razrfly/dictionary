defmodule DevilsDictionary.Absorb.WordnetInstancesTest do
  @moduledoc """
  WordNet's instance edges through the real materializer (#181 build 1).

  The pure mapping is `WordnetTest`'s; this is what lands: an `instance_of`
  claim between two senses — legal only because `priv/predicates/taxonomy.json`
  declares `sense/- → sense/-`, which the endpoint foreign key enforces — with
  the source's own label kept in the claim's metadata, as it is on every edge
  that has one.
  """
  use DevilsDictionary.DataCase, async: true

  alias DevilsDictionary.Absorb.Materializer
  alias DevilsDictionary.Absorb.Sources.Wordnet
  alias DevilsDictionary.Claims.{AssertionRevision, PendingRelation}
  alias DevilsDictionary.{Claims, Fixtures, Repo, Sources}
  alias DevilsDictionary.Sources.{Source, SourceRecord}

  setup do
    Claims.Catalog.seed!()
    :ok
  end

  # A throwaway slug, as `ConceptsTest` does: `Catalog.seed!/0` upserts the
  # real `wordnet` row from other async tests, and the module reads nothing but
  # `record.source_id`.
  defp source! do
    Repo.insert!(%Source{
      slug: "wordnet-#{System.unique_integer([:positive])}",
      name: "WordNet",
      tier: :middle,
      kind: :lexical_db,
      access: :dump
    })
  end

  defp record!(source, raw) do
    Sources.insert_records(source, [%{external_id: raw["id"], raw: raw}])

    Repo.one!(
      from r in SourceRecord,
        where: r.source_id == ^source.id and r.external_id == ^raw["id"]
    )
    |> Sources.with_raw()
  end

  # The class synset Hitler's edge names, as the dump holds it. Only the fields
  # `materialize/1` reads.
  @dictator %{
    "id" => "oewn-10031556-n",
    "members" => ["dictator", "potentate"],
    "partOfSpeech" => "n",
    "definition" => ["a ruler who is unconstrained by a constitution or laws or opposition etc."],
    "_edges" => []
  }

  defp current(key) do
    Repo.all(
      from r in AssertionRevision,
        join: p in assoc(r, :predicate),
        where: p.key == ^key and r.is_current and r.lifecycle_state == :active
    )
  end

  test "an instance edge is instance_of between two senses, with its label" do
    source = source!()
    {:ok, _} = Materializer.run(record!(source, @dictator), Wordnet)
    {:ok, _} = Materializer.run(record!(source, Fixtures.one_raw("wordnet", "Hitler")), Wordnet)

    instances = current("instance_of")

    # Hitler, Adolf Hitler, Der Fuhrer → dictator, potentate.
    assert length(instances) == 6
    assert Enum.all?(instances, &(&1.subject_kind == "sense" and &1.object_kind == "sense"))
    assert Enum.all?(instances, &(&1.metadata == %{"label" => "instance_hypernym"}))
    assert Enum.all?(instances, &(&1.method == "source"))
    assert current("other") == []

    # The second class, *Nazi*, is not held: its edge waits, labelled too, and
    # carries the sense key so the lemma resolver leaves it for the next pass.
    pending = Repo.all(from p in PendingRelation, preload: :predicate)
    assert length(pending) == 6
    assert Enum.all?(pending, &(&1.predicate.key == "instance_of"))
    assert Enum.all?(pending, &(&1.metadata["label"] == "instance_hypernym"))
    assert Enum.all?(pending, &(&1.metadata["to_sense"] =~ "oewn-10369951-n#"))
  end

  test "a re-run writes no new revision" do
    source = source!()
    {:ok, _} = Materializer.run(record!(source, @dictator), Wordnet)
    hitler = record!(source, Fixtures.one_raw("wordnet", "Hitler"))
    {:ok, _} = Materializer.run(hitler, Wordnet)
    before = Repo.aggregate(AssertionRevision, :count)

    {:ok, _} = Materializer.run(Repo.get!(SourceRecord, hitler.id) |> Sources.with_raw(), Wordnet)

    assert Repo.aggregate(AssertionRevision, :count) == before
  end

  test "an unmapped edge is other and says which edge it is" do
    source = source!()

    # `dog` files two `exemplifies` edges at synsets no batch here holds.
    for raw <- Fixtures.raw("wordnet", "dog") do
      {:ok, _} = Materializer.run(record!(source, raw), Wordnet)
    end

    labels =
      Repo.all(
        from p in PendingRelation,
          join: k in assoc(p, :predicate),
          where: k.key == "other",
          select: p.metadata["label"]
      )

    assert labels != []
    assert Enum.all?(labels, &(&1 == "exemplifies"))
  end
end
