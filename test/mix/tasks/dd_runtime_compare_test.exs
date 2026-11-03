defmodule Mix.Tasks.Dd.RuntimeCompareTest do
  @moduledoc """
  `mix dd.runtime compare` end to end (#298 C2, C9; #303 review R1, R5,
  R9): the real CLI path, including its `SET TRANSACTION ISOLATION LEVEL
  REPEATABLE READ, READ ONLY` freeze, which cannot run inside the SQL
  sandbox's transaction. So these tests are unboxed: they commit real rows
  in the private partition and truncate after themselves (DataCase).
  Against the controlled fake of the private service; no real model.
  """
  use DevilsDictionary.DataCase, async: false

  import DevilsDictionary.RefreshFixtures, only: [love_world!: 0]
  import DevilsDictionary.RuntimeFixtures
  import DevilsDictionary.CurationFixtures, only: [account: 1, actor!: 1]

  alias DevilsDictionary.CitationFixtures

  alias DevilsDictionary.Curation.{
    CompositionPublication,
    CompositionVersion,
    Proposal,
    Shelf,
    WholeEntry
  }

  alias DevilsDictionary.Curation.Runtime.Attempt

  @moduletag :unboxed
  @moduletag :tmp_dir
  @moduletag timeout: 300_000

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
    level = Logger.level()
    Mix.shell(Mix.Shell.Process)

    on_exit(fn ->
      Mix.shell(Mix.Shell.IO)
      Logger.configure(level: level)
    end)

    w = love_world!()

    for provider <- Shelf.providers(),
        do: CitationFixtures.observation!(w, provider, namespace: @namespaces[provider])

    v7 = model_config!(%{instruction_version: "voltaire-whole-entry-v7", tag: "9b"}) |> ready!()

    fixed =
      model_config!(%{instruction_version: "voltaire-whole-entry-v7-fixed-lead-v1", tag: "9b"})
      |> ready!()

    bind!()
    test = self()

    stub_ollama!(v7,
      chat: fn request ->
        send(test, {:chat, request})
        {:json, answer(wire(request))}
      end
    )

    %{
      w: w,
      actor: actor!(account([:reviewer])),
      arms: "A0=#{v7.slug},P=#{v7.slug}:text,L=#{fixed.slug},PL=#{fixed.slug}:text"
    }
  end

  defp wire(request) do
    %{"content" => "Packet:\n" <> json} = List.last(request["messages"])
    visible = Jason.decode!(json)
    priority = visible["priority_candidates"]

    lead =
      if is_binary(visible["fixed_lead"]),
        do: nil,
        else: Enum.find(visible["candidates"], &(&1["candidate_id"] in priority))

    %{
      "decision" => "select",
      "lead" =>
        lead &&
          %{
            "candidate_id" => lead["candidate_id"],
            "meaning_id" => hd(lead["allowed_meanings"]),
            "reason" => "It defines the word."
          },
      "selections" =>
        Map.new(WholeEntry.sections(), &{&1, if(&1 in ["examples", "quotes"], do: [], else: nil)}),
      "abstain_reason" => nil
    }
  end

  defp compare!(args), do: Mix.Tasks.Dd.Runtime.run(["compare" | args])

  defp lines(acc \\ []) do
    receive do
      {:mix_shell, :info, [line]} -> lines([line | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  defp rows,
    do:
      for(
        s <- [Attempt, CompositionVersion, CompositionPublication, Proposal],
        do: Repo.aggregate(s, :count)
      )

  defp enable_editor!(ctx) do
    Repo.query!(
      """
      UPDATE curation_configurations
         SET editor_enabled_version_id = current_version_id, editor_switched_by_actor_id = $1,
             editor_switched_at = now(), editor_switch_reason = 'compare CLI test'
       WHERE id = $2
      """,
      [ctx.actor.id, ctx.w.configuration.id]
    )
  end

  test "the dry run freezes in a read-only snapshot, prints, and calls and writes nothing",
       ctx do
    before = rows()
    compare!(~w(--batch cli-dry --page love --dry-run --arms) ++ [ctx.arms])
    out = lines()

    assert Enum.any?(out, &(&1 =~ "matched within each cut"))
    assert Enum.count(out, &(&1 =~ "fingerprint ")) == 4
    assert Enum.any?(out, &(&1 =~ "fixed lead"))
    assert Enum.any?(out, &(&1 =~ "would run" and &1 =~ "yes"))
    assert rows() == before
    refute_received {:chat, _}
  end

  test "with an editor enabled, the dry run says it would refuse and a run refuses", ctx do
    enable_editor!(ctx)
    before = rows()

    compare!(~w(--batch cli-editor --page love --dry-run --arms) ++ [ctx.arms])
    assert Enum.any?(lines(), &(&1 =~ "would run" and &1 =~ "REFUSED: an editor is enabled"))

    out = Path.join(ctx.tmp_dir, "cli-editor.json")

    assert_raise Mix.Error, ~r/an editor is enabled/, fn ->
      compare!(~w(--batch cli-editor --page love --out) ++ [out, "--arms", ctx.arms])
    end

    assert rows() == before
    refute File.exists?(out)
    refute_received {:chat, _}
  end

  test "a run sends four comparison attempts, writes its record, publishes nothing; the batch id is used once",
       ctx do
    out = Path.join(ctx.tmp_dir, "cli-run.json")
    [_attempts | publishing] = rows()

    compare!(~w(--batch cli-run --page love --out) ++ [out, "--arms", ctx.arms])

    attempts = Repo.all(from a in Attempt, order_by: a.id)
    assert length(attempts) == 4
    assert Enum.all?(attempts, &(&1.purpose == :comparison and &1.state == :completed))
    assert Enum.map(attempts, & &1.comparison_case) |> Enum.uniq() == ["cli-run:love:1"]
    assert tl(rows()) == publishing

    body = File.read!(out)
    record = Jason.decode!(body)
    assert record["batch"] == "cli-run"
    assert [%{"status" => "matched", "case_id" => "cli-run:love:1"}] = record["cases"]
    assert is_nil(record["halted"])
    refute body =~ "It defines the word."

    # The same batch id again is refused before anything is sent.
    again = Path.join(ctx.tmp_dir, "cli-run-again.json")

    assert_raise Mix.Error, ~r/already has comparison attempts/, fn ->
      compare!(~w(--batch cli-run --page love --out) ++ [again, "--arms", ctx.arms])
    end

    refute File.exists?(again)
    assert Repo.aggregate(Attempt, :count) == 4

    # The record is read back by the report, which lists its one case.
    {:ok, decoded} = out |> File.read!() |> Jason.decode()

    report =
      DevilsDictionary.Curation.Coverage.comparison("cli-run", record: decoded)

    assert [%{record_status: "matched", attempts: 4, matched: true}] = report.cases
  end

  test "an existing batch record is never overwritten", ctx do
    out = Path.join(ctx.tmp_dir, "cli-taken.json")
    File.write!(out, "{}")

    assert_raise Mix.Error, ~r/never overwritten/, fn ->
      compare!(~w(--batch cli-taken --page love --out) ++ [out, "--arms", ctx.arms])
    end

    assert File.read!(out) == "{}"
    assert Repo.aggregate(Attempt, :count) == 0
  end
end
