defmodule DevilsDictionary.SchemaTest do
  @moduledoc """
  The baseline schema's promises (issue #69 §4), asserted against the database
  rather than against the migration file.
  """

  use DevilsDictionary.DataCase, async: true

  alias DevilsDictionary.Lexicon.{Entry, Lexeme, Scope, ScopeLexeme}
  alias DevilsDictionary.Repo
  alias DevilsDictionary.Sources.{Catalog, Source, SourceRecord}

  defp source! do
    Repo.insert!(%Source{
      slug: "s#{System.unique_integer([:positive])}",
      name: "S",
      tier: :middle,
      kind: :dictionary,
      access: :dump
    })
  end

  defp lexeme!(lemma, pos \\ "noun") do
    Repo.insert!(%Lexeme{lang: "en", lemma: lemma, pos: pos, slug: String.downcase(lemma)})
  end

  test "identity is (lang, lemma, pos)" do
    lexeme!("bank")
    lexeme!("bank", "verb")

    assert {:error, changeset} =
             %Lexeme{}
             |> Lexeme.changeset(%{lang: "en", lemma: "bank", pos: "noun"})
             |> Repo.insert()

    assert {"has already been taken", _} = changeset.errors[:lang]
  end

  test "lemmas are case-sensitive, so Turkey and turkey never merge" do
    lexeme!("Turkey")
    lexeme!("turkey")

    assert Repo.aggregate(Lexeme, :count) == 2
    assert length(DevilsDictionary.Lexicon.list_by_lemma("TURKEY")) == 2
  end

  test "slug is not unique — one page shows every pos and casing" do
    lexeme!("Turkey")
    lexeme!("turkey")

    assert length(DevilsDictionary.Lexicon.list_by_slug("turkey")) == 2
  end

  test "an entry must attach to a word or a thing" do
    source = source!()

    assert_raise Ecto.ConstraintError, ~r/entries_lexeme_or_concept/, fn ->
      Repo.insert!(%Entry{source_id: source.id, headword: "orphan", body: "nothing to attach to"})
    end
  end

  test "scope membership is keyed on (scope, lexeme)" do
    scope = Repo.insert!(%Scope{slug: "sc", name: "Sc"})
    lexeme = lexeme!("wombat")

    Repo.insert!(%ScopeLexeme{scope_id: scope.id, lexeme_id: lexeme.id, reasons: ["a"]})

    assert_raise Ecto.ConstraintError, fn ->
      Repo.insert!(%ScopeLexeme{scope_id: scope.id, lexeme_id: lexeme.id, reasons: ["b"]})
    end
  end

  test "raw payloads are not loaded unless asked for" do
    source = source!()

    record =
      Repo.insert!(%SourceRecord{
        source_id: source.id,
        external_id: "x1",
        raw: %{"big" => "payload"}
      })

    assert Repo.get!(SourceRecord, record.id).raw == nil
    assert DevilsDictionary.Sources.raw(record) == %{"big" => "payload"}
  end

  test "a source record is unique per (source, external_id)" do
    source = source!()
    Repo.insert!(%SourceRecord{source_id: source.id, external_id: "dup", raw: %{}})

    assert {:error, changeset} =
             %SourceRecord{}
             |> SourceRecord.changeset(%{source_id: source.id, external_id: "dup", raw: %{}})
             |> Repo.insert()

    assert changeset.errors != []
  end

  test "the catalog seeds every source and is idempotent" do
    Catalog.seed!()
    Catalog.seed!()

    slugs = Repo.all(Source) |> Enum.map(& &1.slug) |> Enum.sort()
    assert slugs == ~w(bierce johnson wikidata wikipedia wiktionary wordnet)

    wordnet = Repo.get_by!(Source, slug: "wordnet")
    assert wordnet.tier == :middle
    assert wordnet.config["edition"] == "2025-plus"
    assert wordnet.config["dump_url"] =~ "plus-json.zip"
  end

  test "every source can produce a link out" do
    Catalog.seed!()

    for source <- Repo.all(Source) do
      assert is_binary(source.url_template), "#{source.slug} has no url_template (A9)"
      assert is_binary(source.attribution), "#{source.slug} has no attribution"
      assert is_binary(source.license)
    end
  end

  test "the animals scope ships with its rules pinned" do
    Catalog.seed!()
    scope = Repo.get_by!(Scope, slug: "animals")

    assert scope.rules["wordnet_roots"] == ["oewn-00015568-n"]
    assert length(scope.rules["wiktionary_categories"]) > 200
    assert scope.rules["wikidata_root"] == "Q729"
  end

  test "every scope is a file, not code (E2)" do
    files = Path.wildcard(Path.join(Catalog.scopes_dir(), "*.json"))

    assert length(files) == length(Catalog.scopes())
    assert length(files) >= 2, "the extensibility proof needs a second scope"

    for scope <- Catalog.scopes() do
      assert is_binary(scope.slug) and scope.slug != ""
      assert is_binary(scope.name) and scope.name != ""
      assert is_map(scope.rules)
    end

    # A scope with no rule at all would build an empty membership in silence.
    for scope <- Catalog.scopes() do
      assert Map.keys(scope.rules) != [], "#{scope.slug} has no rules"
    end
  end
end
