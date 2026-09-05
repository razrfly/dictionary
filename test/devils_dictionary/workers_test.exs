defmodule DevilsDictionary.WorkersTest do
  @moduledoc """
  The two Oban wrappers. What matters is the pair of rules #69 §5 states and
  that nothing else enforces: a rate limit that is honoured *outside* the
  client, and a 429 that snoozes rather than discards.
  """
  use DevilsDictionary.DataCase, async: true
  use Oban.Testing, repo: DevilsDictionary.Repo

  alias DevilsDictionary.Absorb.Clients
  alias DevilsDictionary.Encyclopedia.Concept
  alias DevilsDictionary.{Fixtures, Repo, Sources}
  alias DevilsDictionary.Sources.SourceRecord
  alias DevilsDictionary.Workers.EnrichWorker

  setup do
    Fixtures.seed_catalog!()
    :ok
  end

  defp record!(slug, external_id) do
    source = Sources.get_source_by_slug!(slug)
    Repo.get_by!(SourceRecord, source_id: source.id, external_id: external_id)
  end

  test "a 429 is a snooze, never a discard" do
    Req.Test.stub(Clients, fn conn ->
      conn
      |> Plug.Conn.put_resp_header("retry-after", "45")
      |> Plug.Conn.resp(429, "slow down")
    end)

    assert {:snooze, 45} =
             perform_job(EnrichWorker, %{"source" => "wikidata", "target" => "Q146"})
  end

  test "a target the source has nothing for is a success, not a failure" do
    Req.Test.stub(Clients, fn conn ->
      Req.Test.json(conn, %{"entities" => %{"Q1" => %{"id" => "Q1", "missing" => ""}}})
    end)

    assert :ok = perform_job(EnrichWorker, %{"source" => "wikidata", "target" => "Q1"})

    record = record!("wikidata", "Q1")
    assert record.absent_until
    assert Sources.raw(record) == %{}
  end

  test "a fetch lands a record and materializes it in one job" do
    entity = Fixtures.raw("wikidata", "cat") |> Enum.find(&(&1["id"] == "Q146"))

    Req.Test.stub(Clients, fn conn ->
      Req.Test.json(conn, %{"entities" => %{"Q146" => entity}})
    end)

    assert :ok = perform_job(EnrichWorker, %{"source" => "wikidata", "target" => "Q146"})

    concept = Repo.get_by!(Concept, qid: "Q146")
    assert concept.wikipedia_title == "Cat"
    assert concept.wordnet_ili == "i46593"
    assert record!("wikidata", "Q146").materialized_at
  end

  test "an unknown source slug is an error the queue can see" do
    assert_raise ArgumentError, ~r/no absorb module/, fn ->
      perform_job(EnrichWorker, %{"source" => "nope", "target" => "x"})
    end
  end
end
