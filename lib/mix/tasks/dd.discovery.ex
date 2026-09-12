defmodule Mix.Tasks.Dd.Discovery do
  @shortdoc "Exercises the visit-driven cultural discovery pipeline on a bounded source sample"

  @moduledoc """
  Selects real definition targets from one registered dictionary source, then
  invokes the same mapping, admission, cache, Oban and provider services used by
  a reader visit. It warms caches, never handpicked answers.

      mix dd.discovery --definition-source bierce --providers cinegraph --limit 20 --dry-run
      mix dd.discovery --definition-source bierce --providers cinegraph --limit 20
      mix dd.discovery --definition-source johnson --providers all --limit 20 --refresh

  Options:

    * `--definition-source SLUG` (required) selects current definitions supplied
      by that source, not every work attributed to its author.
    * `--providers LIST` is a comma-separated list or `all` (default).
    * `--limit N` bounds selection before the corpus is enumerated (default 20,
      maximum 100).
    * `--after OBJECT_ID` is the deterministic resume checkpoint. Re-running is
      safe because fresh positive/negative caches and in-flight jobs deduplicate.
    * `--refresh` asks for fresh work but does not bypass budgets, backoff,
      queue caps, in-flight deduplication, retention or display restrictions.
    * `--dry-run` performs local selection and capability checks only. It makes
      no discovery writes, jobs or external requests.
    * `--wait-ms N` bounds completion polling (default from application config).

  Reports completed nonempty/empty results, fresh-cache skips, failures,
  still-queued work, deferrals and unsupported/disabled providers separately.
  """

  use Mix.Task

  import Ecto.Query

  alias DevilsDictionary.Discovery
  alias DevilsDictionary.Discovery.{Providers, Run}
  alias DevilsDictionary.Repo

  @switches [
    definition_source: :string,
    providers: :string,
    limit: :integer,
    after: :integer,
    refresh: :boolean,
    dry_run: :boolean,
    wait_ms: :integer
  ]

  @impl Mix.Task
  def run(args) do
    Mix.Task.run("app.start")
    {opts, rest, invalid} = OptionParser.parse(args, strict: @switches)
    validate_args!(opts, rest, invalid)

    limit = opts[:limit] || 20
    after_id = opts[:after]
    source = opts[:definition_source]
    requested = opts[:providers] || "all"
    wait_ms = opts[:wait_ms] || discovery_config()[:task_wait_ms]

    with {:ok, targets} <- Discovery.targets_for_definition_source(source, limit, after_id) do
      selection_header(source, targets, limit, after_id)
      {eligible, skipped} = select_providers(requested)
      print_provider_report(eligible, skipped)

      if opts[:dry_run] do
        dry_run_report(targets, eligible)
      else
        outcomes = execute(targets, eligible, opts[:refresh] == true)
        report = wait_and_classify(outcomes, wait_ms)
        print_completion(report, length(targets) * length(eligible), skipped)
      end

      print_checkpoint(targets)
    else
      {:error, :definition_source_not_found} ->
        Mix.raise("definition source #{inspect(source)} is not registered")

      {:error, :not_a_definition_source} ->
        Mix.raise("source #{inspect(source)} is not a dictionary definition catalog")

      {:error, :definition_source_disabled} ->
        Mix.raise("definition source #{inspect(source)} is disabled")
    end
  end

  defp validate_args!(opts, rest, invalid) do
    if rest != [] or invalid != [],
      do: Mix.raise("invalid arguments; run `mix help dd.discovery`")

    unless present?(opts[:definition_source]) do
      Mix.raise("--definition-source is required; run `mix help dd.discovery`")
    end

    limit = opts[:limit] || 20
    unless limit in 1..100, do: Mix.raise("--limit must be between 1 and 100")

    wait_ms = opts[:wait_ms] || discovery_config()[:task_wait_ms]

    unless wait_ms >= 0 and wait_ms <= 120_000,
      do: Mix.raise("--wait-ms must be between 0 and 120000")
  end

  defp selection_header(source, targets, limit, after_id) do
    checkpoint = if after_id, do: " after object #{after_id}", else: ""

    Mix.shell().info(
      "Selected #{length(targets)}/#{limit} targets defined by #{source}#{checkpoint} (stable object-id order)."
    )

    Enum.each(targets, fn target ->
      Mix.shell().info("  #{target.object_id}\t#{target.term}\t#{target.language}")
    end)

    if targets == [] do
      Mix.shell().info("No eligible current definitions were found; no work was requested.")
    end
  end

  defp select_providers(requested) do
    requested_modules =
      case String.trim(requested) do
        "all" -> Providers.all()
        value -> value |> String.split(",", trim: true) |> Enum.map(&String.trim/1)
      end

    Enum.reduce(requested_modules, {[], []}, fn requested_provider, {eligible, skipped} ->
      provider =
        if is_atom(requested_provider),
          do: requested_provider,
          else: Providers.get(requested_provider)

      cond do
        is_nil(provider) ->
          {eligible, [{to_string(requested_provider), "unsupported"} | skipped]}

        !provider.enabled?() ->
          {eligible, [{provider.slug(), "disabled or missing server credentials"} | skipped]}

        provider.capabilities().transport != :server ->
          {eligible, [{provider.slug(), "not server-executable"} | skipped]}

        !provider.capabilities().background ->
          {eligible, [{provider.slug(), "no background retrieval capability"} | skipped]}

        true ->
          {[provider | eligible], skipped}
      end
    end)
    |> then(fn {eligible, skipped} ->
      {Enum.sort_by(eligible, & &1.slug()), Enum.reverse(skipped)}
    end)
  end

  defp print_provider_report(eligible, skipped) do
    Enum.each(eligible, fn provider ->
      capabilities = provider.capabilities()

      Mix.shell().info(
        "Eligible provider #{provider.slug()}: #{capabilities.transport}, " <>
          "#{capabilities.persistence} cache, operations #{Enum.join(capabilities.operations, ",")}."
      )
    end)

    Enum.each(skipped, fn {slug, reason} ->
      Mix.shell().info("Skipped provider #{slug}: #{reason}.")
    end)
  end

  defp dry_run_report(targets, eligible) do
    stages =
      eligible
      |> Enum.flat_map(& &1.capabilities().operations)
      |> Enum.uniq()
      |> Enum.sort()

    Mix.shell().info(
      "Dry run: no writes, jobs or external requests. #{length(targets)} targets × " <>
        "#{length(eligible)} eligible providers; possible stages #{Enum.join(stages, ", ")}. " <>
        "Retries and pagination mean the exact request count is intentionally not claimed."
    )
  end

  defp execute(targets, providers, refresh?) do
    for target <- targets, provider <- providers do
      result = Discovery.request(target, provider.slug(), refresh: refresh?)
      %{target: target, provider: provider.slug(), result: result}
    end
  end

  defp wait_and_classify(outcomes, wait_ms) do
    initial = Enum.map(outcomes, &initial_outcome/1)
    run_ids = for %{kind: :run, run_id: id} <- initial, do: id
    deadline = System.monotonic_time(:millisecond) + wait_ms
    wait_for_runs(run_ids, deadline)

    Enum.map(initial, fn
      %{kind: :run, run_id: id} = item -> Map.merge(item, classify_run(Repo.get(Run, id)))
      item -> item
    end)
  end

  defp initial_outcome(%{target: target, provider: provider, result: {:cached, run}}) do
    %{
      target: target,
      provider: provider,
      kind: if(run.result_count > 0, do: :fresh_cache_nonempty, else: :fresh_cache_empty)
    }
  end

  defp initial_outcome(%{target: target, provider: provider, result: {:queued, run}}) do
    %{target: target, provider: provider, kind: :run, run_id: run.id}
  end

  defp initial_outcome(%{target: target, provider: provider, result: {:deferred, reason}}) do
    %{target: target, provider: provider, kind: :deferred, reason: reason}
  end

  defp initial_outcome(%{target: target, provider: provider, result: {:error, reason}}) do
    %{target: target, provider: provider, kind: :failed, reason: reason}
  end

  defp wait_for_runs([], _deadline), do: :ok

  defp wait_for_runs(run_ids, deadline) do
    unfinished =
      Repo.aggregate(
        from(r in Run, where: r.id in ^run_ids and r.status in [:pending, :running]),
        :count
      )

    remaining = deadline - System.monotonic_time(:millisecond)

    if unfinished > 0 and remaining > 0 do
      receive do
      after
        min(250, remaining) -> wait_for_runs(run_ids, deadline)
      end
    end
  end

  defp classify_run(%Run{status: :succeeded, result_count: count}) when count > 0,
    do: %{kind: :succeeded_nonempty}

  defp classify_run(%Run{status: :succeeded}), do: %{kind: :succeeded_empty}
  defp classify_run(%Run{status: :failed, error_code: code}), do: %{kind: :failed, reason: code}
  defp classify_run(%Run{status: status}), do: %{kind: :queued, reason: status}
  defp classify_run(nil), do: %{kind: :failed, reason: :missing_run}

  defp print_completion(report, denominator, skipped) do
    counts = Enum.frequencies_by(report, & &1.kind)

    Mix.shell().info("Completion report (#{denominator} target-provider requests):")

    for kind <- [
          :fresh_cache_nonempty,
          :fresh_cache_empty,
          :succeeded_nonempty,
          :succeeded_empty,
          :failed,
          :queued,
          :deferred
        ] do
      Mix.shell().info("  #{kind}: #{Map.get(counts, kind, 0)}/#{denominator}")
    end

    Mix.shell().info("  unsupported_or_disabled_provider_skips: #{length(skipped)}")

    report
    |> Enum.filter(&(&1.kind in [:failed, :queued, :deferred]))
    |> Enum.take(discovery_config()[:report_sample])
    |> Enum.each(fn item ->
      Mix.shell().info(
        "  sample #{item.kind}: target #{item.target.object_id} #{item.target.term}, " <>
          "provider #{item.provider}, reason #{item[:reason]}"
      )
    end)
  end

  defp print_checkpoint([]), do: :ok

  defp print_checkpoint(targets) do
    last = List.last(targets)
    Mix.shell().info("Resume after this batch with --after #{last.object_id}.")
  end

  defp present?(value), do: is_binary(value) and String.trim(value) != ""
  defp discovery_config, do: Application.fetch_env!(:devils_dictionary, :discovery)
end
