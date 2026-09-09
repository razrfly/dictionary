defmodule DevilsDictionary.Absorb.Sources.WiktionaryIndexTest do
  @moduledoc """
  The index pass **writes**, and that write is not the materializer's.

  `wiktionary_test.exs` covers the projection, which is pure. What it cannot
  cover is the only part of the codebase that mints identities outside
  `Materializer.run_batch/3`: the index pass writes 1.5 M bare lexemes in its own
  loop. Minting an object and writing its subtype are two statements, and the
  registry's constraint trigger is deferred to **COMMIT** — so in autocommit the
  object's own commit asks for a lexeme row the next statement has not written
  yet, and the first full rebuild died on its first flush with

      object 374480 (kind lexeme) has no lexeme row

  `mix compile` cannot see that, and neither can a test of the projection. This
  runs the pass.
  """

  use DevilsDictionary.DataCase, async: false

  # Real COMMIT semantics: the defect this file exists for is invisible inside
  # the sandbox's enclosing transaction.
  @moduletag :unboxed

  import Ecto.Query

  alias DevilsDictionary.Absorb.ScopeBuilder
  alias DevilsDictionary.Absorb.Sources.Wiktionary
  alias DevilsDictionary.Lexicon
  alias DevilsDictionary.Registry.Lexeme
  alias DevilsDictionary.{Fixtures, Repo}

  setup do
    Fixtures.seed_catalog!()
    :ok
  end

  test "mints an object and its lexeme together, and leaves nothing orphaned" do
    path = dump(~w(cat dog oyster))

    assert {:ok, stats} = Wiktionary.absorb(nil, index: true, path: path, limit: 10)

    assert stats.en_records == 3
    assert stats.lexemes_written == 3
    assert Repo.aggregate(Lexeme, :count) == 3
    assert orphaned() == 0
  end

  test "is idempotent: the same dump twice mints nothing new" do
    path = dump(~w(cat dog))

    {:ok, _} = Wiktionary.absorb(nil, index: true, path: path, limit: 10)
    before = Repo.aggregate(Lexeme, :count)

    {:ok, _} = Wiktionary.absorb(nil, index: true, path: path, limit: 10)

    assert Repo.aggregate(Lexeme, :count) == before
    assert orphaned() == 0
  end

  test "the scoped pass filters on the payload, which is not a column on the record" do
    # `source_records.raw` is virtual — the payload moved to
    # `source_record_revisions` at P1 — so the phase filter that reads
    # `raw->>'word'` compiles and then dies with `column s0.raw does not exist`.
    # The first full rebuild lost this whole stage to it, and nothing before this
    # test ran the scoped pass against the new schema.
    path = dump(~w(nepotism bank egomaniac))
    {:ok, _} = Wiktionary.absorb(nil, index: true, path: path, limit: 10)

    scope = Lexicon.get_scope_by_slug!("culture")
    %{total: 3} = ScopeBuilder.build(scope, reset: true)

    assert {:ok, stats} = Wiktionary.absorb(scope, path: path, limit: 10)

    assert stats.records == 3
    assert stats.senses == 3
    assert orphaned() == 0
  end

  # An object of kind `lexeme` with no `lexemes` row. The composite foreign key
  # makes this unrepresentable at COMMIT; counting it here says so out loud, and
  # keeps the assertion meaningful if the trigger is ever relaxed.
  defp orphaned do
    Repo.one!(
      from o in "objects",
        left_join: l in "lexemes",
        on: l.object_id == o.id,
        where: o.kind == "lexeme" and is_nil(l.object_id),
        select: count(o.id)
    )
  end

  # The marker the index pass greps for is `"lang_code": "en"`, with the space
  # Kaikki writes and `Jason.encode!/1` does not — so the lines are built as
  # text rather than encoded from a fixture map.
  defp dump(words) do
    lines =
      Enum.map_join(words, "\n", fn word ->
        ~s({"word": "#{word}", "pos": "noun", "lang_code": "en", ) <>
          ~s("senses": [{"glosses": ["a gloss for #{word}"]}]})
      end) <> "\n"

    path =
      Path.join(
        System.tmp_dir!(),
        "wiktionary-index-#{System.unique_integer([:positive])}.jsonl.gz"
      )

    File.write!(path, :zlib.gzip(lines))
    on_exit(fn -> File.rm(path) end)
    path
  end
end
