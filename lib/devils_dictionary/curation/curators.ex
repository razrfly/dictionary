defmodule DevilsDictionary.Curation.Curators do
  @moduledoc """
  The public curator pages (#299, #203's profile pages): one read-only
  projection per curator profile, and the directory of them.

  **A projection, never a store.** Everything here is read from records
  that already exist: the profile and its immutable versions
  (`curator_profiles`, `curator_profile_versions`), every configuration
  version that bound it and the activation receipts that dated each binding,
  the model configs, the bot actors and their sources, the inference
  attempts and their ledger, and the composition versions and publications
  the bots wrote. Counts are computed on each read, never kept.

  **Keyed by every binding the profile ever had.** A binding is one bot
  actor and one model config, named together by a configuration version's
  `manifest["editor"]` (#264 R1.1). A profile's attempts are those of its
  bindings' model configs, or requested by its bot actors; its composition
  versions are those its bot actors created; its publications are those of
  those versions.

  **What a public page never carries** (#299 M5): an attempt's `result` or
  `packet_summary` (neither is selected), prompt text, provider payloads,
  item reasons, a human actor's label, or a dossier passage whose source's
  rights note does not permit it. Withheld choices are counted by reason,
  never quoted.

  **Nothing here writes or calls out.** No discovery, no refresh, no model
  call: the page reads, and an old receipt's version stays the version it
  used.
  """

  import Ecto.Query

  alias DevilsDictionary.Curation.{
    Composition,
    CompositionItem,
    CompositionMembership,
    CompositionPublication,
    CompositionVersion,
    Configuration,
    ConfigurationActivation,
    ConfigurationVersion,
    Digest,
    Profile,
    ProfileVersion,
    Published,
    ShelfCitations
  }

  alias DevilsDictionary.Curation.Runtime.{Attempt, LedgerEntry, ModelConfig, Packet}
  alias DevilsDictionary.Registry.{Entity, ExternalIdentifier, Lexeme}
  alias DevilsDictionary.Repo
  alias DevilsDictionary.Routing.Links
  alias DevilsDictionary.Sources.{Actor, Source}

  # The reviewed instruction summaries (#299 M3): one short public text per
  # pinned instruction, never the instruction itself.
  @instructions_dir Path.expand("../../../priv/curation/agents/instructions", __DIR__)
  @summary_paths Path.wildcard(Path.join(@instructions_dir, "*.md"))
  for path <- @summary_paths, do: @external_resource(path)
  @summaries Map.new(@summary_paths, &{Path.basename(&1, ".md"), File.read!(&1)})

  # The dated developer judgments recorded in the repository (#299 §3.7).
  @judgments_path Path.expand("../../../priv/curation/agents/judgments.json", __DIR__)
  @external_resource @judgments_path
  @judgments @judgments_path |> File.read!() |> Jason.decode!()

  # Each profile's subject, by its Wikidata identity (#299 M6, CD-4). The
  # link appears when an entity carries that verified identifier, as
  # Bierce's does; nothing is matched by name.
  @subjects %{
    "bierce" => "Q191050",
    "voltaire" => "Q9068",
    "vonnegut" => "Q49074",
    "hitchens" => "Q49081",
    "le-guin" => "Q181659"
  }

  @request_key ~r/\Aproposal:(\d+):(\d+):\d+\z/

  # ── the directory ─────────────────────────────────────────────────────────

  @doc """
  Every profile, as a card: identity, state, current version and binding,
  and the computed totals. Admitted profiles first, then proposed, then
  retired; each group by id.
  """
  def directory(mode \\ :public) do
    Profile
    |> order_by(:id)
    |> Repo.all()
    |> Enum.map(fn profile ->
      page = assemble(profile, nil, mode, light: true)

      %{
        profile: profile,
        current_version: page.version,
        binding: page.current_binding || List.first(page.bindings),
        live?: not is_nil(page.current_binding),
        totals: page.totals
      }
    end)
    |> Enum.sort_by(&{state_order(&1.profile.state), &1.profile.id})
  end

  defp state_order(:admitted), do: 0
  defp state_order(:proposed), do: 1
  defp state_order(:retired), do: 2

  # ── one profile ───────────────────────────────────────────────────────────

  @doc """
  The page of the profile `slug`, at its current version or, with
  `version: n`, at version `n`: `{:ok, page}` or `{:error, :not_found}`.
  `mode` is the reading mode the subject link is resolved in.
  """
  def page(slug, opts \\ []) when is_binary(slug) do
    mode = Keyword.get(opts, :mode, :public)

    with %Profile{} = profile <- Repo.get_by(Profile, slug: slug),
         {:ok, number} <- version_number(Keyword.get(opts, :version)) do
      case assemble(profile, number, mode) do
        %{version: nil} when is_integer(number) -> {:error, :not_found}
        page -> {:ok, page}
      end
    else
      _ -> {:error, :not_found}
    end
  end

  defp version_number(nil), do: {:ok, nil}
  defp version_number(n) when is_integer(n) and n > 0, do: {:ok, n}
  defp version_number(_), do: :error

  # `light: true` (the directory) skips what only the page shows: the
  # current withheld state and expiry, which revalidate each placed choice.
  defp assemble(profile, number, mode, opts \\ []) do
    light? = Keyword.get(opts, :light, false)

    versions =
      Repo.all(from v in ProfileVersion, where: v.profile_id == ^profile.id, order_by: v.version)

    shown =
      if number,
        do: Enum.find(versions, &(&1.version == number)),
        else: current_version(profile, versions)

    bindings = bindings(profile)
    actor_ids = Enum.map(bindings, & &1.bot_actor.id)

    config_ids =
      bindings |> Enum.map(& &1.model_config) |> Enum.reject(&is_nil/1) |> Enum.map(& &1.id)

    attempts = attempts(config_ids, actor_ids)
    composition_versions = composition_versions(actor_ids, Enum.map(attempts, & &1.id))
    version_ids = Enum.map(composition_versions, & &1.id)
    publications = publications(version_ids)
    published_ids = for p <- publications, p.action == :publish, do: p.published_version_id
    items = items(published_ids)
    compositions = compositions(composition_versions, attempts)
    slugs = page_slugs(Map.keys(compositions))
    charges = charges(Enum.map(attempts, & &1.id))
    withheld = if light?, do: %{}, else: withheld_now(compositions, version_ids)
    by_actor = Map.new(bindings, &{&1.bot_actor.id, &1})
    by_config = for b <- bindings, b.model_config, into: %{}, do: {b.model_config.id, b}

    ctx = %{
      attempts: attempts,
      versions: composition_versions,
      publications: publications,
      items: items,
      charges: charges,
      withheld: withheld,
      light?: light?,
      by_actor: by_actor,
      by_config: by_config
    }

    bindings = Enum.map(bindings, &Map.put(&1, :totals, totals(&1, ctx)))

    %{
      profile: profile,
      versions:
        Enum.map(versions, &version_row(&1, bindings, composition_versions, publications, slugs)),
      version: shown,
      latest_version: List.last(versions),
      current_version_id: profile.current_version_id,
      admission: admission(profile),
      dossier: dossier(shown),
      instruction: instruction(shown),
      bindings: bindings,
      current_binding: Enum.find(bindings, & &1.live?),
      activity: activity(ctx, slugs, compositions),
      holds: holds(compositions, slugs),
      totals: overall(bindings, ctx),
      judgments: judgments(profile),
      subject: subject(profile, shown, mode),
      used_by: shown && used_by(shown, bindings, composition_versions, publications, slugs)
    }
  end

  # The version a profile's page shows by default: its admitted (or newest
  # proposed) version, as the profile row points to it.
  defp current_version(%Profile{current_version_id: nil}, _versions), do: nil

  defp current_version(%Profile{current_version_id: id}, versions),
    do: Enum.find(versions, &(&1.id == id))

  # ── bindings ──────────────────────────────────────────────────────────────

  @doc """
  The profile's bindings, oldest first: each bot actor with its model config,
  the configuration versions that bound them, the profile versions those
  name, and when each was active (from the activation receipts).
  """
  def bindings(%Profile{} = profile) do
    bound =
      Repo.all(
        from v in ConfigurationVersion,
          where: fragment("(?->'editor'->>'profile_id')::bigint", v.manifest) == ^profile.id,
          order_by: v.id
      )

    periods = periods(Enum.uniq(Enum.map(bound, & &1.configuration_id)))

    groups =
      bound
      |> Enum.group_by(
        &{&1.manifest["editor"]["bot_actor_id"], &1.manifest["editor"]["model_config_id"]}
      )
      |> Enum.sort_by(fn {_key, [first | _]} -> first.id end)

    from_manifests =
      for {{actor_id, config_id}, cvs} <- groups, actor <- [Repo.get(Actor, actor_id)], actor do
        binding(actor, Repo.get(ModelConfig, config_id), cvs, periods)
      end

    bound_actor_ids = Enum.map(from_manifests, & &1.bot_actor.id)

    unbound =
      case profile.bot_actor_id do
        nil ->
          []

        id ->
          if id in bound_actor_ids,
            do: [],
            else:
              Enum.reject([Repo.get(Actor, id)], &is_nil/1)
              |> Enum.map(&binding(&1, nil, [], %{}))
      end

    from_manifests ++ unbound
  end

  defp binding(actor, config, cvs, periods) do
    windows = Enum.flat_map(cvs, &Map.get(periods, &1.id, []))
    source = actor.bot_source_id && Repo.get(Source, actor.bot_source_id)
    live? = Enum.any?(windows, &is_nil(&1.until)) and live?(cvs)

    %{
      anchor: "binding-#{actor.id}",
      bot_actor: actor,
      source_slug: source && source.slug,
      model_config: config,
      configuration_versions: cvs,
      profile_version_ids:
        cvs |> Enum.map(& &1.manifest["editor"]["profile_version_id"]) |> Enum.uniq(),
      windows: Enum.sort_by(windows, & &1.from, DateTime),
      live?: live?
    }
    |> then(fn b -> Map.put(b, :editor_on?, b.live? and Enum.any?(cvs, &editor_on?/1)) end)
  end

  # Whether a binding's configuration version is the enabled configuration's
  # current one.
  defp live?(cvs) do
    Enum.any?(cvs, fn cv ->
      Repo.exists?(
        from c in Configuration,
          where:
            c.id == ^cv.configuration_id and c.state == :enabled and
              c.current_version_id == ^cv.id
      )
    end)
  end

  defp editor_on?(cv) do
    match?({:ok, _}, DevilsDictionary.Curation.Configurations.editor_enabled(cv.id))
  end

  # Each configuration version's active windows: from an activation of it
  # to the next activation or disablement of its configuration.
  defp periods([]), do: %{}

  defp periods(configuration_ids) do
    Repo.all(
      from a in ConfigurationActivation,
        where: a.configuration_id in ^configuration_ids,
        order_by: [a.configuration_id, a.committed_at, a.id]
    )
    |> Enum.chunk_by(& &1.configuration_id)
    |> Enum.flat_map(fn receipts ->
      receipts
      |> Enum.zip(tl(receipts) ++ [nil])
      |> Enum.filter(fn {a, _next} -> a.action == :activate end)
      |> Enum.map(fn {a, next} ->
        {a.configuration_version_id,
         %{
           from: a.committed_at,
           until: next && next.committed_at,
           reason: a.reason,
           actor_id: a.actor_id
         }}
      end)
    end)
    |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
  end

  # ── what it did ───────────────────────────────────────────────────────────

  # Never `result` or `packet_summary`: what a page may say about an attempt
  # is its identity, outcome, contract check codes, timing and metrics.
  defp attempts([], []), do: []

  defp attempts(config_ids, actor_ids) do
    Repo.all(
      from a in Attempt,
        where: a.model_config_id in ^config_ids or a.requested_by_actor_id in ^actor_ids,
        order_by: [desc: a.id],
        select: %{
          id: a.id,
          model_config_id: a.model_config_id,
          requested_by_actor_id: a.requested_by_actor_id,
          purpose: a.purpose,
          state: a.state,
          outcome: a.outcome,
          refusal_reasons: a.refusal_reasons,
          metrics: a.metrics,
          request_key: a.request_key,
          admitted_at: a.admitted_at,
          finished_at: a.finished_at
        }
    )
  end

  defp composition_versions([], []), do: []

  defp composition_versions(actor_ids, attempt_ids) do
    Repo.all(
      from v in CompositionVersion,
        where:
          v.origin == :model and
            (v.created_by_actor_id in ^actor_ids or v.attempt_id in ^attempt_ids),
        order_by: v.id,
        select: %{
          id: v.id,
          composition_id: v.composition_id,
          configuration_version_id: v.configuration_version_id,
          version: v.version,
          attempt_id: v.attempt_id,
          created_by_actor_id: v.created_by_actor_id,
          inserted_at: v.inserted_at
        }
    )
  end

  defp publications([]), do: []

  defp publications(version_ids) do
    Repo.all(
      from p in CompositionPublication,
        where: p.published_version_id in ^version_ids or p.previous_version_id in ^version_ids,
        order_by: [p.committed_at, p.id]
    )
    |> Enum.filter(fn p ->
      (p.action == :publish and p.published_version_id in version_ids) or
        (p.action == :withdraw and p.previous_version_id in version_ids)
    end)
  end

  defp items([]), do: []

  defp items(version_ids) do
    Repo.all(
      from i in CompositionItem,
        where: i.composition_version_id in ^version_ids,
        select: %{
          id: i.id,
          composition_version_id: i.composition_version_id,
          shelf_citation_id: i.shelf_citation_id
        }
    )
  end

  # The compositions a profile touched: by a version it wrote, or by the
  # composition id its attempt's request key names.
  defp compositions(versions, attempts) do
    ids =
      Enum.map(versions, & &1.composition_id) ++
        Enum.flat_map(attempts, &List.wrap(request_composition(&1.request_key)))

    case Enum.uniq(ids) do
      [] -> %{}
      ids -> Repo.all(from c in Composition, where: c.id in ^ids) |> Map.new(&{&1.id, &1})
    end
  end

  defp request_composition(key) when is_binary(key) do
    case Regex.run(@request_key, key) do
      [_, composition, _cv] -> String.to_integer(composition)
      _ -> nil
    end
  end

  defp request_composition(_key), do: nil

  # A composition's page, by its first member word's slug (as
  # `Proposals.page_slug/1`), for many at once.
  defp page_slugs([]), do: %{}

  defp page_slugs(ids) do
    Repo.all(
      from m in CompositionMembership,
        join: l in Lexeme,
        on: l.object_id == m.object_id,
        where: m.composition_id in ^ids,
        order_by: [m.composition_id, l.object_id],
        select: {m.composition_id, l.slug}
    )
    |> Enum.reduce(%{}, fn {id, slug}, acc -> Map.put_new(acc, id, slug) end)
  end

  defp charges([]), do: %{}

  defp charges(attempt_ids) do
    Repo.all(
      from l in LedgerEntry,
        where: l.attempt_id in ^attempt_ids and l.kind == :charge,
        group_by: l.attempt_id,
        select: {l.attempt_id, sum(l.amount_ms)}
    )
    |> Map.new()
  end

  # Of the compositions whose current published version this profile wrote,
  # what the reader is not shown now, counted by reason. `Published.current/1`
  # is the word page's own read: it withholds and never substitutes.
  defp withheld_now(compositions, version_ids) do
    for {id, %{current_published_version_id: v}} <- compositions, v in version_ids, into: %{} do
      reasons =
        case Published.current(id) do
          {:ok, %{withheld: withheld}} -> Enum.map(withheld, & &1.reason)
          {:withheld, reasons} -> [{:publication_withheld, reasons}]
          _ -> []
        end

      {v, reasons}
    end
  end

  # The binding an attempt ran under, by its bot actor's id: its model
  # config's binding, or the bot that requested it.
  defp binding_of(ctx, attempt) do
    case Map.get(ctx.by_config, attempt.model_config_id) do
      %{bot_actor: %{id: id}} ->
        id

      nil ->
        if Map.has_key?(ctx.by_actor, attempt.requested_by_actor_id),
          do: attempt.requested_by_actor_id
    end
  end

  defp totals(binding, ctx) do
    id = binding.bot_actor.id
    attempts = Enum.filter(ctx.attempts, &(binding_of(ctx, &1) == id))
    tally(attempts, Enum.filter(ctx.versions, &(&1.created_by_actor_id == id)), ctx)
  end

  defp overall(bindings, ctx) do
    actor_ids = Enum.map(bindings, & &1.bot_actor.id)
    tally(ctx.attempts, Enum.filter(ctx.versions, &(&1.created_by_actor_id in actor_ids)), ctx)
  end

  defp tally(attempts, versions, ctx) do
    version_ids = MapSet.new(versions, & &1.id)

    published =
      Enum.filter(
        ctx.publications,
        &(&1.action == :publish and &1.published_version_id in version_ids)
      )

    published_ids = MapSet.new(published, & &1.published_version_id)
    placed = Enum.filter(ctx.items, &(&1.composition_version_id in published_ids))
    metrics = Enum.map(attempts, & &1.metrics)

    %{
      calls: length(attempts),
      requests: Enum.count(attempts, &(&1.purpose == :request)),
      readiness_checks: Enum.count(attempts, &(&1.purpose == :readiness_smoke)),
      benchmarks: Enum.count(attempts, &(&1.purpose == :benchmark)),
      accepted: Enum.count(attempts, &(&1.outcome == :accepted)),
      abstained: Enum.count(attempts, &(&1.outcome == :abstained)),
      refused: Enum.count(attempts, &(&1.outcome == :refused)),
      other: Enum.count(attempts, &(&1.outcome not in [:accepted, :abstained, :refused])),
      versions: MapSet.size(version_ids),
      publications: length(published),
      pages: published |> Enum.map(& &1.composition_id) |> Enum.uniq() |> length(),
      withdrawals:
        Enum.count(
          ctx.publications,
          &(&1.action == :withdraw and &1.previous_version_id in version_ids)
        ),
      placed: length(placed),
      expired: if(ctx.light?, do: nil, else: Enum.count(placed, &expired?/1)),
      withheld_now:
        ctx.withheld
        |> Enum.filter(fn {v, _} -> v in version_ids end)
        |> Enum.flat_map(&elem(&1, 1))
        |> Enum.frequencies(),
      wall_ms: sum(metrics, "wall_ms"),
      prompt_tokens: sum(metrics, "prompt_eval_count"),
      output_tokens: sum(metrics, "eval_count"),
      charged_ms: attempts |> Enum.map(&Map.get(ctx.charges, &1.id, 0)) |> Enum.sum(),
      lowest_free_percent: metrics |> Enum.flat_map(&free_percents/1) |> Enum.min(fn -> nil end),
      most_swap_bytes: metrics |> Enum.flat_map(&swap_bytes/1) |> Enum.max(fn -> nil end)
    }
  end

  # A placed choice whose cited observation's retention has passed: the
  # reader no longer sees it, and its payload is due to be redacted.
  defp expired?(%{shelf_citation_id: nil}), do: false

  defp expired?(%{shelf_citation_id: id}) do
    case ShelfCitations.get(id) do
      nil -> false
      citation -> ShelfCitations.check(citation) == :retention_expired
    end
  end

  defp sum(metrics, key) do
    metrics
    |> Enum.map(&Map.get(&1 || %{}, key))
    |> Enum.filter(&is_integer/1)
    |> Enum.sum()
  end

  defp free_percents(metrics) do
    for k <- ["memory_before", "memory_after"],
        %{"free_percent" => p} <- [Map.get(metrics || %{}, k)],
        is_number(p),
        do: p
  end

  defp swap_bytes(metrics) do
    for k <- ["memory_before", "memory_after"],
        %{"swap_used_bytes" => b} <- [Map.get(metrics || %{}, k)],
        is_integer(b),
        do: b
  end

  # Newest first: each attempt, as what it led to, and each withdrawal.
  defp activity(ctx, slugs, compositions) do
    by_attempt = Map.new(ctx.versions, &{&1.attempt_id, &1})

    published =
      for p <- ctx.publications, p.action == :publish, into: %{}, do: {p.published_version_id, p}

    attempts =
      Enum.map(ctx.attempts, fn a ->
        version = Map.get(by_attempt, a.id)
        publication = version && Map.get(published, version.id)

        composition_id =
          (version && version.composition_id) || request_composition(a.request_key)

        %{
          kind: :attempt,
          at: a.finished_at || a.admitted_at,
          attempt_id: a.id,
          purpose: a.purpose,
          outcome: a.outcome,
          state: a.state,
          refusal_codes: refusal_codes(a.refusal_reasons),
          binding_id: binding_of(ctx, a),
          page: composition_id && Map.get(slugs, composition_id),
          held?: match?(%{mode: :mine}, composition_id && Map.get(compositions, composition_id)),
          version: version && version.version,
          published?: not is_nil(publication),
          published_at: publication && publication.committed_at
        }
      end)

    versions = Map.new(ctx.versions, &{&1.id, &1})

    withdrawals =
      for p <- ctx.publications, p.action == :withdraw do
        version = Map.get(versions, p.previous_version_id)

        %{
          kind: :withdrawal,
          at: p.committed_at,
          page: Map.get(slugs, p.composition_id),
          version: version && version.version,
          reason: p.reason
        }
      end

    Enum.sort_by(attempts ++ withdrawals, & &1.at, {:desc, DateTime})
  end

  defp refusal_codes(reasons) when is_list(reasons) do
    reasons
    |> Enum.map(fn
      [_where, code] when is_binary(code) -> code
      code when is_binary(code) -> code
      _ -> nil
    end)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  defp refusal_codes(_reasons), do: []

  # The owner's holds on pages this profile touched, as the composition rows
  # hold them now. Their history is not recorded.
  defp holds(compositions, slugs) do
    for {id, %{mode: :mine} = c} <- compositions do
      %{page: Map.get(slugs, id), since: c.mode_set_at}
    end
    |> Enum.sort_by(& &1.page)
  end

  # ── versions ──────────────────────────────────────────────────────────────

  defp version_row(version, bindings, composition_versions, publications, slugs) do
    used = used_by(version, bindings, composition_versions, publications, slugs)

    %{
      version: version,
      created_by: actor_role(version.created_by_actor_id),
      bindings: used.bindings,
      first_active:
        used.bindings
        |> Enum.flat_map(& &1.windows)
        |> Enum.map(& &1.from)
        |> Enum.min(DateTime, fn -> nil end),
      pages: used.published |> Enum.map(& &1.page) |> Enum.uniq() |> length(),
      publications: length(used.published)
    }
  end

  defp used_by(version, bindings, composition_versions, publications, slugs) do
    used = Enum.filter(bindings, &(version.id in &1.profile_version_ids))

    cv_ids =
      for b <- used,
          cv <- b.configuration_versions,
          cv.manifest["editor"]["profile_version_id"] == version.id,
          do: cv.id

    published =
      for p <- publications, p.action == :publish, into: %{}, do: {p.published_version_id, p}

    rows =
      for v <- composition_versions,
          v.configuration_version_id in cv_ids,
          p <- [Map.get(published, v.id)],
          p do
        %{
          page: Map.get(slugs, v.composition_id),
          version: v.version,
          at: p.committed_at,
          attempt_id: v.attempt_id
        }
      end

    %{bindings: used, published: Enum.sort_by(rows, & &1.at, {:desc, DateTime})}
  end

  defp admission(%Profile{state: :admitted} = p) do
    %{at: p.admitted_at, by: actor_role(p.admitted_by_actor_id), reason: p.admission_reason}
  end

  defp admission(_profile), do: nil

  # A human actor is named by role and id, never by label: a label can be
  # an account's name. A bot is its label, the binding's public name.
  defp actor_role(nil), do: nil

  defp actor_role(id) do
    case Repo.get(Actor, id) do
      %Actor{actor_kind: :bot, label: label} -> %{kind: :bot, id: id, label: label}
      %Actor{actor_kind: :user} -> %{kind: :reviewer, id: id, label: nil}
      %Actor{actor_kind: kind} -> %{kind: kind, id: id, label: nil}
      nil -> nil
    end
  end

  # ── what we gave it ───────────────────────────────────────────────────────

  @dossier_keys ~w(disclosure selection principles blind_spots positive_example negative_example)

  defp dossier(nil), do: nil

  defp dossier(%ProfileVersion{} = v) do
    %{
      fields: Map.new(@dossier_keys, &{&1, Map.get(v.dossier || %{}, &1)}),
      other_keys: (v.dossier || %{}) |> Map.keys() |> Kernel.--(@dossier_keys) |> Enum.sort(),
      sources: Enum.map(List.wrap(v.source_refs), &source_ref/1),
      deceased_evidence: Enum.map(List.wrap(v.deceased_evidence_refs), &deceased_ref/1),
      empty?: v.dossier in [nil, %{}] and v.source_refs in [nil, []]
    }
  end

  defp source_ref(%{} = ref) do
    passages = List.wrap(ref["passages"])
    permitted? = passages_permitted?(ref["rights"])

    %{
      work: ref["work"],
      edition: ref["edition"],
      url: public_url(ref["url"]),
      locators: List.wrap(ref["locators"]),
      rights: ref["rights"],
      basis: ref["basis"],
      passages:
        if(permitted?,
          do: Enum.map(passages, &Map.take(&1, ["locator", "speaker", "text"])),
          else: Enum.map(passages, &Map.take(&1, ["locator", "speaker"]))
        ),
      passages_shown?: permitted?
    }
  end

  defp source_ref(_ref),
    do: %{
      work: nil,
      edition: nil,
      url: nil,
      locators: [],
      rights: nil,
      basis: nil,
      passages: [],
      passages_shown?: false
    }

  @doc """
  Whether a source reference's rights note permits showing its exact
  passages: it must say the work is in the public domain. Anything else
  shows the reference and the rights note only (#299 M5).
  """
  def passages_permitted?(rights) when is_binary(rights),
    do: String.match?(rights, ~r/\bpublic domain\b/i)

  def passages_permitted?(_rights), do: false

  defp deceased_ref(%{} = ref) do
    %{
      authority: ref["authority"],
      url: public_url(ref["url"]),
      field: ref["field"],
      value: ref["value"]
    }
  end

  defp deceased_ref(_ref), do: %{authority: nil, url: nil, field: nil, value: nil}

  defp public_url("https://" <> _ = url), do: url
  defp public_url(_url), do: nil

  # ── what it is told ──────────────────────────────────────────────────────

  @doc "The reviewed public summary of a pinned instruction, or `nil`."
  def summary(instruction_version), do: Map.get(@summaries, instruction_version)

  @doc "The instruction versions that have a reviewed summary."
  def summarized, do: @summaries |> Map.keys() |> Enum.sort()

  @doc """
  An instruction's identity: its version, the sha256 of its pinned text
  (the text itself is never shown) and its reviewed summary.
  """
  def instruction(nil), do: nil
  def instruction(%ProfileVersion{template_version: v}), do: instruction(v)

  def instruction(version) when is_binary(version) do
    sha =
      if version in Packet.instruction_versions(),
        do: Digest.sha256(Packet.instruction!(version))

    %{version: version, sha256: sha, summary: summary(version)}
  end

  # ── judged, and subject ──────────────────────────────────────────────────

  defp judgments(%Profile{slug: slug}) do
    @judgments
    |> Enum.filter(&(&1["profile"] == slug))
    |> Enum.sort_by(& &1["date"], :desc)
  end

  @doc "The Wikidata identity a profile's subject is linked by, or `nil`."
  def subject_identity(slug), do: Map.get(@subjects, slug)

  defp subject(profile, shown, mode) do
    entity =
      case subject_identity(profile.slug) do
        nil ->
          nil

        qid ->
          Repo.one(
            from x in ExternalIdentifier,
              join: e in Entity,
              on: e.object_id == x.object_id,
              where:
                x.namespace == "wikidata" and x.external_id == ^qid and x.status == :verified and
                  e.entity_kind == :person,
              order_by: e.object_id,
              limit: 1,
              select: %{object_id: e.object_id, label: e.preferred_label}
          )
      end

    %{
      label: profile.subject_label,
      wikidata: subject_identity(profile.slug),
      path: entity && Links.path(entity.object_id, entity.label || profile.subject_label, mode),
      deceased_evidence:
        if(shown,
          do: Enum.map(List.wrap(shown.deceased_evidence_refs), &deceased_ref/1),
          else: []
        )
    }
  end

  # ── links in ─────────────────────────────────────────────────────────────

  @doc """
  The curator page a bot source belongs to, anchored at its binding, or
  `nil` when the source is no curator's (#299 M1).
  """
  def source_path(%Source{kind: :bot, id: source_id}) do
    with %Actor{} = actor <- Repo.get_by(Actor, actor_kind: :bot, bot_source_id: source_id),
         %Profile{} = profile <- profile_of_bot(actor.id) do
      "/curators/#{profile.slug}#binding-#{actor.id}"
    else
      _ -> nil
    end
  end

  def source_path(_source), do: nil

  defp profile_of_bot(actor_id) do
    Repo.one(
      from v in ConfigurationVersion,
        where: fragment("(?->'editor'->>'bot_actor_id')::bigint", v.manifest) == ^actor_id,
        select: fragment("(?->'editor'->>'profile_id')::bigint", v.manifest),
        order_by: v.id,
        limit: 1
    )
    |> case do
      nil -> Repo.get_by(Profile, bot_actor_id: actor_id)
      id -> Repo.get(Profile, id)
    end
  end

  @doc """
  The exact version page a receipt's chooser links to: the profile version
  the configuration version bound (`manifest["editor"]`), or `nil`.
  """
  def version_path(%{"profile_id" => pid, "profile_version_id" => vid})
      when is_integer(pid) and is_integer(vid) do
    with %Profile{slug: slug} <- Repo.get(Profile, pid),
         %ProfileVersion{profile_id: ^pid, version: n} <- Repo.get(ProfileVersion, vid) do
      "/curators/#{slug}/v/#{n}"
    else
      _ -> nil
    end
  end

  def version_path(_editor), do: nil
end
