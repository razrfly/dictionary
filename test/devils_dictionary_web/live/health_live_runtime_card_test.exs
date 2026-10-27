defmodule DevilsDictionaryWeb.HealthLiveRuntimeCardTest do
  @moduledoc """
  The "Editor runtime" card on `/ops/health` (#267 §8 test 4, #264 R17). It
  renders on an empty database, "none" on every line, and with rows; and
  rendering the page inserts nothing: it reads `Runtime.Snapshot.read/1`,
  never `Gateway.service!/1`, which would insert the slot's row. It is 404
  through the tunnel like the rest of `/ops`.

  Not async: the card reads the configured service key's row, and the
  runtime's own tests keep theirs apart by key.
  """
  use DevilsDictionaryWeb.ConnCase, async: false

  import DevilsDictionary.CurationFixtures, only: [account: 1, actor!: 1]
  import DevilsDictionary.RuntimeFixtures

  alias DevilsDictionary.Curation.Runtime.{
    Attempt,
    Authority,
    Endpoint,
    FakeSystem,
    LedgerEntry,
    Service,
    Snapshot
  }

  alias DevilsDictionary.Repo

  @runtime_tables [Service, Attempt, LedgerEntry]

  defp counts, do: Map.new(@runtime_tables, &{&1, Repo.aggregate(&1, :count)})

  defp line(view, id), do: view |> element("##{id}") |> render() |> text()

  defp text(html), do: html |> LazyHTML.from_fragment() |> LazyHTML.text() |> String.trim()

  describe "on an empty database" do
    test "every line says none, and mounting inserts nothing", %{conn: conn} do
      before = counts()
      assert Repo.get_by(Service, key: Endpoint.get(:service_key)) == nil

      {:ok, view, _html} = live(conn, ~p"/ops/health")

      assert has_element?(view, "#runtime-card")

      for id <-
            ~w(runtime-slot runtime-bound runtime-model runtime-today runtime-smoke runtime-attempt) do
        assert line(view, id) =~ "none", id
      end

      assert line(view, "runtime-process") =~ "not checked here"

      assert counts() == before
      assert Repo.get_by(Service, key: Endpoint.get(:service_key)) == nil
    end

    test "the snapshot is nils and an empty list" do
      assert %{
               service: nil,
               authority: :unbound,
               model_configs: [],
               today: nil,
               last_smoke: nil,
               last_attempt: nil
             } = Snapshot.read()
    end
  end

  describe "with rows" do
    setup do
      config =
        model_config!(%{
          tag: "9b",
          slug: "qwen3.5-9b-v2",
          instruction_version: "generic-editor-v2"
        })

      actor = actor!(account([:reviewer]))
      key = Endpoint.get(:service_key)
      FakeSystem.put_file(Authority.path(), Jason.encode!(Authority.identity()))

      service =
        Repo.insert!(%Service{key: key, state: :available, epoch: 2, fence: 5})

      today = Date.utc_today()
      now = DateTime.utc_now()

      smoke = attempt!(service, config, actor, "smoke:1", :readiness_smoke, now, today)

      rehearsal =
        attempt!(service, config, actor, "rehearsal:qwen3.5-9b-v2:abc", :request, now, today)

      for {attempt, ms} <- [{smoke, 2_400}, {rehearsal, 72_900}] do
        ledger!(service, attempt, :reserve, today, 125_000)
        ledger!(service, attempt, :release, today, 125_000)
        ledger!(service, attempt, :charge, today, ms)
      end

      %{config: config, actor: actor, service: service, smoke: smoke, rehearsal: rehearsal}
    end

    defp attempt!(service, config, actor, key, purpose, now, today) do
      Repo.insert!(%Attempt{
        service_id: service.id,
        model_config_id: config.id,
        request_key: key,
        purpose: purpose,
        packet_hash: String.duplicate("a", 64),
        packet_bytes: 100,
        packet_summary: %{},
        requested_by_actor_id: actor.id,
        owner: "test",
        fence: service.fence,
        service_epoch: service.epoch,
        state: :completed,
        outcome: :accepted,
        reserved_ms: 125_000,
        units: 1,
        budget_day: today,
        admitted_at: now,
        dispatched_at: now,
        finished_at: now,
        settled_at: now,
        lease_expires_at: now
      })
    end

    defp ledger!(service, attempt, kind, day, ms) do
      Repo.insert!(%LedgerEntry{
        service_id: service.id,
        attempt_id: attempt.id,
        kind: kind,
        day: day,
        amount_ms: ms
      })
    end

    test "shows the slot, the binding, the config, today's minutes and the last smoke", ctx do
      before = counts()
      {:ok, view, _html} = live(ctx.conn, ~p"/ops/health")

      assert line(view, "runtime-slot") =~
               "available · studio-ollama · epoch 2 · fence 5 · no holder"

      assert line(view, "runtime-bound") =~
               "#{Authority.identity()["database"]} (run/authority.json) · this database"

      assert line(view, "runtime-model") =~
               "qwen3.5-9b-v2 · generic-editor-v2 · digest #{String.slice(ctx.config.manifest_digest, 0, 8)}… · config ##{ctx.config.id}"

      # 2.4 s and 72.9 s charged: 1 min 15 s of the 30 minutes.
      assert line(view, "runtime-today") == "1 min 15 s of 30 min of inference"
      assert line(view, "runtime-smoke") =~ "smoke:1 · accepted · attempt ##{ctx.smoke.id}"

      assert line(view, "runtime-attempt") =~
               "rehearsal:qwen3.5-9b-v2:abc · accepted · attempt ##{ctx.rehearsal.id}"

      assert counts() == before
    end

    test "a marker naming another database says so, and a live reservation is shown", ctx do
      other = Map.put(Authority.identity(), "database", "devils_dictionary_runtime_bench")
      FakeSystem.put_file(Authority.path(), Jason.encode!(other))

      # Reserved and not yet released.
      today = Date.utc_today()
      now = DateTime.utc_now()
      live = attempt!(ctx.service, ctx.config, ctx.actor, "request:live", :request, now, today)
      ledger!(ctx.service, live, :reserve, today, 125_000)

      {:ok, view, _html} = live(ctx.conn, ~p"/ops/health")

      assert line(view, "runtime-bound") =~
               "devils_dictionary_runtime_bench (run/authority.json) · not this database"

      assert line(view, "runtime-today") =~ "2 min 05 s reserved by a live attempt"
    end
  end

  # On the published host, as `PublicRoutingTest` sets it.
  test "it is 404 through the tunnel, and a proxied request inserts nothing", %{conn: conn} do
    previous = Application.get_env(:devils_dictionary, :published_host)
    Application.put_env(:devils_dictionary, :published_host, "wordhoard.test")
    before = counts()

    try do
      conn = conn |> put_req_header("x-forwarded-for", "203.0.113.7") |> get(~p"/ops/health")

      assert response(conn, 404) =~ "Not Found"
      refute conn.resp_body =~ "runtime-card"
      assert counts() == before
    after
      if previous,
        do: Application.put_env(:devils_dictionary, :published_host, previous),
        else: Application.delete_env(:devils_dictionary, :published_host)
    end
  end
end
