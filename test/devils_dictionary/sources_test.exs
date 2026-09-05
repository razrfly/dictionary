defmodule DevilsDictionary.SourcesTest do
  @moduledoc """
  `insert_records/3` is the one path every source's raw payloads take, and
  `changed_at` is only as honest as the hash it compares.
  """

  use DevilsDictionary.DataCase, async: true

  alias DevilsDictionary.Fixtures
  alias DevilsDictionary.Repo
  alias DevilsDictionary.Sources
  alias DevilsDictionary.Sources.SourceRecord

  setup do
    Fixtures.seed_catalog!()
    {:ok, source: Sources.get_source_by_slug!("wiktionary")}
  end

  defp record(source, external_id) do
    Repo.get_by!(SourceRecord, source_id: source.id, external_id: external_id)
  end

  test "keeps the hash a source computed before trimming", %{source: source} do
    fetched = %{"word" => "cat", "translations" => [%{"lang" => "fr", "word" => "chat"}]}
    stored = Map.delete(fetched, "translations")

    row = %{
      external_id: "cat/noun/1",
      url: "u",
      raw: stored,
      content_hash: SourceRecord.content_hash(fetched)
    }

    assert Sources.insert_records(source, [row]) == 1
    assert record(source, "cat/noun/1").content_hash == SourceRecord.content_hash(fetched)
  end

  test "computes the hash from raw when a source does not trim", %{source: source} do
    raw = %{"id" => "x", "definition" => ["a thing"]}

    assert Sources.insert_records(source, [%{external_id: "x", url: "u", raw: raw}]) == 1
    assert record(source, "x").content_hash == SourceRecord.content_hash(raw)
  end

  test "changed_at moves only when the hash moves", %{source: source} do
    fetched = %{"word" => "oyster", "senses" => [%{"glosses" => ["a mollusc"]}]}

    row = %{
      external_id: "oyster/noun/1",
      url: "u",
      raw: fetched,
      content_hash: SourceRecord.content_hash(fetched)
    }

    assert Sources.insert_records(source, [row]) == 1
    assert is_nil(record(source, "oyster/noun/1").changed_at)

    # The same payload stored differently, e.g. after a trim change: no change.
    assert Sources.insert_records(source, [%{row | raw: Map.delete(fetched, "senses")}]) == 1
    assert is_nil(record(source, "oyster/noun/1").changed_at)

    # The source itself changed.
    changed = Map.put(fetched, "senses", [%{"glosses" => ["an edible mollusc"]}])

    assert Sources.insert_records(source, [
             %{row | raw: changed, content_hash: SourceRecord.content_hash(changed)}
           ]) == 1

    refute is_nil(record(source, "oyster/noun/1").changed_at)
  end
end
