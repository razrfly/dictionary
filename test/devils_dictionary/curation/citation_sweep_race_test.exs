defmodule DevilsDictionary.Curation.CitationSweepRaceTest do
  use DevilsDictionary.DataCase, async: false
  import DevilsDictionary.ProposalFixtures
  import DevilsDictionary.CitationFixtures
  alias DevilsDictionary.Curation.{ShelfCitations, Digest}
  alias DevilsDictionary.Repo
  @moduletag :unboxed
  test "a permitted identical refetch racing the sweep stays live without reviving the older citation" do
    world = editor_world!()

    metadata = %{
      "title" => "A stable fixture headline with five particular words",
      "published_at" => "2026-10-25T00:00:00Z",
      "source_url" => "https://example.test/race"
    }

    config = Application.fetch_env!(:devils_dictionary, :discovery)
    policies = Keyword.get(config, :source_policies, %{})

    Application.put_env(
      :devils_dictionary,
      :discovery,
      Keyword.put(
        config,
        :source_policies,
        Map.put(
          policies,
          "guardian",
          Keyword.put(Map.get(policies, "guardian", []), :retention_seconds, 100_000)
        )
      )
    )

    on_exit(fn -> Application.put_env(:devils_dictionary, :discovery, config) end)

    o =
      observation!(world, "guardian",
        external_id: "race",
        age: 83_000,
        seconds: 100_000,
        metadata: metadata
      )

    assert {:ok, c} =
             ShelfCitations.cite(o.spec, %{
               composition_id: world.composition.id,
               actor_id: o.actor.id
             })

    Application.put_env(:devils_dictionary, :discovery, config)
    assert ShelfCitations.check(c) == :retention_expired
    # The original run permits 100000s, but today's 82800s policy caps the
    # older choice. Both contenders must serialize on the same identity.
    parent = self()

    {:ok, {fresh, sweep}} =
      Repo.transaction(fn ->
        Repo.query!("SELECT pg_advisory_xact_lock(hashtextextended($1,0))", [
          "discovery:#{o.source.id}:#{o.digest}"
        ])

        fresh =
          Task.async(fn ->
            Ecto.Adapters.SQL.Sandbox.checkout(Repo, sandbox: false)
            send(parent, :fresh_ready)

            Repo.transaction(fn ->
              observation!(world, "guardian", external_id: "race", metadata: metadata)
            end)
          end)

        sweep =
          Task.async(fn ->
            Ecto.Adapters.SQL.Sandbox.checkout(Repo, sandbox: false)
            send(parent, :sweep_ready)
            DevilsDictionary.Discovery.purge_expired_payloads(100)
          end)

        assert_receive :fresh_ready
        assert_receive :sweep_ready
        {fresh, sweep}
      end)

    assert {:ok, new} = Task.await(fresh, 15_000)
    assert %{} = Task.await(sweep, 15_000)
    assert new.record.id == o.record.id
    assert ShelfCitations.bound_revision(new.result).id == new.revision.id
    assert DevilsDictionary.Sources.raw(new.record) == new.raw
    assert ShelfCitations.check(Repo.reload!(c)) == :retention_expired
    assert Repo.reload!(c).cited_checksum == o.revision.checksum

    assert Digest.sha256(new.result.external_namespace <> ":" <> new.result.external_id) ==
             o.digest
  end
end
