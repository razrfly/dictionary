defmodule DevilsDictionary.Curation.Runtime.CompareTest do
  @moduledoc """
  #298 C1, C2, C5 and C9: evidence fingerprints, one frozen snapshot feeding
  every arm, the text-focused cut, the rule-fixed lead, comparison attempts
  that never publish, the unmatched-case retry rule and the comparison
  report. Against the controlled fake of the private service; no real model.
  """
  use DevilsDictionary.DataCase, async: false

  import DevilsDictionary.RefreshFixtures, only: [love_world!: 0]
  import DevilsDictionary.RuntimeFixtures
  import DevilsDictionary.CurationFixtures, only: [account: 1, actor!: 1]

  alias DevilsDictionary.{CitationFixtures, PacketFixtures}

  alias DevilsDictionary.Curation.{
    CompositionPublication,
    CompositionVersion,
    Coverage,
    Proposal,
    RefreshState,
    Shelf,
    WholeEntry
  }

  alias DevilsDictionary.Curation.Runtime.{Attempt, Compare, Gateway, LedgerEntry, Packet}

  @namespaces %{
    "guardian" => "guardian_article",
    "bing-news" => "news_article",
    "spotify" => "spotify_track",
    "pexels" => "pexels_photo",
    "unsplash" => "unsplash_photo",
    "openverse" => "openverse_media",
    "commons" => "commons_file",
    "met" => "met_object",
    "cinegraph" => "tmdb_movie",
    "open-library" => "olid",
    "poetrydb" => "poetrydb_poem",
    "wikiquote" => "wikiquote_item"
  }

  setup do
    w = love_world!()

    for provider <- Shelf.providers(),
        do: CitationFixtures.observation!(w, provider, namespace: @namespaces[provider])

    v7 = model_config!(%{instruction_version: "voltaire-whole-entry-v7", tag: "9b"}) |> ready!()

    fixed =
      model_config!(%{instruction_version: "voltaire-whole-entry-v7-fixed-lead-v1", tag: "9b"})
      |> ready!()

    generic =
      model_config!(%{instruction_version: "generic-whole-entry-v1", tag: "9b"}) |> ready!()

    key = "compare-#{System.unique_integer([:positive])}"
    bind!(service_key: key)
    test = self()

    stub_ollama!(v7,
      chat: fn request ->
        send(test, {:chat, request})
        {:json, answer(wire(request))}
      end
    )

    arms = [
      %{label: "A0", config_slug: v7.slug, cut: "current", config: v7},
      %{label: "P", config_slug: v7.slug, cut: "text", config: v7},
      %{label: "L", config_slug: fixed.slug, cut: "current", config: fixed},
      %{label: "PL", config_slug: fixed.slug, cut: "text", config: fixed}
    ]

    %{
      w: w,
      v7: v7,
      fixed: fixed,
      generic: generic,
      arms: arms,
      key: key,
      actor: actor!(account([:reviewer]))
    }
  end

  # The fake model: under a fixed lead, a null lead and one quotation;
  # otherwise the priority lead (or the first definition) and one quotation.
  defp wire(request) do
    %{"content" => "Packet:\n" <> json} = List.last(request["messages"])
    visible = Jason.decode!(json)
    candidates = visible["candidates"]
    priority = visible["priority_candidates"]
    meaning = &hd(&1["allowed_meanings"])

    lead =
      cond do
        is_binary(visible["fixed_lead"]) -> nil
        priority != [] -> Enum.find(candidates, &(&1["candidate_id"] in priority))
        true -> Enum.find(candidates, &(&1["kind"] in ["content", "sense_definition"]))
      end

    quote_choice =
      Enum.find(candidates, &(&1["section"] == "quotes" and &1["candidate_id"] not in priority))

    empty =
      Map.new(WholeEntry.sections(), &{&1, if(&1 in ["examples", "quotes"], do: [], else: nil)})

    selections =
      if quote_choice,
        do:
          Map.put(empty, "quotes", [
            %{
              "candidate_id" => quote_choice["candidate_id"],
              "meaning_id" => meaning.(quote_choice),
              "reason" => "Its supplied words show the meaning.",
              "quote" => nil
            }
          ]),
        else: empty

    %{
      "decision" => "select",
      "lead" =>
        lead &&
          %{
            "candidate_id" => lead["candidate_id"],
            "meaning_id" => meaning.(lead),
            "reason" => "It defines the word."
          },
      "selections" => selections,
      "abstain_reason" => nil
    }
  end

  defp public_rows do
    for schema <- [CompositionVersion, CompositionPublication, Proposal, RefreshState],
        do: Repo.aggregate(schema, :count)
  end

  defp by_label(page), do: Map.new(page.arms, &{&1.label, &1})

  describe "C1: the evidence fingerprint" do
    test "is shared across instructions on one snapshot and excludes the prompt", ctx do
      {:ok, batch} =
        Compare.freeze(
          "c1-fingerprint",
          ["love"],
          [
            %{label: "V7", config_slug: ctx.v7.slug, cut: "current", config: ctx.v7},
            %{label: "GEN", config_slug: ctx.generic.slug, cut: "current", config: ctx.generic},
            %{label: "L", config_slug: ctx.fixed.slug, cut: "current", config: ctx.fixed}
          ]
        )

      [page] = batch.pages
      arms = Map.values(by_label(page))
      assert page.matched
      assert arms |> Enum.map(& &1.evidence_fingerprint) |> Enum.uniq() |> length() == 1
      assert arms |> Enum.map(& &1.packet_hash) |> Enum.uniq() |> length() == 3
      assert arms |> Enum.map(& &1.prompt_sha256) |> Enum.uniq() |> length() == 3
      assert Enum.all?(arms, &(&1.evidence_fingerprint =~ ~r/^[0-9a-f]{64}$/))
    end

    test "changes when any evidence changes, never with the instruction", ctx do
      {:ok, packet} =
        Packet.for_page(PacketFixtures.page("love"),
          instruction_version: ctx.v7.instruction_version
        )

      print = Packet.evidence_fingerprint(packet)

      assert Packet.evidence_fingerprint(
               Map.merge(packet, %{
                 "instruction_version" => "generic-whole-entry-v1",
                 "policy" => %{"cut" => "anything"},
                 "omitted" => [],
                 "fixed_lead" => "c1"
               })
             ) == print

      [first | rest] = packet["candidates"]

      for change <- [
            %{"excerpt_sha256" => String.duplicate("0", 64)},
            %{"label_sha256" => String.duplicate("1", 64)},
            %{"content_revision_id" => -1},
            %{"key" => "another"}
          ] do
        refute Packet.evidence_fingerprint(%{
                 packet
                 | "candidates" => [Map.merge(first, change) | rest]
               }) == print
      end

      refute Packet.evidence_fingerprint(%{packet | "candidates" => rest ++ [first]}) == print

      refute Packet.evidence_fingerprint(
               Map.update!(packet, "meanings", fn [m | ms] -> [Map.put(m, "label", "x") | ms] end)
             ) == print

      refute Packet.evidence_fingerprint(%{packet | "priority_candidates" => []}) == print
    end

    test "is stored on every attempt beside the packet hash and prompt sha256", ctx do
      {:ok, batch} = Compare.freeze("c1-stored", ["love"], Enum.take(ctx.arms, 1))
      {:ok, _} = Compare.run(batch, actor_id: ctx.actor.id, service_key: ctx.key)
      [attempt] = Repo.all(Attempt)
      [%{arms: [arm]}] = batch.pages
      assert attempt.evidence_fingerprint == arm.evidence_fingerprint
      assert attempt.packet_hash == arm.packet_hash
      assert attempt.prompt_sha256 == arm.prompt_sha256
    end
  end

  describe "C9: one frozen snapshot feeding four policy arms" do
    test "fingerprints are equal within a cut and differ across cuts", ctx do
      {:ok, batch} = Compare.freeze("c9-snapshot", ["love"], ctx.arms)
      [page] = batch.pages
      arms = by_label(page)

      assert page.matched
      assert page.snapshot_sha256 =~ ~r/^[0-9a-f]{64}$/
      assert page.snapshot["slug"] == "love"
      assert page.snapshot["pool"] != []
      assert arms["A0"].evidence_fingerprint == arms["L"].evidence_fingerprint
      assert arms["P"].evidence_fingerprint == arms["PL"].evidence_fingerprint
      refute arms["A0"].evidence_fingerprint == arms["P"].evidence_fingerprint
      assert page.fingerprints |> Map.keys() |> Enum.sort() == ["current", "text"]
      assert arms |> Map.values() |> Enum.map(& &1.packet_hash) |> Enum.uniq() |> length() == 4
      refute Jason.encode!(page.snapshot) =~ "excerpt\""
      refute Jason.encode!(page.snapshot) =~ "representation\""
    end

    test "the text cut never offers metadata-only kinds and refills under the same bounds", ctx do
      {:ok, batch} = Compare.freeze("c9-text-cut", ["love"], ctx.arms)
      arms = batch.pages |> hd() |> by_label()
      current = arms["A0"].frozen.packet
      text = arms["P"].frozen.packet
      excluded = Packet.text_cut_excluded_sections()

      assert Enum.any?(current["candidates"], &(WholeEntry.section(&1) in excluded))
      refute Enum.any?(text["candidates"], &(WholeEntry.section(&1) in excluded))
      assert text["policy"]["cut"] == "whole-entry-text-cut-v1"
      assert current["policy"]["cut"] == "whole-entry-cut-v1"
      assert length(text["candidates"]) <= 24
      assert length(text["meanings"]) <= 12
      assert text["packet_version"] == "runtime-packet-v4"

      dropped = Enum.filter(text["omitted"], &(&1["reason"] == "text_cut_excluded"))
      assert dropped != []
      assert Enum.all?(dropped, &(Map.keys(&1) |> Enum.sort() == ~w(key kind object_id reason)))

      text_bearing = Enum.count(current["candidates"], &Packet.text_bearing?/1)
      assert length(text["candidates"]) >= text_bearing
      # Every offered candidate is in the packet or omitted, by id and reason.
      keys = fn p -> Enum.map(p["candidates"] ++ p["omitted"], & &1["key"]) |> Enum.sort() end
      assert keys.(text) == keys.(current)
      assert text["priority_candidates"] == current["priority_candidates"]
      assert {:ok, _} = Packet.freeze(text)
      assert :ok = Packet.verify(arms["P"].frozen)
    end

    test "the fixed lead is the priority candidate, and only for the fixed-lead instruction",
         ctx do
      {:ok, batch} = Compare.freeze("c9-fixed-lead", ["love"], ctx.arms)
      arms = batch.pages |> hd() |> by_label()
      [priority] = arms["L"].frozen.packet["priority_candidates"]

      assert arms["L"].frozen.packet["fixed_lead"] == priority
      assert arms["PL"].frozen.packet["fixed_lead"] == priority
      refute Map.has_key?(arms["A0"].frozen.packet, "fixed_lead")
      refute Map.has_key?(arms["P"].frozen.packet, "fixed_lead")
      [_system, user] = Packet.messages(arms["L"].frozen)

      assert Jason.decode!(String.replace_prefix(user.content, "Packet:\n", ""))["fixed_lead"] ==
               priority

      [_system, a0_user] = Packet.messages(arms["A0"].frozen)
      refute a0_user.content =~ "fixed_lead"
    end

    test "a page without a priority candidate keeps a model-selected lead in every arm", ctx do
      PacketFixtures.pilot!(ctx.w, "greed")
      {:ok, batch} = Compare.freeze("c9-greed", ["greed"], ctx.arms)
      [page] = batch.pages
      arms = by_label(page)
      assert page.matched

      for label <- ["L", "PL"] do
        packet = arms[label].frozen.packet
        assert packet["priority_candidates"] == []
        assert Map.has_key?(packet, "fixed_lead")
        assert is_nil(packet["fixed_lead"])
        schema = DevilsDictionary.Curation.Runtime.Contract.schema(packet)
        assert schema["properties"]["decision"]["enum"] == ["select", "abstain"]
        refute schema["properties"]["lead"] == %{"type" => "null"}
      end

      {:ok, %{cases: [%{status: :matched}]}} =
        Compare.run(batch, actor_id: ctx.actor.id, service_key: ctx.key)

      report = Coverage.comparison("c9-greed")
      [%{arms: rows}] = report.cases

      for row <- rows do
        assert row.decision == "select"
        assert row.lead.reason_origin == "model"
        assert is_nil(row.lead_is_priority)
        assert row.rule_statements == 0
      end
    end
  end

  describe "C2: comparison attempts" do
    test "run back to back as comparison attempts and never publish", ctx do
      before = public_rows()
      {:ok, batch} = Compare.freeze("c2-run", ["love"], ctx.arms)
      [page] = batch.pages

      assert {:ok, %{cases: [result], halted: nil}} =
               Compare.run(batch, actor_id: ctx.actor.id, service_key: ctx.key)

      assert result.status == :matched
      assert result.case_id == "c2-run:love:1"
      assert Enum.map(result.results, & &1.label) == ["A0", "P", "L", "PL"]
      assert Enum.all?(result.results, &(&1.outcome == :accepted))

      attempts = Repo.all(from a in Attempt, order_by: a.id)
      assert length(attempts) == 4
      prepared = by_label(page)

      for a <- attempts do
        assert a.purpose == :comparison
        assert a.comparison_case == "c2-run:love:1"
        assert a.comparison_snapshot == page.snapshot_sha256
        assert a.request_key == "comparison:c2-run:love:1:#{a.arm}"
        assert a.evidence_fingerprint == prepared[a.arm].evidence_fingerprint
        assert a.packet_hash == prepared[a.arm].packet_hash
      end

      # The rule-fixed lead is the rule's, and marked so.
      l = Enum.find(attempts, &(&1.arm == "L"))
      assert l.result["lead"]["reason_origin"] == "rule"

      assert l.result["lead"]["reason"] ==
               DevilsDictionary.Curation.Runtime.Contract.fixed_lead_reason()

      assert l.result["lead"]["candidate_id"] ==
               hd(prepared["L"].frozen.packet["priority_candidates"])

      a0 = Enum.find(attempts, &(&1.arm == "A0"))
      refute Map.has_key?(a0.result["lead"], "reason_origin")

      # No composition version, proposal, publication or refresh row.
      assert public_rows() == before
      assert Repo.aggregate(from(e in LedgerEntry, where: e.kind == :charge), :count) == 4
      assert_received {:chat, _}
    end

    test "the database refuses a publishing row that names a comparison attempt", ctx do
      {:ok, batch} = Compare.freeze("c2-guard", ["love"], Enum.take(ctx.arms, 1))
      {:ok, _} = Compare.run(batch, actor_id: ctx.actor.id, service_key: ctx.key)
      [attempt] = Repo.all(Attempt)

      for table <- ~w(editorial_composition_versions curation_item_bases) do
        assert_raise Postgrex.Error, ~r/comparisons never publish/, fn ->
          Repo.transaction(fn ->
            Repo.query!("INSERT INTO #{table} (attempt_id) VALUES ($1)", [attempt.id])
          end)
        end
      end

      assert_raise Postgrex.Error, ~r/comparison identity cannot change/, fn ->
        Repo.transaction(fn ->
          Repo.query!("UPDATE inference_attempts SET arm = 'X' WHERE id = $1", [attempt.id])
        end)
      end
    end

    test "a comparison attempt needs its identity, and no other attempt carries one", ctx do
      {:ok, batch} = Compare.freeze("c2-identity", ["love"], Enum.take(ctx.arms, 1))
      [%{arms: [arm]}] = batch.pages

      base = [
        request_key: "k-#{System.unique_integer()}",
        actor_id: ctx.actor.id,
        service_key: ctx.key
      ]

      assert {:refused, :comparison_identity_mismatch} =
               Gateway.admit(ctx.v7, arm.frozen, [purpose: :comparison] ++ base)

      assert {:refused, :comparison_identity_mismatch} =
               Gateway.admit(
                 ctx.v7,
                 arm.frozen,
                 [comparison: %{arm: "A0", case: "c2-identity:love:1", snapshot: arm.packet_hash}] ++
                   base
               )

      assert Repo.aggregate(Attempt, :count) == 0
    end

    test "an unmatched case keeps its results and retries the whole set once on a new snapshot",
         ctx do
      {:ok, batch} = Compare.freeze("c2-retry", ["love"], ctx.arms)
      [page] = batch.pages
      batch = %{batch | pages: [%{page | matched: false}]}

      assert {:ok, %{cases: [first, second], halted: nil}} =
               Compare.run(batch, actor_id: ctx.actor.id, service_key: ctx.key)

      assert {first.case_id, first.status, first.reason, first.results} ==
               {"c2-retry:love:1", :unmatched, :fingerprint_mismatch, []}

      assert second.case_id == "c2-retry:love:2"
      assert second.status == :matched
      assert length(second.results) == 4
      cases = Repo.all(from a in Attempt, select: a.comparison_case) |> Enum.uniq()
      assert cases == ["c2-retry:love:2"]
    end

    test "an expired snapshot is never forced: two unmatched cases, no call", ctx do
      {:ok, batch} = Compare.freeze("c2-expired", ["love"], ctx.arms)
      later = DateTime.add(DateTime.utc_now(), 400, :day)

      assert {:ok, %{cases: [first, second]}} =
               Compare.run(batch,
                 actor_id: ctx.actor.id,
                 service_key: ctx.key,
                 now: fn -> later end,
                 window_minutes: 60 * 24 * 1000
               )

      assert {first.status, first.reason} == {:unmatched, :snapshot_expired}
      assert {second.status, second.reason, second.n} == {:unmatched, :snapshot_expired, 2}
      assert Repo.aggregate(Attempt, :count) == 0
      refute_received {:chat, _}
    end

    test "a refusal other than staleness halts the batch; the rest are not run", ctx do
      PacketFixtures.pilot!(ctx.w, "greed")
      {:ok, batch} = Compare.freeze("c2-halt", ["love", "greed"], ctx.arms)
      Gateway.pause("test pause", service_key: ctx.key)

      assert {:ok, %{cases: [love, greed], halted: halted}} =
               Compare.run(batch, actor_id: ctx.actor.id, service_key: ctx.key)

      assert halted
      assert {love.status, love.reason} == {:not_run, halted}
      assert {greed.status, greed.reason} == {:not_run, :batch_halted}
      assert Repo.aggregate(Attempt, :count) == 0
    end

    test "a case after the batch window is not run", ctx do
      {:ok, batch} = Compare.freeze("c2-window", ["love"], ctx.arms)
      later = DateTime.add(batch.frozen_at, 61, :minute)

      assert {:ok, %{cases: [%{status: :not_run, reason: :batch_window_passed}]}} =
               Compare.run(batch,
                 actor_id: ctx.actor.id,
                 service_key: ctx.key,
                 now: fn -> later end
               )
    end

    test "arms and batches are validated before anything is read" do
      assert {:ok, [%{label: "A0", cut: "current"}, %{label: "P", cut: "text"}, %{label: "x"}]} =
               Compare.parse_arms("A0=cfg,P=cfg:text,x")

      assert {:error, :no_arms} = Compare.parse_arms("")
      assert {:error, {:unknown_cut, "wide"}} = Compare.parse_arms("A=cfg:wide")
      assert {:error, {:duplicate_label, "A"}} = Compare.parse_arms("A=cfg,A=other")
      assert {:error, {:invalid_label, "a b"}} = Compare.parse_arms("a b=cfg")

      assert {:error, {:model_config_unknown, "nope"}} =
               Compare.resolve_arms([%{config_slug: "nope"}])

      assert {:error, {:invalid_batch, "X"}} = Compare.freeze("X", ["love"], [])
      assert {:error, {:outside_pilot, ["oats"]}} = Compare.freeze("abc", ["oats"], [])
      assert {:error, {:duplicate_pages, ["love"]}} = Compare.freeze("abc", ["love", "love"], [])
    end
  end

  describe "C5: the comparison report" do
    test "reports per case and arm by ids, hashes and counts, never reason text", ctx do
      {:ok, batch} = Compare.freeze("c5-report", ["love"], ctx.arms)
      {:ok, _} = Compare.run(batch, actor_id: ctx.actor.id, service_key: ctx.key)
      report = Coverage.comparison("c5-report")

      assert report.arms == ["A0", "L", "P", "PL"]
      [c] = report.cases
      assert c.matched and c.complete
      assert c.page == "love"
      assert c.snapshot == [hd(batch.pages).snapshot_sha256]
      rows = Map.new(c.arms, &{&1.arm, &1})

      for {label, rule, model} <- [{"A0", 0, 2}, {"P", 0, 2}, {"L", 1, 1}, {"PL", 1, 1}] do
        row = rows[label]
        assert row.decision == "select"
        assert row.lead_is_priority == true
        assert row.rule_statements == rule
        assert row.model_written_reasons == model
        assert row.highlights == 1
        assert row.highlights_by_section == %{"quotes" => 1}
        assert row.evidence_fingerprint =~ ~r/^[0-9a-f]{64}$/
        assert row.model_config_hash
        assert row.cost.charged_ms > 0
        assert Enum.all?(row.choices, &(&1.reason_sha256 =~ ~r/^[0-9a-f]{64}$/))
      end

      assert rows["L"].lead.reason_origin == "rule"
      assert rows["P"].cut == "whole-entry-text-cut-v1"
      assert rows["P"].omitted_by_reason["text_cut_excluded"] > 0
      assert rows["L"].fixed_lead == hd(rows["L"].priority_candidates)
      assert report.totals["L"].rule_statements == 1
      assert report.totals["A0"].matched_cases == 1

      encoded = Jason.encode!(report)
      refute encoded =~ "It defines the word."
      refute encoded =~ "Its supplied words show the meaning."
      refute encoded =~ "Lead fixed by rule"
      assert Coverage.comparison("other-batch").cases == []
    end

    test "a case missing an arm is incomplete and so unmatched", ctx do
      {:ok, batch} = Compare.freeze("c5-partial", ["love"], ctx.arms)
      {:ok, _} = Compare.run(batch, actor_id: ctx.actor.id, service_key: ctx.key)
      PacketFixtures.pilot!(ctx.w, "greed")
      {:ok, other} = Compare.freeze("c5-partial", ["greed"], Enum.take(ctx.arms, 2))
      {:ok, _} = Compare.run(other, actor_id: ctx.actor.id, service_key: ctx.key)

      report = Coverage.comparison("c5-partial")
      cases = Map.new(report.cases, &{&1.page, &1})
      assert cases["love"].matched
      refute cases["greed"].complete
      refute cases["greed"].matched
    end
  end

  test "the batch record keeps ids and hashes only", ctx do
    {:ok, batch} = Compare.freeze("c9-record", ["love"], ctx.arms)
    {:ok, result} = Compare.run(batch, actor_id: ctx.actor.id, service_key: ctx.key)
    record = Compare.record(batch, result)
    encoded = Jason.encode!(record)

    assert record["record_version"] == "comparison-batch-v1"
    assert record["snapshot_sha256"] == batch.snapshot_sha256
    assert Enum.map(record["arms"], & &1["label"]) == ["A0", "P", "L", "PL"]

    assert Enum.all?(record["arms"], &(&1["instruction_sha256"] =~ ~r/^[0-9a-f]{64}$/))

    assert Enum.find(record["arms"], &(&1["label"] == "A0"))["evidence_guidance"] ==
             "evidence-guidance-v1"

    assert record["snapshots"]["love"]["sha256"] == hd(batch.pages).snapshot_sha256
    refute encoded =~ "excerpt\":"
    refute encoded =~ "It defines the word."
  end
end
