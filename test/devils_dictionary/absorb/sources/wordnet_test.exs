defmodule DevilsDictionary.Absorb.Sources.WordnetTest do
  @moduledoc """
  `materialize/1` is pure, so it is tested directly against real captured
  records with no database and no network.
  """

  use ExUnit.Case, async: true

  alias DevilsDictionary.Absorb.Sources.Wordnet
  alias DevilsDictionary.Fixtures

  defp materialize(lemma) do
    Fixtures.raw("wordnet", lemma)
    |> Enum.map(fn raw ->
      {:ok, out} = Wordnet.materialize(Fixtures.source_record(raw, source_id: 7, id: 99))
      out
    end)
  end

  defp merge(outs) do
    Enum.reduce(outs, %{lexemes: [], senses: [], relations: []}, fn out, acc ->
      %{
        lexemes: acc.lexemes ++ out.lexemes,
        senses: acc.senses ++ out.senses,
        relations: acc.relations ++ out.relations
      }
    end)
  end

  test "cat lands in every synset it belongs to, one sense each" do
    %{senses: senses} = merge(materialize("cat"))

    cat_senses = Enum.filter(senses, &(elem(&1.lexeme, 1) == "cat"))

    assert length(cat_senses) == 10
    assert Enum.all?(cat_senses, &String.starts_with?(&1.group_key, "oewn-"))
    assert Enum.all?(cat_senses, &(&1.source_id == 7))
    assert Enum.all?(cat_senses, &(&1.source_record_id == 99))
  end

  test "sense external ids are synset id + member" do
    %{senses: senses} = merge(materialize("cat"))

    sense =
      Enum.find(senses, &(&1.group_key == "oewn-02124272-n" and elem(&1.lexeme, 1) == "cat"))

    assert sense.key == "oewn-02124272-n#cat"
    assert sense.gloss =~ "feline mammal"
    assert sense.url == "https://en-word.net/id/oewn-02124272-n"
  end

  test "glosses come from the first element of the definition array" do
    %{senses: senses} = merge(materialize("oyster"))

    assert Enum.all?(senses, &is_binary(&1.gloss))
    refute Enum.any?(senses, &is_list(&1.gloss))
  end

  test "synset ids are normalized to the oewn- prefix" do
    %{senses: senses, relations: relations} = merge(materialize("dog"))

    assert Enum.all?(senses, &String.starts_with?(&1.group_key, "oewn-"))
    assert Enum.all?(relations, &String.starts_with?(&1.to_group_key, "oewn-"))
  end

  test "both directions of hypernymy are present, though the dump has only one" do
    %{relations: relations} = merge(materialize("cat"))
    types = relations |> Enum.map(& &1.type) |> Enum.uniq()

    assert :hypernym in types
    assert :hyponym in types, "hyponym edges must be derived by inverting hypernym"
  end

  test "cat has a hypernym reaching feline" do
    %{relations: relations} = merge(materialize("cat"))

    assert Enum.any?(relations, fn r ->
             r.type == :hypernym and elem(r.from_lexeme, 1) == "cat" and r.to_lemma == "feline"
           end)
  end

  test "meronyms carry a subtype naming which kind of part" do
    %{relations: relations} = merge(materialize("dog"))
    by_type = Enum.group_by(relations, & &1.type)

    for type <- [:meronym, :holonym], rows = by_type[type], rows != nil do
      assert Enum.all?(rows, &(&1.subtype in ["part", "substance", "member"]))
    end
  end

  test "relations with no enum slot land as :other carrying the source's label" do
    # dog carries `exemplifies` edges; cat happens to carry none.
    %{relations: relations} = merge(materialize("dog"))
    others = Enum.filter(relations, &(&1.type == :other))

    assert others != []
    assert Enum.all?(others, &is_binary(&1.subtype))
    refute Enum.any?(others, &(&1.subtype in ["hypernym", "hyponym"]))
  end

  describe "instance edges (#181)" do
    # The fixture is `raw` as the absorb stored it before #181, when the edge was
    # filed as `other` with the key in `subtype`. Re-materializing from stored
    # `raw` is the path the fix has to reach (M2), so this is the case that
    # matters; the second test is `raw` as the absorb writes it now.
    test "instance_hypernym is instance_of, from each member to each class member" do
      %{relations: relations} = merge(materialize("Hitler"))
      instances = Enum.filter(relations, &(&1.type == :instance_of))

      assert length(instances) == length(relations)
      assert Enum.all?(instances, &(&1.subtype == "instance_hypernym"))

      # Direction is instance → class, as P31: the named individual is the subject.
      assert {"en", "Adolf Hitler", "noun"} in Enum.map(instances, & &1.from_lexeme)
      assert "oewn-10031556-n#dictator" in Enum.map(instances, & &1.to_sense)

      # Three members of Hitler's synset, two members of each of two classes.
      assert length(instances) == 3 * 2 + 3 * 2
    end

    test "raw written after #181 materializes to the same relations" do
      [raw] = Fixtures.raw("wordnet", "Hitler")

      rewritten =
        Map.update!(raw, "_edges", fn edges ->
          Enum.map(edges, &Map.put(&1, "type", "instance_of"))
        end)

      {:ok, old} = Wordnet.materialize(Fixtures.source_record(raw, source_id: 7, id: 99))
      {:ok, new} = Wordnet.materialize(Fixtures.source_record(rewritten, source_id: 7, id: 99))

      assert old.relations == new.relations
    end

    test "an edge with no mapping stays other with its label" do
      %{relations: relations} = merge(materialize("dog"))

      assert relations
             |> Enum.filter(&(&1.subtype == "exemplifies"))
             |> Enum.all?(&(&1.type == :other))
    end
  end

  test "synonymy is never a relation row — it is co-membership of a synset" do
    %{relations: relations} = merge(materialize("cat"))

    refute Enum.any?(relations, &(&1.type == :synonym))
  end

  test "every relation keeps to_lemma and to_group_key" do
    %{relations: relations} = merge(materialize("oyster"))

    assert relations != []
    assert Enum.all?(relations, &is_binary(&1.to_lemma))
    assert Enum.all?(relations, &is_binary(&1.to_group_key))
  end

  test "metadata carries the ILI and, where present, the Wikidata QID" do
    # 22,036 synsets carry a wikidata QID; two of dog's do, none of cat's.
    %{senses: senses} = merge(materialize("dog"))

    assert Enum.all?(senses, &Map.has_key?(&1.metadata, "ili"))
    assert Enum.all?(senses, &Map.has_key?(&1.metadata, "lexfile"))

    qids = Enum.filter(senses, &Map.has_key?(&1.metadata, "wikidata"))

    assert qids != [],
           "WordNet ships QIDs on 22k synsets; S2's linker gets that rung for free"
  end

  test "parts of speech are normalized, satellites collapsing onto adj" do
    poses =
      materialize("cat")
      |> merge()
      |> Map.fetch!(:lexemes)
      |> Enum.map(&elem(&1.key, 2))
      |> Enum.uniq()

    assert Enum.all?(poses, &(&1 in ~w(noun verb adj adv unknown)))
  end
end
