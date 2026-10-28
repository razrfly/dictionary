defmodule DevilsDictionary.Curation.Proposals.StepTest do
  @moduledoc """
  #264 §8 tests 6–11, 13–16, 29 and 34: the editor step inside a claimed
  refresh run (R3), generation identity, retry and recovery (R4), review
  units (R5), every step result mapped (R6), frozen references (R7),
  abstention (R14.2) and the owner's request (R18). The runtime is stubbed
  with `Req.Test` as the runtime tests stub it; no model is reached.
  """
  use DevilsDictionary.DataCase, async: false

  import DevilsDictionary.CurationFixtures
  import DevilsDictionary.ProposalFixtures
  import DevilsDictionary.RefreshFixtures
  import DevilsDictionary.RuntimeFixtures

  alias DevilsDictionary.Curation.{
    CompositionVersion,
    Configurations,
    Proposal,
    Proposals,
    Refresh,
    RefreshState
  }

  alias DevilsDictionary.Curation.Runtime
  alias DevilsDictionary.Curation.Runtime.{Attempt, Gateway, Ollama, Packet}
  alias DevilsDictionary.{ExemplarFixtures, Registry}

  setup do
    world = editor_world!()
    Map.put(world, :frozen, frozen!())
  end

  defp keep_johnson!(world) do
    item =
      DevilsDictionary.Curation.Compositions.items(world.published.version.id)
      |> Enum.find(&(&1.item_object_id == world.johnson.object_id))

    {:ok, _} =
      DevilsDictionary.Curation.Compositions.keep(
        world.reviewer,
        world.composition.id,
        item.id,
        []
      )
  end

  defp lead_and_johnson(world),
    do: answer_for(world.frozen, world.bierce.object_id, [world.johnson.object_id])

  defp attempts, do: Repo.all(from a in Attempt, order_by: a.id)
  defp proposals, do: Repo.all(from p in Proposal, order_by: p.id)
  defp versions, do: Repo.aggregate(CompositionVersion, :count)

  defp key_of(row),
    do:
      Proposals.request_key(
        row.composition_id,
        row.configuration_version_id,
        row.refresh_generation
      )

  # The service answers nothing at all.
  defp offline!(test \\ self()) do
    Req.Test.stub(Ollama, fn conn ->
      send(test, {:http, conn.request_path})
      Req.Test.transport_error(conn, :econnrefused)
    end)
  end

  # Lets a deferred row retry now.
  defp due!(composition) do
    composition |> row!() |> set!(next_retry_at: ago(1))
  end

  # The generation's attempt, made as the step would make it, and then the
  # job dies: nothing after the receipt runs.
  defp attempt_then_die!(world, frozen) do
    claim = claim!(world)
    {:ok, _row} = Refresh.reserve(claim)
    row = Repo.get!(RefreshState, claim.row_id)

    {:ok, receipt} =
      Runtime.run(
        world.model_config,
        frozen,
        Keyword.merge(world.runtime,
          request_key: key_of(row),
          actor_id: world.bot.id,
          purpose: :request
        )
      )

    {claim, receipt}
  end

  # Runs `fun` once, in this process, right after the runtime records an
  # attempt `completed`: after the answer was validated, before the step
  # writes anything.
  defp after_completion(fun) do
    ref = make_ref()
    test = self()

    :telemetry.attach(
      {__MODULE__, ref},
      [:devils_dictionary, :repo, :query],
      fn _event, _measurements, meta, _config ->
        if self() == test and meta[:source] == "inference_attempts" and
             is_binary(meta[:query]) and String.starts_with?(meta[:query], "UPDATE") and
             "completed" in List.wrap(meta[:params]) and is_nil(Process.get(ref)) do
          Process.put(ref, :done)
          fun.()
        end
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach({__MODULE__, ref}) end)
  end

  # A running row whose lease has run out, recovered by the next visit.
  defp expire_and_recover!(world) do
    world.composition |> row!() |> set!(lease_expires_at: ago(1))
    assert {:ok, :recovered} = Refresh.admit(world.composition.id, slug: "love")
  end

  describe "test 6 (R3): the hand-off" do
    test "an enabled needs-editor check calls the runtime once, as the bot, under the generation's key",
         world do
      test = self()

      stub_ollama!(world.model_config,
        chat: fn request ->
          send(test, {:chat, request})
          {:json, answer(lead_and_johnson(world))}
        end
      )

      assert {:ok, row} = run!(world)
      assert {row.last_outcome, row.last_outcome_reason} == {:proposed, "written"}

      assert_received {:chat, request}
      refute_received {:chat, _second}

      [system | _] = request["messages"]
      assert system["content"] == Packet.instruction!("generic-editor-v2")

      [attempt] = attempts()

      assert attempt.request_key ==
               "proposal:#{world.composition.id}:#{world.editor_version.id}:#{row.refresh_generation}"

      assert attempt.requested_by_actor_id == world.bot.id
      assert attempt.model_config_id == world.model_config.id
      assert attempt.purpose == :request
    end

    test "an input change only the check found is recorded, as with the editor off", world do
      visit!()
      {:ok, checked} = work!(world)

      set!(checked,
        input_fingerprint: Refresh.fingerprint_version() <> ":something-else",
        dirty_at: DateTime.utc_now(),
        dirty_reason: "item_withheld",
        inputs_last_changed_at: nil,
        inputs_last_changed_reason: nil
      )

      stub_answer!(world, lead_and_johnson(world))
      visit!()
      assert {:ok, row} = work!(world)

      assert {row.last_outcome, row.last_outcome_reason} == {:proposed, "written"}
      assert row.inputs_last_changed_reason == "inputs_changed"
      assert row.inputs_last_changed_at == row.last_completed_at
    end

    test "a requested run records an input change only its check found, and still reaches the step",
         world do
      visit!()
      {:ok, checked} = work!(world)

      set!(checked,
        input_fingerprint: Refresh.fingerprint_version() <> ":something-else",
        inputs_last_changed_at: nil,
        inputs_last_changed_reason: nil
      )

      stub_answer!(world, lead_and_johnson(world))
      assert {:ok, row} = run!(world)

      assert_received :chat_called
      assert {row.last_outcome, row.last_outcome_reason} == {:proposed, "written"}
      assert row.inputs_last_changed_reason == "inputs_changed"
      assert row.inputs_last_changed_at == row.last_completed_at
    end

    test "an unchanged check calls nothing", world do
      stub_answer!(world, lead_and_johnson(world))

      # A change reported, but the inputs are what they were.
      Refresh.mark_dirty([world.composition.id], "candidate_added")
      visit!()
      assert {:ok, row} = work!(world)

      assert {row.last_outcome, row.last_outcome_reason} == {:unchanged, "accepted"}
      refute_received :chat_called
      assert attempts() == []
    end
  end

  describe "test 7 (R3.2, R5.4): the fence during the call" do
    test "a suppression during the call writes nothing and releases the unit", world do
      stub_ollama!(world.model_config,
        chat: fn _request ->
          withdraw!(world, world.composition)
          {:json, answer(lead_and_johnson(world))}
        end
      )

      before = versions()
      assert {:error, :lease_lost} = run!(world)

      assert proposals() == []
      assert versions() == before
      row = row!(world.composition)
      assert row.state == :suppressed
      assert is_nil(row.review_unit_reserved_at)
      assert Proposals.units_in_use() == 0
    end

    test "a configuration change during the call writes nothing and releases the unit", world do
      stub_ollama!(world.model_config,
        chat: fn _request ->
          {:ok, manual} =
            Configurations.create_version(world.reviewer, world.configuration.id, %{
              reason: "manual again",
              max_highlights: 2
            })

          {:ok, _} =
            Configurations.activate(world.reviewer, world.configuration.id, manual.id,
              reason: "manual again",
              idempotency_key: key("activate"),
              expected: world.editor_version.id
            )

          {:json, answer(lead_and_johnson(world))}
        end
      )

      before = versions()
      assert {:error, :configuration_changed} = run!(world)

      assert proposals() == []
      assert versions() == before
      row = Repo.get_by!(RefreshState, configuration_version_id: world.editor_version.id)
      assert row.state == :idle
      assert is_nil(row.review_unit_reserved_at)
      assert Proposals.units_in_use() == 0
    end

    test "an expired lease writes nothing; the recovery that takes the row releases the unit",
         world do
      stub_ollama!(world.model_config,
        chat: fn _request ->
          world.composition |> row!() |> set!(lease_expires_at: ago(1))
          {:json, answer(lead_and_johnson(world))}
        end
      )

      before = versions()
      assert {:error, :lease_lost} = run!(world)
      assert proposals() == []
      assert versions() == before

      # The stamp counts until a visit recovers or releases it (R5.5).
      assert %DateTime{} = row!(world.composition).review_unit_reserved_at
      assert Proposals.units_in_use() == 1

      expire_and_recover!(world)
      stub_answer!(world, lead_and_johnson(world))
      assert {:ok, row} = work!(world)

      # The recovered run replays the attempt, writes one proposal, and its
      # unit is now the proposal's.
      assert row.last_outcome == :proposed
      assert is_nil(row.review_unit_reserved_at)
      refute_received :chat_called
      assert [_one] = proposals()
      assert Proposals.units_in_use() == 1
    end
  end

  describe "test 8 (R4.3): retry identity" do
    test "a deferred retry with no attempt and an unmoved pointer keeps generation and parent",
         world do
      offline!()
      assert {:ok, deferred} = run!(world)
      assert deferred.state == :deferred
      assert attempts() == []

      due!(world.composition)
      assert {:ok, :admitted} = Refresh.admit(world.composition.id, slug: "love")
      retried = row!(world.composition)

      assert retried.refresh_generation == deferred.refresh_generation
      assert retried.admitted_parent_version_id == deferred.admitted_parent_version_id
    end

    test "a moved pointer opens a new generation against it", world do
      offline!()
      assert {:ok, deferred} = run!(world)

      %{version: v2} =
        publish!(world, world.composition, world.published.version.id,
          highlights: [world.johnson |> content_spec(world.love) |> Map.put(:note, %{text: "J."})]
        )

      due!(world.composition)
      assert {:ok, :admitted} = Refresh.admit(world.composition.id, slug: "love")
      retried = row!(world.composition)

      assert retried.refresh_generation == deferred.refresh_generation + 1
      assert retried.admitted_parent_version_id == v2.id
    end

    test "an answerless attempt opens a new generation and key", world do
      stub_ollama!(world.model_config, chat: fn _ -> {:status, 500, %{"error" => "boom"}} end)
      assert {:ok, deferred} = run!(world)
      assert {deferred.state, deferred.last_error} == {:deferred, "runtime_error"}
      [spent] = attempts()
      assert spent.request_key == key_of(deferred)

      due!(world.composition)
      assert {:ok, :admitted} = Refresh.admit(world.composition.id, slug: "love")
      retried = row!(world.composition)
      assert retried.refresh_generation == deferred.refresh_generation + 1

      stub_answer!(world, lead_and_johnson(world))
      assert {:ok, row} = work!(world)
      assert row.last_outcome == :proposed
      assert [^spent, fresh] = attempts()
      assert fresh.request_key == key_of(retried)
    end

    test "a lease recovery keeps generation, parent and stamp", world do
      visit!()
      Refresh.request(world.reviewer, world.composition.id, "love", "test")
      claim = claim!(world)
      assert {:ok, reserved} = Refresh.reserve(claim)
      assert %DateTime{} = stamp = reserved.review_unit_reserved_at

      expire_and_recover!(world)
      recovered = row!(world.composition)

      assert recovered.refresh_generation == reserved.refresh_generation
      assert recovered.admitted_parent_version_id == reserved.admitted_parent_version_id
      assert recovered.review_unit_reserved_at == stamp
    end
  end

  describe "test 9 (R4, R9): a crash after the result receipt" do
    test "the recovered run replays the attempt, with no second call, and writes one proposal",
         world do
      stub_answer!(world, lead_and_johnson(world))
      {:ok, :admitted} = Refresh.request(world.reviewer, world.composition.id, "love", "test")
      {_claim, receipt} = attempt_then_die!(world, world.frozen)
      assert {receipt.state, receipt.outcome} == {:completed, :accepted}
      assert_received :chat_called

      expire_and_recover!(world)
      assert {:ok, row} = work!(world)
      assert row.last_outcome == :proposed

      refute_received :chat_called
      assert [attempt] = attempts()
      assert [proposal] = proposals()
      version = Repo.get!(CompositionVersion, proposal.version_id)
      assert version.attempt_id == attempt.id
      assert proposal.request_key == attempt.request_key
    end
  end

  describe "test 10 (R4.4): drift" do
    test "another packet under the generation's key proposes nothing and closes the generation",
         world do
      stub_answer!(world, lead_and_johnson(world))
      {:ok, :admitted} = Refresh.request(world.reviewer, world.composition.id, "love", "test")

      # The attempt was made from a packet cut under other limits.
      {:ok, other} =
        Packet.for_page(page("love"), instruction_version: "generic-editor-v2", max_candidates: 3)

      {:ok, other} = Packet.freeze(other)
      assert other.hash != world.frozen.hash
      {_claim, _receipt} = attempt_then_die!(world, other)

      expire_and_recover!(world)
      before = row!(world.composition)
      assert {:ok, row} = work!(world)

      assert row.state == :idle
      assert %DateTime{} = row.dirty_at
      assert row.dirty_reason == "inputs_changed"
      assert is_nil(row.review_unit_reserved_at)
      assert row.last_completed_at == before.last_completed_at
      assert proposals() == []

      assert {:ok, :admitted} = Refresh.admit(world.composition.id, slug: "love")
      assert row!(world.composition).refresh_generation == row.refresh_generation + 1
    end
  end

  describe "test 11 (R5): review units" do
    setup do
      previous = Application.get_env(:devils_dictionary, :curation_review_units)
      on_exit(fn -> restore(:curation_review_units, previous) end)
      :ok
    end

    defp restore(key, nil), do: Application.delete_env(:devils_dictionary, key)
    defp restore(key, value), do: Application.put_env(:devils_dictionary, key, value)

    test "at the cap a run defers review_capacity without calling", world do
      stub_answer!(world, lead_and_johnson(world))
      {:ok, _row} = run!(world)
      assert_received :chat_called
      assert Proposals.units_in_use() == 1

      # The cap is read at runtime: one pending proposal fills a cap of one,
      # as 29 pending and one reserved fill thirty. A kept mark makes the
      # next run more than a repeat of the pending proposal (R6 row 2).
      Application.put_env(:devils_dictionary, :curation_review_units, 1)
      keep_johnson!(world)

      stub_answer!(
        world,
        answer_for(world.frozen, world.bierce.object_id, [
          {world.profound.object_id, "quotation:1"}
        ])
      )

      assert {:ok, row} = run!(world)
      assert {row.state, row.last_error} == {:deferred, "review_capacity"}
      refute_received :chat_called
      assert length(attempts()) == 1
      assert Proposals.units_in_use() == 1
    end

    test "Take, Dismiss and obsolescence each release one, once", world do
      stub_answer!(world, lead_and_johnson(world))
      {:ok, _row} = run!(world)
      [first] = proposals()
      assert Proposals.units_in_use() == 1

      # A newer proposal (the owner keeps Johnson now) makes the older
      # obsolete: still one pending.
      keep_johnson!(world)

      stub_answer!(
        world,
        answer_for(world.frozen, world.bierce.object_id, [
          {world.intense.object_id, "quotation:0"}
        ])
      )

      {:ok, _row} = run!(world)
      assert Repo.reload!(first).state == :obsolete
      assert Proposals.units_in_use() == 1

      [_obsolete, second] = proposals()
      {:ok, _} = Proposals.dismiss(world.reviewer, second.id, reason: "not this one")
      assert Proposals.units_in_use() == 0

      assert {:error, {:proposal_resolved, :dismissed}} =
               Proposals.dismiss(world.reviewer, second.id, reason: "again")

      assert Proposals.units_in_use() == 0

      work = Enum.find(world.frozen.packet["candidates"], &(&1["kind"] == "work"))

      stub_answer!(
        world,
        answer_for(world.frozen, world.bierce.object_id, [
          {world.intense.object_id, "quotation:0"},
          work["object_id"]
        ])
      )

      {:ok, _row} = run!(world)
      third = List.last(proposals())
      assert third.state == :pending
      items = DevilsDictionary.Curation.Compositions.items(third.version_id)
      published = Repo.reload!(world.composition).current_published_version_id

      {:ok, _} =
        Proposals.take(world.reviewer, third.id,
          reason: "take it",
          expected_pointer: published,
          answers: all_yes(items)
        )

      assert Proposals.units_in_use() == 0

      assert {:error, {:proposal_resolved, :taken}} =
               Proposals.take(world.reviewer, third.id,
                 reason: "again",
                 expected_pointer: published,
                 answers: all_yes(items)
               )
    end

    test "complete, fail, release!, suppress and drift each clear the stamp", world do
      # complete: an abstention.
      stub_answer!(world, abstain())
      {:ok, row} = run!(world)
      assert {row.last_outcome, row.review_unit_reserved_at} == {:abstained, nil}

      # fail: an answer that never came.
      stub_ollama!(world.model_config, chat: fn _ -> {:status, 500, %{}} end)
      {:ok, row} = run!(world)
      assert {row.state, row.review_unit_reserved_at} == {:deferred, nil}

      # release! (a configuration change) and suppress are proved by test 7,
      # drift by test 10; each leaves no unit held.
      assert Proposals.units_in_use() == 0
    end
  end

  describe "test 13 (R6): an offline service" do
    test "defers with backoff, keeps freshness, takes no unit, and never delays the visit",
         world do
      visit!()
      {:ok, before} = work!(world)
      offline!()

      # The visit admits and returns: it calls nothing.
      assert {:ok, :admitted} = Refresh.request(world.reviewer, world.composition.id, "love", "t")
      refute_received {:http, _path}

      assert {:ok, row} = work!(world)
      assert_received {:http, _path}
      assert row.state == :deferred
      assert row.last_error == "service_unreachable"
      assert DateTime.compare(row.next_retry_at, DateTime.utc_now()) == :gt
      assert row.last_completed_at == before.last_completed_at
      assert attempts() == []
      assert is_nil(row.review_unit_reserved_at)
      assert Proposals.units_in_use() == 0
    end
  end

  describe "test 14 (R4.5, R6): every refusal mapped" do
    test "refusals before admission defer and keep the generation", world do
      stub_answer!(world, lead_and_johnson(world))
      Gateway.pause(:operator, world.runtime)

      assert {:ok, row} = run!(world)
      assert {row.state, row.last_error} == {:deferred, "paused"}
      assert attempts() == []

      Gateway.resume(world.runtime)
      due!(world.composition)
      {:ok, :admitted} = Refresh.admit(world.composition.id, slug: "love")
      assert row!(world.composition).refresh_generation == row.refresh_generation
    end

    for refusal <- [
          :foreign_authority,
          :artifact_not_on_models_root,
          :slot_busy,
          :quarantined,
          :budget_exhausted,
          :pending_cap_reached,
          :memory_pressure
        ] do
      test "#{refusal} defers without spending this generation", world do
        visit!()
        {:ok, before} = work!(world)
        stub_answer!(world, lead_and_johnson(world))
        runtime = refuse_runtime!(world, unquote(refusal))
        old_attempts = attempts()
        assert {:ok, row} = run!(world, "love", runtime: runtime)
        assert {row.state, row.last_error} == {:deferred, to_string(unquote(refusal))}
        assert row.last_completed_at == before.last_completed_at
        assert DateTime.compare(row.next_retry_at, DateTime.utc_now()) == :gt
        assert is_nil(row.review_unit_reserved_at)
        assert attempts() == old_attempts
        refute Enum.any?(attempts(), &(&1.request_key == key_of(row)))
        refute_received :chat_called
        assert proposals() == []
        due!(world.composition)
        assert {:ok, :admitted} = Refresh.admit(world.composition.id, slug: "love")
        assert row!(world.composition).refresh_generation == row.refresh_generation
      end
    end

    test "never_sent is a spent answerless attempt, including on replay", world do
      visit!()
      {:ok, before} = work!(world)
      stub_ollama!(world.model_config, chat: fn _ -> {:transport, :econnrefused} end)
      {:ok, :admitted} = Refresh.request(world.reviewer, world.composition.id, "love", "test")
      {_claim, receipt} = attempt_then_die!(world, world.frozen)
      assert {receipt.state, receipt.outcome} == {:failed_pre_dispatch, :never_sent}
      expire_and_recover!(world)
      assert {:ok, row} = work!(world)
      assert {row.state, row.last_error} == {:deferred, "failed_pre_dispatch"}
      assert row.last_completed_at == before.last_completed_at
      assert is_nil(row.review_unit_reserved_at)
      assert DateTime.compare(row.next_retry_at, DateTime.utc_now()) == :gt
      [attempt] = attempts()
      assert {attempt.state, attempt.outcome} == {:failed_pre_dispatch, :never_sent}
      assert attempt.request_key == key_of(row)
      assert proposals() == []
      due!(world.composition)
      assert {:ok, :admitted} = Refresh.admit(world.composition.id, slug: "love")
      assert row!(world.composition).refresh_generation == row.refresh_generation + 1
    end

    test "an unknown recovered attempt replays answerless and spends the generation", world do
      visit!()
      {:ok, before} = work!(world)
      stub_answer!(world, lead_and_johnson(world))
      {:ok, :admitted} = Refresh.request(world.reviewer, world.composition.id, "love", "test")
      claim = claim!(world)
      {:ok, reserved} = Refresh.reserve(claim)
      opts = Keyword.merge(world.runtime, request_key: key_of(reserved), actor_id: world.bot.id)
      {:ok, attempt} = Gateway.admit(world.model_config, world.frozen, opts)
      {:ok, attempt} = Gateway.dispatch(attempt, opts)
      {:ok, _} = Gateway.mark_uncertain(attempt, :timeout, opts)
      # Gateway-only recovery is a database fixture, never a service operation.
      {:ok, _} =
        Gateway.recover(%{stopped_at: DateTime.utc_now(), evidence: %{fixture: true}}, opts)

      {:ok, _} = Gateway.resume(opts)
      expire_and_recover!(world)
      assert {:ok, row} = work!(world)
      assert {row.state, row.last_error} == {:deferred, "ended_by_restart"}
      assert row.last_completed_at == before.last_completed_at
      assert is_nil(row.review_unit_reserved_at)
      assert DateTime.compare(row.next_retry_at, DateTime.utc_now()) == :gt
      [ended] = attempts()
      assert {ended.state, ended.outcome} == {:ended_by_restart, :unknown}
      assert ended.request_key == key_of(row)
      refute_received :chat_called
      assert proposals() == []
      due!(world.composition)
      assert {:ok, :admitted} = Refresh.admit(world.composition.id, slug: "love")
      assert row!(world.composition).refresh_generation == row.refresh_generation + 1
    end

    for {name, chat, expected} <- [
          {"an uncertain call", quote(do: fn _ -> {:transport, :timeout} end), "uncertain"},
          {"a runtime error", quote(do: fn _ -> {:status, 500, %{}} end), "runtime_error"},
          {"a validation refusal",
           quote(do: fn _ -> {:json, answer(selection({"c99", "m9"}, []))} end), "refused"}
        ] do
      test "#{name} spends the generation and never advances freshness", world do
        visit!()
        {:ok, before} = work!(world)

        stub_ollama!(world.model_config, chat: unquote(chat))
        assert {:ok, row} = run!(world)
        assert {row.state, row.last_error} == {:deferred, unquote(expected)}
        assert row.last_completed_at == before.last_completed_at
        assert is_nil(row.review_unit_reserved_at)
        [spent] = attempts()
        assert spent.request_key == key_of(row)

        due!(world.composition)
        {:ok, :admitted} = Refresh.admit(world.composition.id, slug: "love")
        retried = row!(world.composition)
        assert retried.refresh_generation == row.refresh_generation + 1
        refute key_of(retried) == spent.request_key
        assert proposals() == []
      end
    end
  end

  defp refuse_runtime!(world, reason) do
    alias DevilsDictionary.Curation.Runtime.{Authority, FakeSystem}
    opts = world.runtime

    case reason do
      :foreign_authority ->
        identity = Map.put(Authority.identity(opts), "database", "elsewhere")
        FakeSystem.put_file(Authority.path(opts), Jason.encode!(identity))

      :artifact_not_on_models_root ->
        FakeSystem.put(files: %{})
        bind!(opts)

      :memory_pressure ->
        FakeSystem.put(
          memory: [{:ok, %{swap_used_bytes: 0, swap_total_bytes: 1, free_percent: 4}}]
        )

      r when r in [:slot_busy, :quarantined] ->
        {:ok, attempt} =
          Gateway.admit(
            world.model_config,
            world.frozen,
            Keyword.merge(opts, request_key: key("other-slot"), actor_id: world.bot.id)
          )

        if r == :quarantined do
          {:ok, attempt} = Gateway.dispatch(attempt, opts)
          {:ok, _} = Gateway.mark_uncertain(attempt, :timeout, opts)
        end

      _ ->
        :ok
    end

    case reason do
      :budget_exhausted -> Keyword.put(opts, :daily_budget_ms, 0)
      :pending_cap_reached -> Keyword.put(opts, :pending_cap_units, 0)
      _ -> opts
    end
  end

  describe "test 15 (R7): frozen references" do
    test "each item carries its frozen reference, a quotation the packet's words_sha256, never the quote's",
         world do
      # An accepted exemplar under the benevolent sense.
      person = ExemplarFixtures.person!("Fixture exemplar")
      claim = ExemplarFixtures.nominate!(world.author, person, world.benevolent)
      ExemplarFixtures.decide!(world.reviewer, claim)
      frozen = frozen!()

      quotation = pick(frozen, {world.profound.object_id, "quotation:1"})
      work = Enum.find(frozen.packet["candidates"], &(&1["kind"] == "work"))
      exemplar = Enum.find(frozen.packet["candidates"], &(&1["kind"] == "exemplar"))
      lead = pick(frozen, world.bierce.object_id)
      quote = "with looks of cordial love"
      assert String.contains?(quotation["excerpt"], quote)

      content = %{
        "decision" => "select",
        "lead" => %{
          "candidate_id" => lead["candidate_id"],
          "meaning_id" => lead["required_meaning"],
          "reason" => "Bierce leads."
        },
        "highlights" => [
          %{
            "candidate_id" => quotation["candidate_id"],
            "meaning_id" => quotation["required_meaning"],
            "quote" => quote,
            "reason" => "Milton."
          },
          %{
            "candidate_id" => work["candidate_id"],
            "meaning_id" => work["required_meaning"],
            "quote" => nil,
            "reason" => "A painting."
          },
          %{
            "candidate_id" => exemplar["candidate_id"],
            "meaning_id" => exemplar["required_meaning"],
            "quote" => nil,
            "reason" => "An example."
          }
        ],
        "abstain_reason" => nil
      }

      stub_answer!(world, content)
      assert {:ok, %{last_outcome: :proposed}} = run!(world)
      settle!()

      [proposal] = proposals()
      [attempt] = attempts()
      items = DevilsDictionary.Curation.Compositions.items(proposal.version_id)
      meanings = Map.new(frozen.packet["meanings"], &{&1["meaning_id"], &1})

      summarized =
        Enum.find(
          attempt.packet_summary["candidates"],
          &(&1["candidate_id"] == quotation["candidate_id"])
        )

      assert summarized["words_sha256"] == quotation["words_sha256"]

      q = Enum.find(items, &(&1.item_kind == :sense_quotation))
      assert q.words_sha256 == quotation["words_sha256"]
      refute q.words_sha256 == DevilsDictionary.Curation.Digest.sha256(quote)

      assert {q.sense_revision_id, q.locator} ==
               {quotation["sense_revision_id"], quotation["locator"]}

      assert q.meaning_sense_revision_id ==
               meanings[quotation["required_meaning"]]["sense_revision_id"]

      assert attempt.result["highlights"] |> hd() |> get_in(["quote", "sha256"]) ==
               DevilsDictionary.Curation.Digest.sha256(quote)

      l = Enum.find(items, &(&1.role == :lead))

      assert {l.item_object_id, l.content_revision_id} ==
               {lead["object_id"], lead["content_revision_id"]}

      assert l.meaning_lexeme_id == meanings[lead["required_meaning"]]["lexeme_id"]

      w = Enum.find(items, &(&1.item_kind == :work))

      assert {w.catalog_manifest, w.catalog_checksum, w.catalog_identity} ==
               {work["catalog"]["manifest"], work["catalog"]["checksum"],
                work["catalog"]["identity"]}

      e = Enum.find(items, &(&1.item_kind == :exemplar))
      assert e.assertion_revision_id == exemplar["assertion_revision_id"]
      assert e.item_object_id == exemplar["object_id"]

      for item <- items do
        assert {item.selection_origin, item.note_author_kind, item.note_author_actor_id} ==
                 {:model, :model, world.bot.id}
      end
    end
  end

  describe "test 16 (R7.6): a chosen item superseded during the call" do
    test "closes the generation and writes nothing", world do
      # Superseded after the runtime validated the answer and before the
      # write: a revision made during the call itself is refused by the
      # runtime's own validation (C3), which is the earlier guard.
      after_completion(fn ->
        {:ok, _} =
          Registry.add_content_revision(world.johnson.object_id, %{
            headword: "LOVE",
            body: "1. The passion between the sexes, revised.",
            source_id: world.johnson.source_id
          })
      end)

      stub_answer!(world, lead_and_johnson(world))

      before = versions()
      assert {:ok, row} = run!(world)
      assert row.state == :idle
      assert %DateTime{} = row.dirty_at
      assert is_nil(row.review_unit_reserved_at)
      assert proposals() == []
      assert versions() == before

      # The generation is closed: the next admission opens the next one.
      assert {:ok, :admitted} = Refresh.admit(world.composition.id, slug: "love")
      assert row!(world.composition).refresh_generation == row.refresh_generation + 1
    end
  end

  describe "R6 rows through Proposals.step/3" do
    defp forty_eight?(row),
      do: DateTime.diff(row.refresh_after, row.last_completed_at) == 48 * 3600

    # A page of its own, provisioned under the editor's configuration
    # version, and the worker's claim and check of a requested run.
    defp page_composition!(world, lexemes) do
      {:ok, composition} =
        DevilsDictionary.Curation.Compositions.provision(world.author, world.configuration.id, %{
          scope_kind: :lexical_page,
          lexeme_ids: Enum.map(lexemes, & &1.object_id),
          language_tag: "en",
          reason: "#264 R6 test"
        })

      composition
    end

    defp requested_check!(world, composition, slug) do
      {:ok, :admitted} = Refresh.request(world.reviewer, composition.id, slug, "R6 test")
      row = row!(composition)
      {:ok, claim} = Refresh.claim(row.id, row.refresh_generation)
      Refresh.check(claim, slug, runtime: world.runtime)
    end

    test "a refused packet completes needs_editor / packet_refused, 48 hours, no call, no unit",
         world do
      quark = DevilsDictionary.WordFixtures.word!(world, "quark", ~w(wordnet), scope: nil)
      composition = page_composition!(world, [quark])
      stub_answer!(world, abstain())

      assert {:ok, row} = requested_check!(world, composition, "quark")

      assert {row.state, row.last_outcome, row.last_outcome_reason} ==
               {:idle, :needs_editor, "packet_refused:no_candidates"}

      assert forty_eight?(row)
      assert is_nil(row.review_unit_reserved_at)
      refute_received :chat_called
      assert attempts() == []
      assert Proposals.units_in_use() == 0
    end

    test "a pending proposal from the same packet, marks and parent completes proposed / pending, with no call",
         world do
      stub_answer!(world, lead_and_johnson(world))
      {:ok, _row} = run!(world)
      assert_received :chat_called
      [pending] = proposals()

      assert {:ok, row} = run!(world)
      assert {row.last_outcome, row.last_outcome_reason} == {:proposed, "pending"}
      assert forty_eight?(row)
      assert is_nil(row.review_unit_reserved_at)
      refute_received :chat_called
      assert length(attempts()) == 1
      assert [^pending] = proposals()
      assert Proposals.units_in_use() == 1
    end

    test "a merged arrangement the lead rule refuses completes no_change / merge_refused",
         world do
      alias DevilsDictionary.{Curation, WordFixtures}

      # A fallback-lead page: Johnson leads oats by hand, and the owner keeps it.
      oats = WordFixtures.word!(world, "oats", ~w(johnson wiktionary bierce), scope: nil)

      johnson =
        WordFixtures.entry!(world, oats, "johnson",
          headword: "OATS",
          pos: "n. s.",
          body: "A grain."
        )

      sense =
        WordFixtures.sense!(world, oats, "wiktionary",
          gloss: "A cereal grain.",
          examples: [%{"type" => "quotation", "text" => "fixture oats line", "ref" => "r"}]
        )

      composition = page_composition!(world, [oats])

      {:ok, v1} =
        Curation.Compositions.create_version(world.author, composition.id, %{
          lead: content_spec(johnson, oats),
          highlights: [sense |> quotation_spec(0) |> Map.put(:note, %{text: "A line."})],
          reason: "Johnson leads",
          expected_parent: nil
        })

      {:ok, _} =
        Curation.Reviews.decide(world.reviewer, v1.id, :accepted,
          reason: "ok",
          idempotency_key: key("r")
        )

      {:ok, _} =
        Curation.Publications.publish(world.reviewer, v1.id,
          reason: "ok",
          idempotency_key: key("p"),
          expected_pointer: nil
        )

      lead = Curation.Compositions.items(v1.id) |> Enum.find(&(&1.role == :lead))
      {:ok, _} = Curation.Compositions.keep(world.reviewer, composition.id, lead.id, [])

      # A Bierce entry for oats appears: only it may lead now. The kept
      # Johnson lead is carried and takes the lead, the editor's Bierce lead
      # overflows, and the lead rule refuses the merge, on every retry alike.
      bierce =
        WordFixtures.entry!(world, oats, "bierce",
          headword: "OATS",
          pos: "n",
          body: "fixture bierce oats."
        )

      frozen = frozen!("oats")

      stub_answer!(
        world,
        answer_for(frozen, bierce.object_id, [{sense.object_id, "quotation:0"}])
      )

      before = versions()

      assert {:ok, row} = requested_check!(world, composition, "oats")
      assert {row.last_outcome, row.last_outcome_reason} == {:no_change, "merge_refused"}
      assert forty_eight?(row)
      assert is_nil(row.review_unit_reserved_at)
      assert_received :chat_called
      assert [%{state: :completed, outcome: :accepted}] = attempts()
      assert versions() == before
      assert proposals() == []
      assert Proposals.units_in_use() == 0
    end

    test "{:refused, :stale}: deferred stale, freshness kept, stamp cleared, the generation spent",
         world do
      visit!()
      {:ok, before} = work!(world)

      # The slot is lost while the model answers: a sweep past the lease
      # quarantines the dispatched attempt, so its completion is stale.
      stub_ollama!(world.model_config,
        chat: fn _request ->
          later = DateTime.add(DateTime.utc_now(), 3600)
          {:ok, :quarantined} = Gateway.sweep(Keyword.put(world.runtime, :now, later))
          {:json, answer(lead_and_johnson(world))}
        end
      )

      assert {:ok, row} = run!(world)
      assert {row.state, row.last_error} == {:deferred, "stale"}
      assert row.last_completed_at == before.last_completed_at
      assert is_nil(row.review_unit_reserved_at)
      [spent] = attempts()
      assert spent.request_key == key_of(row)
      assert spent.state == :uncertain

      due!(world.composition)
      {:ok, :admitted} = Refresh.admit(world.composition.id, slug: "love")
      retried = row!(world.composition)
      assert retried.refresh_generation == row.refresh_generation + 1
      refute key_of(retried) == spent.request_key
      assert proposals() == []
    end
  end

  describe "test 29 (R14.2): abstention" do
    test "writes nothing, completes abstained for 48 hours and releases the unit", world do
      stub_answer!(world, abstain())
      before = versions()

      assert {:ok, row} = run!(world)
      assert {row.last_outcome, row.last_outcome_reason} == {:abstained, "abstained"}
      assert DateTime.diff(row.refresh_after, row.last_completed_at) == 48 * 3600
      assert is_nil(row.review_unit_reserved_at)
      assert versions() == before
      assert proposals() == []

      # A visit before 48 hours admits nothing.
      assert {:ok, :fresh} = visit!()

      # A changed input admits.
      Refresh.mark_dirty([world.composition.id], "candidate_added")
      assert {:ok, :admitted} = visit!()
    end
  end

  describe "test 34 (R18): request a proposal" do
    test "is a reviewer's, lifts the backoff, reaches the step on unchanged inputs, once",
         world do
      assert {:error, :unauthorized} =
               Refresh.request(world.author, world.composition.id, "love", "please")

      # A checked page, inputs unchanged.
      visit!()
      stub_answer!(world, lead_and_johnson(world))
      {:ok, checked} = work!(world)
      assert checked.last_outcome == :unchanged
      refute_received :chat_called

      # A deferral with a backoff in the future.
      offline!()
      {:ok, deferred} = run!(world)
      assert deferred.state == :deferred
      assert DateTime.compare(deferred.next_retry_at, DateTime.utc_now()) == :gt

      stub_answer!(world, lead_and_johnson(world))

      history =
        Map.take(row!(world.composition), [:inputs_last_changed_at, :inputs_last_changed_reason])

      assert {:ok, :admitted} =
               Refresh.request(world.reviewer, world.composition.id, "love", "please")

      assert {:ok, :in_flight} =
               Refresh.request(world.reviewer, world.composition.id, "love", "again")

      # Dirty, but no input change in the history (#273 review, rec. 8).
      requested = row!(world.composition)
      assert requested.dirty_reason == "requested"

      assert Map.take(requested, [:inputs_last_changed_at, :inputs_last_changed_reason]) ==
               history

      assert {:ok, row} = work!(world)
      assert row.last_outcome == :proposed
      assert_received :chat_called
    end
  end
end
