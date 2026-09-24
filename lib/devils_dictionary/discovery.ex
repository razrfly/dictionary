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
  alias DevilsDictionary.Corpus.SourceRecordRevision
  alias DevilsDictionary.Discovery.{Mapping, Policy, Providers, Result, Run}
  alias DevilsDictionary.Discovery.RunWorker
  alias DevilsDictionary.Lexicon
  alias DevilsDictionary.Registry.{ContentItem, ContentRevision, Lexeme, Object, Sense}
  alias DevilsDictionary.Repo
  alias DevilsDictionary.SourceIdentity
  alias DevilsDictionary.SourceIdentity.Resolution
  alias DevilsDictionary.Sources
  alias DevilsDictionary.Sources.{Actor, Source, SourceRecord}

  @process_label "Wordhoard automatic discovery"

  @type target :: %{
          object_id: integer(),
          lexeme_ids: [integer()],
          term: String.t(),
          language: String.t(),
          relevance: String.t()
        }

  @doc """
  Derives a deterministic, term-level target from the actual rendered word page.

  The target is **the page's lexeme set** (K4 of #109). `object_id` still names
  one lexeme, because a mapping's `target_object_id` is a registry identity and
  a set is not one — but it is the lexeme the page itself opens on (its first,
  which `WordPage` has already ranked noun before verb before the rest), not the
  lowest object id. `/define/war` is seven lexemes and the lowest id is a
  prefix; the noun is the word the page is about.

  `lexeme_ids` is the whole page, read by the shared rule in
  `DevilsDictionary.Lexicon.page_scope/1` rather than taken from the rendered
  page, because `mapping_target/1` has to rebuild the identical set at
  publication time when there is no page — and a set that differed between the
  two would make every evidence-versioned run fail as stale.
  """
  def target_for_page(_page, _canonical_object_id, true), do: nil

  def target_for_page(%{headword: %{lexemes: []}}, _canonical_object_id, _demo), do: nil

  def target_for_page(page, canonical_object_id, _demo) do
    lexemes = page.headword.lexemes
    selected = Enum.find(lexemes, &(&1.id == canonical_object_id)) || hd(lexemes)

    %{
      object_id: selected.id,
      lexeme_ids: Lexicon.page_lexeme_ids(selected.id),
      term: page.headword.lemma,
      language: selected.language,
      relevance: if(length(lexemes) > 1, do: "term_unverified", else: "term")
    }
  end

  @doc """
  The page's lexeme set for a target, however the target was built.

  A provider reads the whole page's evidence rather than one lexeme's, so this
  is the shared scope it asks for. A target from `target_for_page/3` carries the
  set already; one built from a mapping or a maintenance task does not, and pays
  a query for it.
  """
  def page_lexeme_ids(%{lexeme_ids: [_ | _] = ids}), do: ids
  def page_lexeme_ids(%{object_id: object_id}), do: Lexicon.page_lexeme_ids(object_id)

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

        # #164 C1: whatever creator identity needs from the network is fetched
        # here, before `finish_owned_run/2` opens the publication transaction,
        # so no lock is held across a Wikidata request.
        # The same eligibility `complete_success/4` re-checks after the request
        # is checked first, so a mapping disabled or re-versioned while the
        # provider was answering does not spend Wikidata budget on a run that
        # will not publish (#164 audit residual 3).
        prepared =
          case response do
            {:ok, result} ->
              if publishable?(run, provider),
                do: prepare_creators(run, provider, result),
                else: %{}

            _ ->
              %{}
          end

        finish_owned_run(run, fn ->
          case response do
            {:ok, result} -> complete_success(run, provider, result, prepared)
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

  @doc """
  One cleanup tick: recovery, retention, the bounded sweep, and the ledger.

  Four things, in this order, because each depends on the one before it:

  1. **Recovery.** A run whose execution lease expired is handed back as
     `pending` so the next worker can finish it.
  2. **Retention** (#144 Phase 2). A held result past its source's
     `retention_seconds` is *gone*, including when its run is the page's
     current display root: the run is **withdrawn** (`display_allowed = false`,
     the branch that existed and nothing could reach), its results are deleted,
     and the `source_records` those results owned are deleted when nothing else
     references them. The run row itself stays — it is the ledger of what was
     spent, and deleting it would take the accounting with the content.
  3. **The bounded sweep.** The pre-existing rule: delete run rows past the
     global cutoff, or beyond `retained_attempts_per_position` for their
     position, never touching a run a page is displaying. Its results are
     purged first, for the same reason retention purges them — a deleted run
     used to cascade to its results and leave the provider's **payload** in
     `source_records` behind it.
  4. **The ledger.** `discovery_request_attempts` is pruned to
     `retained_attempts_per_position` per position, for protected roots too,
     which is the only path that ever reaches them: attempts were deleted only
     with their run, and a protected run is never deleted.

  Retention runs **before** the sweep so that a run the sweep is about to
  delete has already had its source records considered, and a run the sweep
  protects has still had its content taken.
  """
  def cleanup do
    config = config()
    cutoff = DateTime.add(DateTime.utc_now(), -config[:retention_seconds], :second)
    keep = config[:retained_attempts_per_position]

    recovered = recover_abandoned(config[:cleanup_batch_size])
    retention = enforce_retention(config[:cleanup_batch_size])

    # The runs the bounded sweep is about to delete, named first so their
    # results and source records go with them. Deleting a run cascades to its
    # results and **not** to `source_records`, which is how the provider's own
    # payload was left behind under a row nothing referenced (#144 Phase 2).
    %{rows: sweepable} =
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
        )
        SELECT ranked.id
          FROM ranked
          LEFT JOIN protected ON protected.id = ranked.id
         WHERE protected.id IS NULL AND (ranked.completed_at < $1 OR ranked.rank > $2)
         LIMIT $3
        """,
        [cutoff, keep, config[:cleanup_batch_size]]
      )

    sweepable_ids = Enum.map(sweepable, &hd/1)
    {_swept_results, swept_records} = purge_results(sweepable_ids)

    {count, _} =
      if sweepable_ids == [],
        do: {0, nil},
        else: Repo.delete_all(from(r in Run, where: r.id in ^sweepable_ids))

    pruned_attempts = prune_attempts(keep, config[:cleanup_batch_size])

    Map.merge(retention, %{
      deleted: count,
      recovered: recovered,
      pruned_attempts: pruned_attempts,
      swept_source_records: swept_records
    })
  end

  @doc """
  The run rows a retention sweep would act on right now, newest first.

  Public because `mix dd.discovery.status` and the admin page answer "retention
  due" with it, and because a session auditing a source's terms should be able
  to ask the question without running the sweep.
  """
  def retention_due(limit \\ 500) do
    retention_due_query(DateTime.utc_now(), limit)
  end

  # A run is past retention when its own `expires_at` says so. `expires_at` was
  # written as `now` by every run before #144 Phase 2 and is immutable on a
  # completed run, so those rows fall back to `completed_at +` the source's
  # current policy — otherwise the first tick after this ships would withdraw
  # every shelf in the database at once.
  #
  # Oldest first, and only runs that still have something to take: a run
  # already withdrawn and purged is done with, and re-reading it every fifteen
  # minutes forever would make the batch size meaningless.
  defp retention_due_query(now, limit) do
    held = from(result in Result, distinct: true, select: result.run_id)

    from(run in Run,
      join: mapping in Mapping,
      on: mapping.id == run.mapping_id,
      join: source in Source,
      on: source.id == mapping.source_id,
      where: run.status == :succeeded and not is_nil(run.completed_at),
      where: run.display_allowed or run.id in subquery(held),
      order_by: [asc: run.completed_at, asc: run.id],
      limit: ^limit,
      select: %{
        id: run.id,
        slug: source.slug,
        completed_at: run.completed_at,
        expires_at: run.expires_at,
        display_allowed: run.display_allowed
      }
    )
    |> Repo.all()
    |> Enum.filter(&expired?(&1, now))
  end

  defp expired?(%{slug: slug, completed_at: completed_at, expires_at: expires_at}, now) do
    deadline =
      if expires_at && DateTime.compare(expires_at, completed_at) == :gt,
        do: expires_at,
        else: DateTime.add(completed_at, Policy.retention_seconds(slug), :second)

    DateTime.compare(deadline, now) != :gt
  end

  # Withdraw, purge, and say what it cost. Bounded by the same batch size the
  # rest of the tick uses, so a database that has been holding nothing for a
  # month catches up over several ticks rather than in one long transaction.
  defp enforce_retention(batch_size) do
    now = DateTime.utc_now()

    due = retention_due_query(now, batch_size)
    run_ids = Enum.map(due, & &1.id)

    {results, records} = purge_results(run_ids)

    withdrawn =
      due
      |> Enum.filter(& &1.display_allowed)
      |> Enum.map(& &1.id)

    {withdrawn_count, _} =
      if withdrawn == [],
        do: {0, nil},
        else:
          Repo.update_all(from(r in Run, where: r.id in ^withdrawn),
            set: [display_allowed: false, updated_at: now]
          )

    %{
      withdrawn: withdrawn_count,
      expired_results: results,
      expired_source_records: records
    }
  end

  @doc """
  Deletes these runs' results, and the source records they owned alone.

  The second half is the one that was missing (#144 Phase 2): a
  `discovery_results` row is the normalized item and the **payload** lives in
  `source_records`, whose foreign key is `ON DELETE RESTRICT` — so deleting a
  run cascaded to its results and left the provider's own response behind,
  under a row nothing pointed at any more.

  A source record is deleted only when nothing else in the encyclopedia is
  standing on it: no other discovery result, and nothing referencing it or any
  of its revisions. A record that a registry entity was built from — an
  `external_identifiers` row, a `sense_revision`, a corpus row's provenance —
  **survives**, because deleting it would cascade its revisions and silently
  null the provenance of something durable. Retention takes the search cache;
  it does not take the encyclopedia.
  """
  def purge_results([]), do: {0, 0}

  def purge_results(run_ids) when is_list(run_ids) do
    record_ids =
      Repo.all(
        from result in Result,
          where: result.run_id in ^run_ids and not is_nil(result.source_record_id),
          distinct: true,
          select: result.source_record_id
      )

    {results, _} = Repo.delete_all(from(r in Result, where: r.run_id in ^run_ids))

    records =
      if record_ids == [] do
        0
      else
        %{num_rows: deleted} =
          Repo.query!(
            """
            DELETE FROM source_records AS sr
             WHERE sr.id = ANY($1)
               AND NOT EXISTS (SELECT 1 FROM discovery_results d WHERE d.source_record_id = sr.id)
               AND NOT EXISTS (SELECT 1 FROM pending_relations p WHERE p.source_record_id = sr.id)
               AND NOT EXISTS (SELECT 1 FROM reconciliation_cases c WHERE c.source_record_id = sr.id)
               AND NOT EXISTS (SELECT 1 FROM source_assertion_outputs a WHERE a.source_record_id = sr.id)
               AND NOT EXISTS (SELECT 1 FROM source_materialized_outputs m WHERE m.source_record_id = sr.id)
               AND NOT EXISTS (
                 SELECT 1 FROM source_record_revisions rev
                  WHERE rev.source_record_id = sr.id
                    AND (
                      EXISTS (SELECT 1 FROM assertion_evidence x WHERE x.source_record_revision_id = rev.id) OR
                      EXISTS (SELECT 1 FROM content_revisions x WHERE x.source_record_revision_id = rev.id) OR
                      EXISTS (SELECT 1 FROM external_identifiers x WHERE x.source_record_revision_id = rev.id) OR
                      EXISTS (SELECT 1 FROM lexeme_forms x WHERE x.source_record_revision_id = rev.id) OR
                      EXISTS (SELECT 1 FROM object_names x WHERE x.source_record_revision_id = rev.id) OR
                      EXISTS (SELECT 1 FROM sense_revisions x WHERE x.source_record_revision_id = rev.id)
                    )
                 )
            """,
            [record_ids]
          )

        deleted
      end

    {results, records}
  end

  # The ledger's only path to a bound. `discovery_request_attempts.run_id` is
  # `ON DELETE CASCADE`, so an attempt row was deleted only when its run was —
  # and a protected root is never deleted, so its attempts grew without limit
  # (402 rows and climbing, measured 2026-09-21). Keeping the most recent
  # `retained_attempts_per_position` per position keeps what a session reads
  # when it asks what a page cost, and drops the rest.
  #
  # Never an attempt still inside a budget window, whatever its rank: `Budget`
  # counts attempts younger than the source's window to decide whether a
  # request may be made, and a pruned row would let a source overspend its
  # limit by exactly the rows pruned. The cutoff is the longest window any
  # source is configured with (CodeRabbit on #166, applied in #167).
  defp prune_attempts(keep, batch_size) do
    cutoff =
      DateTime.add(DateTime.utc_now(), -Policy.longest_budget_window_seconds(), :second)

    %{num_rows: pruned} =
      Repo.query!(
        """
        WITH ranked AS (
          SELECT attempts.id,
                 attempts.attempted_at,
                 row_number() OVER (
                   PARTITION BY runs.mapping_id, runs.position_key, attempts.source_id
                   ORDER BY attempts.attempted_at DESC, attempts.id DESC
                 ) AS rank
            FROM discovery_request_attempts AS attempts
            JOIN discovery_runs AS runs ON runs.id = attempts.run_id
        )
        DELETE FROM discovery_request_attempts
         WHERE id IN (
           SELECT id FROM ranked WHERE rank > $1 AND attempted_at < $3 LIMIT $2
         )
        """,
        [keep, batch_size, cutoff]
      )

    pruned
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

  # The recipe is built first and the key is derived from it, so the evidence
  # behind a mapping is read once per request rather than once to name the
  # mapping and again to fill it.
  defp ensure_automatic_mapping(target, provider, source) do
    {operation, parameters} = provider.automatic_mapping(target)
    key = automatic_mapping_key(provider, target.object_id, parameters)

    case Repo.one(
           from m in Mapping,
             where: m.mapping_key == ^key and m.enabled,
             limit: 1
         ) do
      %Mapping{} = mapping ->
        {:ok, mapping}

      nil ->
        with {:ok, actor} <- ensure_process_actor() do
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

  # The automatic mapping key is the mapping's identity: `ensure_mapping_version/2`
  # disables every other automatic mapping for the same target and source, so a
  # key that changes is a new version and the old row stops being readable.
  # Appending the provider's evidence fingerprint is therefore what stops a
  # mapping created for one QID set being reused, parameters and all, after the
  # encyclopedia has moved to another.
  defp automatic_mapping_key(provider, target_object_id, parameters) do
    base = "automatic/#{provider.slug()}/#{target_object_id}/#{provider.adapter_version()}"

    case mapping_identity(provider, parameters) do
      nil -> base
      identity -> base <> "/" <> identity
    end
  end

  defp mapping_identity(provider, parameters) do
    if evidence_versioned?(provider), do: provider.mapping_identity(parameters), else: nil
  end

  defp evidence_versioned?(provider) do
    Code.ensure_loaded?(provider) and function_exported?(provider, :mapping_identity, 1)
  end

  # A run outlives the claim it rests on: it is queued, it waits behind a rate
  # limit, it retries. Rebuilding the recipe here is what makes the withdrawal
  # of the supporting `refers_to` claim reach a run already in flight, instead
  # of that run publishing results whose evidence no longer exists.
  #
  # A provider that does not version by evidence is not asked, so this costs
  # nothing for CineGraph. Nor is a hand-configured mapping: it was not derived
  # from claims, so claims are not what makes it current.
  defp mapping_evidence_current(%Mapping{} = mapping, provider) do
    automatic_prefix = "automatic/#{provider.slug()}/#{mapping.target_object_id}/"

    if evidence_versioned?(provider) and
         String.starts_with?(mapping.mapping_key, automatic_prefix) do
      {_operation, parameters} = provider.automatic_mapping(mapping_target(mapping))

      if mapping.mapping_key ==
           automatic_mapping_key(provider, mapping.target_object_id, parameters),
         do: :ok,
         else: {:error, :mapping_evidence_changed}
    else
      :ok
    end
  end

  # A mapping's parameters record the target that produced them, so the recipe
  # can be rebuilt from the mapping alone — at publication there is no page.
  defp mapping_target(%Mapping{} = mapping) do
    %{
      object_id: mapping.target_object_id,
      # Not in the parameters: the page's lexeme set is derived, not frozen, so
      # a lexeme joining or leaving the page is evidence moving and has to move
      # the mapping's fingerprint with it.
      lexeme_ids: Lexicon.page_lexeme_ids(mapping.target_object_id),
      term: mapping.parameters["term"],
      language: mapping.parameters["language"],
      relevance: mapping.parameters["relevance"]
    }
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

      # Bound once and not twice: a `cond` clause cannot bind, and the version
      # before #144 Phase 0 ran the same query in its test and again in its
      # body — two round trips and, between them, a window in which a cleanup
      # tick could delete the run the clause had just decided to return.
      cached_run =
        if !refresh? and persistence == :persistent do
          cached_run(mapping.id, request, now, provider.adapter_version())
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

        cached_run ->
          {:cached, cached_run}

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
          # What the shelf header says about its own age (#144 Phase 2). The
          # root's `completed_at` is when this shelf was fetched and
          # `refresh_after` is when the next visit will go again;
          # `refresh_due` is the same comparison the reader used to compute
          # nothing with — it was read by one test and by no page.
          fetched_at: root.completed_at,
          refresh_after: root.refresh_after,
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
    # Filtered on the adapter version, as `latest_display_root/2` is. Without
    # it, an adapter bump left the page reading the *old* version's succeeded
    # run — which `latest_display_root/2` had just refused — and reporting
    # `:expired` for a provider that had never run at this version at all. The
    # honest answer there is `:idle`, which is what this returns once the old
    # run is out of scope (#144 Phase 0).
    adapter_version = provider.adapter_version()

    latest =
      Repo.one(
        from r in Run,
          where:
            r.mapping_id == ^mapping.id and r.page == 0 and
              r.adapter_version == ^adapter_version,
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

        # Retention is the one thing that withdraws a *run* (#144 Phase 2),
        # and it deletes that run's results before it does, so there is
        # nothing left to describe as withheld. `:expired` is the honest
        # reading — the kit no longer holds this and the next visit will ask
        # again — and it is what the reader already renders as *will retry
        # when available*. A withdrawn **result** is a different thing and
        # still says `:withdrawn`, through `state_for_mapping/2`'s
        # `empty_reason`.
        %Run{status: :succeeded, display_allowed: false} ->
          :expired

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

      # The identifiers the provider proposed travel in the source record's
      # payload, which lives on its current revision (`Sources.raw/1`). They
      # come back onto the result as a virtual field so a shelf can dedup two
      # providers' copies of one thing on a shared namespace (#116 M3).
      results =
        Repo.all(
          from result in Result,
            left_join: record in assoc(result, :source_record),
            left_join: revision in SourceRecordRevision,
            on:
              revision.source_record_id == record.id and
                revision.revision_key == record.content_hash,
            left_join: object in Object,
            on: object.id == result.object_id,
            left_join: content in ContentRevision,
            on: content.content_id == result.object_id and content.is_current,
            left_join: item in ContentItem,
            on: item.object_id == result.object_id,
            where:
              result.run_id in ^run_ids and result.display_allowed and
                (is_nil(result.source_record_id) or record.display_allowed),
            order_by: [asc: result.run_id, asc: result.position],
            select:
              {result, revision.payload["identifiers"], object.kind, content.id,
               item.metadata["provenance"]}
        )

      # One read for the whole shelf (#164 C5): the creators the registry
      # credits now, never the hint the run wrote.
      credited =
        results
        |> Enum.map(fn {result, _, _, _, _} -> result.object_id end)
        |> Enum.reject(&is_nil/1)
        |> SourceIdentity.Creators.credited()

      results
      |> Enum.map(fn {result, identifiers, kind, content_revision_id, provenance} ->
        %{
          result
          | identifiers: Enum.filter(List.wrap(identifiers), &is_map/1),
            object_kind: kind,
            content_revision_id: content_revision_id,
            provenance: if(is_map(provenance), do: provenance),
            creator_links: Map.get(credited, result.object_id, [])
        }
      end)
      |> Enum.sort_by(&{pages[&1.run_id], &1.position, &1.id})
      |> Enum.uniq_by(fn result ->
        result.object_id || {result.external_namespace, result.external_id}
      end)
    end
  end

  # `complete_success/4`'s gate, read fresh, without the outcome: what decides
  # whether a run's proposals will be published at all.
  defp publishable?(run, provider) do
    run = Repo.get!(Run, run.id) |> Repo.preload(mapping: :source)

    with true <- run.mapping.enabled,
         :ok <- validate_target(run.mapping.target_object_id),
         {:ok, ^provider, _source} <- eligible_provider_for_mapping(run.mapping),
         true <- run.adapter_version == provider.adapter_version(),
         :ok <- mapping_evidence_current(run.mapping, provider) do
      true
    else
      _ -> false
    end
  end

  defp complete_success(run, provider, response, prepared) do
    run = Repo.get!(Run, run.id) |> Repo.preload(mapping: :source)

    with true <- run.mapping.enabled,
         :ok <- validate_target(run.mapping.target_object_id),
         {:ok, ^provider, _source} <- eligible_provider_for_mapping(run.mapping),
         true <- run.adapter_version == provider.adapter_version(),
         :ok <- mapping_evidence_current(run.mapping, provider) do
      publish_success(run, provider, response, prepared)
    else
      {:error, :mapping_evidence_changed} -> complete_failure(run, "mapping_evidence_changed")
      _ -> complete_failure(run, "publication_ineligible")
    end
  end

  defp publish_success(run, provider, response, prepared) do
    now = DateTime.utc_now()
    persistent? = provider.capabilities().persistence == :persistent
    items = Enum.uniq_by(response.items, &{&1.external_namespace, &1.external_id})

    result =
      Repo.transaction(fn ->
        if persistent?, do: persist_results(run, provider, items, prepared)

        run
        |> Run.lifecycle_changeset(%{
          request_parameters: merge_transport_state(run.id, response.request_parameters),
          status: :succeeded,
          completed_at: now,
          refresh_after:
            DateTime.add(now, Policy.refresh_seconds(provider.slug(), length(items)), :second),
          # The hold deadline, and real since #144 Phase 2: `completed_at +` the
          # source's `retention_seconds`. It was written as `now` and read by
          # nothing, so every run in the ledger was "expired" at the moment it
          # completed. `cleanup/0` reads it, which is what makes a source's
          # terms about retention a rule the kit can keep rather than a
          # sentence in a document. Written here and never updated, because a
          # completed run is immutable in the database — a policy change
          # applies to what runs after it, and the sweep falls back to the
          # policy for anything written before this existed.
          expires_at: DateTime.add(now, Policy.retention_seconds(provider.slug()), :second),
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
        # Per source since #144 Phase 2. A shared five minutes is wrong in both
        # directions: one 429 from GDELT closes its gate for a minute (#134),
        # and a source that answered a malformed body will answer the same one
        # in five.
        retry_at: DateTime.add(now, Policy.failure_backoff_seconds(failed_slug(run)), :second),
        error_code: safe_code(code),
        completion_reason: nil,
        execution_lease_expires_at: nil
      })
      |> Repo.update!()

    {:notify, completed, [], :ok}
  end

  # The slug of a run whose mapping may or may not be preloaded. A failure path
  # is the one place that cannot assume it: `complete_failure/2` is reached from
  # `finish_owned_run/2` with whatever the caller had.
  defp failed_slug(%Run{mapping: %Mapping{source: %Source{slug: slug}}}), do: slug

  defp failed_slug(%Run{mapping_id: mapping_id}),
    do: source_slug(Repo.get!(Mapping, mapping_id).source_id)

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

  # The half of creator identity that may touch the network (#164 C1): every
  # relationship target the run's durable proposals name, looked up in one
  # query, with only the missing QIDs fetched against the `wikidata` budget.
  # A transient provider persists nothing and so credits nobody.
  defp prepare_creators(run, provider, response) do
    if provider.capabilities().persistence == :persistent do
      response.items
      |> Enum.uniq_by(&{&1.external_namespace, &1.external_id})
      |> Enum.flat_map(fn item ->
        case identity_proposal(provider, item) do
          {:ok, %{eligibility: :eligible, retention: :durable} = entry} -> [entry]
          _ -> []
        end
      end)
      |> SourceIdentity.Creators.prepare(run_id: run.id)
    else
      %{}
    end
  end

  defp persist_results(run, provider, items, prepared) do
    source = run.mapping.source

    proposed = Enum.map(items, &{&1, identity_proposal(provider, &1)})

    proposed
    |> Enum.flat_map(fn
      {_item, {:ok, entry}} -> [entry]
      _ -> []
    end)
    |> SourceIdentity.lock_entries(prepared)

    Enum.each(proposed, fn {item, proposal} ->
      {:ok, record} =
        Sources.upsert_record(source, %{
          external_id: "#{item.external_namespace}:#{item.external_id}",
          url: item.preview_metadata["source_url"],
          raw: source_payload(item)
        })

      resolution =
        resolve_identity(proposal, source, record,
          prepared: prepared,
          adapter_version: provider.adapter_version()
        )

      attrs =
        item
        |> Map.put(:run_id, run.id)
        |> Map.put(:object_id, resolution.object_id)
        |> Map.put(:source_record_id, record.id)
        |> Map.put(:resolution_state, resolution.state)
        |> Map.update!(:preview_metadata, &put_creators(&1, resolution.relationships))

      %Result{} |> Result.changeset(attrs) |> Repo.insert!()
    end)
  end

  # `preview_metadata["creators"]` is a **hint** (#164 C5): the labels the
  # card may print and the counts the operator reads. Whether the creator line
  # is a link is decided at render from the assertions as they are then, so a
  # withdrawn credit unlinks without anything here being rewritten.
  defp put_creators(metadata, []), do: metadata

  defp put_creators(metadata, relationships) do
    Map.put(
      metadata,
      "creators",
      Enum.map(relationships, fn relationship ->
        %{
          "role" => relationship.role,
          "qid" => relationship.qid,
          "object_id" => relationship.object_id,
          "state" => to_string(relationship.state),
          "label" => relationship.label
        }
      end)
    )
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
    # `Code.ensure_loaded?/1` first, like every other optional-callback probe in
    # this module: under lazy loading `function_exported?/3` alone answers false
    # for a module that has simply not been loaded yet, and a provider with a
    # durable identity contract would silently degrade to
    # `insufficient_evidence` for the life of that node (#144 Phase 0).
    if Code.ensure_loaded?(provider) and function_exported?(provider, :identity_record, 1) do
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

  defp resolve_identity({:ok, entry}, source, record, opts) do
    entry
    |> Map.merge(%{
      source_id: source.id,
      source_record_id: record.id,
      source_record_revision_id: record.current_revision.id
    })
    |> SourceIdentity.resolve(opts)
  end

  defp resolve_identity({:resolution, resolution}, _source, _record, _opts), do: resolution

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

        # An evidence fingerprint lives one segment past the adapter version, and
        # a stale one is already disabled by `ensure_mapping_version/2` — so this
        # admits the suffix rather than recomputing it on every reader render.
        # Matching `"#{key}/%"` and not `"#{key}%"` keeps `v1` from admitting `v10`.
        current_automatic_prefix = current_automatic_key <> "/%"

        automatic_prefix = "automatic/#{provider_slug}/#{target_id}/%"

        Repo.one(
          from m in Mapping,
            join: source in assoc(m, :source),
            where:
              m.target_object_id == ^target_id and source.slug == ^provider_slug and m.enabled and
                source.active and
                (not like(m.mapping_key, ^automatic_prefix) or
                   m.mapping_key == ^current_automatic_key or
                   like(m.mapping_key, ^current_automatic_prefix)),
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

  # `display_allowed` matters here since #144 Phase 2: retention withdraws a
  # root whose content it took, and a withdrawn root that is still inside its
  # refresh window would otherwise answer `{:cached, run}` for up to thirty
  # days — a page showing the honest empty and never asking again. A run the
  # kit is no longer allowed to display is not a cache hit.
  defp fresh_run(mapping_id, now, adapter_version) do
    Repo.one(
      from r in Run,
        where:
          r.mapping_id == ^mapping_id and r.page == 0 and r.status == :succeeded and
            r.display_allowed and
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
      # Where this source sorts among the others on a shelf (#116 M2). Read
      # from the source row, which is where tier lives; the provider's own
      # declaration is what seeded it.
      tier: if(source, do: source.tier, else: attrs[:tier]),
      # The mark the badge draws beside the name (#152), from the row like the
      # tier, with the declaration as the fallback a fresh database reads.
      logo: if(source, do: source.logo, else: attrs[:logo]),
      # The one-line qualifier a provider wants beside its name on the shelf
      # ("keywords: TMDb"). The reader renders whatever is here and knows no
      # provider by name.
      provider_detail: shelf_detail(provider),
      # A mark this source's licence makes a condition of using it (#142). Read
      # the same way and for the same reason as the qualifier above: the reader
      # renders whatever is here, and a source with no obligation declares
      # none and its shelf gains nothing.
      attribution_mark: attribution_mark(provider),
      content_types: content_types,
      pagination: provider.capabilities().pagination
    }
  end

  defp shelf_detail(provider) do
    if Code.ensure_loaded?(provider) and function_exported?(provider, :shelf_detail, 0),
      do: provider.shelf_detail()
  end

  defp attribution_mark(provider) do
    if Code.ensure_loaded?(provider) and function_exported?(provider, :attribution_mark, 0),
      do: provider.attribution_mark()
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
