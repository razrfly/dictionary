defmodule Mix.Tasks.Dd.Runtime do
  @shortdoc "Operate the private curation runtime (#195): service, setup, readiness, requests, recovery, benchmark"

  @moduledoc """
  The operator's harness for the curation runtime (#195 stage A). See
  `docs/curation/runtime-operations.md`.

  **The service**, one private `ollama serve` on loopback, with its models on
  the external volume:

      mix dd.runtime service start|stop|restart|status

  **Setup.** This is explicit, and the only thing that ever downloads:

      mix dd.runtime setup --model qwen3.5:4b --slug qwen3.5-4b-v1 [--pull] --accept-license

  `setup` checks that the volume is mounted and external, that the service is
  up, and, before `--pull`, the free space. After a pull it prints the
  model's license. Only `--accept-license` records the pinned model config:
  its digests, quantization, license digest, template digest, runtime version
  and generation settings.

  **Work:**

      mix dd.runtime ready   --model-config SLUG [--smoke]
      mix dd.runtime packet  --lexeme ID[,ID] [--language en] --out PATH
      mix dd.runtime request --model-config SLUG --packet PATH --key KEY

  `request` runs one frozen packet and prints its receipt. It writes an
  attempt and its accounting, and never a composition, review, publication,
  claim or page.

  **The slot:**

      mix dd.runtime budget [--day YYYY-MM-DD]
      mix dd.runtime sweep                          # expired leases: release or quarantine
      mix dd.runtime recover                        # confirmed stop, settle, restart; stays paused
      mix dd.runtime resume  --model-config SLUG    # readiness, then available
      mix dd.runtime pause   --reason TEXT

  **The benchmark**, in a `*_bench` database only:

      DD_DATABASE=devils_dictionary_runtime_bench mix dd.runtime bench seed --plan PLAN --packets DIR
      DD_DATABASE=devils_dictionary_runtime_bench mix dd.runtime bench run  --plan PLAN --packets DIR --out FILE

  Every command starts the repository and an HTTP client, and nothing else:
  no Oban node, no endpoint.
  """

  use Mix.Task

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
    ServiceProcess
  }

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
    language: :string,
    out: :string,
    packet: :string,
    key: :string,
    day: :string,
    reason: :string,
    plan: :string,
    packets: :string,
    min_free_gib: :integer
  ]

  @impl Mix.Task
  def run(args) do
    {opts, rest, invalid} = OptionParser.parse(args, strict: @switches)
    if invalid != [], do: Mix.raise("unknown options: #{inspect(invalid)}")
    start!()
    command(rest, opts)
  end

  defp command(["service", action], _opts) do
    case action do
      "start" -> print(ServiceProcess.start())
      "stop" -> print(ServiceProcess.stop())
      "restart" -> print(with({:ok, _} <- ServiceProcess.stop(), do: ServiceProcess.start()))
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
        Mix.shell().info("pulling #{model} (explicit setup; #{free} GiB free)…")
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
        print(Provenance.register(model, slug, operator!().id))
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
    ids = required(opts, :lexeme) |> String.split(",") |> Enum.map(&String.to_integer/1)
    out = required(opts, :out)

    with {:ok, packet} <- Packet.build(ids, Keyword.get(opts, :language, "en")),
         {:ok, frozen} <- Packet.freeze(packet) do
      hash = Packet.write!(frozen, out)

      Mix.shell().info(
        "#{out}: #{length(packet["candidates"])} candidates, #{frozen.bytes} bytes, sha256 #{hash}"
      )
    else
      error -> print(error)
    end
  end

  defp command(["request"], opts) do
    config = config!(opts)

    print(
      Runtime.run(config, required(opts, :packet),
        request_key: required(opts, :key),
        actor_id: operator!().id
      )
    )
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
    seeded = Bench.seed!(plan)
    hashes = Bench.freeze_packets!(seeded, dir)

    Enum.each(hashes, fn {case_id, hash} ->
      Mix.shell().info("#{case_id}: #{Path.join(dir, case_id <> ".json")} #{hash}")
    end)
  end

  defp command(["bench", "run"], opts) do
    plan = Bench.plan!(required(opts, :plan))
    dir = required(opts, :packets)
    run_id = "#{System.os_time(:second)}"

    {records, missing} = Bench.run(plan, dir, run_id: run_id, actor_id: operator!().id)

    report = %{
      run_id: run_id,
      finished_at: DateTime.utc_now(),
      service: Bench.service_facts(),
      budget: Gateway.budget(Date.utc_today()),
      summary: Bench.summarize(records, plan, dir),
      not_measured: missing,
      samples: records
    }

    File.write!(required(opts, :out), Jason.encode!(json(report), pretty: true))
    Mix.shell().info("#{length(records)} samples, #{length(missing)} gaps → #{opts[:out]}")
  end

  defp command(other, _opts),
    do: Mix.raise("unknown command #{inspect(other)}; see mix help dd.runtime")

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
    {:ok, _} = Application.ensure_all_started([:postgrex, :ecto_sql, :req])

    case Repo.start_link() do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> :ok
    end
  end
end
