defmodule Mix.Tasks.Dd.Links.ReinstateTest do
  @moduledoc """
  D12's tool: a bulk reversal that is still a revision per claim.

  The thing worth testing is not that rows change state — it is that the
  selection is narrow, that a dry run changes nothing, and that the withdrawal
  it reverses is still in the history afterwards. A bulk `update_all` would pass
  the first of those and fail the other two.
  """

  use DevilsDictionary.DataCase, async: false

  import DevilsDictionary.WordFixtures
  import ExUnit.CaptureIO

  alias DevilsDictionary.Claims
  alias DevilsDictionary.Claims.AssertionRevision
  alias DevilsDictionary.Repo
  alias Mix.Tasks.Dd.Links.Reinstate

  setup do
    catalog = DevilsDictionary.Fixtures.seed_catalog!()
    Mix.shell(Mix.Shell.Process)
    on_exit(fn -> Mix.shell(Mix.Shell.IO) end)
    %{sources: catalog.sources, animals: catalog.scopes["animals"]}
  end

  defp withdrawn_link(ctx, lemma, qid, label, rationale, opts \\ []) do
    word = word!(ctx, lemma, ~w(wordnet))
    sense = sense!(ctx, word, "wordnet")
    entity = concept!(qid, label)

    {:ok, assertion} =
      Claims.assert(sense.object_id, "refers_to", entity.object_id, %{
        confidence: 0.95,
        method: Keyword.get(opts, :method, "wordnet_wikidata")
      })

    {:ok, _} = Claims.withdraw(assertion.id, reason: rationale)
    %{word: word, sense: sense, entity: entity, assertion: assertion}
  end

  defp run(args), do: capture_io(fn -> Reinstate.run(args) end)

  test "a dry run counts by method and changes nothing", ctx do
    war = withdrawn_link(ctx, "war", "Q198", "War", "Retired after issue #82 bounded the QIDs")

    other =
      withdrawn_link(ctx, "grief", "Q169251", "grief", "Withdrawn by a reviewer, not by #82",
        method: "wiktionary_qid"
      )

    run(["--predicate", "refers_to", "--rationale-match", "issue #82"])

    assert_received {:mix_shell, :info, ["withdrawn, current, matching: 1"]}
    assert_received {:mix_shell, :info, [line]} when is_binary(line)
    assert_received {:mix_shell, :info, ["\nDry run. Nothing changed. Re-run with --apply" <> _]}

    assert Claims.current_revision(war.assertion.id).lifecycle_state == :withdrawn
    assert Claims.current_revision(other.assertion.id).lifecycle_state == :withdrawn
  end

  test "--apply reinstates only the matching claims, as new revisions", ctx do
    war = withdrawn_link(ctx, "war", "Q198", "War", "Retired after issue #82 bounded the QIDs")

    other =
      withdrawn_link(ctx, "grief", "Q169251", "grief", "Withdrawn by a reviewer, not by #82")

    run([
      "--predicate",
      "refers_to",
      "--rationale-match",
      "issue #82",
      "--apply",
      "--rationale",
      "Reinstated under issue #102"
    ])

    current = Claims.current_revision(war.assertion.id)
    assert current.lifecycle_state == :active
    assert current.rationale == "Reinstated under issue #102"
    assert current.revision_number == 3

    # The claim still says what it said: endpoints, confidence and method all
    # carry forward, because only lifecycle moved.
    assert current.subject_object_id == war.sense.object_id
    assert current.object_object_id == war.entity.object_id
    assert current.confidence == 0.95
    assert current.method == "wordnet_wikidata"

    # And the withdrawal is still there to read.
    history = Claims.history(war.assertion.id)
    assert Enum.map(history, & &1.lifecycle_state) == [:active, :withdrawn, :active]
    refute Enum.any?(history, &(&1.rationale == nil and &1.revision_number == 2))

    assert Claims.current_revision(other.assertion.id).lifecycle_state == :withdrawn
  end

  test "--limit bounds a run without changing what it selects", ctx do
    for lemma <- ~w(war combat battle) do
      withdrawn_link(ctx, lemma, "Q#{:erlang.phash2(lemma)}", lemma, "Retired after issue #82")
    end

    run([
      "--predicate",
      "refers_to",
      "--rationale-match",
      "issue #82",
      "--apply",
      "--limit",
      "2"
    ])

    assert_received {:mix_shell, :info, ["withdrawn, current, matching: 3"]}
    assert_received {:mix_shell, :info, ["reinstated: 2"]}

    active =
      Repo.aggregate(
        from(r in AssertionRevision,
          where: r.is_current and r.lifecycle_state == :active and not is_nil(r.rationale)
        ),
        :count,
        :id
      )

    assert active == 2
  end

  test "an unknown predicate is refused rather than matching nothing quietly", _ctx do
    assert_raise Mix.Error, ~r/no predicate/, fn ->
      run(["--predicate", "refers_to_maybe", "--rationale-match", "issue #82"])
    end
  end

  test "both arguments are required", _ctx do
    assert_raise Mix.Error, ~r/--predicate and --rationale-match are required/, fn ->
      run(["--predicate", "refers_to"])
    end
  end

  test "a reinstated link is immediately the Met's match key", ctx do
    war = withdrawn_link(ctx, "war", "Q198", "War", "Retired after issue #82 bounded the QIDs")

    target = %{
      object_id: war.word.object_id,
      term: "war",
      language: war.word.language_tag,
      relevance: "term"
    }

    refute DevilsDictionary.Discovery.Providers.Met.covers?(target)

    run(["--predicate", "refers_to", "--rationale-match", "issue #82", "--apply"])

    assert DevilsDictionary.Discovery.Providers.Met.covers?(target)

    assert {_operation, %{"entities" => [%{"qid" => "Q198", "label" => "War"}]}} =
             DevilsDictionary.Discovery.Providers.Met.automatic_mapping(target)
  end
end
