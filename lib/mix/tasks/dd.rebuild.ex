defmodule Mix.Tasks.Dd.Rebuild do
  @shortdoc "Rebuild the whole corpus from the archived inputs, in order"

  @moduledoc """
  #74's milestone 5: *"Run full re-import of the six existing sources with
  resumability and explicit unresolved/error reporting."*

      mix dd.rebuild                       # everything, in order
      mix dd.rebuild --from wiktionary     # resume at a stage
      mix dd.rebuild --only wordnet,bierce # just these
      mix dd.rebuild --scope culture       # the bounded pilot
      mix dd.rebuild --dry-run             # print the plan and the inputs

  ## The order, and why it is this order

  Each stage needs what the one before it wrote, and nothing else:

  | # | stage | needs | writes |
  |---|---|---|---|
  | 1 | `manifest` | the archives | nothing; **fails loudly on a bad digest** |
  | 2 | `wordnet` | the zip | synsets, senses, the closed graph |
  | 3 | `wiktionary-index` | the 2.6 GB dump | the 1.5 M-row index and its forms |
  | 4 | `scope` | the index and WordNet | scope membership, with reasons |
  | 5 | `wiktionary` | the scope | scoped records, senses, relations |
  | 6 | `bierce` | the HTML | definitions, credited and dated |
  | 7 | `johnson` | the TEI-XML | the same, plus quotations |
  | 8 | `wikidata` | the sense QIDs | entities and the taxonomy |
  | 9 | `wikipedia` | the scope and the entities | articles and candidates |
  | 10 | `resolve` | everything above | pending edges become assertions |
  | 11 | `link` | senses and entities | the word ↔ thing ladder |
  | 12 | `wikidata-taxon` | Wikipedia's entities | the P31/P279 edges whose target arrived late |
  | 13 | `scope` again | the taxonomy | the `wikidata_taxon` rule, now able to run |
  | 14 | `wiktionary-taxon` | the grown scope | senses for the words the taxonomy added |
  | 15 | `resolve-taxon` | those senses | their edges become assertions |
  | 16 | `link-taxon` | all of it | the ladder over the whole scope |

  ## The second sweep, and why five stages run twice

  Nothing here is a retry. Each of these stages can only do its work once a
  *later* stage has run, and the pipeline is a straight line, so the line has to
  come back round.

  **The scope grows.** Its third rule walks the Wikidata taxonomy, which does not
  exist on the first pass — so the first build is what gives Wiktionary and
  Wikipedia something to scope *to*, and the second adds 8,724 lemmas to Animals
  that were not there when Wiktionary ran. Without a second sweep *pica*, *loris*
  and *calyptra* sit in the scope with no senses. MVP-0 found this the same way
  and closed it by hand ("Wiktionary re-absorbed on the grown scope"); here it is
  a stage, so a rebuild does not depend on anybody remembering.

  **The taxonomy grows too.** Wikidata records a P31 edge to whatever the source
  names — `Q24089999 instance_of Q34038`, *Slippery Falls* is a *Waterfall* — but
  P31 and P279 targets are recorded, not chased, so the edge waits for its target
  to exist. Wikipedia introduces 3,350 of those targets *after* Wikidata has
  finished. Re-materializing Wikidata closes them; without it the corpus is short
  exactly that many edges and nothing reports it.

  ## Resumability

  Every stage is idempotent — that is what M2 measures — so `--from` is a
  convenience rather than a repair: re-running a finished stage writes no
  revisions and costs the time of reading its input. What `--from` buys is not
  having to read the 2.6 GB dump again.

  Wikipedia and Wikidata read from `priv/replay/` when it is present, because
  their records exist **only** in a database: ~3 hours of batched API calls, and
  the reason `mix dd.export.replay` exists. `--live` forces the network instead.

  ## What it reports

  Per stage: what it wrote, what it could not resolve, and what failed. #74 asks
  for "explicit unresolved/error reporting", so an unresolved edge and a failed
  fetch are printed as numbers rather than folded into a success.
  """

  use Mix.Task

  import Mix.Tasks.Dd.Report

  alias DevilsDictionary.Absorb.{Batch, Linker, Resolver, ScopeBuilder}
  alias DevilsDictionary.{Lexicon, Sources}

  @requirements ["app.start"]

  @stages [
    {:manifest, "verify the archived inputs"},
    {:wordnet, "WordNet: synsets, senses, the closed graph"},
    {:"wiktionary-index", "Wiktionary: the full English index"},
    {:scope, "build the scope from the index and WordNet"},
    {:wiktionary, "Wiktionary: the scoped records"},
    {:bierce, "Bierce: 997 definitions"},
    {:johnson, "Johnson: the 1755 dictionary"},
    {:wikidata, "Wikidata: entities and the taxonomy"},
    {:wikipedia, "Wikipedia: articles and candidates"},
    {:resolve, "drain pending edges into assertions"},
    {:link, "the word ↔ thing ladder"},
    {:"wikidata-taxon", "close the taxonomy edges Wikipedia's entities unlocked"},
    {:"scope-taxon", "rebuild the scope, now that the taxonomy exists"},
    {:"wiktionary-taxon", "Wiktionary: the words the taxonomy added"},
    {:"resolve-taxon", "drain the edges those words brought"},
    {:"link-taxon", "the ladder, over the grown scope"}
  ]

  @impl Mix.Task
  def run(args) do
    {opts, _, _} =
      OptionParser.parse(args,
        strict: [
          from: :string,
          only: :string,
          scope: :string,
          limit: :integer,
          dry_run: :boolean,
          live: :boolean
        ]
      )

    scope = opts[:scope] || "animals"
    plan = plan(opts)

    say("rebuild · scope #{scope} · #{length(plan)} stages")
    say("")

    if opts[:dry_run] do
      for {stage, what} <- plan, do: row(to_string(stage), what)
      say("")
      say("  --dry-run: nothing was written.")
    else
      started = System.monotonic_time(:millisecond)
      results = Enum.map(plan, &run_stage(&1, scope, opts))
      report(results, System.monotonic_time(:millisecond) - started)
    end
  end

  defp plan(opts) do
    stages =
      case opts[:only] do
        nil -> @stages
        list -> Enum.filter(@stages, fn {stage, _} -> to_string(stage) in split(list) end)
      end

    case opts[:from] do
      nil -> stages
      from -> Enum.drop_while(stages, fn {stage, _} -> to_string(stage) != from end)
    end
  end

  defp split(list), do: list |> String.split(",", trim: true) |> Enum.map(&String.trim/1)

  defp run_stage({stage, what}, scope, opts) do
    say("── #{stage} · #{what}")
    started = System.monotonic_time(:millisecond)

    result =
      try do
        {:ok, do_stage(stage, scope, opts)}
      rescue
        error -> {:error, Exception.message(error)}
      catch
        :exit, reason -> {:error, inspect(reason)}
      end

    elapsed = System.monotonic_time(:millisecond) - started

    case result do
      {:ok, stats} ->
        for {key, value} <- summarise(stats), do: row(to_string(key), value)
        row("elapsed", duration(elapsed))

      {:error, message} ->
        row("FAILED", message)
    end

    say("")
    {stage, result, elapsed}
  end

  # ── the stages ────────────────────────────────────────────────────────────

  defp do_stage(:manifest, _scope, _opts) do
    case DevilsDictionary.Sources.Manifest.verify() do
      {:ok, results} ->
        %{verified: length(results)}

      {:error, results} ->
        bad = Enum.reject(results, &(&1.status == :ok))

        # Loudly, and before anything is written: #74 requires the checksum be
        # verified before import and that a mismatch fail clearly. A rebuild
        # from bytes nobody pinned is not a rebuild.
        raise "input verification failed: " <>
                Enum.map_join(bad, "; ", &"#{&1.source} #{&1.status} (#{&1.detail})")
    end
  end

  defp do_stage(:wordnet, _scope, opts), do: absorb("wordnet", [], opts)

  defp do_stage(:"wiktionary-index", _scope, opts),
    do: absorb("wiktionary", [index: true, rebuild_indexes: true], opts)

  defp do_stage(:scope, scope, _opts), do: build_scope(scope)
  defp do_stage(:"scope-taxon", scope, _opts), do: build_scope(scope)

  defp do_stage(:wiktionary, scope, opts), do: absorb("wiktionary", [scope: scope], opts)

  defp do_stage(:"wiktionary-taxon", scope, opts),
    do: absorb("wiktionary", [scope: scope], opts)

  defp do_stage(:bierce, _scope, opts), do: absorb("bierce", [], opts)
  defp do_stage(:johnson, _scope, opts), do: absorb("johnson", [], opts)
  defp do_stage(:wikidata, scope, opts), do: replay_or_absorb("wikidata", [scope: scope], opts)

  defp do_stage(:wikipedia, scope, opts),
    do: replay_or_absorb("wikipedia", [scope: scope], opts)

  # Wikidata's P171 walk chases parents; P31 and P279 are *recorded* rather than
  # chased, so an edge to an entity Wikipedia had not introduced yet was counted
  # as unresolved and left there. Re-materializing after Wikipedia closes them —
  # no fetching, no network, just the records already on disk read again.
  defp do_stage(:"wikidata-taxon", _scope, _opts) do
    source = Sources.get_source_by_slug!("wikidata")
    module = DevilsDictionary.Absorb.source_module!("wikidata")
    run = Sources.start_run("materialize", source_id: source.id)

    counts = Batch.run(module, source, only_stale: false, run_id: run.id)
    Sources.finish_run(run, stringify(counts))

    Map.take(counts, [
      :concept_relations,
      :concept_relations_skipped,
      :concept_relations_skipped_parent_taxon,
      :concept_relations_skipped_unchased
    ])
  end

  defp do_stage(:"resolve-taxon", scope, opts), do: do_stage(:resolve, scope, opts)
  defp do_stage(:"link-taxon", scope, opts), do: do_stage(:link, scope, opts)

  defp do_stage(:resolve, _scope, _opts) do
    result = Resolver.run()

    %{
      resolved: result.resolved,
      canonical: result.canonical,
      still_unresolved: unresolved_total(result.by_type)
    }
  end

  defp do_stage(:link, scope, _opts) do
    scope = Lexicon.get_scope_by_slug(scope)
    %{rungs: rungs, corroboration: corroboration} = Linker.run(scope)

    Map.merge(rungs, corroboration)
  end

  defp build_scope(slug) do
    case Lexicon.get_scope_by_slug(slug) do
      nil -> %{skipped: "no scope #{slug}"}
      scope -> ScopeBuilder.build(scope, reset: true) |> Map.take([:total, :without_reason])
    end
  end

  # `absorb/2`'s first argument is the **scope**, not the source — a source
  # module looks its own source up. Passing a `%Source{}` there matched no
  # clause in Wiktionary or Wikipedia, the two that pattern-match on it, and the
  # first full rebuild lost both stages to it.
  defp absorb(slug, stage_opts, opts) do
    module = DevilsDictionary.Absorb.source_module!(slug)
    source = Sources.get_source_by_slug!(slug)
    scope = stage_opts[:scope] && Lexicon.get_scope_by_slug!(stage_opts[:scope])

    stage_opts =
      if opts[:limit], do: Keyword.put(stage_opts, :limit, opts[:limit]), else: stage_opts

    # One run per stage, and every output the stage writes carries its id, so
    # `Materializer.reconcile/2` can tell what a source stopped emitting from
    # what it never emitted.
    run = Sources.start_run("absorb", source_id: source.id, scope_id: scope && scope.id)
    stage_opts = Keyword.put(stage_opts, :run_id, run.id)

    try do
      case module.absorb(scope, stage_opts) do
        {:ok, stats} ->
          Sources.finish_run(run, stringify(stats))
          stats

        {:error, reason} ->
          raise "absorb failed: #{inspect(reason)}"
      end
    rescue
      error ->
        Sources.finish_run(run, %{"error" => Exception.message(error)})
        reraise error, __STACKTRACE__
    end
  end

  # Wikipedia's 85,044 and Wikidata's 72,770 records exist **only** in a
  # database — about three hours of batched API calls — so a rebuild reads the
  # checksummed replay archive where one is present. That archive is those two
  # sources' equivalent of a pinned dump, which is exactly why
  # `mix dd.export.replay` was written before the old database was touched.
  defp replay_or_absorb(slug, stage_opts, opts) do
    archive = Path.join("priv/replay", "#{slug}.jsonl.gz")

    if opts[:live] || not File.exists?(archive) do
      absorb(slug, stage_opts, opts)
    else
      # `Mix.Task.run/2` runs a task **once per session** and returns `:noop`
      # after that, so the second replay stage of a rebuild silently did nothing
      # — Wikipedia's 85,044 records were reported as replayed in 0 ms and were
      # not in the database.
      Mix.Task.rerun("dd.replay", ["--source", slug, "--quiet"])
      %{replayed: archive}
    end
  end

  defp unresolved_total(by_type) do
    by_type |> Map.values() |> Enum.map(& &1.unresolved) |> Enum.sum()
  end

  # ── reporting ─────────────────────────────────────────────────────────────

  defp summarise(stats) when is_map(stats) do
    stats
    |> Enum.reject(fn {_k, v} -> is_list(v) or is_map(v) end)
    |> Enum.sort_by(&elem(&1, 0))
  end

  defp summarise(other), do: [{"result", inspect(other)}]

  defp report(results, elapsed) do
    failed = Enum.filter(results, fn {_s, r, _e} -> match?({:error, _}, r) end)

    say("── rebuild")
    row("stages", length(results))
    row("failed", length(failed))
    row("elapsed", duration(elapsed))

    if failed != [] do
      say("")

      for {stage, {:error, message}, _} <- failed do
        say("  #{stage}: #{message}")
      end

      # A rebuild that failed a stage is not a rebuild, and the exit status is
      # what a script reads.
      exit({:shutdown, 1})
    end
  end

  defp duration(ms) when ms < 1_000, do: "#{ms} ms"
  defp duration(ms) when ms < 60_000, do: "#{Float.round(ms / 1_000, 1)} s"

  defp duration(ms) do
    minutes = div(ms, 60_000)
    seconds = rem(div(ms, 1_000), 60)
    "#{minutes}m #{seconds}s"
  end
end
