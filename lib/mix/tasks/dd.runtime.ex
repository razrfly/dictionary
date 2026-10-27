defmodule Mix.Tasks.Dd.Runtime do
  @shortdoc "Operate the private curation runtime (#195): service, setup, readiness, requests, rehearsals, recovery, benchmark"

  @moduledoc """
  The operator's harness for the curation runtime (#195 stage A). See
  `docs/curation/runtime-operations.md`.

  **The service**, one private `ollama serve` on loopback, with its models on
  the external volume:

      mix dd.runtime service start|stop|restart|status [--rebind]

  `start` binds the service's one slot to the connected database
  (`Runtime.Authority`). Callers of any other database are refused at
  readiness. `--rebind` moves the binding, and is for an operator who has
  checked that the old database's slot holds no live attempt.

  **Setup.** This is explicit, and the only thing that ever downloads:

      mix dd.runtime setup --model qwen3.5:9b --slug qwen3.5-9b-v2 [--pull] \
        --instruction generic-editor-v2 --accept-license

  `setup` checks that the volume is mounted and external, that the service is
  up, and, before `--pull`, the free space. After a pull it prints the
  model's license. Only `--accept-license` records the pinned model config:
  its digests, quantization, license digest, template digest, runtime version,
  generation settings and the instruction it runs (`--instruction`, one of
  `Packet.instruction_versions/0`, never a default). A new instruction for
  the same model is a new config, under a new slug.

  **Work:**

      mix dd.runtime ready   --model-config SLUG [--smoke]
      mix dd.runtime packet  --model-config SLUG --lexeme ID[,ID] [--language en] --out PATH
      mix dd.runtime packet  --scope SLUG --dry-run (--model-config SLUG | --instruction V) [--language en]
      mix dd.runtime request --model-config SLUG --packet PATH --key KEY [--deadline-ms MS]

  `packet` builds for the config's pinned instruction, and `request` refuses a
  packet built for another. `request` runs one frozen packet and prints its
  receipt. It writes an
  attempt and its accounting, and never a composition, review, publication,
  claim or page. `--deadline-ms` shortens the call's deadline, and with it the
  reservation and the lease, for a recovery drill. It never lengthens them.

  `packet --dry-run` prints what an editor would be offered for the On page
  SLUG (#262 §2.2): the cut and its counts, the Bierce entries always in,
  what was left out and why, by id, and the hashes. It admits nothing and
  writes nothing, not even a file. The instruction is a pinned config's
  (`--model-config`) or one of `Packet.instruction_versions/0`
  (`--instruction`), never a default.

  **A rehearsal** (#267) runs one real page's packet once, as an attempt
  only (`Runtime.Rehearsal`):

      mix dd.runtime rehearse --model-config SLUG --scope SLUG --dry-run [--language en]
      mix dd.runtime rehearse --model-config SLUG --scope SLUG [--out PATH] [--language en]

  `--dry-run` prints the packet as `packet --dry-run` does, with the request
  key it would use, and calls and writes nothing. Without it, `rehearse`
  refuses unless the service is bound to the connected database and
  readiness passes, then sends the frozen packet once under the request key
  `rehearsal:<config>:<packet hash>`, with the benchmark's memory, swap and
  resident-set readings. It writes the attempt and its accounting, and one
  JSON record (`--out`, by default
  `priv/curation/runtime_bench/rehearsals/<UTC date>/<scope>.json`, never
  overwritten), whether it ran, replayed or refused. The same scope and
  packet replay the same receipt.

  **The slot:**

      mix dd.runtime budget [--day YYYY-MM-DD]
      mix dd.runtime sweep                          # expired leases: release or quarantine
      mix dd.runtime recover                        # confirmed stop, settle, restart; stays paused
      mix dd.runtime resume  --model-config SLUG    # readiness, then available
      mix dd.runtime pause   --reason TEXT

  **The benchmark**, in a `*_bench` database only. `seed` freezes the packets
  for the plan's `instruction_version`, and `run` writes the samples, the
  summary and the plan's go or no-go per model:

      DD_DATABASE=devils_dictionary_runtime_bench mix dd.runtime bench seed --plan PLAN --packets DIR
      DD_DATABASE=devils_dictionary_runtime_bench mix dd.runtime bench run  --plan PLAN --packets DIR --out FILE

  Every command starts the repository and an HTTP client, and nothing else:
  no Oban node, no endpoint.
  """

  use Mix.Task

  alias DevilsDictionary.Curation.Candidates
  alias DevilsDictionary.Curation.Runtime

  alias DevilsDictionary.Curation.Runtime.{
    Bench,
    Endpoint,
    Gateway,
    ModelConfig,
    Ollama,
    Packet,
    Provenance,
    Readiness,
    Rehearsal,
    ServiceProcess
  }

  alias DevilsDictionary.Lexicon
  alias DevilsDictionary.Lexicon.WordPage
  alias DevilsDictionary.Repo
  alias DevilsDictionary.Sources.Actor

  @switches [
    model: :string,
    slug: :string,
    pull: :boolean,
    accept_license: :boolean,
    model_config: :string,
    smoke: :boolean,
    lexeme: :string,
    scope: :string,
    dry_run: :boolean,
    language: :string,
    out: :string,
    packet: :string,
    key: :string,
    day: :string,
    reason: :string,
    instruction: :string,
    plan: :string,
    packets: :string,
    min_free_gib: :integer,
    deadline_ms: :integer,
    rebind: :boolean
  ]

  # Every command this task answers, as its positional words.
  @commands [
    ["service", "start"],
    ["service", "stop"],
    ["service", "restart"],
    ["service", "status"],
    ["setup"],
    ["ready"],
    ["packet"],
    ["request"],
    ["rehearse"],
    ["budget"],
    ["sweep"],
    ["recover"],
    ["resume"],
    ["pause"],
    ["bench", "seed"],
    ["bench", "run"]
  ]

  @impl Mix.Task
  def run(args) do
    {opts, rest} = parse!(args)
    start!()
    command(rest, opts)
  end

  @doc false
  # The commands and their switches, without starting anything: what the
  # runbook's commands are checked against (#267 §8 test 5).
  def commands, do: @commands

  @doc false
  def parse!(args) do
    {opts, rest, invalid} = OptionParser.parse(args, strict: @switches)
    if invalid != [], do: Mix.raise("unknown options: #{inspect(invalid)}")
    {opts, rest}
  end

  defp command(["service", action], opts) do
    start = Keyword.take(opts, [:rebind])

    case action do
      "start" -> print(ServiceProcess.start(start))
      "stop" -> print(ServiceProcess.stop())
      "restart" -> print(with({:ok, _} <- ServiceProcess.stop(), do: ServiceProcess.start(start)))
      "status" -> print({:ok, ServiceProcess.status()})
      other -> Mix.raise("unknown service action #{other}")
    end
  end

  defp command(["setup"], opts) do
    model = required(opts, :model)
    slug = required(opts, :slug)
    system = Endpoint.system()

    with {:ok, %{mounted: true, external: true}} <- system.volume(Endpoint.get(:mount_point)),
         true <- system.dir?(Endpoint.get(:models_root)) || {:error, :models_root_missing},
         {:ok, version} <- Ollama.version() do
      Mix.shell().info(
        "runtime #{version} at #{Endpoint.get(:base_url)}, models under #{Endpoint.get(:models_root)}"
      )

      if opts[:pull] do
        free = free_gib(Endpoint.get(:models_root))
        min = Keyword.get(opts, :min_free_gib, 20)
        if free < min, do: Mix.raise("only #{free} GiB free on the model volume; need #{min}")
        Mix.shell().info("pulling #{model} (explicit setup; #{free} GiB free)...")
        print(Ollama.pull(model))
      end

      {:ok, show} = Ollama.show(model)

      Mix.shell().info(
        ("license (first lines):\n" <> (show["license"] || "(none)"))
        |> String.split("\n")
        |> Enum.take(8)
        |> Enum.join("\n")
      )

      if opts[:accept_license] do
        instruction = required(opts, :instruction)

        print(Provenance.register(model, slug, operator!().id, instruction_version: instruction))
      else
        Mix.shell().info(
          "not recorded: re-run with --accept-license once the license is acceptable"
        )
      end
    else
      other -> print({:error, other})
    end
  end

  defp command(["ready"], opts) do
    config = config!(opts)

    case Readiness.check(config) do
      {:ok, report} ->
        print({:ok, report})

        if opts[:smoke],
          do: print(Runtime.smoke(config, request_key: key("smoke"), actor_id: operator!().id))

      {:error, reason, report} ->
        print({:error, reason, report})
    end
  end

  defp command(["packet"], opts) do
    if opts[:dry_run], do: dry_run(opts), else: write_packet(opts)
  end

  defp command(["request"], opts) do
    config = config!(opts)

    print(
      Runtime.run(
        config,
        required(opts, :packet),
        [request_key: required(opts, :key), actor_id: operator!().id] ++ deadline(opts)
      )
    )
  end

  defp command(["rehearse"], opts) do
    config = config!(opts)
    scope = required(opts, :scope)
    language = Keyword.get(opts, :language, "en")

    if opts[:dry_run],
      do: rehearse_dry_run(scope, config, language),
      else: rehearse(scope, config, opts)
  end

  defp command(["budget"], opts) do
    day = if opts[:day], do: Date.from_iso8601!(opts[:day]), else: Date.utc_today()
    print({:ok, Gateway.budget(day)})
  end

  defp command(["sweep"], _opts), do: print(Gateway.sweep())
  defp command(["recover"], _opts), do: print(Runtime.recover())
  defp command(["resume"], opts), do: print(Runtime.resume(config!(opts)))
  defp command(["pause"], opts), do: print(Gateway.pause(required(opts, :reason)))

  defp command(["bench", "seed"], opts) do
    plan = Bench.plan!(required(opts, :plan))
    dir = required(opts, :packets)

    instruction =
      plan["instruction_version"] || Mix.raise("the plan names no instruction_version")

    seeded = Bench.seed!(plan)
    hashes = Bench.freeze_packets!(seeded, dir, instruction)

    Enum.each(hashes, fn {case_id, hash} ->
      Mix.shell().info("#{case_id}: #{Path.join(dir, case_id <> ".json")} #{hash}")
    end)
  end

  defp command(["bench", "run"], opts) do
    Bench.bench_database!("run the benchmark in")
    plan = Bench.plan!(required(opts, :plan))
    dir = required(opts, :packets)
    run_id = "#{System.os_time(:second)}"

    {records, missing} = Bench.run(plan, dir, run_id: run_id, actor_id: operator!().id)
    summary = Bench.summarize(records, plan, dir)

    report = %{
      run_id: run_id,
      database: Repo.config()[:database],
      plan: plan["plan_version"],
      instruction_version: plan["instruction_version"],
      finished_at: DateTime.utc_now(),
      service: Bench.service_facts(),
      budget: Gateway.budget(Date.utc_today()),
      summary: summary,
      verdict:
        Map.new(plan["models"], fn m ->
          {m, Bench.verdict(m, summary[m], records, missing, plan)}
        end),
      not_measured: missing,
      samples: records
    }

    File.write!(required(opts, :out), Jason.encode!(json(report), pretty: true))
    Mix.shell().info("#{length(records)} samples, #{length(missing)} gaps → #{opts[:out]}")
  end

  defp command(other, _opts),
    do: Mix.raise("unknown command #{inspect(other)}; see mix help dd.runtime")

  # ── packets ───────────────────────────────────────────────────────────────

  defp write_packet(opts) do
    config = config!(opts)
    ids = required(opts, :lexeme) |> String.split(",") |> Enum.map(&String.to_integer/1)
    out = required(opts, :out)
    language = Keyword.get(opts, :language, "en")

    with {:ok, packet} <-
           Packet.build(ids, language, instruction_version: config.instruction_version),
         {:ok, frozen} <- Packet.freeze(packet) do
      hash = Packet.write!(frozen, out)

      Mix.shell().info(
        "#{out}: #{length(packet["candidates"])} candidates, #{frozen.bytes} bytes, sha256 #{hash}"
      )
    else
      error -> print(error)
    end
  end

  defp dry_run(opts) do
    slug = required(opts, :scope)
    language = Keyword.get(opts, :language, "en")
    instruction = dry_run_instruction(opts)
    page = slug |> Lexicon.lookup(language) |> WordPage.build(viewer: :public)
    candidates = Candidates.for_page(page)
    result = Packet.for_page(page, instruction_version: instruction, candidates: candidates)

    shell = Mix.shell()
    Enum.each(dry_run_lines(slug, result, candidates), &shell.info/1)
  end

  # ── rehearsals ────────────────────────────────────────────────────────────

  # What the rehearsal would send, and under which key. No readiness, no
  # call, no row, no file.
  defp rehearse_dry_run(scope, config, language) do
    lines =
      case Rehearsal.dry_run(scope, config, language: language) do
        {:ok, prepared} ->
          [row("model_config", "#{config.slug} · config ##{config.id}")] ++
            dry_run_lines(scope, {:ok, prepared.packet}, prepared.candidates) ++
            ["request_key      #{prepared.request_key}"]

        {:error, reason} ->
          dry_run_lines(scope, {:error, reason}, nil)
      end

    shell = Mix.shell()
    Enum.each(lines, &shell.info/1)
  end

  defp rehearse(scope, config, opts) do
    rehearsal_opts =
      [actor_id: fn -> operator!().id end, language: Keyword.get(opts, :language, "en")] ++
        Keyword.take(opts, [:out])

    case Rehearsal.run(scope, config, rehearsal_opts) do
      {:error, {:record_exists, path}} ->
        Mix.raise("#{path} exists: a rehearsal record is never overwritten; name another --out")

      {_status, record} ->
        shell = Mix.shell()
        Enum.each(rehearsal_lines(record), &shell.info/1)
    end
  end

  defp rehearsal_lines(record) do
    packet = record["packet"]

    packet_line =
      packet &&
        row(
          "packet",
          "#{packet["candidates"]} of #{packet["offered"]} candidates, " <>
            "#{packet["meanings"]} of #{packet["meanings_total"]} meanings, " <>
            "omitted #{packet["omitted"]} (reasons recorded)"
        )

    outcome_line =
      case record["status"] do
        "refused" ->
          row(
            "refused",
            "at #{record["refused_at"]}: #{inspect(record["refusal"])}" <>
              if(record["refusal_detail"],
                do: " (#{inspect(record["refusal_detail"])})",
                else: ""
              )
          )

        status ->
          attempt_line(status, record)
      end

    Enum.reject(
      [
        row("database", record["database"]),
        packet_line,
        outcome_line,
        row("record", record["path"])
      ],
      &is_nil/1
    )
  end

  defp attempt_line(status, record) do
    attempt = record["attempt"]
    answer = record["answer"]
    lead = answer && answer["lead"]
    wall = record["latency_ms"]["wall"]
    memory = record["memory"]

    swap =
      case memory do
        %{"before" => %{"swap_used_bytes" => a}, "after" => %{"swap_used_bytes" => b}} ->
          "swap #{if b >= a, do: "+", else: "-"}#{div(abs(b - a), 1024 * 1024)} MB"

        _ ->
          "swap not read"
      end

    row(
      "attempt",
      Enum.join(
        [
          "#{attempt.attempt_id}: #{attempt.outcome || attempt.state}" <>
            if(status == "ok", do: "", else: " (#{status})"),
          if(lead,
            do: "lead #{lead["candidate_id"]} (#{lead["source"] || lead["kind"]})",
            else: "no lead"
          ),
          highlights((answer && answer["highlights"]) || []),
          if(wall, do: "#{Float.round(wall / 1000, 1)} s", else: "no time"),
          swap
        ],
        " · "
      )
    )
  end

  defp highlights([_one]), do: "1 highlight"
  defp highlights(list), do: "#{length(list)} highlights"

  defp dry_run_instruction(opts) do
    versions = Packet.instruction_versions()

    cond do
      opts[:model_config] ->
        config!(opts).instruction_version

      opts[:instruction] in versions ->
        opts[:instruction]

      opts[:instruction] ->
        Mix.raise("--instruction must be one of #{Enum.join(versions, ", ")}")

      true ->
        Mix.raise(
          "--model-config or --instruction is required: an instruction is never defaulted"
        )
    end
  end

  defp dry_run_lines(slug, {:error, reason}, _candidates) do
    [row("packet_version", Packet.version()), row("scope", slug), row("refused", inspect(reason))]
  end

  defp dry_run_lines(slug, {:ok, packet}, candidates) do
    target = packet["target"]
    policy = packet["policy"]
    counts = packet["counts"]
    chosen = packet["candidates"]
    omitted = packet["omitted"]
    kept = length(packet["meanings"])
    required = counts["meanings_required"]
    kinds = Enum.frequencies_by(chosen, & &1["kind"])
    reasons = Enum.frequencies_by(omitted, & &1["reason"])

    hash =
      case Packet.freeze(packet) do
        {:ok, frozen} -> frozen.hash
        {:error, reason} -> "not frozen: #{inspect(reason)}"
      end

    [
      row("packet_version", packet["packet_version"]),
      row("instruction", packet["instruction_version"]),
      row(
        "scope",
        "#{slug} · lexemes #{Enum.join(target["lexeme_ids"], " ")} · #{target["language_tag"]}"
      ),
      row(
        "meanings",
        "#{kept} of #{counts["meanings_total"]} (required #{required}, bounded #{kept - required})" <>
          " · policy #{policy["meanings"]}"
      ),
      row(
        "candidates",
        "#{length(chosen)} of #{counts["offered"]} · " <>
          Enum.map_join(Packet.kinds(), ", ", &"#{&1} #{Map.get(kinds, &1, 0)}") <>
          " · policy #{policy["cut"]}"
      ),
      row("priority", priority_text(packet, candidates)),
      row(
        "omitted",
        "#{length(omitted)}" <>
          if(reasons == %{},
            do: "",
            else:
              " · by id with reason: " <>
                (reasons |> Enum.sort() |> Enum.map_join(", ", fn {r, n} -> "#{r} #{n}" end))
          )
      ),
      row("hashes", "packet sha256 #{hash}, candidate set sha256 #{Packet.digest(packet)}"),
      "chosen"
    ] ++
      Enum.map(chosen, fn c ->
        "  " <>
          Enum.map_join(
            [{c["candidate_id"], 4}, {c["kind"], 16}, {c["source"] || "-", 12}, {c["key"], 30}],
            "",
            fn {text, width} -> String.pad_trailing(to_string(text), width) end
          ) <> c["required_meaning"]
      end) ++
      ["omitted"] ++
      Enum.map(omitted, fn o ->
        "  " <>
          String.pad_trailing(o["key"], 34) <> String.pad_trailing(o["kind"], 16) <> o["reason"]
      end)
  end

  defp priority_text(%{"priority_candidates" => []}, _candidates),
    do: "none (no applicable Bierce entry)"

  defp priority_text(packet, candidates) do
    by_id = Map.new(packet["candidates"], &{&1["candidate_id"], &1})

    Enum.map_join(packet["priority_candidates"], "; ", fn id ->
      c = by_id[id]
      title = Candidates.find(candidates, c["key"])
      "#{c["source"]} #{title && title.title} (#{c["key"]}, always in)"
    end)
  end

  defp row(label, value), do: String.pad_trailing(label, 17) <> to_string(value)

  # ── helpers ───────────────────────────────────────────────────────────────

  defp config!(opts) do
    slug = required(opts, :model_config)
    Repo.get_by(ModelConfig, slug: slug) || Mix.raise("no model config #{slug}")
  end

  # The CLI acts as an operator process. Its attempts carry this actor, which
  # approves nothing: runtime results are not reviews or publications.
  defp operator! do
    label = "Curation runtime operator (CLI)"

    Repo.get_by(Actor, actor_kind: :import, label: label) ||
      Repo.insert!(
        Actor.changeset(%Actor{}, %{
          actor_kind: :import,
          label: label,
          metadata: %{"operation" => "curation_runtime"}
        })
      )
  end

  # A drill may shorten the deadline, never lengthen it.
  defp deadline(opts) do
    case opts[:deadline_ms] do
      nil -> []
      ms when ms > 0 -> [deadline_ms: min(ms, Endpoint.get(:deadline_ms))]
      _ -> Mix.raise("--deadline-ms must be positive")
    end
  end

  defp required(opts, key),
    do: opts[key] || Mix.raise("--#{String.replace(to_string(key), "_", "-")} is required")

  defp key(prefix), do: "#{prefix}:#{System.os_time(:millisecond)}"

  defp free_gib(path) do
    {out, 0} = System.cmd("df", ["-k", path])
    [_header, line | _] = String.split(out, "\n", trim: true)
    line |> String.split() |> Enum.at(3) |> String.to_integer() |> div(1024 * 1024)
  end

  defp print(value),
    do:
      Mix.shell().info(inspect(json(value), pretty: true, limit: :infinity, printable_limit: 400))

  defp json(%DateTime{} = dt), do: DateTime.to_iso8601(dt)
  defp json(%Date{} = d), do: Date.to_iso8601(d)

  defp json(%{__struct__: _} = struct),
    do: struct |> Map.from_struct() |> Map.delete(:__meta__) |> json()

  defp json(%{} = map), do: Map.new(map, fn {k, v} -> {k, json(v)} end)
  defp json(list) when is_list(list), do: Enum.map(list, &json/1)
  defp json(tuple) when is_tuple(tuple), do: tuple |> Tuple.to_list() |> json()
  defp json(other), do: other

  defp start! do
    Mix.Task.run("app.config")
    # Receipts are the output; dev's per-query debug logs would bury them.
    Logger.configure(level: :info)
    {:ok, _} = Application.ensure_all_started([:postgrex, :ecto_sql, :req])

    case Repo.start_link() do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> :ok
    end
  end
end
