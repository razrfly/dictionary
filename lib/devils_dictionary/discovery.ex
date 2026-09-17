defmodule DevilsDictionary.Discovery do
  @moduledoc """
  Visit-driven cultural discovery with versioned recipes and disposable caches.

  Definitions never wait for this context. A valid page creates an automatic
  term recipe lazily, admits at most one database-coordinated refresh, and lets
  an Oban worker perform provider I/O. Discovery appearances remain search
  cache and never create `illustrates` claims. Approved adapters may resolve an
  eligible result to a durable registry identity, whose lifecycle is separate
  from this cache.
  """

  import Ecto.Query

  alias DevilsDictionary.Claims.AssertionRevision
  alias DevilsDictionary.Discovery.{Mapping, Policy, Providers, Result, Run}
  alias DevilsDictionary.Discovery.RunWorker
  alias DevilsDictionary.Registry.{Lexeme, Object, Sense}
  alias DevilsDictionary.Repo
  alias DevilsDictionary.SourceIdentity
  alias DevilsDictionary.SourceIdentity.Resolution
  alias DevilsDictionary.Sources
  alias DevilsDictionary.Sources.{Actor, Source, SourceRecord}

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
         :ok <- provider_eligible(provider, source),
         :ok <- provider_covers(provider, target),
         {:ok, mapping} <- ensure_automatic_mapping(target, provider, source) do
      request_mapping(mapping, opts)
    end
  end

  @doc """
  Whether a provider has anything to work with for a target.

  Public because the reader asks it too: the first, disconnected render builds a
  *looking for…* shelf before any run exists, and a shelf for a provider that
  will decline is a promise the page cannot keep.
  """
  def covers?(_provider, nil), do: false

  def covers?(provider, target) do
    if Code.ensure_loaded?(provider) and function_exported?(provider, :covers?, 1),
      do: provider.covers?(target),
      else: true
  end

  # A provider that cannot match this target is not failing and is not
  # deferred — there is simply nothing to ask. Declining here is what stops a
  # mapping, a run and a shelf being created for an answer already known.
  defp provider_covers(provider, target) do
    if covers?(provider, target), do: :ok, else: {:error, :target_not_covered}
  end

  @doc "Admits a refresh or pagination run without bypassing cache, backoff or queue limits."
  def request_mapping(%Mapping{} = mapping, opts \\ []) do
    refresh? = Keyword.get(opts, :refresh, false)
    after_cursor = Keyword.get(opts, :after)
    page_context = Keyword.get(opts, :page_context)
    page = Keyword.get(opts, :page, if(after_cursor, do: 1, else: 0))

    with :ok <- validate_target(mapping.target_object_id),
         true <- mapping.enabled || {:error, :mapping_disabled},
         {:ok, provider, source} <- eligible_provider_for_mapping(mapping),
         :ok <- provider_available(source),
         {:ok, request} <- request_parameters(mapping, provider, after_cursor, page_context, page),
         result <- admit(mapping, provider, request, refresh?, after_cursor) do
      result
    end
  end

  @doc "Returns the reader state for an enabled provider without making external requests."
  def state(target_id, provider_slug) do
    with {:ok, provider} <- provider(provider_slug),
         %Mapping{} = mapping <- enabled_mapping(target_id, provider.slug()),
         {:ok, ^provider, _source} <- eligible_provider_for_mapping(mapping),
         :ok <- validate_target(target_id) do
      state_for_mapping(mapping, provider)
    else
      _ -> idle_state(provider_slug)
    end
  end

  @doc "Returns enabled provider states independently, preserving failure isolation."
  def states(target_id) do
    Providers.all()
    |> Enum.map(fn provider -> {provider.slug(), state(target_id, provider.slug())} end)
    |> Map.new()
  end

  @doc "Reports the shared runtime/read/admission eligibility decision for one provider."
  def provider_eligibility(provider_slug) do
    with {:ok, provider} <- provider(provider_slug),
         %Source{} = source <- Sources.get_source_by_slug(provider_slug),
         :ok <- provider_eligible(provider, source) do
      :ok
    else
      nil -> {:error, :provider_not_registered}
      error -> error
    end
  end

  @doc "Validates a PubSub event against the current target, mapping and provider policy."
  def current_event?(target_id, provider_slug, mapping_id) do
    case state(target_id, provider_slug) do
      %{mapping_id: ^mapping_id} -> true
      _ -> false
    end
  end

  @doc "Changes operational provider eligibility and invalidates mounted readers."
  def set_provider_active(provider_slug, active) when is_boolean(active) do
    with {:ok, provider} <- provider_configured(provider_slug),
         {:ok, source} <- ensure_source(provider),
         {:ok, source} <- source |> Source.changeset(%{active: active}) |> Repo.update() do
      source.id
      |> mapping_targets()
      |> Enum.each(fn {target_id, mapping_id} ->
        broadcast(target_id, mapping_id, provider_slug, [])
      end)

      {:ok, source}
    end
  end

  @doc "Admits the next cursor page only for the currently enabled mapping/context."
  def request_next(target_id, provider_slug, page_context, page, cursor) do
    with %Mapping{} = mapping <- enabled_mapping(target_id, provider_slug),
         {:ok, _provider, _source} <- eligible_provider_for_mapping(mapping) do
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
    case start_run(run_id) do
      {:ok, run} -> execute_owned_run(run)
      {:already_finished, _run} -> :ok
      {:deferred, seconds} -> {:snooze, seconds}
      {:capacity, seconds} -> {:snooze, seconds}
      {:error, reason} -> {:error, reason}
    end
  end

  defp execute_owned_run(run) do
    try do
      with true <- run.mapping.enabled || {:error, "mapping_disabled"},
           :ok <- validate_target(run.mapping.target_object_id),
           {:ok, provider, _source} <- eligible_provider_for_mapping(run.mapping),
           true <-
             run.adapter_version == provider.adapter_version() ||
               {:error, "adapter_version_changed"},
           :ok <- provider.validate_mapping(run.mapping.operation, run.mapping.parameters) do
        request_fun = fn stage, payload ->
          DevilsDictionary.Discovery.Transport.request(provider, run.id, stage, payload)
        end

        response =
          provider.retrieve(
            run.mapping.operation,
            run.mapping.parameters,
            run.request_parameters,
            request_fun
          )

        finish_owned_run(run, fn ->
          case response do
            {:ok, result} -> complete_success(run, provider, result)
            {:error, code} -> complete_failure(run, code)
            {:deferred, code, seconds, params} -> defer_run(run, code, seconds, params)
          end
        end)
      else
        {:error, code} when is_binary(code) ->
          finish_owned_run(run, fn -> complete_failure(run, code) end)

        {:error, _reason} ->
          finish_owned_run(run, fn -> complete_failure(run, "mapping_ineligible") end)
      end
    rescue
      exception ->
        release_owned_run(run, "worker_exception")
        reraise exception, __STACKTRACE__
    catch
      kind, reason ->
        release_owned_run(run, "worker_#{kind}")
        :erlang.raise(kind, reason, __STACKTRACE__)
    end
  end

  # The lease identifies this execution. Recovery may have handed the same run
  # to another worker while an old request was still in flight.
  defp finish_owned_run(run, callback) do
    {:ok, result} =
      Repo.transaction(fn ->
        current = Repo.one(from r in Run, where: r.id == ^run.id, lock: "FOR UPDATE")

        if current && current.status == :running &&
             current.execution_lease_expires_at == run.execution_lease_expires_at do
          callback.()
        else
          :ok
        end
      end)

    case result do
      {:notify, completed, transient_items, outcome} ->
        broadcast(
          completed.mapping.target_object_id,
          completed.mapping_id,
          completed.mapping.source.slug,
          transient_items
        )

        outcome

      outcome ->
        outcome
    end
  end

  defp release_owned_run(run, code) do
    finish_owned_run(run, fn ->
      now = DateTime.utc_now()

      Repo.update_all(from(r in Run, where: r.id == ^run.id),
        set: [
          status: :pending,
          started_at: nil,
          retry_at: now,
          error_code: safe_code(code),
          execution_lease_expires_at: nil,
          updated_at: now
        ]
      )

      :ok
    end)
  end

  @doc "Recovers abandoned attempts and deletes one bounded batch of disposable cache rows."
  def cleanup do
    config = config()
    cutoff = DateTime.add(DateTime.utc_now(), -config[:retention_seconds], :second)
    keep = config[:retained_attempts_per_position]

    recovered = recover_abandoned(config[:cleanup_batch_size])

    %{rows: [[count]]} =
      Repo.query!(
        """
        WITH current_roots AS (
          SELECT DISTINCT ON (runs.mapping_id)
                 runs.mapping_id, runs.page_context
            FROM discovery_runs AS runs
            JOIN discovery_mappings AS mappings ON mappings.id = runs.mapping_id
           WHERE mappings.enabled AND runs.page = 0 AND runs.status = 'succeeded'
             AND runs.display_allowed
           ORDER BY runs.mapping_id, runs.completed_at DESC NULLS LAST, runs.id DESC
        ), protected AS (
          SELECT runs.id
            FROM discovery_runs AS runs
            JOIN current_roots
              ON current_roots.mapping_id = runs.mapping_id
             AND current_roots.page_context = runs.page_context
           WHERE runs.status = 'succeeded' AND runs.display_allowed
        ), ranked AS (
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
             SELECT ranked.id
               FROM ranked
               LEFT JOIN protected ON protected.id = ranked.id
              WHERE protected.id IS NULL AND (ranked.completed_at < $1 OR ranked.rank > $2)
              LIMIT $3
           )
          RETURNING id
        )
        SELECT count(*) FROM deleted
        """,
        [cutoff, keep, config[:cleanup_batch_size]]
      )

    %{deleted: count, recovered: recovered}
  end

  @doc "Durably withdraws a provider item without touching linked objects or claims."
  def withdraw_result(result_id, reason \\ "provider item withdrawn") do
    with %Result{source_record_id: source_record_id} when not is_nil(source_record_id) <-
           Repo.get(Result, result_id),
         {:ok, actor} <- ensure_process_actor() do
      set_source_record_policy(source_record_id, false, actor.id, reason)
    else
      _ -> {0, nil}
    end
  end

  @doc "Explicitly reinstates one durable provider identity with an accountable actor."
  def reinstate_result(result_id, actor_id, reason)
      when is_integer(actor_id) and is_binary(reason) and byte_size(reason) > 0 do
    with %Actor{} <- Repo.get(Actor, actor_id),
         %Result{source_record_id: source_record_id} when not is_nil(source_record_id) <-
           Repo.get(Result, result_id) do
      set_source_record_policy(source_record_id, true, actor_id, reason)
    else
      _ -> {:error, :invalid_reinstatement}
    end
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

  @doc "Resolves an exact resumable set of definition targets, rejecting missing identities."
  def targets_for_definition_source_ids(source_slug, object_ids) when is_list(object_ids) do
    with %Source{} = source <- Sources.get_source_by_slug(source_slug),
         true <- source.active || {:error, :definition_source_disabled},
         true <- source.kind == :dictionary || {:error, :not_a_definition_source} do
      targets =
        Repo.all(
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
                (is_nil(sense.object_id) or sense.identity_state == :active) and
                lexeme.object_id in ^object_ids,
            order_by: [asc: lexeme.object_id],
            distinct: true,
            select: {lexeme.object_id, lexeme.lemma, lexeme.language_tag}
        )
        |> Enum.map(fn {object_id, term, language} ->
          %{object_id: object_id, term: term, language: language, relevance: "term"}
        end)

      found = MapSet.new(targets, & &1.object_id)
      missing = Enum.reject(object_ids, &MapSet.member?(found, &1))

      if missing == [], do: {:ok, targets}, else: {:error, {:missing_resume_targets, missing}}
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

      automatic_prefix = "automatic/#{source_slug(attrs.source_id)}/#{attrs.target_object_id}/%"

      Repo.update_all(
        from(m in Mapping,
          where:
            m.target_object_id == ^attrs.target_object_id and m.source_id == ^attrs.source_id and
              m.enabled and like(m.mapping_key, ^automatic_prefix) and m.mapping_key != ^key
        ),
        set: [enabled: false, updated_at: DateTime.utc_now()]
      )

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
      advisory_lock("discovery-admit-provider:#{mapping.source_id}")
      advisory_lock("discovery-admit:#{mapping.id}:#{request.position_key}")
      now = DateTime.utc_now()
      source = Repo.get!(Source, mapping.source_id)
      persistence = provider.capabilities().persistence

      cooldown_run =
        if refresh? and is_nil(after_cursor) do
          recent_success(
            mapping.id,
            request.position_key,
            now,
            config()[:refresh_cooldown_seconds],
            provider.adapter_version()
          )
        end

      cond do
        provider_eligible(provider, source) != :ok ->
          {:deferred, :provider_disabled}

        provider_available(source) != :ok ->
          {:deferred, :provider_backoff}

        retry_blocked?(mapping.id, request.position_key, now) ->
          {:deferred, :backoff}

        cooldown_run ->
          {:cached, cooldown_run}

        !refresh? and persistence == :persistent and
            cached_run(mapping.id, request, now, provider.adapter_version()) ->
          {:cached, cached_run(mapping.id, request, now, provider.adapter_version())}

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

  defp request_parameters(mapping, provider, after_cursor, page_context, page) do
    limit = config()[:result_limit]
    max_pages = config()[:max_pages_per_context]

    cond do
      is_nil(after_cursor) and page == 0 ->
        context = Ecto.UUID.generate()
        parameters = %{"after" => nil, "first" => limit}
        {:ok, keyed_request(parameters, context, 0)}

      is_binary(after_cursor) and is_binary(page_context) and page > 0 and page < max_pages ->
        with %Run{} = root <- latest_display_root(mapping.id, provider.adapter_version()),
             true <- root.page_context == page_context,
             %Run{} = predecessor <-
               page_run(mapping.id, page_context, page - 1, provider.adapter_version()),
             true <- predecessor.next_cursor == after_cursor do
          parameters =
            root.request_parameters
            |> Map.delete("transport_attempts")
            |> Map.put("after", after_cursor)
            |> Map.put("first", limit)

          {:ok, keyed_request(parameters, page_context, page)}
        else
          _ -> {:error, :stale_pagination}
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

  defp recent_success(mapping_id, position_key, now, cooldown_seconds, adapter_version) do
    cutoff = DateTime.add(now, -cooldown_seconds, :second)

    Repo.one(
      from r in Run,
        where:
          r.mapping_id == ^mapping_id and r.position_key == ^position_key and
            r.status == :succeeded and r.completed_at > ^cutoff and
            r.adapter_version == ^adapter_version,
        order_by: [desc: r.completed_at, desc: r.id],
        limit: 1
    )
  end

  defp state_for_mapping(mapping, provider) do
    now = DateTime.utc_now()

    case latest_display_root(mapping.id, provider.adapter_version()) do
      %Run{} = root ->
        runs =
          Repo.all(
            from r in Run,
              where:
                r.mapping_id == ^mapping.id and r.page_context == ^root.page_context and
                  r.status == :succeeded and r.display_allowed,
              order_by: [asc: r.page, desc: r.started_at, desc: r.id]
          )
          |> Enum.uniq_by(& &1.page)
          |> Enum.sort_by(& &1.page)

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
        |> Map.merge(provider_metadata(provider, mapping.source))

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
        %Run{status: :pending, retry_at: %DateTime{} = retry_at} ->
          if(DateTime.compare(retry_at, DateTime.utc_now()) == :gt, do: :deferred, else: :loading)

        %Run{status: status} when status in [:pending, :running] ->
          :loading

        %Run{status: :failed} ->
          :failed

        %Run{status: :succeeded, display_allowed: false} ->
          :withdrawn

        %Run{status: :succeeded} ->
          :expired

        _ ->
          :idle
      end

    %{
      status: status,
      items: [],
      provider: provider.slug(),
      mapping_id: mapping.id,
      term: mapping.parameters["term"],
      relevance: mapping.parameters["relevance"]
    }
    |> Map.merge(provider_metadata(provider, mapping.source))
  end

  defp display_items(runs) do
    run_ids = Enum.map(runs, & &1.id)

    if run_ids == [] do
      []
    else
      pages = Map.new(runs, &{&1.id, &1.page})

      Repo.all(
        from result in Result,
          left_join: record in assoc(result, :source_record),
          where:
            result.run_id in ^run_ids and result.display_allowed and
              (is_nil(result.source_record_id) or record.display_allowed),
          order_by: [asc: result.run_id, asc: result.position]
      )
      |> Enum.sort_by(&{pages[&1.run_id], &1.position, &1.id})
      |> Enum.uniq_by(fn result ->
        result.object_id || {result.external_namespace, result.external_id}
      end)
    end
  end

  defp complete_success(run, provider, response) do
    run = Repo.get!(Run, run.id) |> Repo.preload(mapping: :source)

    with true <- run.mapping.enabled,
         :ok <- validate_target(run.mapping.target_object_id),
         {:ok, ^provider, _source} <- eligible_provider_for_mapping(run.mapping),
         true <- run.adapter_version == provider.adapter_version() do
      publish_success(run, provider, response)
    else
      _ -> complete_failure(run, "publication_ineligible")
    end
  end

  defp publish_success(run, provider, response) do
    now = DateTime.utc_now()
    persistent? = provider.capabilities().persistence == :persistent
    items = Enum.uniq_by(response.items, &{&1.external_namespace, &1.external_id})

    result =
      Repo.transaction(fn ->
        if persistent?, do: persist_results(run, provider, items)

        run
        |> Run.lifecycle_changeset(%{
          request_parameters: merge_transport_state(run.id, response.request_parameters),
          status: :succeeded,
          completed_at: now,
          refresh_after:
            DateTime.add(now, Policy.refresh_seconds(provider.slug(), length(items)), :second),
          # Kept non-null for the rollout-compatible schema. It is deliberately
          # not a display deadline: identity and policy, never age, govern use.
          expires_at: now,
          retry_at: nil,
          next_cursor: response.next_cursor,
          error_code: nil,
          completion_reason:
            if(persistent?, do: response.completion_reason, else: :transient_results),
          result_count: length(items),
          execution_lease_expires_at: nil
        })
        |> Repo.update!()
      end)

    case result do
      {:ok, completed} ->
        transient_items = if persistent?, do: [], else: items

        {:notify, completed, transient_items, :ok}

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
        completion_reason: nil,
        execution_lease_expires_at: nil
      })
      |> Repo.update!()

    {:notify, completed, [], :ok}
  end

  defp defer_run(run, code, seconds, params) do
    deferred =
      run
      |> Run.lifecycle_changeset(%{
        request_parameters: merge_transport_state(run.id, params),
        status: :pending,
        started_at: nil,
        retry_at: DateTime.add(DateTime.utc_now(), seconds, :second),
        error_code: safe_code(code),
        execution_lease_expires_at: nil
      })
      |> Repo.update!()

    {:notify, deferred, [], {:snooze, seconds}}
  end

  defp persist_results(run, provider, items) do
    source = run.mapping.source

    proposed = Enum.map(items, &{&1, identity_proposal(provider, &1)})

    proposed
    |> Enum.flat_map(fn
      {_item, {:ok, entry}} -> [entry]
      _ -> []
    end)
    |> SourceIdentity.lock_entries()

    Enum.each(proposed, fn {item, proposal} ->
      {:ok, record} =
        Sources.upsert_record(source, %{
          external_id: "#{item.external_namespace}:#{item.external_id}",
          url: item.preview_metadata["source_url"],
          raw: source_payload(item)
        })

      resolution = resolve_identity(proposal, source, record)

      attrs =
        item
        |> Map.put(:run_id, run.id)
        |> Map.put(:object_id, resolution.object_id)
        |> Map.put(:source_record_id, record.id)
        |> Map.put(:resolution_state, resolution.state)

      %Result{} |> Result.changeset(attrs) |> Repo.insert!()
    end)
  end

  defp source_payload(item) do
    %{
      "external_namespace" => item.external_namespace,
      "external_id" => item.external_id,
      "identifiers" => Enum.map(item[:identifiers] || [], &stringify_identifier/1),
      "preview_metadata" => item.preview_metadata,
      "match_details" => item.match_details
    }
  end

  defp stringify_identifier(identifier) do
    %{
      "namespace" => identifier.namespace,
      "external_id" => identifier.external_id,
      "metadata" => identifier[:metadata] || %{},
      "exclusive" => Map.get(identifier, :exclusive, true)
    }
  end

  defp identity_proposal(provider, item) do
    if function_exported?(provider, :identity_record, 1) do
      case provider.identity_record(item) do
        {:ok, entry} ->
          {:ok, entry}

        :ignore ->
          {:resolution, %Resolution{state: :insufficient_evidence, reason: "adapter_ignored"}}

        {:error, reason} ->
          {:resolution, %Resolution{state: :insufficient_evidence, reason: to_string(reason)}}
      end
    else
      {:resolution,
       %Resolution{state: :insufficient_evidence, reason: "adapter_has_no_identity_contract"}}
    end
  end

  defp resolve_identity({:ok, entry}, source, record) do
    entry
    |> Map.merge(%{
      source_id: source.id,
      source_record_id: record.id,
      source_record_revision_id: record.current_revision.id
    })
    |> SourceIdentity.resolve()
  end

  defp resolve_identity({:resolution, resolution}, _source, _record), do: resolution

  defp start_run(run_id) do
    Repo.transaction(fn ->
      run = Repo.get!(Run, run_id) |> Repo.preload(mapping: :source)
      advisory_lock("discovery-execute-provider:#{run.mapping.source_id}")
      # Another worker may have claimed this run while we waited for the provider.
      run = Repo.one!(from r in Run, where: r.id == ^run_id, lock: "FOR UPDATE")
      run = Repo.preload(run, mapping: :source)

      case run.status do
        :pending ->
          now = DateTime.utc_now()

          if run.retry_at && DateTime.compare(run.retry_at, now) == :gt do
            Repo.rollback({:deferred, seconds_until(run.retry_at, now)})
          end

          active =
            Repo.aggregate(
              from(r in Run,
                join: m in Mapping,
                on: m.id == r.mapping_id,
                where:
                  m.source_id == ^run.mapping.source_id and r.status == :running and
                    r.execution_lease_expires_at > ^now
              ),
              :count
            )

          if active >= config()[:provider_concurrency] do
            Repo.rollback({:capacity, config()[:capacity_retry_seconds]})
          end

          run
          |> Run.lifecycle_changeset(%{
            status: :running,
            started_at: run.started_at || now,
            retry_at: nil,
            error_code: nil,
            execution_lease_expires_at:
              DateTime.add(now, config()[:execution_lease_seconds], :second)
          })
          |> Repo.update!()

        status when status in [:succeeded, :failed] ->
          Repo.rollback({:already_finished, run})

        :running ->
          Repo.rollback({:capacity, config()[:capacity_retry_seconds]})
      end
    end)
    |> case do
      {:ok, run} -> {:ok, Repo.preload(run, [mapping: :source], force: true)}
      {:error, {:already_finished, run}} -> {:already_finished, run}
      {:error, {:deferred, seconds}} -> {:deferred, seconds}
      {:error, {:capacity, seconds}} -> {:capacity, seconds}
      {:error, reason} -> {:error, reason}
    end
  end

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
    case Providers.get(provider_slug) do
      nil ->
        nil

      provider ->
        current_automatic_key =
          "automatic/#{provider_slug}/#{target_id}/#{provider.adapter_version()}"

        automatic_prefix = "automatic/#{provider_slug}/#{target_id}/%"

        Repo.one(
          from m in Mapping,
            join: source in assoc(m, :source),
            where:
              m.target_object_id == ^target_id and source.slug == ^provider_slug and m.enabled and
                source.active and
                (not like(m.mapping_key, ^automatic_prefix) or
                   m.mapping_key == ^current_automatic_key),
            order_by: [desc: m.version],
            preload: [source: source],
            limit: 1
        )
    end
  end

  defp source_slug(source_id) do
    Repo.get!(Source, source_id).slug
  end

  defp provider(slug) do
    with {:ok, provider} <- provider_configured(slug),
         true <- provider.enabled?() || {:error, :provider_disabled} do
      {:ok, provider}
    end
  end

  defp provider_configured(slug) do
    case Providers.get(slug) do
      nil -> {:error, :unsupported_provider}
      provider -> {:ok, provider}
    end
  end

  defp eligible_provider_for_mapping(%Mapping{} = mapping) do
    mapping = Repo.preload(mapping, :source)

    with {:ok, provider} <- provider(mapping.source.slug),
         :ok <- provider_eligible(provider, mapping.source),
         :ok <- provider.validate_mapping(mapping.operation, mapping.parameters) do
      {:ok, provider, mapping.source}
    end
  end

  # The capability map is a claim and the exported callbacks are the proof, so
  # this gate has to ask for both. `Providers.server_providers/1` already does,
  # but `request/3` resolves from `Providers.all/0` and arrives here instead —
  # without this clause a module declaring the pipeline and exporting none of it
  # would get a mapping and a queued run, and raise where nothing can recover.
  defp provider_eligible(provider, %Source{} = source) do
    capabilities = provider.capabilities()

    cond do
      !source.active -> {:error, :provider_disabled}
      !provider.enabled?() -> {:error, :provider_disabled}
      !capabilities.background -> {:error, :provider_not_background}
      capabilities.transport != :server -> {:error, :provider_not_server}
      !Providers.retrievable?(provider) -> {:error, :provider_not_retrievable}
      true -> :ok
    end
  end

  defp provider_available(%Source{discovery_retry_after: nil}), do: :ok

  defp provider_available(%Source{discovery_retry_after: retry_after}) do
    if DateTime.compare(retry_after, DateTime.utc_now()) == :gt,
      do: {:deferred, :provider_backoff},
      else: :ok
  end

  defp cached_run(mapping_id, %{page: 0}, now, adapter_version),
    do: fresh_run(mapping_id, now, adapter_version)

  defp cached_run(mapping_id, request, _now, adapter_version) do
    Repo.one(
      from r in Run,
        where:
          r.mapping_id == ^mapping_id and r.request_key == ^request.request_key and
            r.page_context == ^request.page_context and r.page == ^request.page and
            r.status == :succeeded and r.display_allowed and
            r.adapter_version == ^adapter_version,
        order_by: [desc: r.started_at, desc: r.id],
        limit: 1
    )
  end

  defp fresh_run(mapping_id, now, adapter_version) do
    Repo.one(
      from r in Run,
        where:
          r.mapping_id == ^mapping_id and r.page == 0 and r.status == :succeeded and
            r.refresh_after > ^now and r.adapter_version == ^adapter_version,
        order_by: [desc: r.started_at, desc: r.id],
        limit: 1
    )
  end

  defp latest_display_root(mapping_id, adapter_version) do
    Repo.one(
      from r in Run,
        where:
          r.mapping_id == ^mapping_id and r.page == 0 and r.status == :succeeded and
            r.display_allowed and r.adapter_version == ^adapter_version,
        order_by: [desc: r.started_at, desc: r.id],
        preload: [:results],
        limit: 1
    )
  end

  defp page_run(mapping_id, page_context, page, adapter_version) do
    Repo.one(
      from r in Run,
        where:
          r.mapping_id == ^mapping_id and r.page_context == ^page_context and r.page == ^page and
            r.status == :succeeded and r.display_allowed and r.adapter_version == ^adapter_version,
        order_by: [desc: r.started_at, desc: r.id],
        limit: 1
    )
  end

  defp idle_state(provider_slug) do
    metadata =
      case Providers.get(provider_slug) do
        nil -> %{}
        provider -> provider_metadata(provider, Sources.get_source_by_slug(provider_slug))
      end

    Map.merge(
      %{status: :idle, items: [], provider: provider_slug, mapping_id: nil},
      metadata
    )
  end

  defp provider_metadata(provider, source) do
    attrs = provider.source_attrs()
    content_types = provider.capabilities().content_types

    %{
      provider_name: if(source, do: source.name, else: attrs.name),
      provider_attribution: if(source, do: source.attribution, else: attrs.attribution),
      # The one-line qualifier a provider wants beside its name on the shelf
      # ("keywords: TMDb"). The reader renders whatever is here and knows no
      # provider by name.
      provider_detail: shelf_detail(provider),
      content_types: content_types,
      pagination: provider.capabilities().pagination
    }
  end

  defp shelf_detail(provider) do
    if Code.ensure_loaded?(provider) and function_exported?(provider, :shelf_detail, 0),
      do: provider.shelf_detail()
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

  defp set_source_record_policy(source_record_id, display_allowed, actor_id, reason) do
    now = DateTime.utc_now()

    Repo.transaction(fn ->
      record =
        Repo.one!(
          from record in SourceRecord,
            where: record.id == ^source_record_id,
            lock: "FOR UPDATE"
        )

      updated =
        record
        |> SourceRecord.changeset(%{
          display_allowed: display_allowed,
          display_policy_reason:
            if(
              display_allowed,
              do: "reinstated: #{String.trim(reason)}",
              else: String.trim(reason)
            ),
          display_policy_changed_at: now,
          display_policy_actor_id: actor_id
        })
        |> Repo.update!()

      affected =
        Repo.all(
          from result in Result,
            join: run in assoc(result, :run),
            join: mapping in assoc(run, :mapping),
            join: source in assoc(mapping, :source),
            where: result.source_record_id == ^source_record_id,
            distinct: true,
            select: {mapping.target_object_id, mapping.id, source.slug}
        )

      Enum.each(affected, fn {target_id, mapping_id, provider_slug} ->
        broadcast(target_id, mapping_id, provider_slug, [])
      end)

      updated
    end)
    |> case do
      {:ok, record} -> {1, record}
      error -> error
    end
  end

  defp mapping_targets(source_id) do
    Repo.all(
      from m in Mapping,
        where: m.source_id == ^source_id and m.enabled,
        select: {m.target_object_id, m.id}
    )
  end

  defp recover_abandoned(limit) do
    now = DateTime.utc_now()

    %{rows: rows} =
      Repo.query!(
        """
        WITH candidates AS (
          SELECT id FROM discovery_runs
           WHERE status = 'running' AND execution_lease_expires_at <= $1
           ORDER BY execution_lease_expires_at, id
           LIMIT $2
           FOR UPDATE SKIP LOCKED
        )
        UPDATE discovery_runs AS runs
           SET status = 'pending', started_at = NULL, retry_at = NULL, error_code = NULL,
               execution_lease_expires_at = NULL, updated_at = $1
          FROM candidates
         WHERE runs.id = candidates.id
        RETURNING runs.id
        """,
        [now, limit]
      )

    pending_ids =
      Repo.all(
        from r in Run,
          where:
            r.status == :pending and (is_nil(r.retry_at) or r.retry_at <= ^now) and
              r.updated_at < ago(1, "minute"),
          order_by: [asc: r.updated_at, asc: r.id],
          limit: ^limit,
          select: r.id
      )

    (Enum.map(rows, &List.first/1) ++ pending_ids)
    |> Enum.uniq()
    |> Enum.each(fn run_id -> Oban.insert(RunWorker.new(%{"run_id" => run_id})) end)

    length(rows)
  end

  defp merge_transport_state(run_id, params) do
    persisted = Repo.get!(Run, run_id).request_parameters

    case persisted["transport_attempts"] do
      attempts when is_map(attempts) -> Map.put(params, "transport_attempts", attempts)
      _ -> params
    end
  end

  defp seconds_until(future, now) do
    max(DateTime.diff(future, now, :second), 1)
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
