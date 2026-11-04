defmodule DevilsDictionary.Installation.ComparisonAttemptsMigrationTest do
  @moduledoc """
  #298 C1/C2's migration, `20261103202412_add_comparison_attempts`: old
  code's attempts insert unchanged after it; up/down/up before any history;
  `down` refuses once a fingerprint or a comparison attempt exists.
  """
  use DevilsDictionary.DataCase, async: false

  alias DevilsDictionary.{Fixtures, Repo}
  alias DevilsDictionary.Curation.Runtime.Gateway
  alias DevilsDictionary.Routing.Recovery

  @moduletag :unboxed
  @moduletag timeout: 300_000

  @before 20_261_101_170_541
  @this 20_261_103_202_412

  defp migrate(direction, opts),
    do:
      Ecto.Migrator.run(
        Repo,
        Ecto.Migrator.migrations_path(Repo),
        direction,
        [dynamic_repo: Repo.get_dynamic_repo(), log: false] ++ opts
      )

  # An attempt as code before this migration writes it: none of the new
  # columns named.
  defp old_attempt!(service, config, actor, key, extra \\ []) do
    now = DateTime.utc_now()

    Repo.insert_all("inference_attempts", [
      Map.merge(
        %{
          service_id: service.id,
          model_config_id: config.id,
          request_key: key,
          purpose: "request",
          packet_hash: String.duplicate("a", 64),
          packet_bytes: 10,
          packet_summary: %{},
          requested_by_actor_id: actor.id,
          owner: "test",
          fence: 1,
          service_epoch: service.epoch,
          state: "admitted",
          reserved_ms: 1_000,
          units: 1,
          budget_day: DateTime.to_date(now),
          admitted_at: now,
          lease_expires_at: now,
          inserted_at: now,
          updated_at: now
        },
        Map.new(extra)
      )
    ])
  end

  defp column?(name) do
    %{rows: rows} =
      Repo.query!(
        "SELECT 1 FROM information_schema.columns WHERE table_name = 'inference_attempts' AND column_name = $1",
        [name]
      )

    rows != []
  end

  test "additive for old code, reversible before history, refusing after it" do
    name = Repo.config()[:database] <> "_cmp"
    config = Keyword.put(Repo.config(), :database, name)
    assert :ok = Ecto.Adapters.Postgres.storage_up(config)
    on_exit(fn -> Ecto.Adapters.Postgres.storage_down(config) end)

    Recovery.with_database(name, fn ->
      migrate(:up, to: @before)
      refute column?("evidence_fingerprint")
      migrate(:up, to: @this)
      assert column?("evidence_fingerprint")

      Fixtures.seed_catalog!()
      model = DevilsDictionary.RuntimeFixtures.model_config!()

      actor =
        DevilsDictionary.CurationFixtures.actor!(
          DevilsDictionary.CurationFixtures.account([:reviewer])
        )

      service = Gateway.service!("cmp-migration")

      # Old code's insert, unchanged, satisfies both shape constraints.
      assert {1, _} = old_attempt!(service, model, actor, "old-1")

      # Before any fingerprint or comparison: down, then up again.
      migrate(:down, step: 1)
      refute column?("arm")
      migrate(:up, to: @this)
      assert column?("arm")

      # A comparison purpose needs its identity, in the database too.
      assert_raise Postgrex.Error, ~r/inference_attempts_comparison_shape/, fn ->
        Repo.transaction(fn ->
          old_attempt!(Gateway.service!("cmp-bad"), model, actor, "bad", purpose: "comparison")
        end)
      end

      %{rows: [[id]]} =
        Repo.query!("SELECT id FROM inference_attempts WHERE request_key = 'old-1'")

      assert_raise Postgrex.Error, ~r/comparison identity cannot change/, fn ->
        Repo.transaction(fn ->
          Repo.query!("UPDATE inference_attempts SET arm = 'A0' WHERE id = $1", [id])
        end)
      end

      # Once new code records a fingerprint, down refuses and changes nothing.
      assert {1, _} =
               old_attempt!(Gateway.service!("cmp-new"), model, actor, "new-1",
                 evidence_fingerprint: String.duplicate("b", 64)
               )

      assert_raise Postgrex.Error, ~r/evidence-fingerprint history exists/, fn ->
        migrate(:down, step: 1)
      end

      assert column?("comparison_case")
    end)
  end
end
