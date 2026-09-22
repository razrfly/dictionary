defmodule DevilsDictionary.Discovery.RetentionTest do
  @moduledoc """
  Retention is a rule, not a hope (#144 Phase 2).

  Before this the kit refreshed well and **forgot nothing**: one global
  `retention_seconds`, a cleanup that exempted the current display root from
  the age cutoff so a displayed run lived until it was superseded, and a run
  deletion that cascaded to its results and left the provider's own payload in
  `source_records` behind it. A source's terms — the Guardian's "not retained
  longer than 24 hours" (#142), Artsy's "removed on termination" — could not be
  kept by the code, only by a sentence in a document.

  The cases here are the ones the issue names: a day-old result under a
  day-long policy is gone including its source record, the same result under
  the default is not, a source record the encyclopedia is standing on survives,
  and a page whose root was withdrawn shows the honest empty and asks again.
  """

  use DevilsDictionary.DataCase, async: false
  use Oban.Testing, repo: DevilsDictionary.Repo

  import DevilsDictionary.WordFixtures
  import Ecto.Query

  alias DevilsDictionary.Discovery
  alias DevilsDictionary.Discovery.{Policy, RequestAttempt, Result, Run}
  alias DevilsDictionary.Discovery.Providers.CineGraph
  alias DevilsDictionary.FakeOffsetDiscoveryProvider, as: Provider
  alias DevilsDictionary.Repo
  alias DevilsDictionary.Corpus.SourceRecordRevision
  alias DevilsDictionary.Sources.SourceRecord

  @slug DevilsDictionary.FakeOffsetDiscoveryProvider.slug()

  # One hour old, against `config/test.exs`'s two-hour default and a
  # half-hour policy. The issue writes this as 25 hours against a day, which
  # is the same shape at a scale the suite's own configuration does not have.
  @age 60 * 60
  @short 30 * 60

  setup ctx do
    catalog = DevilsDictionary.Fixtures.seed_catalog!()
    original = Application.fetch_env!(:devils_dictionary, :discovery)
    providers = Application.fetch_env!(:devils_dictionary, :discovery_providers)

    req_options = Application.fetch_env!(:devils_dictionary, :discovery_req_options)

    Application.put_env(:devils_dictionary, :discovery_providers, [Provider])
    Application.put_env(:devils_dictionary, :discovery_req_options, plug: {Req.Test, Provider})

    on_exit(fn ->
      Application.put_env(:devils_dictionary, :discovery, original)
      Application.put_env(:devils_dictionary, :discovery_providers, providers)
      Application.put_env(:devils_dictionary, :discovery_req_options, req_options)
    end)

    Map.merge(ctx, %{sources: catalog.sources, scopes: catalog.scopes})
  end

  defp configure(overrides) do
    config = Application.fetch_env!(:devils_dictionary, :discovery)
    Application.put_env(:devils_dictionary, :discovery, Keyword.merge(config, overrides))
  end

  defp policy(slug, overrides) do
    config = Application.fetch_env!(:devils_dictionary, :discovery)
    policies = Keyword.get(config, :source_policies, %{})
    configure(source_policies: Map.put(policies, slug, overrides))
  end

  defp run!(ctx, lemma, keyword_id) do
    word = word!(ctx, lemma, ~w(wordnet))

    # A bare JSON array, which is what this REST-shaped text provider returns,
    # and a provider with **no** `identity_record/1`: its results are search
    # cache and nothing else, which is exactly the source a retention promise
    # is made about. See the last case in this file for the other half.
    Req.Test.stub(Provider, fn conn ->
      conn = Plug.Conn.fetch_query_params(conn)
      limit = String.to_integer(conn.params["limit"])
      offset = String.to_integer(conn.params["offset"] || "0")

      rows =
        Enum.map(1..1//1, fn id ->
          %{
            "id" => keyword_id + id,
            "title" => "#{lemma} #{id}",
            "text" => "a line that uses #{lemma} plainly",
            "year" => "1751"
          }
        end)

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(200, Jason.encode!(Enum.slice(rows, offset, limit)))
    end)

    target = %{
      object_id: word.object_id,
      lexeme_ids: [word.object_id],
      term: word.lemma,
      language: word.language_tag,
      relevance: "term"
    }

    assert {:queued, run} = Discovery.request(target, @slug)
    assert :ok = Discovery.execute_run(run.id)
    run = Repo.get!(Run, run.id)
    assert run.status == :succeeded
    assert run.result_count > 0

    %{word: word, target: target, run: run}
  end

  # A completed run is immutable in the database — `completed_at` and
  # `expires_at` are both in `discovery_runs_keep_completed_immutable`'s
  # protected list, which is why retention *withdraws* a run rather than
  # restamping it. Making a run old is therefore something only a test does,
  # and it says so out loud: the trigger is disabled for the one statement and
  # restored immediately, inside the sandbox transaction.
  defp age!(run, seconds) do
    then = DateTime.add(DateTime.utc_now(), -seconds, :second)

    Repo.query!(
      "ALTER TABLE discovery_runs DISABLE TRIGGER discovery_runs_keep_completed_immutable"
    )

    Repo.query!(
      "UPDATE discovery_runs SET completed_at = $1, expires_at = $2 WHERE id = $3",
      [then, DateTime.add(then, retention_of(run), :second), run.id]
    )

    Repo.query!(
      "ALTER TABLE discovery_runs ENABLE TRIGGER discovery_runs_keep_completed_immutable"
    )

    Repo.get!(Run, run.id)
  end

  # The deadline the run was written with, preserved as it is moved: an aged
  # run carries the retention that was in force when it published, which is
  # the whole point of `expires_at` being on the row.
  defp retention_of(run) do
    DateTime.diff(run.expires_at, run.completed_at, :second)
  end

  describe "a source's retention is honoured, including its display root" do
    test "a 25-hour-old result under a 24-hour policy is gone, and so is its source record",
         ctx do
      policy(@slug, retention_seconds: @short)
      %{run: run, target: target} = run!(ctx, "retained-day", 9001)

      [result] = Repo.all(from r in Result, where: r.run_id == ^run.id)
      record_id = result.source_record_id
      assert record_id

      # It is the page's current display root, which is exactly the case the
      # old sweep exempted: a displayed run lived until it was superseded.
      assert Discovery.state(target.object_id, @slug).status == :ready

      age!(run, @age)

      assert %{withdrawn: 1, expired_results: 1, expired_source_records: 1} = Discovery.cleanup()

      # The run stays: it is the ledger of what was spent, and the accounting
      # should not disappear with the content.
      assert %Run{display_allowed: false} = Repo.get!(Run, run.id)
      assert Repo.aggregate(from(r in Result, where: r.run_id == ^run.id), :count) == 0

      # And the payload, which is the half that used to survive every delete.
      refute Repo.get(SourceRecord, record_id)

      assert Repo.aggregate(
               from(rev in SourceRecordRevision, where: rev.source_record_id == ^record_id),
               :count
             ) == 0
    end

    test "the same result under the default retention is untouched", ctx do
      # The suite's own default, from `config/test.exs`. What matters is the
      # contrast with the case above: the same age, one policy short enough to
      # take it and one long enough to keep it.
      default = Policy.retention_seconds(@slug)
      assert default > @age

      %{run: run, target: target} = run!(ctx, "retained-default", 9002)
      [result] = Repo.all(from r in Result, where: r.run_id == ^run.id)

      age!(run, @age)

      assert %{withdrawn: 0, expired_results: 0, expired_source_records: 0} = Discovery.cleanup()

      assert %Run{display_allowed: true} = Repo.get!(Run, run.id)
      assert Repo.get(Result, result.id)
      assert Repo.get(SourceRecord, result.source_record_id)
      assert Discovery.state(target.object_id, @slug).status == :ready
    end

    test "a source record the encyclopedia is standing on survives its result", ctx do
      policy(@slug, retention_seconds: @short)
      %{run: run} = run!(ctx, "retained-durable", 9003)

      [result] = Repo.all(from r in Result, where: r.run_id == ^run.id)
      record = Repo.get!(SourceRecord, result.source_record_id)

      revision =
        Repo.one!(
          from rev in SourceRecordRevision,
            where: rev.source_record_id == ^record.id,
            order_by: [desc: rev.id],
            limit: 1
        )

      # What a corpus row, or any durable identity, leaves behind: a revision
      # of this record is the provenance of something in the registry.
      # Deleting the record would cascade the revision and silently null it.
      Repo.insert!(%DevilsDictionary.Registry.ExternalIdentifier{
        object_id: result.object_id || durable_object!(ctx),
        namespace: "retention_test",
        external_id: "keeps-the-record",
        source_record_revision_id: revision.id
      })

      age!(run, @age)

      assert %{withdrawn: 1, expired_results: 1, expired_source_records: 0} = Discovery.cleanup()

      # The search cache is gone; the encyclopedia is not.
      assert Repo.aggregate(from(r in Result, where: r.run_id == ^run.id), :count) == 0
      assert Repo.get(SourceRecord, record.id)
    end
  end

  describe "the page whose root retention took" do
    test "shows the honest empty and admits a new run on the next visit", ctx do
      policy(@slug, retention_seconds: @short)
      %{run: run, target: target} = run!(ctx, "retained-revisit", 9004)

      age!(run, @age)
      assert %{withdrawn: 1} = Discovery.cleanup()

      # Not `:withdrawn`, which is a policy act on a *result* and has a reason
      # to show. There is nothing withheld here: the kit stopped holding it.
      state = Discovery.state(target.object_id, @slug)
      assert state.status == :expired
      assert state.items == []

      # And the next visit asks again rather than reading the withdrawn root
      # out of the cache for the rest of its thirty-day refresh window.
      assert {:queued, %Run{id: fresh_id}} = Discovery.request(target, @slug)
      refute fresh_id == run.id
    end
  end

  describe "the ledger" do
    test "attempts are pruned per position, for a protected root too", ctx do
      # CineGraph, and not this file's fixture provider, because the case is
      # about a **single** run spending more than one request: a page costs a
      # keyword search plus the discovery query, both on one position. Neither
      # attempt row was ever deletable —
      # `discovery_request_attempts.run_id` is `ON DELETE CASCADE`, so an
      # attempt goes only when its run does, and the current display root is
      # never deleted. 402 rows and climbing, measured 2026-09-21.
      Application.put_env(:devils_dictionary, :discovery_providers, [CineGraph])
      Application.put_env(:devils_dictionary, :discovery_req_options, plug: {Req.Test, CineGraph})
      configure(retained_attempts_per_position: 1)

      word = word!(ctx, "retained-ledger", ~w(wordnet))

      Req.Test.stub(CineGraph, fn conn ->
        {:ok, raw, conn} = Plug.Conn.read_body(conn)
        body = Jason.decode!(raw)

        payload =
          if String.contains?(body["query"], "searchMovieKeywords") do
            %{
              "data" => %{
                "searchMovieKeywords" => [
                  %{"tmdbId" => 4242, "name" => "retained-ledger", "movieCount" => 1}
                ]
              }
            }
          else
            %{
              "data" => %{
                "discoverMovies" => %{
                  "edges" => [
                    %{
                      "cursor" => "cursor-4242",
                      "node" => %{
                        "movie" => %{
                          "tmdbId" => 4242,
                          "imdbId" => nil,
                          "title" => "A film about retained-ledger",
                          "releaseDate" => "1999-01-01",
                          "posterPath" => "/poster.jpg",
                          "cinegraphUrl" => "https://cinegraph.org/movies/4242"
                        },
                        "matchedKeywords" => [%{"tmdbId" => 4242, "name" => "retained-ledger"}],
                        "matchedGenres" => []
                      }
                    }
                  ],
                  "pageInfo" => %{"endCursor" => nil, "hasNextPage" => false}
                }
              }
            }
          end

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, Jason.encode!(payload))
      end)

      target = %{
        object_id: word.object_id,
        lexeme_ids: [word.object_id],
        term: word.lemma,
        language: word.language_tag,
        relevance: "term"
      }

      assert {:queued, run} = Discovery.request(target, "cinegraph")
      assert :ok = Discovery.execute_run(run.id)
      assert Repo.get!(Run, run.id).status == :succeeded

      spent = Repo.aggregate(RequestAttempt, :count)
      assert spent > 1, "one run, #{spent} request(s): this case needs a multi-request page"

      assert %{pruned_attempts: pruned, deleted: 0} = Discovery.cleanup()
      assert pruned == spent - 1
      assert Repo.aggregate(RequestAttempt, :count) == 1

      # The run is untouched: the ledger is bounded, and what it accounts for
      # is still displayed.
      assert %Run{display_allowed: true} = Repo.get!(Run, run.id)
      assert Discovery.state(target.object_id, "cinegraph").status == :ready

      # Idempotent: the next tick has nothing left to take.
      assert %{pruned_attempts: 0} = Discovery.cleanup()
    end
  end

  describe "expires_at" do
    test "is completed_at plus the source's retention, and is what the sweep reads", ctx do
      policy(@slug, retention_seconds: @short)
      %{run: run} = run!(ctx, "retained-deadline", 9006)

      assert DateTime.diff(run.expires_at, run.completed_at, :second) == @short

      # It is a deadline the run carries, so a policy loosened after the fact
      # does not resurrect what the run already promised to drop — and one
      # tightened after the fact still reaches a run written before it,
      # through the `completed_at + policy` fallback for rows that predate
      # this field meaning anything.
      age!(run, @age)
      assert [%{id: due_id}] = Discovery.retention_due()
      assert due_id == run.id
    end
  end

  describe "per-source failure backoff" do
    test "a failed run waits its source's own interval, not a shared five minutes", ctx do
      policy(@slug, failure_backoff_seconds: 42)
      word = word!(ctx, "retained-failure", ~w(wordnet))

      Req.Test.stub(Provider, fn conn -> Plug.Conn.send_resp(conn, 418, "nope") end)

      target = %{
        object_id: word.object_id,
        lexeme_ids: [word.object_id],
        term: word.lemma,
        language: word.language_tag,
        relevance: "term"
      }

      assert {:queued, run} = Discovery.request(target, @slug)
      assert :ok = Discovery.execute_run(run.id)

      failed = Repo.get!(Run, run.id)
      assert failed.status == :failed

      waited = DateTime.diff(failed.retry_at, failed.completed_at, :second)
      assert waited in 41..43, "waited #{waited}s, and the source's policy says 42"
    end
  end

  defp durable_object!(ctx) do
    word!(ctx, "retention-anchor", ~w(wordnet)).object_id
  end
end
