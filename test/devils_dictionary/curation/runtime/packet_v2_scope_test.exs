defmodule DevilsDictionary.Curation.Runtime.PacketV2ScopeTest do
  @moduledoc """
  Packet v2 on whole On scopes (#262 §6, tests 1, 3, 4, 5, 6, 9 and 10): the
  ten pilot pages, shaped as `PacketFixtures` shapes them, offer exactly what
  the screen offers, cut deterministically and bounded in meanings; the cut
  says what it left out; every kind is re-derived before dispatch; the dry
  run prints and writes nothing; and P5's fingerprint takes the packet.
  """
  use DevilsDictionary.DataCase, async: false

  import DevilsDictionary.CurationFixtures, only: [account: 1]

  alias DevilsDictionary.{Claims, Fixtures, OpeningFixtures, PacketFixtures, RefreshFixtures}
  alias DevilsDictionary.{Registry, Repo}
  alias DevilsDictionary.Curation.{Candidates, Refresh}
  alias DevilsDictionary.Curation.Runtime.Packet

  setup do
    %{sources: sources} = Fixtures.seed_catalog!()
    %{sources: sources}
  end

  defp v2(page, opts \\ []),
    do: Packet.for_page(page, Keyword.put_new(opts, :instruction_version, "generic-editor-v2"))

  defp kinds(packet), do: Enum.frequencies_by(packet["candidates"], & &1["kind"])

  defp love!(ctx) do
    made = PacketFixtures.pilot!(ctx, "love")
    {made, PacketFixtures.page("love")}
  end

  describe "test 1: the screen's candidates, and nothing else" do
    test "every offered candidate is in the packet or omitted, on all ten pilot pages", ctx do
      people = [contributor: account([:contributor]), reviewer: account([:reviewer])]
      for slug <- PacketFixtures.pilot_slugs(), do: PacketFixtures.pilot!(ctx, slug, nil, people)

      for slug <- PacketFixtures.pilot_slugs() do
        page = PacketFixtures.page(slug)
        candidates = Candidates.for_page(page)
        assert {:ok, packet} = v2(page, candidates: candidates), slug

        offered = for c <- candidates.highlights, c.status == :ok, into: %{}, do: {c.key, c}
        sent = Enum.map(packet["candidates"], & &1["key"])
        omitted = Enum.map(packet["omitted"], & &1["key"])

        assert Enum.sort(sent ++ omitted) == Enum.sort(Map.keys(offered)), slug
        assert length(Enum.uniq(sent ++ omitted)) == length(sent ++ omitted), slug

        # Each as the screen has it: its kind and the meaning it is offered under.
        meanings = Map.new(packet["meanings"], &{&1["meaning_id"], &1})

        for c <- packet["candidates"] do
          screen = offered[c["key"]]
          assert c["kind"] == to_string(screen.kind)

          assert target(meanings[c["required_meaning"]]) == screen.spec.meaning,
                 "#{slug} #{c["key"]}"
        end

        assert {:ok, frozen} = Packet.freeze(packet)
        assert :ok = Packet.verify(frozen), slug
      end
    end

    test "a candidate the screen lists but does not offer never enters the packet", ctx do
      %{entries: [bierce | _]} = PacketFixtures.pilot!(ctx, "patience")
      DevilsDictionary.CurationFixtures.disallow_record!(bierce)

      page = PacketFixtures.page("patience")

      listed =
        Enum.find(
          Candidates.for_page(page).highlights,
          &(&1.spec[:object_id] == bierce.object_id)
        )

      assert listed.status != :ok

      {:ok, packet} = v2(page)

      refute Enum.any?(
               packet["candidates"] ++ packet["omitted"],
               &(&1["object_id"] == bierce.object_id)
             )

      assert packet["priority_candidates"] == []
    end
  end

  defp target(%{"kind" => "lexeme", "lexeme_id" => id}), do: {:lexeme, id}
  defp target(%{"kind" => "sense_revision", "sense_revision_id" => id}), do: {:sense_revision, id}

  describe "test 3: the cut" do
    test "quotas, flow-down and tie-breaks are deterministic, to the byte", ctx do
      {made, page} = love!(ctx)

      {:ok, packet} = v2(page)
      {:ok, again} = v2(PacketFixtures.page("love"))
      {:ok, frozen} = Packet.freeze(packet)
      {:ok, frozen_again} = Packet.freeze(again)
      assert frozen.json == frozen_again.json

      # Three definitions use three of four content places; the fourth flows
      # to the quotations, which take four of fourteen.
      assert kinds(packet) == %{
               "content" => 3,
               "sense_quotation" => 3,
               "work" => 1,
               "exemplar" => 1,
               "sense_definition" => 1,
               "claim" => 1
             }

      # Bierce, then Johnson; within a source, by object id.
      assert packet["candidates"] |> Enum.take(3) |> Enum.map(& &1["object_id"]) ==
               Enum.map(made.entries, & &1.object_id)

      assert hd(packet["candidates"])["source"] == "bierce"

      # WordNet's quotations before Wiktionary's; works by object id;
      # exemplars by the date they were accepted.
      sources = for c <- packet["candidates"], c["kind"] == "sense_quotation", do: c["source"]
      assert sources == Enum.sort_by(sources, &(&1 != "wordnet"))

      works = for c <- packet["candidates"], c["kind"] == "work", do: c["object_id"]
      assert works == Enum.sort(works)

      claims =
        for c <- packet["candidates"], c["kind"] == "exemplar", do: c["assertion_revision_id"]

      assert claims == made.exemplars |> Enum.take(1) |> Enum.map(& &1.id)

      # The order the screen lists its candidates in is not an input.
      candidates = Candidates.for_page(page)
      reversed = %{candidates | highlights: Enum.reverse(candidates.highlights)}
      assert {:ok, ^packet} = v2(page, candidates: reversed)
    end

    test "unused quota flows only to the next kind", ctx do
      PacketFixtures.pilot!(ctx, "greed")
      {:ok, packet} = v2(PacketFixtures.page("greed"))

      # One definition leaves three places to the quotations (3 + 3), and
      # nothing flows back from the works and exemplars greed does not have.
      assert kinds(packet) == %{"content" => 1, "sense_quotation" => 5, "sense_definition" => 3}

      assert Enum.frequencies_by(packet["omitted"], &{&1["kind"], &1["reason"]}) == %{
               {"sense_quotation", "over_quota"} => 2,
               {"sense_definition", "over_quota"} => 1
             }
    end
  end

  describe "test 4: meanings are bounded" do
    test "love, war and hope build, freeze and verify with twelve meanings", ctx do
      people = [contributor: account([:contributor]), reviewer: account([:reviewer])]

      for {slug, total, words} <- [{"love", 48, 5}, {"war", 37, 2}, {"hope", 58, 3}] do
        PacketFixtures.pilot!(ctx, slug, nil, people)
        page = PacketFixtures.page(slug)
        assert length(page.headword.lexemes) == words

        {:ok, packet} = v2(page)
        ids = MapSet.new(packet["meanings"], & &1["meaning_id"])
        assert {MapSet.size(ids), packet["counts"]["meanings_total"]} == {12, total}, slug

        for c <- packet["candidates"] do
          assert c["required_meaning"] in ids
          assert Enum.all?(c["allowed_meanings"], &(&1 in ids))
        end

        assert {:ok, frozen} = Packet.freeze(packet)
        assert :ok = Packet.verify(frozen)
      end
    end

    test "a candidate whose meaning no longer fits gives its place to the next", ctx do
      {_made, page} = love!(ctx)
      {:ok, tight} = v2(page, max_meanings: 4)

      kept = MapSet.new(tight["meanings"], & &1["meaning_id"])
      assert MapSet.size(kept) == 4
      assert Enum.all?(tight["candidates"], &(&1["required_meaning"] in kept))

      # The words and two WordNet senses fill the four places; the other
      # quotations and two exemplars name senses that no longer fit, and the
      # quotations' unused places flow to the works, which share a kept sense.
      assert kinds(tight) == %{
               "content" => 3,
               "sense_quotation" => 2,
               "work" => 2,
               "exemplar" => 1,
               "sense_definition" => 1,
               "claim" => 1
             }

      out = Enum.frequencies_by(tight["omitted"], &{&1["kind"], &1["reason"]})

      assert out == %{
               {"sense_quotation", "meaning_out_of_bound"} => 12,
               {"exemplar", "over_quota"} => 2,
               {"sense_definition", "over_quota"} => 42,
               {"work", "over_quota"} => 2
             }

      assert {:ok, _} = Packet.freeze(tight, max_meanings: 4)
      assert {:error, {:too_many_meanings, 4}} = Packet.freeze(tight, max_meanings: 3)
    end
  end

  describe "test 5: what the cut left out" do
    test "is named by id and reason, and the summary keeps no text", ctx do
      {_made, page} = love!(ctx)
      {:ok, packet} = v2(page)
      {:ok, frozen} = Packet.freeze(packet)

      assert length(packet["omitted"]) == 58
      assert Enum.all?(packet["omitted"], &(&1["reason"] == "over_quota"))

      for o <- packet["omitted"] do
        assert o |> Map.keys() |> Enum.sort() == ~w(key kind object_id reason)
      end

      summary = Packet.summary(frozen)
      assert summary["omitted"] == packet["omitted"]

      assert summary["counts"] == %{
               "offered" => 68,
               "meanings_total" => 48,
               "meanings_required" =>
                 length(Enum.uniq_by(packet["candidates"], & &1["required_meaning"]))
             }

      assert summary["policy"]["meanings"] == "meanings-v2"
      assert summary["instruction_version"] == "generic-editor-v2"
      assert summary["candidate_set_sha256"] == Packet.digest(packet)

      json = Jason.encode!(summary)

      for c <- packet["candidates"], text = c["excerpt"] || c["label"] do
        refute json =~ text
      end

      for m <- packet["meanings"], do: refute(json =~ m["label"])
    end
  end

  describe "test 6: every kind is re-derived before dispatch" do
    @tag :tmp_dir
    test "a work whose catalog changed and an exemplar whose claim was withdrawn",
         %{tmp_dir: root} = ctx do
      {_made, page} = love!(ctx)
      {:ok, packet} = v2(page)
      {:ok, frozen} = Packet.freeze(packet)
      assert :ok = Packet.verify(frozen)

      [exemplar | _] = for c <- packet["candidates"], c["kind"] == "exemplar", do: c

      {:ok, _} =
        Claims.review(exemplar["assertion_revision_id"], :withdrawn, %{reason: "withdrawn"})

      assert {:error, {:packet_stale, reasons}} = Packet.verify(frozen)
      assert [exemplar["candidate_id"], "claim_not_accepted"] in reasons

      # The catalog as a manifest that verifies but is not this build's.
      OpeningFixtures.committed_manifest!(root, :not_compiled)
      previous = Application.get_env(:devils_dictionary, :committed_manifest_root)
      Application.put_env(:devils_dictionary, :committed_manifest_root, root)

      on_exit(fn ->
        if previous,
          do: Application.put_env(:devils_dictionary, :committed_manifest_root, previous),
          else: Application.delete_env(:devils_dictionary, :committed_manifest_root)
      end)

      assert {:error, {:packet_stale, reasons}} = Packet.verify(frozen)
      works = for c <- packet["candidates"], c["kind"] == "work", do: c["candidate_id"]
      assert length(works) == 1
      for id <- works, do: assert([id, "catalog_changed"] in reasons)
    end

    test "a candidate the screen no longer offers, or whose label changed", ctx do
      {_made, page} = love!(ctx)
      {:ok, packet} = v2(page)
      at = Enum.find_index(packet["candidates"], &(&1["kind"] == "work"))
      id = Enum.at(packet["candidates"], at)["candidate_id"]

      relabelled = put_in(packet, ["candidates", Access.at(at), "label"], "Another title")
      assert {:error, {:packet_stale, [[^id, "label_changed"]]}} = Packet.verify(relabelled)

      elsewhere = put_in(packet, ["candidates", Access.at(at), "key"], "work-0")
      assert {:error, {:packet_stale, [[^id, "not_offered"]]}} = Packet.verify(elsewhere)

      # A definition revised since the cut is stale for its own reason.
      content = hd(packet["candidates"])
      {:ok, _} = Registry.add_content_revision(content["object_id"], %{body: "A revision."})
      assert {:error, {:packet_stale, reasons}} = Packet.verify(packet)
      assert ["c1", "revision_superseded"] in reasons
    end
  end

  describe "test 6, as the registry moves" do
    test "a definition whose defines claim was withdrawn is no longer offered", ctx do
      {made, page} = love!(ctx)
      {:ok, packet} = v2(page)
      [_bierce, _noun, verb_entry] = made.entries
      sent = Enum.find(packet["candidates"], &(&1["object_id"] == verb_entry.object_id))

      claim = DevilsDictionary.CurationFixtures.defines_claim!(verb_entry, Enum.at(made.words, 1))
      {:ok, _} = Claims.withdraw(claim.assertion_id, reason: "no longer")

      assert {:error, {:packet_stale, [[id, "not_offered"]]}} = Packet.verify(packet)
      assert id == sent["candidate_id"]
    end

    test "a definition of two of the page's words verifies as the cut saw it", ctx do
      # *LoVe* made before *Love*: the page puts *Love* first (by lemma), the
      # ids put *LoVe* first, and an entry defining both means the first.
      shape = PacketFixtures.shape("love")
      [noun, verb, love_name, capital, lo_ve] = shape.words

      %{words: words} =
        PacketFixtures.pilot!(ctx, "love", %{
          shape
          | words: [noun, verb, lo_ve, capital, love_name]
        })

      [_noun, _verb, other_name, _capital, name] = words
      assert other_name.object_id < name.object_id

      shared =
        DevilsDictionary.WordFixtures.entry!(ctx, name, "wiktionary", body: "A shared name.")

      {:ok, _} =
        Claims.assert(shared.object_id, "defines", other_name.object_id, %{
          source_id: ctx.sources["wiktionary"].id
        })

      page = PacketFixtures.page("love")
      order = Enum.map(page.headword.lexemes, & &1.id)
      first = Enum.find(order, &(&1 in [name.object_id, other_name.object_id]))
      assert first == name.object_id

      {:ok, packet} = v2(page)
      assert packet["target"]["page_lexeme_ids"] == order

      c = Enum.find(packet["candidates"], &(&1["object_id"] == shared.object_id))
      meaning = Enum.find(packet["meanings"], &(&1["meaning_id"] == c["required_meaning"]))
      assert meaning["lexeme_id"] == first

      assert {:ok, frozen} = Packet.freeze(packet)
      assert :ok = Packet.verify(frozen)
    end

    test "a Bierce entry that appeared after the cut makes the packet stale", ctx do
      %{words: [greed | _]} = PacketFixtures.pilot!(ctx, "greed")
      {:ok, packet} = v2(PacketFixtures.page("greed"))
      assert packet["priority_candidates"] == []

      DevilsDictionary.WordFixtures.entry!(ctx, greed, "bierce", body: "A fixture Bierce entry.")

      assert {:error, {:packet_stale, reasons}} = Packet.verify(packet)
      assert ["priority_candidates", "priority_changed"] in reasons
    end

    test "a definition is offered as the screen shows it, by its first block", ctx do
      %{words: [nepotism | _]} = PacketFixtures.pilot!(ctx, "nepotism")

      entry =
        DevilsDictionary.WordFixtures.entry!(ctx, nepotism, "johnson",
          body: "The first block of a fixture entry.\n\nA second block the page folds away."
        )

      {:ok, packet} = v2(PacketFixtures.page("nepotism"))
      c = Enum.find(packet["candidates"], &(&1["object_id"] == entry.object_id))
      assert c["excerpt"] == "The first block of a fixture entry."
      assert :ok = Packet.verify(packet)
    end
  end

  describe "test 9: the dry run" do
    setup do
      Mix.shell(Mix.Shell.Process)
      level = Logger.level()

      on_exit(fn ->
        Mix.shell(Mix.Shell.IO)
        Logger.configure(level: level)
      end)
    end

    defp dry_run!(slug) do
      writes = writes()

      Mix.Tasks.Dd.Runtime.run(
        ~w(packet --scope #{slug} --dry-run --instruction generic-editor-v2)
      )

      assert writes() == writes, "the dry run wrote to the database"
      lines()
    end

    # Rows this transaction inserted, updated or deleted so far.
    defp writes do
      %{rows: [[n]]} =
        Repo.query!(
          "SELECT coalesce(sum(n_tup_ins + n_tup_upd + n_tup_del), 0)::bigint FROM pg_stat_xact_user_tables"
        )

      n
    end

    defp lines(acc \\ []) do
      receive do
        {:mix_shell, :info, [line]} -> lines([line | acc])
      after
        0 -> Enum.reverse(acc)
      end
    end

    defp row(lines, label), do: Enum.find(lines, &String.starts_with?(&1, label <> " "))

    test "prints the cut for greed and love, and writes nothing", ctx do
      PacketFixtures.pilot!(ctx, "greed")
      greed = PacketFixtures.page("greed")
      ids = greed.headword.lexemes |> Enum.map(& &1.id) |> Enum.sort() |> Enum.join(" ")

      lines = dry_run!("greed")
      assert row(lines, "packet_version") =~ "runtime-packet-v3"
      assert row(lines, "instruction") =~ "generic-editor-v2"
      assert row(lines, "scope") =~ "greed · lexemes #{ids} · en"
      assert row(lines, "meanings") =~ "6 of 6 (required 5, bounded 1) · policy meanings-v2"

      assert row(lines, "candidates") =~
               "9 of 12 · content 1, sense_quotation 5, work 0, exemplar 0, sense_definition 3, claim 0, shelf 0 · policy cut-v2"

      assert row(lines, "priority") =~ "none (no applicable Bierce entry)"
      assert row(lines, "omitted") =~ "3 · by id with reason: over_quota 3"

      assert row(lines, "hashes") =~
               ~r/packet sha256 [0-9a-f]{64}, candidate set sha256 [0-9a-f]{64}/

      {_made, _page} = love!(ctx)
      lines = dry_run!("love")
      assert row(lines, "meanings") =~ "12 of 48 (required 5, bounded 7)"

      assert row(lines, "candidates") =~
               "10 of 68 · content 3, sense_quotation 3, work 1, exemplar 1, sense_definition 1, claim 1, shelf 0"

      assert row(lines, "priority") =~ "bierce LOVE (n)"
      assert row(lines, "omitted") =~ "58 · by id with reason: over_quota 58"

      # Nothing a reader could quote: no excerpt or label text is printed.
      {:ok, packet} = v2(PacketFixtures.page("love"))
      printed = Enum.join(lines, "\n")
      for c <- packet["candidates"], do: refute(printed =~ (c["excerpt"] || c["label"]))
    end

    test "an instruction is required, and only a pinned one" do
      assert_raise Mix.Error, ~r/--model-config or --instruction is required/, fn ->
        Mix.Tasks.Dd.Runtime.run(~w(packet --scope greed --dry-run))
      end

      assert_raise Mix.Error, ~r/--instruction must be one of/, fn ->
        Mix.Tasks.Dd.Runtime.run(~w(packet --scope greed --dry-run --instruction v9))
      end
    end
  end

  describe "test 10: P5's fingerprint takes the packet" do
    import RefreshFixtures

    setup ctx do
      world = love_world!(ctx)
      composition = provision!(world)
      published = publish!(world, composition)
      Map.merge(world, %{composition: composition, published: published})
    end

    defp version_of(fingerprint), do: fingerprint |> String.split(":", parts: 2) |> hd()

    test "a candidates-v1 baseline re-admits one run, and the next visit admits none", ctx do
      visit!()
      drain!()
      row = row!(ctx.composition)
      assert version_of(row.input_fingerprint) == "packet-v3/cut-v2/meanings-v2"

      # The baseline P5 wrote on v2 before this build: another version.
      [_version, rest] = String.split(row.input_fingerprint, ":", parts: 2)
      set!(row, input_fingerprint: "candidates-v1:" <> rest)

      before =
        {Repo.reload!(ctx.composition).current_published_version_id, length(curation_jobs())}

      assert {:ok, :admitted} = visit!()
      drain!()

      row = row!(ctx.composition)
      assert {row.last_outcome, row.last_outcome_reason} == {:needs_editor, "fingerprint_version"}
      assert version_of(row.input_fingerprint) == Refresh.fingerprint_version()

      assert {:ok, :fresh} = visit!()
      assert {:ok, :fresh} = visit!()

      {pointer, jobs} = before
      assert Repo.reload!(ctx.composition).current_published_version_id == pointer
      assert length(curation_jobs()) == jobs + 1
    end

    test "a change of policy version re-admits once, and never loops", ctx do
      visit!()
      drain!()

      runtime = Application.get_env(:devils_dictionary, :curation_runtime, [])

      Application.put_env(
        :devils_dictionary,
        :curation_runtime,
        Keyword.put(runtime, :meaning_policy, "meanings-v3")
      )

      on_exit(fn -> Application.put_env(:devils_dictionary, :curation_runtime, runtime) end)

      assert {:ok, :admitted} = visit!()
      drain!()

      row = row!(ctx.composition)
      assert {row.last_outcome, row.last_outcome_reason} == {:needs_editor, "fingerprint_version"}
      assert version_of(row.input_fingerprint) == "packet-v3/cut-v2/meanings-v3"
      assert {:ok, :fresh} = visit!()
    end
  end

  describe "the fingerprint covers the cut, not what it left out" do
    test "a candidate eligible outside the cut leaves the packet's digest as it was", ctx do
      {made, page} = love!(ctx)
      {:ok, packet} = v2(page)

      # A new quotation under the last sense, which no chosen candidate and
      # no kept meaning names: it sorts after every quotation, so it is cut.
      last = List.last(made.senses)
      revision = Registry.current_sense_revision(last.object_id)
      kept = for m <- packet["meanings"], do: m["sense_revision_id"]
      refute revision.id in kept

      {:ok, _} =
        Registry.add_sense_revision(last.object_id, %{
          gloss: revision.gloss,
          position: revision.position,
          examples: [
            %{"type" => "quotation", "text" => "A late fixture line.", "ref" => "Later:"}
          ]
        })

      {:ok, after_change} = v2(PacketFixtures.page("love"))
      assert Packet.digest(after_change) == Packet.digest(packet)
      assert length(after_change["omitted"]) == length(packet["omitted"]) + 1
    end

    test "a sense added elsewhere renumbers the meanings and leaves the digest as it was", ctx do
      {made, page} = love!(ctx)
      {:ok, packet} = v2(page)

      # Uncited and first in WordNet's order: every sense meaning's number moves.
      DevilsDictionary.WordFixtures.sense!(ctx, hd(made.words), "wordnet",
        gloss: "An early fixture sense.",
        position: 0,
        group_key: "fixture-love-early"
      )

      {:ok, renumbered} = v2(PacketFixtures.page("love"))
      ids = fn p -> Enum.map(p["meanings"], &{&1["meaning_id"], &1["sense_revision_id"]}) end
      refute ids.(renumbered) == ids.(packet)
      # A newly offered sense definition changes this v3 cut. Pure renumbering
      # still leaves the chosen candidate/meaning identity unchanged.
      refute Packet.digest(renumbered) == Packet.digest(packet)
      rename = fn id -> "renumbered-" <> id end

      same =
        packet
        |> Map.update!(
          "meanings",
          &Enum.map(&1, fn m -> Map.update!(m, "meaning_id", rename) end)
        )

      same =
        Map.update!(
          same,
          "candidates",
          &Enum.map(&1, fn c ->
            c
            |> Map.update!("required_meaning", rename)
            |> Map.update!("allowed_meanings", fn ids -> Enum.map(ids, rename) end)
          end)
        )

      assert Packet.digest(same) == Packet.digest(packet)
    end
  end
end
