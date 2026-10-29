defmodule DevilsDictionary.Curation.AutonomousCuratorTest do
  use DevilsDictionary.DataCase, async: false
  import Ecto.Query
  import Phoenix.ConnTest
  @endpoint DevilsDictionaryWeb.Endpoint
  import DevilsDictionary.CurationFixtures
  import DevilsDictionary.ProposalFixtures
  import DevilsDictionary.RefreshFixtures

  alias DevilsDictionary.Curation.{
    Configurations,
    Compositions,
    CompositionVersion,
    CompositionPublication,
    CompositionReview,
    Proposal,
    Published,
    Receipt,
    Refresh,
    DueDispatcher
  }

  setup do
    w = editor_world!(%{}, publish: false, enable: false)

    {:ok, version} =
      Configurations.create_version(w.reviewer, w.configuration.id, %{
        reason: "autonomous test policy",
        refresh_window: 86_400,
        editor_publication: "single_editor_v1",
        editor: %{
          profile_id: w.profile.id,
          profile_version_id: w.profile_version.id,
          model_config_id: w.model_config.id
        }
      })

    {:ok, _} =
      Configurations.activate(w.reviewer, w.configuration.id, version.id,
        reason: "test activation",
        expected: w.editor_version.id,
        idempotency_key: key("activate-auto")
      )

    w = %{w | editor_version: version, configuration_version: version}
    enable!(w)
    Map.put(w, :frozen, frozen!())
  end

  defp choose(w) do
    stub_answer!(w, answer_for(w.frozen, w.bierce.object_id, [w.johnson.object_id]))
  end

  defp assess(w) do
    assert {:ok, :admitted} = Refresh.admit(w.composition.id, slug: "love")
    result = work!(w)
    if match?({:ok, _}, result), do: settle!()
    result
  end

  test "routine admitted assessment publishes exact model version with no review or pending queue",
       w do
    choose(w)
    assert {:ok, row} = assess(w)
    assert row.last_outcome_reason == "published_automatically"
    assert row.superseded_on_arrival == false
    assert row.review_unit_reserved_at == nil
    assert_received :chat_called
    assert Repo.aggregate(CompositionReview, :count) == 0
    assert Repo.aggregate(Proposal, :count) == 0
    receipt = Repo.one!(CompositionPublication)
    assert receipt.authority_kind == :single_editor
    assert receipt.actor_id == w.bot.id
    assert receipt.authorizing_review_id == nil
    version = Repo.get!(CompositionVersion, receipt.published_version_id)
    assert version.origin == :model
    assert version.attempt_id
    assert {:ok, published} = Published.current(w.composition.id)
    assert published.version.id == version.id
    assert {:ok, public_receipt} = Receipt.read("love", version.version)
    assert public_receipt.review_actor == nil
    assert public_receipt.publication.authority_kind == :single_editor
    assert Enum.any?(public_receipt.items, &(&1.chooser.attempt_id == version.attempt_id))
    assert {:ok, :fresh} = Refresh.admit(w.composition.id, slug: "love")
    refute_received :chat_called
  end

  test "unchanged valid assessment does not create another publication", w do
    choose(w)
    assert {:ok, _} = assess(w)
    first = Repo.one!(CompositionPublication)
    assert {:ok, row} = run!(w)
    assert row.last_outcome == :no_change
    assert row.last_outcome_reason == "matches_published"
    assert Repo.one!(CompositionPublication).id == first.id
    assert Repo.aggregate(CompositionVersion, :count) == 1
  end

  test "owner mine is a durable hold, skips calls and dispatch", w do
    choose(w)
    assert {:ok, _} = Compositions.set_mode(w.reviewer, w.composition.id, :mine, [])
    DueDispatcher.dispatch(w.editor_version)
    refute Repo.exists?(DevilsDictionary.Curation.RefreshState)
    assert {:ok, row} = run!(w)
    assert row.last_outcome_reason == "owner_hold"
    refute_received :chat_called
    refute Repo.exists?(CompositionPublication)
    assert Repo.reload!(w.composition).mode == :mine
    assert {:ok, _} = Compositions.set_mode(w.reviewer, w.composition.id, :open, [])
    assert {:ok, _} = run!(w)
    assert Repo.exists?(CompositionPublication)
  end

  test "due dispatcher coalesces with visits and stops on disabled switch", w do
    DueDispatcher.dispatch(w.editor_version)
    row = row!(w.composition)
    assert row.state == :queued
    assert {:ok, :in_flight} = Refresh.admit(w.composition.id, slug: "love")

    assert Enum.count(
             Repo.all(Oban.Job),
             &(&1.worker == "DevilsDictionary.Curation.RefreshWorker")
           ) == 1

    {:ok, _} = Configurations.disable_editor(w.reviewer, w.configuration.id, reason: "test stop")
    before = Repo.aggregate(Oban.Job, :count)

    assert :ok =
             DueDispatcher.perform(%Oban.Job{
               args: %{"configuration_version_id" => w.editor_version.id}
             })

    assert Repo.aggregate(Oban.Job, :count) == before
  end

  test "manual policy is default and unsupported publication policies are refused", w do
    assert {:error, :invalid_publication_policy} =
             Configurations.create_version(w.reviewer, w.configuration.id, %{
               reason: "invalid",
               editor_publication: "anything"
             })

    assert {:error, :invalid_publication_policy} =
             Configurations.create_version(w.reviewer, w.configuration.id, %{
               reason: "missing binding",
               editor_publication: "single_editor_v1"
             })
  end

  defp after_answer(fun) do
    ref = make_ref()
    test = self()

    :telemetry.attach(
      {__MODULE__, ref},
      [:devils_dictionary, :repo, :query],
      fn _, _, meta, _ ->
        if self() == test and meta[:source] == "inference_attempts" and
             is_binary(meta[:query]) and String.starts_with?(meta[:query], "UPDATE") and
             "completed" in List.wrap(meta[:params]) and is_nil(Process.get(ref)) do
          Process.put(ref, true)
          fun.()
        end
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach({__MODULE__, ref}) end)
  end

  test "owner publication during inference wins and model version is not written", w do
    choose(w)
    after_answer(fn -> publish!(w, w.composition) end)
    assert {:ok, _} = assess(w)
    [receipt] = Repo.all(CompositionPublication)
    assert receipt.authority_kind == :operator
    assert Repo.aggregate(CompositionVersion, :count) == 1
  end

  test "hold set during inference prevents automatic publication", w do
    choose(w)
    after_answer(fn -> Compositions.set_mode(w.reviewer, w.composition.id, :mine, []) end)
    assert {:ok, row} = assess(w)
    assert row.last_outcome_reason == "owner_hold"
    refute Repo.exists?(CompositionPublication)
    refute Repo.exists?(CompositionVersion)
  end

  test "disable during inference vetoes publication; no human queue is created", w do
    choose(w)

    after_answer(fn ->
      Configurations.disable_editor(w.reviewer, w.configuration.id, reason: "stop")
    end)

    assert {:ok, row} = assess(w)
    assert row.state == :deferred
    assert row.last_completed_at == nil
    refute Repo.exists?(CompositionPublication)
    refute Repo.exists?(Proposal)
  end

  test "input mutation during inference closes without publication", w do
    choose(w)

    after_answer(fn ->
      Repo.update_all(DevilsDictionary.Curation.RefreshState, inc: [dirty_seq: 1])
    end)

    assert {:ok, row} = assess(w)
    assert row.last_completed_at == nil
    refute Repo.exists?(CompositionPublication)
    refute Repo.exists?(CompositionVersion)
  end

  test "abstention is assessed without publication; offline failure defers honestly", w do
    stub_answer!(w, DevilsDictionary.RuntimeFixtures.abstain())
    assert {:ok, row} = assess(w)
    assert row.last_outcome == :abstained
    assert row.last_completed_at
    refute Repo.exists?(CompositionPublication)

    Req.Test.stub(DevilsDictionary.Curation.Runtime.Ollama, fn conn ->
      Req.Test.transport_error(conn, :econnrefused)
    end)

    completed_at = row.last_completed_at
    assert {:ok, row} = run!(w)
    assert row.state == :deferred
    assert row.last_completed_at == completed_at
    refute Repo.exists?(CompositionPublication)
  end

  test "withdrawal remains suppressed across unattended dispatch", w do
    choose(w)
    assert {:ok, _} = assess(w)
    published = Repo.reload!(w.composition).current_published_version_id

    assert {:ok, _} =
             DevilsDictionary.Curation.Publications.withdraw(w.reviewer, w.composition.id,
               reason: "owner withdrawal",
               expected_pointer: published,
               idempotency_key: key("withdraw")
             )

    settle!()
    DueDispatcher.dispatch(w.editor_version)
    assert row!(w.composition).state == :suppressed
    assert Repo.reload!(w.composition).current_published_version_id == nil
  end

  test "raw database receipt cannot forge an agent authority on manual history", w do
    manual = publish!(w, w.composition)

    assert_raise Postgrex.Error, fn ->
      Repo.insert!(%CompositionPublication{
        composition_id: w.composition.id,
        action: :publish,
        authority_kind: :single_editor,
        previous_version_id: manual.version.id,
        published_version_id: manual.version.id,
        actor_id: w.bot.id,
        reason: "forged",
        eligibility_fingerprint: manual.version.eligibility_fingerprint,
        idempotency_key: key("forge")
      })
    end
  end

  for provider <- DevilsDictionary.Curation.Shelf.providers() do
    test "#{provider}: exact agent shelf choice publishes directly with shared basis and receipt",
         w do
      o = DevilsDictionary.ProviderCitationFixtures.provider_observation!(w, unquote(provider))
      frozen = frozen!()
      lead = Enum.find(frozen.packet["candidates"], &(&1["object_id"] == w.bierce.object_id))

      shelf =
        Enum.find(
          frozen.packet["candidates"],
          &(&1["kind"] == "shelf" and &1["shelf"]["result"] == o.result.id)
        )

      assert shelf

      stub_answer!(
        w,
        DevilsDictionary.RuntimeFixtures.selection(
          {lead["candidate_id"], lead["required_meaning"]},
          [{shelf["candidate_id"], shelf["required_meaning"], nil}]
        )
      )

      assert {:ok, row} = assess(w)
      assert row.last_outcome_reason == "published_automatically"
      publication = Repo.one!(CompositionPublication)
      version = Repo.get!(CompositionVersion, publication.published_version_id)
      assert {:ok, receipt} = Receipt.read("love", version.version)
      item = Enum.find(receipt.items, & &1.citation)
      assert item.status == :shown
      assert item.citation.discovery_result_id == o.result.id
      assert item.citation.cited_revision_id == o.revision.id
      assert item.citation.cited_checksum == o.revision.checksum
      assert item.basis.origin == "model"
      assert item.basis.supplied_sha256 == shelf["label_sha256"]
      assert item.chooser.attempt_id == version.attempt_id
      assert receipt.review_actor == nil
      refute Repo.exists?(CompositionReview)
      refute Repo.exists?(Proposal)
    end
  end

  test "native sense and linked claim use the same automatic publication receipt", w do
    entity = DevilsDictionary.WordFixtures.concept!("Q270905", "Autonomous fixture entity")
    DevilsDictionary.WordFixtures.link!(w.love, entity, sense: w.profound)
    frozen = frozen!()
    lead = Enum.find(frozen.packet["candidates"], &(&1["object_id"] == w.bierce.object_id))

    choices =
      for kind <- ["sense_definition", "claim"],
          do: Enum.find(frozen.packet["candidates"], &(&1["kind"] == kind))

    stub_answer!(
      w,
      DevilsDictionary.RuntimeFixtures.selection(
        {lead["candidate_id"], lead["required_meaning"]},
        Enum.map(choices, &{&1["candidate_id"], &1["required_meaning"], nil})
      )
    )

    assert {:ok, row} = assess(w)
    assert row.last_outcome_reason == "published_automatically"

    version =
      Repo.get!(CompositionVersion, Repo.one!(CompositionPublication).published_version_id)

    assert {:ok, receipt} = Receipt.read("love", version.version)
    assert Enum.all?(receipt.items, &(&1.basis.origin == "model" and &1.status == :shown))
    assert Enum.any?(receipt.items, &(&1.kind == :sense_definition))
    assert Enum.any?(receipt.items, &(&1.kind == :claim))
  end

  test "actual expiry and cleanup preserve the automatic choice identity and attribution", w do
    o = DevilsDictionary.CitationFixtures.observation!(w)
    frozen = frozen!()
    lead = Enum.find(frozen.packet["candidates"], &(&1["object_id"] == w.bierce.object_id))

    shelf =
      Enum.find(
        frozen.packet["candidates"],
        &(&1["kind"] == "shelf" and &1["shelf"]["result"] == o.result.id)
      )

    stub_answer!(
      w,
      DevilsDictionary.RuntimeFixtures.selection(
        {lead["candidate_id"], lead["required_meaning"]},
        [{shelf["candidate_id"], shelf["required_meaning"], nil}]
      )
    )

    assert {:ok, _} = assess(w)

    version =
      Repo.get!(CompositionVersion, Repo.one!(CompositionPublication).published_version_id)

    config = Application.fetch_env!(:devils_dictionary, :discovery)
    policies = Keyword.get(config, :source_policies, %{})

    Application.put_env(
      :devils_dictionary,
      :discovery,
      Keyword.put(config, :source_policies, Map.put(policies, "guardian", retention_seconds: 0))
    )

    on_exit(fn -> Application.put_env(:devils_dictionary, :discovery, config) end)
    assert {:ok, receipt} = Receipt.read("love", version.version)
    item = Enum.find(receipt.items, & &1.citation)
    assert item.status_reason == :retention_expired
    DevilsDictionary.Discovery.cleanup()
    assert {:ok, cleaned} = Receipt.read("love", version.version)
    history = Enum.find(cleaned.items, & &1.citation)
    assert history.status_reason == :retention_expired
    assert history.citation.cited_revision_id == o.revision.id
    assert history.chooser.attempt_id == version.attempt_id
    assert history.provider_metadata == nil
  end

  test "one failed pilot page cannot starve later due pages", w do
    previous = Application.fetch_env(:devils_dictionary, :curation_pilot_pages)
    Application.put_env(:devils_dictionary, :curation_pilot_pages, ["war", "love"])

    on_exit(fn ->
      case previous do
        {:ok, pages} -> Application.put_env(:devils_dictionary, :curation_pilot_pages, pages)
        :error -> Application.delete_env(:devils_dictionary, :curation_pilot_pages)
      end
    end)

    read = fn
      "war" -> raise "fixture page failure"
      "love" -> page("love")
    end

    assert [{"war", {:error, :page_read_failed}}, {"love", {:ok, :admitted}}] =
             DueDispatcher.dispatch(w.editor_version, read)

    assert row!(w.composition).state == :queued
  end

  test "enabled executing dispatcher schedules one successor and admits due work", w do
    [job] =
      Repo.all(from j in Oban.Job, where: j.worker == "DevilsDictionary.Curation.DueDispatcher")

    job =
      job
      |> Ecto.Changeset.change(state: "executing", attempted_at: DateTime.utc_now())
      |> Repo.update!()

    assert :ok = DueDispatcher.perform(job)

    future =
      Repo.all(
        from j in Oban.Job,
          where: j.worker == "DevilsDictionary.Curation.DueDispatcher" and j.state == "scheduled"
      )

    assert [successor] = future
    assert DateTime.diff(successor.scheduled_at, DateTime.utc_now()) in 295..300
    assert row!(w.composition).state == :queued
    assert :ok = DueDispatcher.perform(job)

    assert Repo.aggregate(
             from(j in Oban.Job,
               where:
                 j.worker == "DevilsDictionary.Curation.DueDispatcher" and j.state == "scheduled"
             ),
             :count
           ) == 1
  end

  test "a lost lease after an accepted answer cannot publish", w do
    choose(w)
    after_answer(fn -> row!(w.composition) |> set!(lease_expires_at: ago(1)) end)
    assert {:error, :lease_lost} = assess(w)
    refute Repo.exists?(CompositionPublication)
    refute Repo.exists?(CompositionVersion)
  end

  test "public receipt renders honest automatic authority without a human reviewer", w do
    choose(w)
    assert {:ok, _} = assess(w)

    version =
      Repo.get!(CompositionVersion, Repo.one!(CompositionPublication).published_version_id)

    conn = build_conn() |> get("/on/love/receipt/#{version.version}")
    html = html_response(conn, 200)
    assert html =~ "receipt-agent-authority"
    assert html =~ "no human approval"
    refute html =~ "Reviewed by"
  end

  test "replacement retains the original chooser for a kept item and both committed receipts",
       w do
    choose(w)
    assert {:ok, _} = assess(w)
    first = Repo.one!(CompositionPublication)

    original =
      Compositions.items(first.published_version_id)
      |> Enum.find(&(&1.item_object_id == w.johnson.object_id))

    assert {:ok, _} = Compositions.keep(w.reviewer, w.composition.id, original.id, [])
    frozen = frozen!()

    stub_answer!(
      w,
      answer_for(frozen, w.bierce.object_id, [{w.intense.object_id, "quotation:0"}])
    )

    assert {:ok, row} = run!(w)
    assert row.last_outcome_reason == "published_automatically"
    settle!()
    latest = DevilsDictionary.Curation.Publications.latest(w.composition.id)
    assert latest.previous_version_id == first.published_version_id
    version = Repo.get!(CompositionVersion, latest.published_version_id)
    assert {:ok, receipt} = Receipt.read("love", version.version)
    carried = Enum.find(receipt.items, &(&1.reference["item_object_id"] == w.johnson.object_id))
    assert carried

    assert carried.chooser.attempt_id ==
             Repo.get!(CompositionVersion, first.published_version_id).attempt_id

    assert Repo.aggregate(CompositionPublication, :count) == 2
    assert Repo.aggregate(CompositionReview, :count) == 0
    first_version = Repo.get!(CompositionVersion, first.published_version_id)
    assert {:ok, prior} = Receipt.read("love", first_version.version)
    assert Enum.all?(prior.items, &(&1.status == :replaced))
  end

  test "runtime pilot override cannot widen the database-enforced autonomous set", w do
    previous = Application.fetch_env(:devils_dictionary, :curation_pilot_pages)
    Application.put_env(:devils_dictionary, :curation_pilot_pages, ["outside-pilot", "love"])

    on_exit(fn ->
      case previous do
        {:ok, pages} -> Application.put_env(:devils_dictionary, :curation_pilot_pages, pages)
        :error -> Application.delete_env(:devils_dictionary, :curation_pilot_pages)
      end
    end)

    read = fn
      "outside-pilot" -> flunk("outside pilot must never be read or admitted")
      "love" -> page("love")
    end

    assert [{"love", {:ok, :admitted}}] = DueDispatcher.dispatch(w.editor_version, read)
  end

  test "fixed autonomous/default pilot agrees with the publication migration" do
    sql =
      File.read!(
        Application.app_dir(
          :devils_dictionary,
          "priv/repo/migrations/20261029142135_allow_single_editor_publication.exs"
        )
      )

    [_, list] = Regex.run(~r/l\.slug IN \(([^)]+)\)/, sql)
    slugs = list |> String.replace("'", "") |> String.split(",") |> Enum.map(&String.trim/1)
    assert Enum.sort(slugs) == Enum.sort(DevilsDictionary.Curation.Pilot.autonomous_pages())
  end
end
