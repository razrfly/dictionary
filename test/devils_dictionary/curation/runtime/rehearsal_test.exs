defmodule DevilsDictionary.Curation.Runtime.RehearsalTest do
  @moduledoc """
  `mix dd.runtime rehearse` (#267 §8, tests 1–3): one real page's packet,
  run once through the runtime as an attempt only, against the controlled
  fake of the private service the other runtime tests use. The dry run
  prints the packet and calls and writes nothing; a rehearsal refuses a
  foreign binding and a failed readiness, recording either; one that runs
  writes exactly one attempt and one record; and the same scope and packet
  replay the same receipt.
  """
  use DevilsDictionary.DataCase, async: false

  import DevilsDictionary.CurationFixtures,
    only: [account: 1, actor!: 1, disallow_record!: 1, settle!: 0]

  import DevilsDictionary.RuntimeFixtures

  alias DevilsDictionary.{Fixtures, PacketFixtures}

  alias DevilsDictionary.Curation.{
    Composition,
    CompositionPublication,
    CompositionReview,
    CompositionVersion,
    RefreshState
  }

  alias DevilsDictionary.Curation.Runtime.{
    Attempt,
    Authority,
    FakeSystem,
    LedgerEntry,
    Ollama,
    Rehearsal,
    Service
  }

  @moduletag :tmp_dir

  setup ctx do
    %{sources: sources} = Fixtures.seed_catalog!()
    ctx = Map.put(ctx, :sources, sources)
    made = PacketFixtures.pilot!(ctx, "patience")

    config =
      model_config!(%{tag: "9b", instruction_version: "generic-editor-v2"}) |> ready!()

    key = "rehearsal-#{System.unique_integer([:positive])}"
    actor = actor!(account([:reviewer]))

    %{
      sources: sources,
      made: made,
      config: config,
      key: key,
      actor: actor,
      opts: [service_key: key, actor_id: actor.id]
    }
  end

  # Records the request paths the fake service is asked for.
  defp stub_counting!(config, chat) do
    test = self()

    stub_ollama!(config,
      chat: fn request ->
        send(test, {:chat, request})
        chat.(request)
      end
    )
  end

  defp unreachable! do
    test = self()

    Req.Test.stub(Ollama, fn conn ->
      send(test, {:called, conn.request_path})
      Req.Test.transport_error(conn, :econnrefused)
    end)
  end

  defp path(ctx, name), do: Path.join(ctx.tmp_dir, name)

  defp attempts(ctx) do
    case Repo.get_by(Service, key: ctx.key) do
      nil -> 0
      service -> Repo.aggregate(from(a in Attempt, where: a.service_id == ^service.id), :count)
    end
  end

  defp read_record(path), do: path |> File.read!() |> Jason.decode!()

  # Lead with Bierce's entry under its meaning, and one quotation.
  defp selection_for(ctx) do
    {:ok, prepared} = Rehearsal.prepare("patience", ctx.config)
    candidates = prepared.packet["candidates"]
    lead = Enum.find(candidates, &(&1["source"] == "bierce"))
    quotation = Enum.find(candidates, &(&1["kind"] == "sense_quotation"))

    selection(
      {lead["candidate_id"], lead["required_meaning"]},
      [{quotation["candidate_id"], quotation["required_meaning"], nil}]
    )
  end

  defp public_rows do
    for schema <- [
          Composition,
          CompositionVersion,
          CompositionReview,
          CompositionPublication,
          RefreshState
        ],
        do: Repo.aggregate(schema, :count)
  end

  describe "test 1: the dry run" do
    setup do
      Mix.shell(Mix.Shell.Process)
      level = Logger.level()

      on_exit(fn ->
        Mix.shell(Mix.Shell.IO)
        Logger.configure(level: level)
      end)
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

    test "prints the packet and its request key, and writes and calls nothing", ctx do
      unreachable!()
      writes = writes()
      rehearsals = File.ls(Path.dirname(Rehearsal.default_path("patience")))

      Mix.Tasks.Dd.Runtime.run(
        ~w(rehearse --model-config #{ctx.config.slug} --scope patience --dry-run)
      )

      assert writes() == writes, "the dry run wrote to the database"
      refute_received {:called, _path}
      assert File.ls(Path.dirname(Rehearsal.default_path("patience"))) == rehearsals

      {:ok, prepared} = Rehearsal.prepare("patience", ctx.config)
      lines = lines()

      assert row(lines, "model_config") =~ "#{ctx.config.slug} · config ##{ctx.config.id}"
      assert row(lines, "packet_version") =~ "runtime-packet-v2"
      assert row(lines, "instruction") =~ "generic-editor-v2"
      assert row(lines, "priority") =~ "bierce PATIENCE (n)"

      assert row(lines, "candidates") =~
               "#{length(prepared.packet["candidates"])} of #{prepared.packet["counts"]["offered"]}"

      assert row(lines, "hashes") =~ "packet sha256 #{prepared.frozen.hash}"

      assert row(lines, "request_key") =~
               "rehearsal:#{ctx.config.slug}:#{prepared.frozen.hash}"

      # Nothing a reader could quote: no excerpt or label text is printed.
      printed = Enum.join(lines, "\n")

      for c <- prepared.packet["candidates"],
          do: refute(printed =~ (c["excerpt"] || c["label"]))
    end

    test "is the packet `packet --dry-run` prints for the same scope and instruction", ctx do
      Mix.Tasks.Dd.Runtime.run(
        ~w(rehearse --model-config #{ctx.config.slug} --scope patience --dry-run)
      )

      rehearsed = lines()

      Mix.Tasks.Dd.Runtime.run(
        ~w(packet --scope patience --dry-run --model-config #{ctx.config.slug})
      )

      packet = lines()

      assert rehearsed -- packet ==
               [row(rehearsed, "model_config"), row(rehearsed, "request_key")]
    end
  end

  describe "test 2: refusals, and one attempt and one record when it runs" do
    test "a marker naming another database refuses foreign_authority, recorded, and touches nothing",
         ctx do
      unreachable!()

      other =
        ctx.opts
        |> Authority.identity()
        |> Map.put("database", "devils_dictionary_v2")

      FakeSystem.put_file(Authority.path(ctx.opts), Jason.encode!(other))
      out = path(ctx, "foreign.json")
      writes_before = public_rows()

      opts =
        Keyword.merge(ctx.opts,
          out: out,
          actor_id: fn -> flunk("no actor for a refused rehearsal") end
        )

      assert {:refused, record} = Rehearsal.run("patience", ctx.config, opts)
      assert record["refused_at"] == "authority"
      assert record["refusal"] == :foreign_authority
      assert record["refusal_detail"]["database"] == "devils_dictionary_v2"

      written = read_record(out)
      assert written["status"] == "refused"
      assert written["refusal"] == "foreign_authority"
      assert written["database"] == Authority.identity(ctx.opts)["database"]

      # No service row, no attempt, no call, nothing public.
      assert Repo.get_by(Service, key: ctx.key) == nil
      assert attempts(ctx) == 0
      refute_received {:called, _path}
      assert public_rows() == writes_before
    end

    test "an unreachable service refuses service_unreachable at readiness, recorded", ctx do
      bind!(ctx.opts)
      unreachable!()
      out = path(ctx, "unreachable.json")

      opts =
        Keyword.merge(ctx.opts,
          out: out,
          actor_id: fn -> flunk("no actor for a refused rehearsal") end
        )

      assert {:refused, record} = Rehearsal.run("patience", ctx.config, opts)
      assert record["refused_at"] == "readiness"
      assert record["refusal"] == :service_unreachable

      written = read_record(out)
      assert written["status"] == "refused"
      assert written["refusal"] == "service_unreachable"
      assert written["authority"]["database"] == written["database"]

      # The packet it would have sent is recorded by ids and hashes.
      assert written["packet"]["hash"] =~ ~r/^[0-9a-f]{64}$/
      assert written["packet"]["summary"]["packet_hash"] == written["packet"]["hash"]

      assert Enum.any?(
               written["readiness"],
               &(&1["check"] == "runtime_version" and &1["status"] == "service_unreachable")
             )

      assert attempts(ctx) == 0
      refute_received {:chat, _request}
    end

    test "a packet the page cannot build is refused at the packet step, recorded", ctx do
      bind!(ctx.opts)
      unreachable!()
      out = path(ctx, "nothing.json")

      assert {:refused, record} =
               Rehearsal.run("no-such-word", ctx.config, Keyword.put(ctx.opts, :out, out))

      assert {record["refused_at"], record["refusal"]} == {"packet", :not_lexemes}
      assert read_record(out)["refusal"] == "not_lexemes"
      refute_received {:called, _path}
    end

    test "a rehearsal that runs writes exactly one attempt and one record, and nothing public",
         ctx do
      bind!(ctx.opts)
      answer = selection_for(ctx)
      stub_counting!(ctx.config, fn _request -> {:json, answer(answer)} end)
      before = public_rows()
      ledger = Repo.aggregate(LedgerEntry, :count)
      out = path(ctx, "2026-11-03/patience.json")

      assert {:ok, record} =
               Rehearsal.run("patience", ctx.config, Keyword.put(ctx.opts, :out, out))

      settle!()

      assert_received {:chat, _request}
      refute_received {:chat, _request}
      assert attempts(ctx) == 1
      assert File.ls!(Path.dirname(out)) == ["patience.json"]
      assert public_rows() == before
      # Reserve, release and charge: the attempt's accounting.
      assert Repo.aggregate(LedgerEntry, :count) == ledger + 3

      {:ok, prepared} = Rehearsal.prepare("patience", ctx.config)
      attempt = Repo.one!(from a in Attempt, where: a.request_key == ^record["request_key"])

      assert attempt.request_key == "rehearsal:#{ctx.config.slug}:#{prepared.frozen.hash}"
      assert attempt.purpose == :request
      assert attempt.requested_by_actor_id == ctx.actor.id
      assert attempt.packet_hash == prepared.frozen.hash
      assert {attempt.state, attempt.outcome} == {:completed, :accepted}

      written = read_record(out)
      assert written["status"] == "ok"
      assert written["record_version"] == "runtime-rehearsal-v1"
      assert written["scope"] == "patience"
      assert written["model_config"]["slug"] == ctx.config.slug
      assert written["authority"]["database"] == written["database"]
      assert written["attempt"]["attempt_id"] == attempt.id
      assert written["answer"]["decision"] == "select"
      assert written["answer"]["lead"]["source"] == "bierce"
      assert written["answer"]["lead"]["reason"] == "It defines the word."
      assert length(written["answer"]["highlights"]) == 1
      assert written["latency_ms"]["total"] == 2000
      assert written["tokens"] == %{"prompt" => 900, "output" => 120}
      assert written["memory"]["before"]["swap_used_bytes"] == 0
      assert written["readings"]["before"]["memory"]["free_percent"] == 60
      assert written["readings"]["after"]["service"]["version"] == runtime_version()

      assert written["packet"]["candidates"] == length(prepared.packet["candidates"])
      assert written["packet"]["omitted"] == length(prepared.packet["omitted"])

      # Ids and hashes, never excerpt text.
      json = File.read!(out)

      for c <- prepared.packet["candidates"],
          text = c["excerpt"] || c["label"],
          do: refute(json =~ text)
    end

    test "a record is never overwritten", ctx do
      out = path(ctx, "kept.json")
      File.write!(out, "{}")
      unreachable!()

      assert {:error, {:record_exists, ^out}} =
               Rehearsal.run("patience", ctx.config, Keyword.put(ctx.opts, :out, out))

      assert File.read!(out) == "{}"
      refute_received {:called, _path}
    end

    test "the path is claimed before the rehearsal runs: a concurrent one with the same path is refused",
         ctx do
      bind!(ctx.opts)
      answer = selection_for(ctx)
      out = path(ctx, "claimed.json")
      test = self()

      # While the first rehearsal's call is in flight, a second is started
      # with the same path.
      stub_ollama!(ctx.config,
        chat: fn _request ->
          send(test, {:stub, read_record(out)})

          send(
            test,
            {:second, Rehearsal.run("patience", ctx.config, Keyword.put(ctx.opts, :out, out))}
          )

          {:json, answer(answer)}
        end
      )

      assert {:ok, _record} =
               Rehearsal.run("patience", ctx.config, Keyword.put(ctx.opts, :out, out))

      assert_received {:stub, %{"status" => "running", "scope" => "patience"} = stub}
      assert stub["model_config"] == ctx.config.slug
      assert_received {:second, {:error, {:record_exists, ^out}}}
      assert read_record(out)["status"] == "ok"
      assert attempts(ctx) == 1
    end

    test "a rehearsal that raises gives the path back", ctx do
      bind!(ctx.opts)
      stub_ollama!(ctx.config)
      out = path(ctx, "raised.json")

      opts = Keyword.merge(ctx.opts, out: out, actor_id: fn -> raise "no operator" end)

      assert_raise RuntimeError, "no operator", fn ->
        Rehearsal.run("patience", ctx.config, opts)
      end

      refute File.exists?(out)
      assert attempts(ctx) == 0
    end
  end

  describe "the task, run for real against the fake service" do
    setup do
      Mix.shell(Mix.Shell.Process)
      level = Logger.level()

      on_exit(fn ->
        Mix.shell(Mix.Shell.IO)
        Logger.configure(level: level)
      end)
    end

    defp printed(acc \\ []) do
      receive do
        {:mix_shell, :info, [line]} -> printed([line | acc])
      after
        0 -> Enum.reverse(acc)
      end
    end

    # The task speaks for the configured service key, as an operator does.
    test "prints the packet, the attempt and the record; refuses to overwrite it", ctx do
      bind!()
      answer = selection_for(ctx)
      stub_counting!(ctx.config, fn _request -> {:json, answer(answer)} end)
      out = path(ctx, "patience.json")
      # The volume's name has a space: the path is one argument.
      args = ~w(rehearse --model-config #{ctx.config.slug} --scope patience --out) ++ [out]

      Mix.Tasks.Dd.Runtime.run(args)

      [database, packet, attempt, record] = printed()
      {:ok, prepared} = Rehearsal.prepare("patience", ctx.config)
      written = read_record(out)

      assert database =~ ~r/^database\s+#{written["database"]}$/

      assert packet =~
               "#{length(prepared.packet["candidates"])} of #{prepared.packet["counts"]["offered"]} candidates, " <>
                 "#{length(prepared.packet["meanings"])} of #{prepared.packet["counts"]["meanings_total"]} meanings, " <>
                 "omitted #{length(prepared.packet["omitted"])} (reasons recorded)"

      assert attempt =~
               ~r/^attempt\s+#{written["attempt"]["attempt_id"]}: accepted · lead c\d+ \(bierce\) · 1 highlight · [\d.]+ s · swap \+0 MB$/

      assert record =~ out

      # The operator's actor made the attempt.
      operator =
        Repo.get_by!(DevilsDictionary.Sources.Actor,
          actor_kind: :import,
          label: "Curation runtime operator (CLI)"
        )

      assert Repo.get!(Attempt, written["attempt"]["attempt_id"]).requested_by_actor_id ==
               operator.id

      assert_raise Mix.Error, ~r/never overwritten/, fn -> Mix.Tasks.Dd.Runtime.run(args) end
    end

    test "says so when memory could not be read", ctx do
      bind!()
      FakeSystem.put(memory: [{:error, :unavailable}])
      answer = selection_for(ctx)
      stub_counting!(ctx.config, fn _request -> {:json, answer(answer)} end)
      out = path(ctx, "no-memory.json")

      Mix.Tasks.Dd.Runtime.run(
        ~w(rehearse --model-config #{ctx.config.slug} --scope patience --out) ++ [out]
      )

      assert [_database, _packet, attempt, _record] = printed()
      assert attempt =~ ~r/ · swap not read$/
      assert read_record(out)["memory"]["before"] == %{"unavailable" => true}
    end

    test "prints a refusal and where it is recorded", ctx do
      bind!()
      unreachable!()
      out = path(ctx, "refused.json")

      Mix.Tasks.Dd.Runtime.run(
        ~w(rehearse --model-config #{ctx.config.slug} --scope patience --out) ++ [out]
      )

      assert [_database, _packet, refused, _record] = printed()
      assert refused =~ ~r/^refused\s+at readiness: :service_unreachable$/
      assert read_record(out)["refusal"] == "service_unreachable"
    end
  end

  describe "test 3: the same scope and packet replay the same receipt" do
    test "a second rehearsal sends nothing, and its record says replay", ctx do
      bind!(ctx.opts)
      answer = selection_for(ctx)
      stub_counting!(ctx.config, fn _request -> {:json, answer(answer)} end)

      assert {:ok, first} =
               Rehearsal.run(
                 "patience",
                 ctx.config,
                 Keyword.put(ctx.opts, :out, path(ctx, "1.json"))
               )

      settle!()
      assert_received {:chat, _request}

      assert {:replay, again} =
               Rehearsal.run(
                 "patience",
                 ctx.config,
                 Keyword.put(ctx.opts, :out, path(ctx, "2.json"))
               )

      refute_received {:chat, _request}
      assert attempts(ctx) == 1
      assert again["request_key"] == first["request_key"]
      assert again["attempt"].attempt_id == first["attempt"].attempt_id

      written = read_record(path(ctx, "2.json"))
      assert written["status"] == "replay"
      assert written["attempt"]["attempt_id"] == first["attempt"].attempt_id
      assert written["answer"] == read_record(path(ctx, "1.json"))["answer"]
    end

    test "a changed packet is a new request key", ctx do
      bind!(ctx.opts)
      answer = selection_for(ctx)
      stub_counting!(ctx.config, fn _request -> {:json, answer(answer)} end)
      {:ok, before} = Rehearsal.prepare("patience", ctx.config)

      assert {:ok, _} =
               Rehearsal.run(
                 "patience",
                 ctx.config,
                 Keyword.put(ctx.opts, :out, path(ctx, "a.json"))
               )

      # Bierce's entry is withheld: the packet the page offers changes.
      disallow_record!(hd(ctx.made.entries))
      {:ok, changed} = Rehearsal.prepare("patience", ctx.config)
      refute changed.request_key == before.request_key
      assert changed.packet["priority_candidates"] == []
    end
  end
end
