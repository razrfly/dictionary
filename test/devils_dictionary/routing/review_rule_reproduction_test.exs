defmodule DevilsDictionary.Routing.ReviewRuleReproductionTest do
  @moduledoc """
  The standing review rule (#237 Part A′, C10) against #224's own inputs:
  the population `docs/routing/stage-2/candidates.json` (`c2cbd2ef…`), the
  part of the export `routing-input.jsonl` (`a33f1bc8…`) its evaluation
  reads, the owner's review worksheet and the owner's review file, as #224
  left them (`test/fixtures/routing/cp4-224/`, see its README).

  What it proves:

    * the inputs are #224's: the export subset classifies every worksheet
      row to the fingerprint the owner reviewed;
    * **from the state #224 left** — the owner's 124 confirmations standing
      as overrides at their addresses, the 5 deferrals recorded — the rule
      decides exactly the owner's 124 confirmations and 5 deferrals, family,
      path and fingerprint, and writes nothing of its own;
    * **from the evidence alone** — nobody's decision — it confirms 99 of
      the 129, every one a record the owner confirmed, in the owner's family
      and at the owner's path except the 3 whose path the owner renamed; it
      never confirms a record the owner deferred; and it defers the 25
      judgments its clauses forbid it — the 14 sole-candidate classifications,
      the 3 blocked collision rows and the groups they block, and the 2
      duplicate identities the owner told apart;
    * a collision group is qualified whole from its evidence or deferred
      whole, and the order records arrive in decides nothing.

  `ReviewRule.decide/2` is pure, so this needs no database.
  """
  use ExUnit.Case, async: true

  alias DevilsDictionary.Routing.{AuditSnapshot, Classifications, Policy, ReviewRule}

  @dir Path.expand("../../fixtures/routing/cp4-224", __DIR__)
  @population Path.expand("../../../docs/routing/stage-2/candidates.json", __DIR__)

  @population_sha256 "c2cbd2ef7703b7a01acbd9e3f63051097779ce75ebed874d83ce408ded553d51"
  @export_sha256 "a33f1bc8c62b630be701d84b48f994fcfb6c127a8d4012bf492911cdb1b55fd0"
  @reviews_sha256 "57e26405cce64fd8b05a1d79e3d811f85e91b0cd428a1862946cb07f7a987792"

  # The owner renamed these three uncontested paths in #224; the rule keeps
  # the policy's proposal.
  @renamed [3, 6, 1_886_465]

  # The owner's confirmations the rule's own clauses defer, by clause.
  @classification_reviews [
    1_829_906,
    1_830_860,
    1_831_199,
    1_831_413,
    1_852_573,
    1_857_525,
    1_863_456,
    1_867_856,
    1_873_905,
    1_876_187,
    1_877_206,
    1_879_477,
    1_968_096,
    3_733_859
  ]
  @blocked [1_846_395, 1_885_953, 1_893_450]
  @blocked_groups [1_878_370, 1_884_890, 1_893_365, 1_893_414, 1_899_000, 1_899_664]
  @duplicates_confirmed [2, 1_894_610]
  @owner_deferred [3_734_402, 3_737_584, 3_739_174, 3_740_879, 3_742_759]

  setup_all do
    population_bytes = File.read!(@population)
    population = Jason.decode!(population_bytes)
    {:ok, snapshot} = AuditSnapshot.read(Path.join(@dir, "export-subset.jsonl"))
    worksheet = @dir |> Path.join("review-worksheet.json") |> File.read!() |> Jason.decode!()
    owner_bytes = File.read!(Path.join(@dir, "reviews-owner.json"))
    owner = Jason.decode!(owner_bytes)
    policy = Policy.load()
    entities = Map.new(snapshot.entities, &{&1["object_id"], &1})

    results =
      Map.new(population["records"], fn r ->
        id = r["object_id"]
        {id, Policy.classify(entities[id], snapshot.graph, policy)}
      end)

    group_of =
      for {path, ids} <- population["groups"], id <- ids, into: %{}, do: {id, path}

    %{
      population_bytes: population_bytes,
      population: population,
      snapshot: snapshot,
      worksheet: Map.new(worksheet["rows"], &{&1["object_id"], &1}),
      worksheet_file: worksheet,
      owner: Map.new(owner["reviews"], &{&1["object_id"], &1}),
      owner_file: owner,
      owner_bytes: owner_bytes,
      entities: entities,
      results: results,
      group_of: group_of
    }
  end

  # ── the states ───────────────────────────────────────────────────────────

  defp evaluator(result) do
    %{
      status: result.status,
      family: if(result.status == "mapped", do: result.family),
      origin: "evaluator",
      fingerprint: Classifications.fingerprint(result),
      reasons: result.reasons,
      rule_sha256: nil
    }
  end

  defp state(ctx, record, decision, canonical \\ nil, earlier \\ nil) do
    id = record["object_id"]

    %{
      object_id: id,
      label: ctx.entities[id]["label"],
      role: if(ctx.results[id].page_role == "edition", do: :edition, else: :subject),
      population: Map.put(record, "group", ctx.group_of[id]),
      entity: ctx.entities[id],
      decision: decision,
      canonical: canonical,
      earlier_review: earlier,
      stale: nil
    }
  end

  # Nobody has decided anything: every record's current decision is the
  # evaluator's, as after #224's run without reviews.
  defp from_evidence(ctx) do
    Enum.map(ctx.population["records"], &state(ctx, &1, evaluator(ctx.results[&1["object_id"]])))
  end

  # The state #224 left: each confirmation an override by the reviewer at
  # the owner's path, each deferral recorded as the reviewer's.
  defp as_224_left(ctx) do
    states =
      Enum.map(ctx.population["records"], fn record ->
        id = record["object_id"]

        case ctx.owner[id] do
          %{"action" => "confirm"} = review ->
            decision = %{
              status: "mapped",
              family: review["family"],
              origin: "override",
              fingerprint: review["evidence_fingerprint"],
              reasons: ["editorial_override"],
              rule_sha256: nil
            }

            state(ctx, record, decision, review["path"], review)

          %{"action" => "defer"} = review ->
            state(ctx, record, evaluator(ctx.results[id]), nil, review)

          nil ->
            state(ctx, record, evaluator(ctx.results[id]))
        end
      end)

    held =
      for {id, %{"action" => "confirm", "path" => path}} <- ctx.owner,
          into: %{},
          do: {String.normalize(path, :nfc), id}

    {states, held}
  end

  defp counts(decisions),
    do: decisions |> Map.values() |> Enum.frequencies_by(&{&1.action, &1.clause})

  defp ids(decisions, fun),
    do: for({id, d} <- decisions, fun.(d), do: id) |> Enum.sort()

  # ── the tests ────────────────────────────────────────────────────────────

  test "the inputs are #224's, and the export subset gives the worksheet's fingerprints", ctx do
    assert AuditSnapshot.digest(ctx.population_bytes) == @population_sha256
    assert AuditSnapshot.digest(ctx.owner_bytes) == @reviews_sha256
    assert ctx.population["summary"]["inputs"]["input_sha256"] == @export_sha256
    assert ctx.worksheet_file["population_sha256"] == @population_sha256
    assert ctx.worksheet_file["input_sha256"] == @export_sha256
    assert ctx.owner_file["population_sha256"] == @population_sha256

    population_ids = MapSet.new(ctx.population["records"], & &1["object_id"])
    assert MapSet.new(Map.keys(ctx.entities)) == population_ids
    assert map_size(ctx.worksheet) == 129
    assert MapSet.new(Map.keys(ctx.owner)) == MapSet.new(Map.keys(ctx.worksheet))

    for {id, row} <- ctx.worksheet do
      assert Classifications.fingerprint(ctx.results[id]) == row["evidence_fingerprint"],
             "object #{id}: the subset does not give the fingerprint the owner reviewed"

      assert ctx.results[id].status == row["status"]
      assert ctx.owner[id]["evidence_fingerprint"] in [nil, row["evidence_fingerprint"]]
    end
  end

  test "from the state #224 left, it reproduces the owner's 124 confirmations and 5 deferrals",
       ctx do
    {states, held} = as_224_left(ctx)
    decisions = ReviewRule.decide(states, held)

    assert counts(decisions) == %{
             {:confirm, "standing_decision"} => 124,
             {:defer, "standing_decision"} => 5,
             {:not_addressed, "classification_review"} => 38,
             {:not_addressed, "excluded_source_page"} => 2,
             {:not_addressed, "identity_lifecycle_review"} => 1
           }

    for {id, review} <- ctx.owner do
      decision = decisions[id]

      case review["action"] do
        "confirm" ->
          assert %{action: :confirm, standing: true} = decision
          assert {decision.family, decision.path} == {review["family"], review["path"]}
          assert decision.fingerprint == ctx.worksheet[id]["evidence_fingerprint"]

        "defer" ->
          assert %{action: :defer, clause: "standing_decision"} = decision
          assert decision.reason =~ review["reason"]
      end
    end

    assert ids(decisions, &(&1.action == :defer)) == @owner_deferred

    # Every confirmation is an address already held: the rule writes nothing.
    assert Enum.all?(Map.values(decisions), &(&1.action != :confirm or &1.standing))
  end

  test "from the evidence alone, it confirms only what the owner confirmed and defers the rest",
       ctx do
    decisions = ReviewRule.decide(from_evidence(ctx))

    assert counts(decisions) == %{
             {:confirm, "uncontested_mapping"} => 50,
             {:confirm, "qualified_collision"} => 49,
             {:defer, "classification_review"} => 17,
             {:defer, "duplicate_identity_review"} => 7,
             {:defer, "unqualified_collision"} => 6,
             {:not_addressed, "classification_review"} => 38,
             {:not_addressed, "excluded_source_page"} => 2,
             {:not_addressed, "identity_lifecycle_review"} => 1
           }

    confirmed = ids(decisions, &(&1.action == :confirm))

    for id <- confirmed do
      decision = decisions[id]
      review = ctx.owner[id]
      assert review["action"] == "confirm", "the rule confirmed #{id}, which the owner did not"
      assert decision.family == review["family"]
      assert decision.fingerprint == review["evidence_fingerprint"]

      if id in @renamed do
        record = Enum.find(ctx.population["records"], &(&1["object_id"] == id))
        assert decision.path == record["candidate_path"]
        refute decision.path == review["path"]
      else
        assert decision.path == review["path"]
      end
    end

    # Nothing the owner deferred.
    for id <- @owner_deferred, do: assert(decisions[id].action == :defer)

    # The owner's confirmations it defers are exactly the judgments its
    # clauses forbid.
    owner_confirmed = for {id, %{"action" => "confirm"}} <- ctx.owner, do: id
    deferred_confirmations = Enum.sort(owner_confirmed -- confirmed)

    assert deferred_confirmations ==
             Enum.sort(
               @classification_reviews ++ @blocked ++ @blocked_groups ++ @duplicates_confirmed
             )

    for id <- @classification_reviews ++ @blocked,
        do: assert(%{action: :defer, clause: "classification_review"} = decisions[id])

    for id <- @duplicates_confirmed,
        do: assert(%{action: :defer, clause: "duplicate_identity_review"} = decisions[id])

    for id <- @blocked_groups do
      assert %{action: :defer, clause: "unqualified_collision", reason: reason} = decisions[id]
      assert reason =~ "cannot be qualified whole"
    end

    assert length(confirmed) == 99
    assert length(deferred_confirmations) == 25
  end

  test "a collision group is qualified whole from its evidence, or deferred whole", ctx do
    states = from_evidence(ctx)
    butterflies = ctx.population["groups"]["/works/butterfly"]
    assert length(butterflies) == 19

    decisions = ReviewRule.decide(states)

    for id <- butterflies do
      record = Enum.find(ctx.population["records"], &(&1["object_id"] == id))
      assert %{action: :confirm, clause: "qualified_collision"} = decisions[id]
      assert decisions[id].path == record["proposed_path"]
    end

    # One member the evidence cannot qualify: the whole group waits, never
    # 18 of 19 by whoever came first.
    [first | _] = butterflies

    undescribed =
      Enum.map(states, fn
        %{object_id: ^first} = s -> put_in(s, [:entity, "description"], "")
        s -> s
      end)

    decisions = ReviewRule.decide(undescribed)

    for id <- butterflies do
      assert %{action: :defer, clause: "unqualified_collision", reason: reason} = decisions[id]
      assert reason =~ "#{first}: the evidence gives no readable qualifier"
    end

    # Two members the evidence cannot tell apart: the same.
    [a, b | _] = butterflies
    twin = Enum.find(states, &(&1.object_id == a)).entity

    twins =
      Enum.map(states, fn
        %{object_id: ^b} = s ->
          %{s | entity: Map.merge(s.entity, Map.take(twin, ["description", "work_kind"]))}

        s ->
          s
      end)

    decisions = ReviewRule.decide(twins)
    assert Enum.all?(butterflies, &(decisions[&1].action == :defer))

    # A qualified path another page already holds is not taken: the group
    # waits.
    path = ReviewRule.decide(states)[first].path
    holder = 999_999_999
    held = ReviewRule.decide(states, %{String.normalize(path, :nfc) => holder})

    for id <- butterflies do
      assert %{action: :defer, clause: "unqualified_collision", reason: reason} = held[id]
      assert reason =~ "held by object #{holder}"
    end
  end

  test "the order records arrive in decides nothing", ctx do
    states = from_evidence(ctx)
    expected = ReviewRule.decide(states)

    for seed <- [1, 2, 3] do
      :rand.seed(:exsss, {seed, seed, seed})
      assert ReviewRule.decide(Enum.shuffle(states)) == expected
    end

    assert ReviewRule.decide(Enum.reverse(states)) == expected

    {left, held} = as_224_left(ctx)
    assert ReviewRule.decide(Enum.reverse(left), held) == ReviewRule.decide(left, held)
  end

  test "what a human decided stands: a deferral, a family, an address", ctx do
    states = from_evidence(ctx)
    bierce = Enum.find(states, &(&1.object_id == 1))
    assert %{action: :confirm, clause: "uncontested_mapping"} = ReviewRule.decide([bierce])[1]

    deferred = %{bierce | earlier_review: %{"action" => "defer", "reason" => "not yet"}}
    assert %{action: :defer, clause: "standing_decision"} = ReviewRule.decide([deferred])[1]

    review = %{bierce | decision: %{bierce.decision | status: "needs_review", origin: "override"}}
    assert %{action: :defer, clause: "standing_decision"} = ReviewRule.decide([review])[1]

    # An address the page already holds is kept, whatever the label would
    # propose now.
    moved = %{bierce | canonical: "/people/a-g-bierce"}

    assert %{
             action: :confirm,
             clause: "standing_decision",
             path: "/people/a-g-bierce",
             standing: true
           } =
             ReviewRule.decide([moved])[1]

    # A rule's own earlier override is not a human's decision: decided again.
    ruled = %{
      bierce
      | decision: %{bierce.decision | origin: "override", rule_sha256: String.duplicate("a", 64)}
    }

    refute ReviewRule.human?(ruled.decision)
    assert %{action: :confirm, clause: "uncontested_mapping"} = ReviewRule.decide([ruled])[1]

    # Stale evidence is the backfill's to defer; the rule decides nothing on it.
    stale = %{bierce | stale: "evidence_changed: not current: Q191050"}
    assert %{action: :stale} = ReviewRule.decide([stale])[1]
  end
end
