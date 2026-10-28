defmodule DevilsDictionary.Curation.Proposals.ReviewRegressionTest do
  use DevilsDictionary.DataCase, async: false
  import Phoenix.LiveViewTest, only: [render_component: 2]
  import DevilsDictionary.CurationFixtures
  import DevilsDictionary.ProposalFixtures
  import DevilsDictionary.RefreshFixtures
  import DevilsDictionary.RuntimeFixtures

  alias DevilsDictionary.Curation.{
    Compositions,
    CompositionVersion,
    Proposals,
    PublishedReader,
    Refresh
  }

  alias DevilsDictionary.WordFixtures
  @moduletag :unboxed

  test "R5 reservation-to-proposal conversion cannot disappear from the cap count" do
    old = Application.get_env(:devils_dictionary, :curation_review_units)
    Application.put_env(:devils_dictionary, :curation_review_units, 1)

    on_exit(fn ->
      if old,
        do: Application.put_env(:devils_dictionary, :curation_review_units, old),
        else: Application.delete_env(:devils_dictionary, :curation_review_units)
    end)

    world = editor_world!()
    hope = WordFixtures.word!(world, "hope", ~w(wiktionary), scope: nil)

    {:ok, other} =
      Compositions.provision(world.author, world.configuration.id, %{
        scope_kind: :lexical_page,
        lexeme_ids: [hope.object_id],
        language_tag: "en",
        reason: "review probe"
      })

    {:ok, :admitted} = Refresh.admit(other.id, slug: "hope")
    r = row!(other)
    {:ok, claim} = Refresh.claim(r.id, r.refresh_generation)
    parent = self()
    tag = make_ref()

    :ok =
      :telemetry.attach(
        tag,
        [:devils_dictionary, :repo, :query],
        fn _, _, meta, _ ->
          if Process.get(:reviewer_gate) && is_binary(meta[:query]) &&
               String.starts_with?(meta.query, "SELECT (SELECT count(*) FROM curation_proposals") do
            Process.delete(:reviewer_gate)
            send(parent, {:counted_pending, self()})

            receive do
              :continue_count -> :ok
            after
              15_000 -> raise "count gate timeout"
            end
          end
        end,
        nil
      )

    on_exit(fn -> :telemetry.detach(tag) end)

    contender =
      Task.async(fn ->
        Ecto.Adapters.SQL.Sandbox.checkout(Repo, sandbox: false)

        receive do
          :reserve -> :ok
        end

        Process.put(:reviewer_gate, true)
        Refresh.reserve(claim)
      end)

    content = answer_for(frozen!(), world.bierce.object_id, [world.johnson.object_id])

    stub_ollama!(world.model_config,
      chat: fn _ ->
        send(contender.pid, :reserve)
        assert_receive {:counted_pending, pid} when pid == contender.pid, 10_000
        {:json, answer(content)}
      end
    )

    assert {:ok, %{last_outcome: :proposed}} = run!(world)
    send(contender.pid, :continue_count)
    result = Task.await(contender, 15_000)
    assert match?({:deferred, _}, result)
    assert Proposals.units_in_use() == 1
  end

  for state <- [:pending, :dismissed] do
    test "R13 ordinary manual child of #{state} is not attributed as a taken proposal" do
      world = editor_world!()

      stub_answer!(
        world,
        answer_for(frozen!(), world.bierce.object_id, [world.johnson.object_id])
      )

      assert {:ok, %{last_outcome: :proposed}} = run!(world)
      proposal = Proposals.pending(world.composition.id)

      if unquote(state) == :dismissed do
        {:ok, _} = Proposals.dismiss(world.reviewer, proposal.id, reason: "not this proposal")
      end

      %{version: manual} =
        publish!(world, world.composition, world.published.version.id,
          highlights: [
            world.johnson
            |> content_spec(world.love)
            |> Map.put(:note, %{text: "Independent owner choice."})
          ]
        )

      assert manual.parent_version_id == proposal.version_id
      assert Repo.reload!(proposal).state == unquote(state)
      opening = PublishedReader.opening(page("love"))
      refute Map.has_key?(opening.review.selected_by, :taken_by)
    end
  end

  test "R16 a carried model note keeps its original attempt through another proposal and Take" do
    world = editor_world!()
    stub_answer!(world, answer_for(frozen!(), world.bierce.object_id, [world.johnson.object_id]))
    assert {:ok, %{last_outcome: :proposed}} = run!(world)
    first = Proposals.pending(world.composition.id)
    first_attempt = Repo.get!(CompositionVersion, first.version_id).attempt_id

    {:ok, %{version: taken}} =
      Proposals.take(world.reviewer, first.id,
        reason: "fixture take",
        expected_pointer: world.published.version.id,
        answers: all_yes(Compositions.items(first.version_id))
      )

    kept =
      Compositions.items(taken.id) |> Enum.find(&(&1.item_object_id == world.johnson.object_id))

    {:ok, _} = Compositions.keep(world.reviewer, world.composition.id, kept.id, [])

    stub_answer!(
      world,
      answer_for(frozen!(), world.bierce.object_id, [{world.intense.object_id, "quotation:0"}])
    )

    assert {:ok, %{last_outcome: :proposed}} = run!(world)
    second = Proposals.pending(world.composition.id)

    {:ok, _} =
      Proposals.take(world.reviewer, second.id,
        reason: "fixture second take",
        expected_pointer: taken.id,
        answers: all_yes(Compositions.items(second.version_id))
      )

    for {{object, locator}, generation} <-
          Enum.with_index([
            {world.profound, "quotation:1"},
            {world.intense, "quotation:0"},
            {world.profound, "quotation:1"}
          ]) do
      content = answer_for(frozen!(), world.bierce.object_id, [{object.object_id, locator}])
      content = put_in(content, ["lead", "reason"], "Fresh lead assessment #{generation}.")
      stub_answer!(world, content)

      assert {:ok, %{last_outcome: :proposed}} = run!(world)
      next = Proposals.pending(world.composition.id)
      pointer = Repo.reload!(world.composition).current_published_version_id

      {:ok, _} =
        Proposals.take(world.reviewer, next.id,
          reason: "carry again",
          expected_pointer: pointer,
          answers: all_yes(Compositions.items(next.version_id))
        )
    end

    opening = PublishedReader.opening(page("love"))
    johnson = Enum.find(opening.highlights, &(&1.position == 1))
    reason = Enum.find(johnson.reasons, &(&1.kind == :editorial))
    assert reason.author.attempt_id == first_attempt

    html =
      render_component(&DevilsDictionaryWeb.Opening.section/1,
        opening: opening,
        mode: :internal,
        reviewer?: true
      )

    assert html =~ "Generated by #{reason.author.label}, an AI model, attempt ##{first_attempt}"
    link = html |> LazyHTML.from_fragment() |> LazyHTML.query("#opening-about-revision-1-attempt")
    assert LazyHTML.attribute(link, "href") == ["/ops/curation/attempts/#{first_attempt}"]
  end
end
