defmodule DevilsDictionary.Curation.Runtime.CompareTest do
  @moduledoc """
  #298 C1, C2, C5 and C9: evidence fingerprints, one frozen snapshot feeding
  every arm, the text-focused cut, the rule-fixed lead, comparison attempts
  that never publish, the unmatched-case retry rule and the comparison
  report. #305 D8: the text cut without word-bound claims. Against the
  controlled fake of the private service; no real model.
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

  # Another fake model: `:lead_only` gives a fixed-lead arm a null lead and
  # every section empty (other arms keep their lead, without highlights);
  # `:abstain_fixed` makes a fixed-lead arm abstain, against its schema.
  defp stub_mode!(ctx, mode) do
    stub_ollama!(ctx.v7,
      chat: fn request ->
        %{"content" => "Packet:\n" <> json} = List.last(request["messages"])
        fixed? = is_binary(Jason.decode!(json)["fixed_lead"])
        wire = wire(request)

        empty =
          Map.new(wire["selections"], fn {k, v} -> {k, if(is_list(v), do: [], else: nil)} end)

        wire =
          case {mode, fixed?} do
            {:lead_only, _} ->
              %{wire | "selections" => empty}

            {:abstain_fixed, true} ->
              %{wire | "decision" => "abstain", "selections" => empty, "abstain_reason" => "No."}

            {:abstain_fixed, false} ->
              wire
          end

        {:json, answer(wire)}
      end
    )
  end

  # A clock: the real time for the first `n` reads, then `later`.
  defp clock(n, later) do
    {:ok, agent} = Agent.start_link(fn -> 0 end)
    real = DateTime.utc_now()

    fn ->
      if Agent.get_and_update(agent, &{&1, &1 + 1}) < n, do: real, else: later
    end
  end

  defp enable_editor!(ctx) do
    Repo.query!(
      """
      UPDATE curation_configurations
         SET editor_enabled_version_id = current_version_id, editor_switched_by_actor_id = $1,
             editor_switched_at = now(), editor_switch_reason = 'compare refusal test'
       WHERE id = $2
      """,
      [ctx.actor.id, ctx.w.configuration.id]
    )
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

  # The 2 × 2 of #305 D8: the nudge and attribution instructions, each on
  # the text cut and on the text cut without word-bound claims.
  defp d8_arms do
    nudge =
      model_config!(%{
        instruction_version: "voltaire-whole-entry-v7-fixed-lead-cap200-nudge-v1",
        tag: "9b"
      })
      |> ready!()

    attrib =
      model_config!(%{
        instruction_version: "voltaire-whole-entry-v7-fixed-lead-cap200-nudge-attrib-v1",
        tag: "9b"
      })
      |> ready!()

    [
      %{label: "N", config_slug: nudge.slug, cut: "text", config: nudge},
      %{label: "NX", config_slug: nudge.slug, cut: "text2", config: nudge},
      %{label: "NA", config_slug: attrib.slug, cut: "text", config: attrib},
      %{label: "NXA", config_slug: attrib.slug, cut: "text2", config: attrib}
    ]
  end

  # A claim from the word itself, as a title match writes it.
  defp word_claim!(ctx) do
    entity = DevilsDictionary.WordFixtures.concept!("Q305801", "Fixture spelling concept")
    DevilsDictionary.WordFixtures.link!(ctx.w.love, entity, method: :title_match)
  end

  defp claims(packet, bound) do
    words = for %{"kind" => "lexeme", "meaning_id" => id} <- packet["meanings"], do: id

    Enum.filter(
      packet["candidates"],
      &(&1["kind"] == "claim" and &1["required_meaning"] in words == (bound == :word))
    )
  end

  describe "#305 D8: the text cut without word-bound claims" do
    test "v2 omits the word-bound claim and keeps the sense-bound ones; v1 keeps both", ctx do
      word_claim!(ctx)
      {:ok, batch} = Compare.freeze("d8-claims", ["love"], d8_arms())
      [page] = batch.pages
      arms = by_label(page)
      text = arms["N"].frozen.packet
      text2 = arms["NX"].frozen.packet

      assert text["policy"]["cut"] == "whole-entry-text-cut-v1"
      assert text2["policy"]["cut"] == "whole-entry-text-cut-v2"
      assert [word] = claims(text, :word)
      assert [_ | _] = sense = claims(text, :sense)
      assert claims(text2, :word) == []
      assert Enum.map(claims(text2, :sense), & &1["key"]) == Enum.map(sense, & &1["key"])

      assert [%{"key" => key, "kind" => "claim", "reason" => "lexeme_claim_excluded"}] =
               Enum.filter(text2["omitted"], &(&1["reason"] == "lexeme_claim_excluded"))

      assert key == word["key"]
      refute Enum.any?(text["omitted"], &(&1["reason"] == "lexeme_claim_excluded"))

      # v2 is the text cut still: nothing metadata-only is offered.
      excluded = Packet.text_cut_excluded_sections()
      refute Enum.any?(text2["candidates"], &(WholeEntry.section(&1) in excluded))
      assert Enum.any?(text2["omitted"], &(&1["reason"] == "text_cut_excluded"))

      # Arms that share a cut share a fingerprint; the cuts differ here.
      assert page.matched
      assert arms["N"].evidence_fingerprint == arms["NA"].evidence_fingerprint
      assert arms["NX"].evidence_fingerprint == arms["NXA"].evidence_fingerprint
      refute arms["N"].evidence_fingerprint == arms["NX"].evidence_fingerprint
      assert page.fingerprints |> Map.keys() |> Enum.sort() == ["text", "text2"]

      # A packet of the new cut freezes and verifies under runtime-packet-v4.
      assert text2["packet_version"] == "runtime-packet-v4"
      assert {:ok, _} = Packet.freeze(text2)
      assert :ok = Packet.verify(arms["NX"].frozen)
      assert :ok = Packet.verify(arms["NXA"].frozen)
    end

    test "the freed slot is refilled under the same bounds; every candidate is accounted for",
         ctx do
      word_claim!(ctx)

      # Enough text-bearing quotations that the cut's 24 candidates bind.
      DevilsDictionary.WordFixtures.sense!(ctx.w, ctx.w.love, "wiktionary",
        examples:
          for(
            n <- 1..16,
            do: %{"type" => "quotation", "text" => "fixture quotation #{n}", "ref" => "fixture"}
          )
      )

      {:ok, batch} = Compare.freeze("d8-refill", ["love"], d8_arms())
      arms = batch.pages |> hd() |> by_label()
      text = arms["N"].frozen.packet
      text2 = arms["NX"].frozen.packet
      keys = fn p, from -> p[from] |> Enum.map(& &1["key"]) |> MapSet.new() end

      assert length(text["candidates"]) == 24
      assert length(text2["candidates"]) == 24
      assert length(text2["meanings"]) <= 12
      assert [word] = claims(text, :word)

      # The one candidate v2 drops is the word-bound claim; the one it adds
      # is a text-bearing candidate v1 left out over quota.
      assert MapSet.difference(keys.(text, "candidates"), keys.(text2, "candidates")) ==
               MapSet.new([word["key"]])

      assert [added] =
               MapSet.difference(keys.(text2, "candidates"), keys.(text, "candidates"))
               |> MapSet.to_list()

      assert %{"reason" => "over_quota"} = Enum.find(text["omitted"], &(&1["key"] == added))
      assert Packet.text_bearing?(Enum.find(text2["candidates"], &(&1["key"] == added)))

      # Every offered candidate is in the packet or omitted, by id and reason.
      all = fn p -> MapSet.union(keys.(p, "candidates"), keys.(p, "omitted")) end
      assert all.(text2) == all.(text)
    end

    test "on a page without a word-bound claim, v2 sends what v1 sends", _ctx do
      {:ok, batch} = Compare.freeze("d8-same", ["love"], d8_arms())
      [page] = batch.pages
      arms = by_label(page)

      assert claims(arms["N"].frozen.packet, :word) == []
      assert arms["N"].evidence_fingerprint == arms["NX"].evidence_fingerprint
      assert arms["NA"].evidence_fingerprint == arms["NXA"].evidence_fingerprint

      # The prompt never carries the cut's name, so it is the same prompt.
      assert arms["N"].prompt_sha256 == arms["NX"].prompt_sha256
      assert arms["NA"].prompt_sha256 == arms["NXA"].prompt_sha256
      refute arms["N"].prompt_sha256 == arms["NA"].prompt_sha256
      refute arms["N"].packet_hash == arms["NX"].packet_hash
    end

    test "the report counts the new omission by name", ctx do
      word_claim!(ctx)
      {:ok, batch} = Compare.freeze("d8-report", ["love"], d8_arms())

      {:ok, %{cases: [%{status: :matched}]}} =
        Compare.run(batch, actor_id: ctx.actor.id, service_key: ctx.key)

      [%{arms: rows}] = Coverage.comparison("d8-report").cases
      rows = Map.new(rows, &{&1.arm, &1})

      for label <- ["NX", "NXA"] do
        assert rows[label].cut == "whole-entry-text-cut-v2"
        assert rows[label].omitted_by_reason["lexeme_claim_excluded"] == 1
        refute Map.has_key?(rows[label].omitted_by_reason, "unknown")
      end

      for label <- ["N", "NA"],
          do: refute(Map.has_key?(rows[label].omitted_by_reason, "lexeme_claim_excluded"))
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

    test "a batch is refused while any editor is enabled, before anything is sent", ctx do
      {:ok, batch} = Compare.freeze("c2-editor-on", ["love"], ctx.arms)
      enable_editor!(ctx)

      assert Compare.preflight("c2-editor-on") == {:error, :editor_enabled}

      assert {:error, :editor_enabled} =
               Compare.run(batch, actor_id: ctx.actor.id, service_key: ctx.key)

      assert Repo.aggregate(Attempt, :count) == 0
      refute_received {:chat, _}
    end

    test "a batch id is used once: a re-run never replays under a new snapshot", ctx do
      {:ok, batch} = Compare.freeze("c2-once", ["love"], ctx.arms)
      assert Compare.preflight("c2-once") == :ok
      {:ok, _} = Compare.run(batch, actor_id: ctx.actor.id, service_key: ctx.key)
      assert Repo.aggregate(Attempt, :count) == 4

      {:ok, again} = Compare.freeze("c2-once", ["love"], ctx.arms)
      assert {:error, {:batch_exists, "c2-once"}} = Compare.preflight("c2-once")

      assert {:error, {:batch_exists, "c2-once"}} =
               Compare.run(again, actor_id: ctx.actor.id, service_key: ctx.key)

      assert Repo.aggregate(Attempt, :count) == 4
      # A new id is a new batch: new attempts, never replays of the old ones.
      {:ok, fresh} = Compare.freeze("c2-once-b", ["love"], ctx.arms)

      {:ok, %{cases: [%{results: results}]}} =
        Compare.run(fresh, actor_id: ctx.actor.id, service_key: ctx.key)

      assert Enum.all?(results, &(&1.status == :ok))
      assert Repo.aggregate(Attempt, :count) == 8
    end

    test "the snapshot's earliest expiry stops a text-cut arm whose own packet has no news",
         ctx do
      p = Enum.find(ctx.arms, &(&1.label == "P"))
      {:ok, batch} = Compare.freeze("c2-snapshot-expiry", ["love"], [p])
      [page] = batch.pages
      {:ok, snapshot_expiry, _} = DateTime.from_iso8601(page.snapshot["earliest_expiry"])
      [arm] = page.arms

      {:ok, own_expiry, _} =
        DateTime.from_iso8601(Packet.earliest_expiry(arm.frozen.packet["candidates"]))

      # The text cut dropped the news that expires first.
      assert DateTime.compare(own_expiry, snapshot_expiry) == :gt
      between = DateTime.add(snapshot_expiry, 1, :second)

      assert {:ok, %{cases: [first, second]}} =
               Compare.run(batch,
                 actor_id: ctx.actor.id,
                 service_key: ctx.key,
                 now: fn -> between end,
                 window_minutes: 60 * 24 * 1000
               )

      assert {first.status, first.reason} == {:unmatched, :snapshot_expired}
      assert {second.status, second.reason} == {:unmatched, :snapshot_expired}
      assert Repo.aggregate(Attempt, :count) == 0
    end

    test "an arm expiring mid-case keeps the earlier arms' results as unmatched", ctx do
      {:ok, batch} = Compare.freeze("c2-midcase", ["love"], ctx.arms)
      later = DateTime.add(DateTime.utc_now(), 400, :day)

      # Read 1 is the case's window check, read 2 A0's expiry check.
      assert {:ok, %{cases: [first, second], halted: nil}} =
               Compare.run(batch,
                 actor_id: ctx.actor.id,
                 service_key: ctx.key,
                 now: clock(2, later),
                 window_minutes: 60 * 24 * 1000
               )

      assert {first.case_id, first.status, first.reason} ==
               {"c2-midcase:love:1", :unmatched, :snapshot_expired}

      assert [%{label: "A0", outcome: :accepted, attempt_id: id}] = first.results
      assert Repo.get!(Attempt, id).comparison_case == "c2-midcase:love:1"

      assert {second.case_id, second.status, second.results} ==
               {"c2-midcase:love:2", :unmatched, []}

      assert Repo.aggregate(Attempt, :count) == 1

      record = Compare.record(batch, %{cases: [first, second], halted: nil})
      report = Coverage.comparison("c2-midcase", record: record)
      assert [one, two] = report.cases

      assert {one.record_status, one.attempts, one.complete, one.matched} ==
               {"unmatched", 1, false, false}

      assert {two.record_status, two.attempts, two.matched} == {"unmatched", 0, false}
    end

    test "a lead-only answer under a fixed lead is accepted with registry checks on", ctx do
      stub_mode!(ctx, :lead_only)
      arms = Enum.filter(ctx.arms, &(&1.label in ["A0", "L"]))
      {:ok, batch} = Compare.freeze("c2-lead-only", ["love"], arms)

      {:ok, %{cases: [%{status: :matched}], halted: nil}} =
        Compare.run(batch, actor_id: ctx.actor.id, service_key: ctx.key)

      l = Repo.get_by!(Attempt, arm: "L")
      assert l.outcome == :accepted
      assert l.result["highlights"] == []
      assert l.result["lead"]["reason_origin"] == "rule"

      [c] = Coverage.comparison("c2-lead-only").cases
      row = Enum.find(c.arms, &(&1.arm == "L"))

      assert {row.decision, row.highlights, row.rule_statements, row.model_written_reasons,
              row.lead_is_priority} == {"select", 0, 1, 0, true}
    end

    test "an abstention under a fixed lead is refused, recorded, and halts nothing", ctx do
      stub_mode!(ctx, :abstain_fixed)
      {:ok, batch} = Compare.freeze("c2-abstain-fixed", ["love"], ctx.arms)

      {:ok, %{cases: [c], halted: nil}} =
        Compare.run(batch, actor_id: ctx.actor.id, service_key: ctx.key)

      assert c.status == :matched

      assert Enum.map(c.results, &{&1.label, &1.outcome}) ==
               [{"A0", :accepted}, {"P", :accepted}, {"L", :refused}, {"PL", :refused}]

      l = Repo.get_by!(Attempt, arm: "L")
      assert l.refusal_reasons == [["decision", "fixed_lead_requires_select"]]
      [report_case] = Coverage.comparison("c2-abstain-fixed").cases
      row = Enum.find(report_case.arms, &(&1.arm == "L"))

      assert {row.decision, row.lead, row.lead_is_priority, row.choices} ==
               {"refused", nil, false, []}
    end

    @tag :tmp_dir
    test "recorded/2 finds the records that name a batch, whatever their file names",
         %{tmp_dir: dir} do
      File.mkdir_p!(Path.join(dir, "2026-11-04"))
      named = Path.join([dir, "2026-11-04", "d6.json"])
      renamed = Path.join(dir, "batch.json")
      File.write!(named, Jason.encode!(%{"batch" => "d6", "status" => "running"}))
      File.write!(renamed, Jason.encode!(%{"batch" => "d6", "cases" => []}))
      File.write!(Path.join(dir, "other.json"), Jason.encode!(%{"batch" => "d7"}))
      File.write!(Path.join(dir, "broken.json"), "{not json")

      patterns = [Path.join([dir, "*", "*.json"]), Path.join(dir, "*.json")]
      assert Compare.recorded("d6", patterns) == Enum.sort([named, renamed])
      assert Compare.recorded("d8", patterns) == []
    end

    test "arms and batches are validated before anything is read" do
      assert {:ok, [%{label: "A0", cut: "current"}, %{label: "P", cut: "text"}, %{label: "x"}]} =
               Compare.parse_arms("A0=cfg,P=cfg:text,x")

      assert {:ok, [%{label: "NX", config_slug: "cfg", cut: "text2"}]} =
               Compare.parse_arms("NX=cfg:text2")

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

    test "with the batch record, every case is listed, attempts or not", ctx do
      PacketFixtures.pilot!(ctx.w, "greed")
      {:ok, batch} = Compare.freeze("c5-record", ["love", "greed"], ctx.arms)
      Gateway.pause("test pause", service_key: ctx.key)
      {:ok, result} = Compare.run(batch, actor_id: ctx.actor.id, service_key: ctx.key)
      record = Compare.record(batch, result)

      without = Coverage.comparison("c5-record")
      assert without.cases == []
      assert without.case_list =~ "attempts only"

      report = Coverage.comparison("c5-record", record: record)
      assert report.case_list == "every case in the batch record"
      assert report.arms == ["A0", "L", "P", "PL"]

      assert Enum.map(report.cases, &{&1.case_id, &1.record_status, &1.attempts}) == [
               {"c5-record:love:1", "not_run", 0},
               {"c5-record:greed:1", "not_run", 0}
             ]

      assert [_halted, %{record_reason: "batch_halted"}] = report.cases
      assert report.cases_by_status == %{"not_run" => 2}

      assert {:error, :record_for_another_batch} =
               Coverage.comparison("other", record: record)
    end

    test "with the record, a case unmatched at the freeze is reported with no attempts", ctx do
      {:ok, batch} = Compare.freeze("c5-freeze", ["love"], ctx.arms)
      [page] = batch.pages
      batch = %{batch | pages: [%{page | matched: false}]}
      {:ok, result} = Compare.run(batch, actor_id: ctx.actor.id, service_key: ctx.key)

      report = Coverage.comparison("c5-freeze", record: Compare.record(batch, result))

      assert Enum.map(report.cases, &{&1.case_id, &1.record_status, &1.attempts, &1.matched}) == [
               {"c5-freeze:love:1", "unmatched", 0, false},
               {"c5-freeze:love:2", "matched", 4, true}
             ]

      assert hd(report.cases).record_reason == "fingerprint_mismatch"
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
