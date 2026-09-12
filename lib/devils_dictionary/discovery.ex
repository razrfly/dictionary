defmodule DevilsDictionary.Discovery do
  @moduledoc """
  Visit-driven cultural discovery with versioned recipes and disposable caches.

  Definitions never wait for this context. A valid page creates an automatic
  term recipe lazily, admits at most one database-coordinated refresh, and lets
  an Oban worker perform provider I/O. Discovery results remain search cache:
  they never create `illustrates` claims or permanent objects.
  """

  import Ecto.Query

  alias DevilsDictionary.Claims.AssertionRevision
  alias DevilsDictionary.Discovery.{Mapping, Providers, Result, Run}
  alias DevilsDictionary.Discovery.RunWorker
  alias DevilsDictionary.Registry.{ExternalIdentifier, Lexeme, Object, Sense}
  alias DevilsDictionary.Repo
  alias DevilsDictionary.Sources
  alias DevilsDictionary.Sources.{Actor, Source}

  @process_label "Wordhoard automatic discovery"

  @type target :: %{
          object_id: integer(),
          term: String.t(),
          language: String.t(),
          relevance: String.t()
        }

  @doc "Derives a deterministic, term-level target from the actual rendered word page."
  def target_for_page(_page, _canonical_object_id, true), do: nil

  def target_for_page(%{headword: %{lexemes: []}}, _canonical_object_id, _demo), do: nil

  def target_for_page(page, canonical_object_id, _demo) do
    lexemes = page.headword.lexemes

    selected =
      Enum.find(lexemes, &(&1.id == canonical_object_id)) || Enum.min_by(lexemes, & &1.id)

    %{
      object_id: selected.id,
      term: page.headword.lemma,
      language: selected.language,
      relevance: if(length(lexemes) > 1, do: "term_unverified", else: "term")
    }
  end

  @doc "The PubSub topic for one exact registry target."
  def topic(target_id), do: "discovery:target:#{target_id}"

  def subscribe(target_id),
    do: Phoenix.PubSub.subscribe(DevilsDictionary.PubSub, topic(target_id))

  def unsubscribe(target_id),
    do: Phoenix.PubSub.unsubscribe(DevilsDictionary.PubSub, topic(target_id))

  @doc "Requests each enabled server-side provider independently for a page target."
  def request_all(%{object_id: _} = target, opts \\ []) do
    Enum.map(Providers.server_providers(), fn provider ->
      {provider.slug(), request(target, provider.slug(), opts)}
    end)
  end

  @doc "Creates the automatic mapping when absent, then reuses or admits its cache refresh."
  def request(%{object_id: _} = target, provider_slug, opts \\ []) do
    with {:ok, provider} <- provider(provider_slug),
         :ok <- validate_target(target.object_id),
         {:ok, source} <- ensure_source(provider),
         true <- source.active || {:error, :provider_disabled},
         {:ok, mapping} <- ensure_automatic_mapping(target, provider, source) do
      request_mapping(mapping, opts)
    end
  end

  @doc "Admits a refresh or pagination run without bypassing cache, backoff or queue limits."
  def request_mapping(%Mapping{} = mapping, opts \\ []) do
    refresh? = Keyword.get(opts, :refresh, false)
    after_cursor = Keyword.get(opts, :after)
    page_context = Keyword.get(opts, :page_context)
    page = Keyword.get(opts, :page, if(after_cursor, do: 1, else: 0))

    with :ok <- validate_target(mapping.target_object_id),
         true <- mapping.enabled || {:error, :mapping_disabled},
         {:ok, provider} <- provider_for_mapping(mapping),
         {:ok, request} <- request_parameters(mapping, after_cursor, page_context, page),
         result <- admit(mapping, provider, request, refresh?, after_cursor) do
      result
    end
  end

  @doc "Returns the reader state for an enabled provider without making external requests."
  def state(target_id, provider_slug \\ "cinegraph") do
    with {:ok, provider} <- provider(provider_slug),
         %Mapping{} = mapping <- enabled_mapping(target_id, provider.slug()),
         :ok <- validate_target(target_id) do
      state_for_mapping(mapping, provider)
    else
      _ -> %{status: :idle, items: [], provider: provider_slug, mapping_id: nil}
    end
  end

  @doc "Admits the next cursor page only for the currently enabled mapping/context."
  def request_next(target_id, provider_slug, page_context, page, cursor) do
    with %Mapping{} = mapping <- enabled_mapping(target_id, provider_slug) do
      request_mapping(mapping,
        after: cursor,
        page_context: page_context,
        page: page + 1
      )
    else
      nil -> {:error, :mapping_changed}
    end
  end

  @doc "Creates a new immutable mapping version and disables the prior version atomically."
  def create_mapping_version(mapping_key, attrs) when is_binary(mapping_key) do
    Repo.transaction(fn ->
      advisory_lock("mapping-version:#{mapping_key}")

      previous =
        Repo.one(
          from m in Mapping,
            where: m.mapping_key == ^mapping_key,
            order_by: [desc: m.version],
            limit: 1
        )

      if previous && previous.enabled do
        previous |> Mapping.activation_changeset(false) |> Repo.update!()
      end

      version = if previous, do: previous.version + 1, else: 1

      %Mapping{}
      |> Mapping.create_changeset(Map.merge(attrs, %{mapping_key: mapping_key, version: version}))
      |> Repo.insert!()
    end)
  end

  @doc "Runs one admitted attempt. Called by Oban and directly by focused tests."
  def execute_run(run_id) do
    with {:ok, run} <- start_run(run_id),
         true <- run.mapping.enabled || {:error, "mapping_disabled"},
         :ok <- validate_target(run.mapping.target_object_id),
         {:ok, provider} <- provider_for_mapping(run.mapping),
         true <- provider.enabled?() || {:error, "provider_disabled"},
         true <-
           run.adapter_version == provider.adapter_version() ||
             {:error, "adapter_version_changed"},
         :ok <- provider.validate_mapping(run.mapping.operation, run.mapping.parameters) do
      request_fun = fn payload ->
        DevilsDictionary.Discovery.Transport.graphql(provider, run.id, payload)
      end

      case provider.retrieve(
             run.mapping.operation,
             run.mapping.parameters,
             run.request_parameters,
             request_fun
           ) do
        {:ok, response} -> complete_success(run, provider, response)
        {:error, code} -> complete_failure(run, code)
        {:deferred, code, seconds, params} -> defer_run(run, code, seconds, params)
      end
    else
      {:already_finished, _run} -> :ok
      {:error, code} when is_binary(code) -> fail_if_possible(run_id, code)
      {:error, _reason} -> fail_if_possible(run_id, "mapping_ineligible")
    end
  end

  @doc "Deletes expired/excess attempts; cascades only into disposable discovery results."
  def cleanup do
    config = config()
    cutoff = DateTime.add(DateTime.utc_now(), -config[:retention_seconds], :second)
    keep = config[:retained_attempts_per_position]

    %{rows: [[count]]} =
      Repo.query!(
        """
        WITH ranked AS (
          SELECT id, completed_at,
                 row_number() OVER (
                   PARTITION BY mapping_id, position_key
                   ORDER BY started_at DESC NULLS LAST, id DESC
                 ) AS rank
            FROM discovery_runs
           WHERE status IN ('succeeded', 'failed')
        ), deleted AS (
          DELETE FROM discovery_runs
           WHERE id IN (
             SELECT id FROM ranked WHERE completed_at < $1 OR rank > $2
           )
          RETURNING id
        )
        SELECT count(*) FROM deleted
        """,
        [cutoff, keep]
      )

    count
  end

  @doc "Marks a cached item withdrawn without touching any linked object or claim."
  def withdraw_result(result_id) do
    Repo.update_all(from(r in Result, where: r.id == ^result_id), set: [display_allowed: false])
  end

  @doc "Deterministically selects real lexical targets defined by one registered source."
  def targets_for_definition_source(source_slug, limit, after_id \\ nil)
      when is_integer(limit) and limit > 0 do
    with %Source{} = source <- Sources.get_source_by_slug(source_slug),
         true <- source.active || {:error, :definition_source_disabled},
         true <- source.kind == :dictionary || {:error, :not_a_definition_source} do
      base_query =
        from ci in DevilsDictionary.Registry.ContentItem,
          join: cr in DevilsDictionary.Registry.ContentRevision,
          on: cr.content_id == ci.object_id and cr.is_current and cr.lifecycle_state == :active,
          join: link in AssertionRevision,
          on: link.subject_object_id == ci.object_id and link.is_current,
          join: predicate in assoc(link, :predicate),
          left_join: sense in Sense,
          on: sense.object_id == link.object_object_id,
          join: lexeme in Lexeme,
          on: lexeme.object_id == coalesce(sense.lexeme_id, link.object_object_id),
          join: object in Object,
          on: object.id == lexeme.object_id,
          where:
            ci.source_id == ^source.id and predicate.key == "defines" and
              link.lifecycle_state == :active and object.lifecycle_state == :active and
              (is_nil(sense.object_id) or sense.identity_state == :active)

      query =
        if after_id do
          from [_, _, _, _, _, lexeme, _] in base_query,
            where: lexeme.object_id > ^after_id
        else
          base_query
        end

      targets =
        Repo.all(
          from [_, _, _, _, _, lexeme, _] in query,
            order_by: [asc: lexeme.object_id],
            distinct: true,
            limit: ^limit,
            select: {lexeme.object_id, lexeme.lemma, lexeme.language_tag}
        )
        |> Enum.map(fn {object_id, term, language} ->
          %{object_id: object_id, term: term, language: language, relevance: "term"}
        end)

      {:ok, targets}
    else
      nil -> {:error, :definition_source_not_found}
      error -> error
    end
  end

  defp ensure_automatic_mapping(target, provider, source) do
    key = "automatic/#{provider.slug()}/#{target.object_id}/#{provider.adapter_version()}"

    case Repo.one(
           from m in Mapping,
             where: m.mapping_key == ^key and m.enabled,
             limit: 1
         ) do
      %Mapping{} = mapping ->
        {:ok, mapping}

      nil ->
        with {:ok, actor} <- ensure_process_actor() do
          {operation, parameters} = provider.automatic_mapping(target)

          attrs = %{
            target_object_id: target.object_id,
            source_id: source.id,
            operation: operation,
            parameters: parameters,
            configured_by_actor_id: actor.id,
            enabled: true
          }

          ensure_mapping_version(key, attrs)
        end
    end
  end

  defp ensure_mapping_version(key, attrs) do
    Repo.transaction(fn ->
      advisory_lock("mapping-version:#{key}")

      case Repo.one(from m in Mapping, where: m.mapping_key == ^key and m.enabled, limit: 1) do
        %Mapping{} = mapping ->
          mapping

        nil ->
          latest =
            Repo.one(
              from m in Mapping,
                where: m.mapping_key == ^key,
                order_by: [desc: m.version],
                limit: 1
            )

          %Mapping{}
          |> Mapping.create_changeset(
            Map.merge(attrs, %{
              mapping_key: key,
              version: if(latest, do: latest.version + 1, else: 1)
            })
          )
          |> Repo.insert!()
      end
    end)
  end

  defp ensure_source(provider) do
    attrs = provider.source_attrs()

    %Source{}
    |> Source.changeset(attrs)
    |> Repo.insert(on_conflict: :nothing, conflict_target: [:slug])

    case Sources.get_source_by_slug(provider.slug()) do
      %Source{} = source -> {:ok, source}
      nil -> {:error, :provider_not_registered}
    end
  end

  defp ensure_process_actor do
    Repo.transaction(fn ->
      advisory_lock("discovery-process-actor")

      Repo.one(
        from a in Actor,
          where: a.actor_kind == :import and a.label == ^@process_label,
          limit: 1
      ) ||
        %Actor{}
        |> Actor.changeset(%{
          actor_kind: :import,
          label: @process_label,
          metadata: %{"process" => "automatic_cultural_discovery"}
        })
        |> Repo.insert!()
    end)
  end

  defp admit(mapping, provider, request, refresh?, after_cursor) do
    Repo.transaction(fn ->
      advisory_lock("discovery-admit:#{mapping.id}:#{request.position_key}")
      now = DateTime.utc_now()

      cooldown_run =
        if refresh? and is_nil(after_cursor) do
          recent_success(
            mapping.id,
            request.position_key,
            now,
            config()[:refresh_cooldown_seconds]
          )
        end

      cond do
        retry_blocked?(mapping.id, request.position_key, now) ->
          {:deferred, :backoff}

        cooldown_run ->
          {:cached, cooldown_run}

        !refresh? and is_nil(after_cursor) and fresh_run(mapping.id, now) ->
          {:cached, fresh_run(mapping.id, now)}

        in_flight = in_flight(mapping.id, request.request_key) ->
          {:queued, in_flight}

        queue_full?(mapping.source_id) ->
          {:deferred, :queue_full}

        true ->
          run =
            %Run{}
            |> Run.create_changeset(%{
              mapping_id: mapping.id,
              adapter_version: provider.adapter_version(),
              request_parameters: request.parameters,
              request_key: request.request_key,
              position_key: request.position_key,
              page_context: request.page_context,
              page: request.page,
              status: :pending
            })
            |> Repo.insert!()

          case Oban.insert(RunWorker.new(%{"run_id" => run.id})) do
            {:ok, _job} -> {:queued, run}
            {:error, error} -> Repo.rollback(error)
          end
      end
    end)
    |> case do
      {:ok, answer} ->
        answer

      {:error, %Ecto.ConstraintError{}} ->
        case in_flight(mapping.id, request.request_key) do
          nil -> {:deferred, :contention}
          run -> {:queued, run}
        end

      {:error, error} ->
        {:error, error}
    end
  end

  defp request_parameters(mapping, after_cursor, page_context, page) do
    limit = config()[:result_limit]
    max_pages = config()[:max_pages_per_context]

    cond do
      is_nil(after_cursor) and page == 0 ->
        context = Ecto.UUID.generate()
        parameters = %{"after" => nil, "first" => limit}
        {:ok, keyed_request(parameters, context, 0)}

      is_binary(after_cursor) and is_binary(page_context) and page > 0 and page < max_pages ->
        with %Run{} = root <- root_run(mapping.id, page_context) do
          parameters =
            root.request_parameters
            |> Map.put("after", after_cursor)
            |> Map.put("first", limit)

          {:ok, keyed_request(parameters, page_context, page)}
        else
          nil -> {:error, :stale_pagination}
        end

      true ->
        {:error, :invalid_pagination}
    end
  end

  defp keyed_request(parameters, page_context, page) do
    position_key = digest(parameters["after"] || "root")

    request_key =
      if page == 0,
        do: position_key,
        else: digest([page_context, page, parameters["after"]])

    %{
      parameters: parameters,
      page_context: page_context,
      page: page,
      position_key: position_key,
      request_key: request_key
    }
  end

  defp recent_success(mapping_id, position_key, now, cooldown_seconds) do
    cutoff = DateTime.add(now, -cooldown_seconds, :second)

    Repo.one(
      from r in Run,
        where:
          r.mapping_id == ^mapping_id and r.position_key == ^position_key and
            r.status == :succeeded and r.completed_at > ^cutoff,
        order_by: [desc: r.completed_at, desc: r.id],
        limit: 1
    )
  end

  defp state_for_mapping(mapping, provider) do
    now = DateTime.utc_now()

    case latest_display_root(mapping.id, now) do
      %Run{} = root ->
        runs =
          Repo.all(
            from r in Run,
              where:
                r.mapping_id == ^mapping.id and r.page_context == ^root.page_context and
                  r.status == :succeeded and r.display_allowed and r.expires_at > ^now,
              order_by: [asc: r.page, asc: r.started_at, asc: r.id]
          )

        items = display_items(runs)
        last = List.last(runs) || root

        status =
          cond do
            root.result_count == 0 -> :empty
            items == [] -> :empty
            true -> :ready
          end

        %{
          status: status,
          empty_reason:
            if(items == [] and root.result_count > 0,
              do: :withdrawn,
              else: root.completion_reason
            ),
          items: items,
          provider: provider.slug(),
          mapping_id: mapping.id,
          mapping_version: mapping.version,
          page_context: root.page_context,
          page: last.page,
          next_cursor: if(last.page + 1 < config()[:max_pages_per_context], do: last.next_cursor),
          refresh_due: DateTime.compare(root.refresh_after, now) != :gt,
          relevance: mapping.parameters["relevance"],
          term: mapping.parameters["term"]
        }

      nil ->
        pending_or_failure_state(mapping, provider)
    end
  end

  defp pending_or_failure_state(mapping, provider) do
    latest =
      Repo.one(
        from r in Run,
          where: r.mapping_id == ^mapping.id and r.page == 0,
          order_by: [desc: r.inserted_at, desc: r.id],
          limit: 1
      )

    status =
      case latest do
        %Run{status: status} when status in [:pending, :running] -> :loading
        %Run{status: :failed} -> :failed
        %Run{status: :succeeded, display_allowed: false} -> :withdrawn
        %Run{status: :succeeded} -> :expired
        _ -> :idle
      end

    %{
      status: status,
      items: [],
      provider: provider.slug(),
      mapping_id: mapping.id,
      term: mapping.parameters["term"],
      relevance: mapping.parameters["relevance"]
    }
  end

  defp display_items(runs) do
    run_ids = Enum.map(runs, & &1.id)

    if run_ids == [] do
      []
    else
      pages = Map.new(runs, &{&1.id, &1.page})

      Repo.all(
        from result in Result,
          where: result.run_id in ^run_ids and result.display_allowed,
          order_by: [asc: result.run_id, asc: result.position]
      )
      |> Enum.sort_by(&{pages[&1.run_id], &1.position, &1.id})
      |> Enum.uniq_by(fn result ->
        result.object_id || {result.external_namespace, result.external_id}
      end)
    end
  end

  defp complete_success(run, provider, response) do
    now = DateTime.utc_now()
    config = config()
    persistent? = provider.capabilities().persistence == :persistent
    items = Enum.uniq_by(response.items, &{&1.external_namespace, &1.external_id})

    result =
      Repo.transaction(fn ->
        if persistent?, do: persist_results(run.id, items)

        run
        |> Run.lifecycle_changeset(%{
          request_parameters: response.request_parameters,
          status: :succeeded,
          completed_at: now,
          refresh_after: DateTime.add(now, config[:refresh_seconds], :second),
          expires_at: DateTime.add(now, config[:hard_expiry_seconds], :second),
          retry_at: nil,
          next_cursor: response.next_cursor,
          error_code: nil,
          completion_reason:
            if(persistent?, do: response.completion_reason, else: :transient_results),
          result_count: length(items)
        })
        |> Repo.update!()
      end)

    case result do
      {:ok, completed} ->
        transient_items = if persistent?, do: [], else: items

        broadcast(
          completed.mapping.target_object_id,
          completed.mapping_id,
          provider.slug(),
          transient_items
        )

        cleanup()
        :ok

      {:error, _} ->
        complete_failure(run, "persistence_failed")
    end
  end

  defp complete_failure(run, code) do
    now = DateTime.utc_now()

    completed =
      run
      |> Run.lifecycle_changeset(%{
        status: :failed,
        completed_at: now,
        retry_at: DateTime.add(now, config()[:failure_backoff_seconds], :second),
        error_code: safe_code(code),
        completion_reason: nil
      })
      |> Repo.update!()

    broadcast(
      completed.mapping.target_object_id,
      completed.mapping_id,
      completed.mapping.source.slug,
      []
    )

    :ok
  end

  defp defer_run(run, code, seconds, params) do
    run
    |> Run.lifecycle_changeset(%{
      request_parameters: params,
      status: :pending,
      started_at: nil,
      retry_at: DateTime.add(DateTime.utc_now(), seconds, :second),
      error_code: safe_code(code)
    })
    |> Repo.update!()

    {:snooze, seconds}
  end

  defp persist_results(run_id, items) do
    identity_map = existing_object_ids(items)

    Enum.each(items, fn item ->
      attrs =
        item
        |> Map.put(:run_id, run_id)
        |> Map.put(:object_id, identity_map[{item.external_namespace, item.external_id}])

      %Result{} |> Result.changeset(attrs) |> Repo.insert!()
    end)
  end

  defp existing_object_ids(items) do
    identities = Enum.map(items, &{&1.external_namespace, &1.external_id})
    namespaces = identities |> Enum.map(&elem(&1, 0)) |> Enum.uniq()
    external_ids = identities |> Enum.map(&elem(&1, 1)) |> Enum.uniq()

    Repo.all(
      from identifier in ExternalIdentifier,
        where:
          identifier.status == :verified and identifier.namespace in ^namespaces and
            identifier.external_id in ^external_ids,
        select: {identifier.namespace, identifier.external_id, identifier.object_id}
    )
    |> Enum.filter(fn {namespace, external_id, _object_id} ->
      {namespace, external_id} in identities
    end)
    |> Map.new(fn {namespace, external_id, object_id} ->
      {{namespace, external_id}, object_id}
    end)
  end

  defp start_run(run_id) do
    Repo.transaction(fn ->
      run = Repo.get!(Run, run_id) |> Repo.preload(mapping: :source)

      case run.status do
        :pending ->
          run
          |> Run.lifecycle_changeset(%{
            status: :running,
            started_at: run.started_at || DateTime.utc_now(),
            retry_at: nil,
            error_code: nil
          })
          |> Repo.update!()

        status when status in [:succeeded, :failed] ->
          Repo.rollback({:already_finished, run})

        :running ->
          run
      end
    end)
    |> case do
      {:ok, run} -> {:ok, Repo.preload(run, [mapping: :source], force: true)}
      {:error, {:already_finished, run}} -> {:already_finished, run}
      {:error, reason} -> {:error, reason}
    end
  end

  defp fail_if_possible(run_id, code) do
    case Repo.get(Run, run_id) |> maybe_preload_mapping() do
      %Run{status: status} = run when status in [:pending, :running] ->
        complete_failure(run, code)

      _ ->
        :ok
    end
  end

  defp maybe_preload_mapping(nil), do: nil
  defp maybe_preload_mapping(run), do: Repo.preload(run, mapping: :source)

  defp validate_target(object_id) do
    case Repo.get(Object, object_id) do
      %Object{kind: :lexeme, lifecycle_state: :active} ->
        :ok

      %Object{kind: :sense, lifecycle_state: :active} ->
        case Repo.get(Sense, object_id) do
          %Sense{identity_state: :active} -> :ok
          _ -> {:error, :invalid_target}
        end

      _ ->
        {:error, :invalid_target}
    end
  end

  defp enabled_mapping(target_id, provider_slug) do
    Repo.one(
      from m in Mapping,
        join: source in assoc(m, :source),
        where: m.target_object_id == ^target_id and source.slug == ^provider_slug and m.enabled,
        order_by: [desc: m.version],
        preload: [source: source],
        limit: 1
    )
  end

  defp provider(slug) do
    case Providers.get(slug) do
      nil -> {:error, :unsupported_provider}
      provider -> if(provider.enabled?(), do: {:ok, provider}, else: {:error, :provider_disabled})
    end
  end

  defp provider_for_mapping(%Mapping{source: %Source{slug: slug}}), do: provider(slug)

  defp provider_for_mapping(%Mapping{} = mapping) do
    mapping |> Repo.preload(:source) |> provider_for_mapping()
  end

  defp fresh_run(mapping_id, now) do
    Repo.one(
      from r in Run,
        where:
          r.mapping_id == ^mapping_id and r.page == 0 and r.status == :succeeded and
            r.refresh_after > ^now,
        order_by: [desc: r.started_at, desc: r.id],
        limit: 1
    )
  end

  defp latest_display_root(mapping_id, now) do
    Repo.one(
      from r in Run,
        where:
          r.mapping_id == ^mapping_id and r.page == 0 and r.status == :succeeded and
            r.display_allowed and r.expires_at > ^now,
        order_by: [desc: r.started_at, desc: r.id],
        preload: [:results],
        limit: 1
    )
  end

  defp root_run(mapping_id, page_context) do
    Repo.one(
      from r in Run,
        where:
          r.mapping_id == ^mapping_id and r.page_context == ^page_context and r.page == 0 and
            r.status == :succeeded and r.display_allowed,
        order_by: [desc: r.started_at, desc: r.id],
        limit: 1
    )
  end

  defp in_flight(mapping_id, request_key) do
    Repo.one(
      from r in Run,
        where:
          r.mapping_id == ^mapping_id and r.request_key == ^request_key and
            r.status in [:pending, :running],
        limit: 1
    )
  end

  defp retry_blocked?(mapping_id, position_key, now) do
    Repo.exists?(
      from r in Run,
        where:
          r.mapping_id == ^mapping_id and r.position_key == ^position_key and
            not is_nil(r.retry_at) and r.retry_at > ^now and r.status == :failed
    )
  end

  defp queue_full?(source_id) do
    count =
      Repo.one(
        from r in Run,
          join: m in Mapping,
          on: m.id == r.mapping_id,
          where: m.source_id == ^source_id and r.status in [:pending, :running],
          select: count(r.id)
      )

    count >= config()[:queue_cap]
  end

  defp broadcast(target_id, mapping_id, provider_slug, transient_items) do
    Phoenix.PubSub.broadcast(
      DevilsDictionary.PubSub,
      topic(target_id),
      {:discovery_updated, target_id, mapping_id, provider_slug, transient_items}
    )
  end

  defp advisory_lock(value) do
    _ = Repo.query!("SELECT pg_advisory_xact_lock(hashtextextended($1, 0))", [value])
    :ok
  end

  defp safe_code(code) when is_binary(code) do
    if Regex.match?(~r/\A[a-z0-9_]{1,64}\z/, code), do: code, else: "provider_error"
  end

  defp safe_code(_code), do: "provider_error"

  defp digest(value) do
    :sha256
    |> :crypto.hash(:erlang.term_to_binary(value))
    |> Base.url_encode64(padding: false)
  end

  defp config, do: Application.fetch_env!(:devils_dictionary, :discovery)
end
