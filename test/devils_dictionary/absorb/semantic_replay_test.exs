defmodule DevilsDictionary.Absorb.SemanticReplayTest do
  @moduledoc """
  Scorecard M2's boundary around the resolve pass: a re-materialization
  re-creates every string-target edge as a pending relation, which only the
  resolver drains again. So pending relations are compared — provenance and
  endpoints included, and changed content at an unchanged count caught — when
  the resolve pass is inside the comparison, and reported as not compared
  when it is not.
  """
  use DevilsDictionary.DataCase, async: true

  import Ecto.Query

  alias DevilsDictionary.Absorb.{Resolver, SemanticReplay}
  alias DevilsDictionary.{FakeSource, Repo, Sources}
  alias DevilsDictionary.Sources.Source

  setup do
    DevilsDictionary.Claims.Catalog.seed!()

    source =
      Repo.insert!(%Source{
        slug: "fake-#{System.unique_integer([:positive])}",
        name: "Fake",
        tier: :middle,
        kind: :dictionary,
        access: :dump
      })

    # One edge whose target exists (the resolver drains it) and one whose
    # target does not (it stays pending, with its evidence).
    Sources.insert_records(source, [
      %{external_id: "bear/noun", raw: %{"lemma" => "bear", "to_lemma" => "mammal"}},
      %{external_id: "mammal/noun", raw: %{"lemma" => "mammal", "relations" => false}},
      %{
        external_id: "gryphon/noun",
        raw: %{"lemma" => "gryphon", "to_lemma" => "chimaera", "subtype" => "heraldic"}
      }
    ])

    SemanticReplay.run(FakeSource, source, all: true, resolve: true)
    %{source: source}
  end

  defp pending, do: Repo.all(from p in "pending_relations", select: {p.to_lemma, p.metadata})

  test "with the resolve pass inside it, an unchanged replay is identical, pending relations included",
       ctx do
    assert pending() == [{"chimaera", %{"label" => "heraldic"}}]

    replay = SemanticReplay.run(FakeSource, ctx.source, all: true, resolve: true)
    assert replay.identical
    assert "pending_relations" in replay.compared
    assert replay.not_compared == []
    assert replay.resolved.resolved >= 1
  end

  test "without it, the materialize pass leaves drained edges pending again, so they are not compared",
       ctx do
    replay = SemanticReplay.run(FakeSource, ctx.source, all: true, resolve: false)

    # The drained bear → mammal edge is pending again until a resolver runs.
    assert length(pending()) == 2
    assert replay.not_compared == ["pending_relations"]
    refute "pending_relations" in replay.compared
    assert replay.identical

    Resolver.run(source_id: ctx.source.id)
    assert length(pending()) == 1
  end

  test "changed pending provenance at an unchanged count is a difference", ctx do
    Sources.insert_records(ctx.source, [
      %{
        external_id: "gryphon/noun",
        raw: %{"lemma" => "gryphon", "to_lemma" => "chimaera", "subtype" => "mythical"}
      }
    ])

    replay = SemanticReplay.run(FakeSource, ctx.source, all: true, resolve: true)
    assert pending() == [{"chimaera", %{"label" => "mythical"}}]
    refute replay.identical
    assert %{"pending_relations" => %{"before" => before, "after" => now}} = replay.changed
    assert before["rows"] == now["rows"]
    refute before["sha256"] == now["sha256"]
  end
end
