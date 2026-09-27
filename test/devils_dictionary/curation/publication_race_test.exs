defmodule DevilsDictionary.Curation.PublicationRaceTest do
  @moduledoc """
  R5, and the commit-time checks behind R3 and K1, on committed connections.

  A sandbox wraps a test in one transaction, which never commits. So a
  deferred check never runs there, and two tasks share one connection.
  These tests are `:unboxed`: each task checks out its own connection, rows
  really commit, and the database's row locks and COMMIT-time checks are the
  ones under test. Each task waits at a gate the test opens, and the order of
  events is fixed by messages, never by sleeping.
  """
  use DevilsDictionary.DataCase, async: false

  import DevilsDictionary.CurationFixtures

  alias DevilsDictionary.Curation.{
    Composition,
    CompositionItem,
    CompositionPublication,
    Compositions,
    Publications,
    Reviews
  }

  alias DevilsDictionary.Repo

  @moduletag :unboxed

  setup do
    world = world!()
    {config, _} = enabled_test_configuration!(world.reviewer, "race")

    {:ok, composition} =
      Compositions.provision(world.contributor, config.id, %{
        scope_kind: :lexeme,
        lexeme_ids: [world.love.object_id],
        language_tag: "en",
        reason: "curate love"
      })

    {:ok, v1} =
      Compositions.create_version(world.contributor, composition.id, %{
        lead: content_spec(world.bierce, world.love),
        reason: "one",
        expected_parent: nil
      })

    {:ok, v2} =
      Compositions.create_version(world.contributor, composition.id, %{
        lead: content_spec(world.bierce, world.love),
        highlights: [quotation_spec(world.sense, 1)],
        reason: "two",
        expected_parent: v1.id
      })

    reviews =
      for v <- [v1, v2], into: %{} do
        {:ok, r} =
          Reviews.decide(world.reviewer, v.id, :accepted, reason: "ok", idempotency_key: key())

        {v.id, r}
      end

    Map.merge(world, %{config: config, composition: composition, v1: v1, v2: v2, reviews: reviews})
  end

  # A task on its own connection, which starts when it is sent `{:go, gate}`.
  defp gated(gate, fun) do
    parent = self()

    Task.async(fn ->
      Ecto.Adapters.SQL.Sandbox.checkout(Repo, sandbox: false)
      send(parent, {:ready, self()})
      receive do: ({:go, ^gate} -> fun.())
    end)
  end

  test "two reviewers publishing from the same pointer: exactly one wins, nothing is overwritten",
       ctx do
    second = account([:reviewer])
    gate = make_ref()

    tasks =
      for {reviewer, version} <- [{ctx.reviewer, ctx.v1}, {second, ctx.v2}] do
        gated(gate, fn ->
          Publications.publish(reviewer, version.id,
            reason: "race",
            idempotency_key: key("race"),
            expected_pointer: nil
          )
        end)
      end

    for _ <- tasks, do: assert_receive({:ready, _pid})
    Enum.each(tasks, &send(&1.pid, {:go, gate}))
    results = Enum.map(tasks, &Task.await(&1, 15_000))

    assert [{:ok, receipt}] = Enum.filter(results, &match?({:ok, _}, &1))
    assert [{:error, {:stale_pointer, pointer}}] = Enum.filter(results, &match?({:error, _}, &1))

    assert pointer == receipt.published_version_id
    assert Repo.aggregate(CompositionPublication, :count) == 1
    assert Repo.get!(Composition, ctx.composition.id).current_published_version_id == pointer
  end

  # Postgrex logs the connection it drops after the refused COMMIT.
  @tag :capture_log
  test "writers that skip the service's lock still cannot both commit from one pointer", ctx do
    actor = actor!(ctx.reviewer)
    parent = self()

    # Each writer inserts a receipt continuing from `nil`, then moves the
    # pointer, the way a careless caller would, with no lock first.
    writer = fn version, step ->
      Task.async(fn ->
        Ecto.Adapters.SQL.Sandbox.checkout(Repo, sandbox: false)
        receive do: (:start -> :ok)

        try do
          Repo.transaction(fn ->
            Repo.insert!(%CompositionPublication{
              composition_id: ctx.composition.id,
              action: :publish,
              authority_kind: :operator,
              published_version_id: version.id,
              authorizing_review_id: ctx.reviews[version.id].id,
              actor_id: actor.id,
              reason: "raw",
              eligibility_fingerprint: version.eligibility_fingerprint,
              idempotency_key: key("raw")
            })

            send(parent, {step, :inserted})

            Repo.query!(
              "UPDATE editorial_compositions SET current_published_version_id = $1 WHERE id = $2",
              [version.id, ctx.composition.id]
            )

            send(parent, {step, :moved})
            receive do: (:commit -> :ok)
          end)
        rescue
          e in Postgrex.Error -> {:refused, e.postgres.code, e.postgres.message}
        end
      end)
    end

    first = writer.(ctx.v1, :first)
    second = writer.(ctx.v2, :second)

    send(first.pid, :start)
    assert_receive {:first, :moved}, 5_000

    # The second writer's UPDATE waits on the first's row lock; its receipt is
    # already in.
    send(second.pid, :start)
    assert_receive {:second, :inserted}, 5_000

    send(first.pid, :commit)
    assert {:ok, _} = Task.await(first, 15_000)

    send(second.pid, :commit)

    assert {:refused, :integrity_constraint_violation, message} = Task.await(second, 15_000)
    assert message =~ "does not match its latest publication receipt"

    assert Repo.get!(Composition, ctx.composition.id).current_published_version_id == ctx.v1.id
    assert Repo.aggregate(CompositionPublication, :count) == 1
  end

  @tag :capture_log
  test "every deferred check refuses at a real COMMIT", ctx do
    item = hd(Compositions.items(ctx.v1.id))

    commits = fn fun ->
      try do
        Repo.transaction(fun)
        :committed
      rescue
        e in Postgrex.Error -> {e.postgres.code, e.postgres.message}
      end
    end

    # A configuration pointer with no activation receipt.
    {:ok, v2} =
      DevilsDictionary.Curation.Configurations.create_version(ctx.reviewer, ctx.config.id, %{
        reason: "v2",
        max_highlights: 1
      })

    assert {:integrity_constraint_violation, m1} =
             commits.(fn ->
               Repo.query!(
                 "UPDATE curation_configurations SET current_version_id = $1 WHERE id = $2",
                 [v2.id, ctx.config.id]
               )
             end)

    assert m1 =~ "latest activation receipt"

    # An item added to a version after its transaction.
    assert {:integrity_constraint_violation, m2} =
             commits.(fn ->
               fields =
                 item
                 |> Map.from_struct()
                 |> Map.drop([:__meta__, :id])
                 |> Map.merge(%{role: :highlight, position: 3})

               Repo.insert!(struct(CompositionItem, fields))
             end)

    assert m2 =~ "arrangement differs"

    # A scope whose members no longer match its signature and receipt.
    assert {:integrity_constraint_violation, m3} =
             commits.(fn ->
               Repo.query!(
                 "INSERT INTO editorial_composition_memberships (composition_id, object_id, role, inserted_at) VALUES ($1, $2, 'lexeme', now())",
                 [ctx.composition.id, ctx.amor.object_id]
               )
             end)

    assert m3 =~ "scope does not match"

    # A publication pointer with no receipt.
    assert {:integrity_constraint_violation, m4} =
             commits.(fn ->
               Repo.query!(
                 "UPDATE editorial_compositions SET current_published_version_id = $1 WHERE id = $2",
                 [ctx.v1.id, ctx.composition.id]
               )
             end)

    assert m4 =~ "latest publication receipt"

    assert Repo.get!(Composition, ctx.composition.id).current_published_version_id == nil
    assert length(Compositions.items(ctx.v1.id)) == 1
  end

  test "two provisions of one scope make one composition", ctx do
    {:ok, other} =
      Compositions.provision(ctx.contributor, ctx.config.id, %{
        scope_kind: :lexeme,
        lexeme_ids: [ctx.oats.object_id],
        language_tag: "en",
        reason: "warm up"
      })

    gate = make_ref()
    author = account([:contributor])

    tasks =
      for scope <- [ctx.contributor, author] do
        gated(gate, fn ->
          Compositions.provision(scope, ctx.config.id, %{
            scope_kind: :lexical_page,
            lexeme_ids: [ctx.amor.object_id],
            language_tag: "en",
            reason: "amor's page"
          })
        end)
      end

    for _ <- tasks, do: assert_receive({:ready, _pid})
    Enum.each(tasks, &send(&1.pid, {:go, gate}))

    assert [{:ok, %{id: a}}, {:ok, %{id: b}}] = Enum.map(tasks, &Task.await(&1, 15_000))
    assert a == b
    refute a == other.id

    assert Repo.aggregate(
             from(c in Composition, where: c.scope_kind == :lexical_page),
             :count
           ) == 1
  end
end
