defmodule DevilsDictionary.Routing.Ledger do
  @moduledoc """
  The only writer of public addresses (ADR 0004 §5).

  Every operation is one transaction that locks, validates, then writes the
  path rows, the page pointer and their `route_changes` rows together. The
  database refuses any routing change without a matching ledger row, so this
  module cannot skip history even by mistake.

  | Operation | Who | What it does |
  |---|---|---|
  | `allocate/3` | any actor (a batch job) | reserves a new canonical for an active page |
  | `move/3` | a human | old canonical becomes a permanent alias |
  | `merge/3` | a human | every path of the merged page aliases the survivor |
  | `split/3` | a human | the page becomes a choice among named successors |
  | `retire/2` | a human | every path becomes a reserved tombstone (410) |
  | `rollback/2` | a human | restores the before-state of one operation |

  ## Concurrency

  Locks are always taken in one order — per-path advisory locks sorted by
  path, then page rows by id, then path rows by id — so two operations
  cannot deadlock on each other. The unique indexes are the final arbiter: an
  operation that loses a unique, serialization or deadlock race is attempted
  at most three times in all, and then `{:error, :allocation_conflict}` is
  returned. No caller invents an
  alternative path; a taken path is `{:error, {:path_taken, owner}}`.

  Retrying needs its own transaction. Called inside a caller's transaction, a
  failure is re-raised for the caller to roll back.

  ## What it never does

  Publish a page (Stage 5), guess a destination, reuse an address for an
  unrelated page, or allocate a subject path without a current `mapped`
  classification in that family — there is no silent Subjects fallback.
  Reclassification after allocation moves nothing; only an explicit `move/3`
  does.
  """

  import Ecto.Query

  alias DevilsDictionary.{Registry, Repo}
  alias DevilsDictionary.Registry.Object
  alias DevilsDictionary.Routing.{Address, Classifications, Page, Pages, PublicPath, RouteChange}
  alias DevilsDictionary.Sources.Actor

  @max_attempts 3
  @retryable [:unique_violation, :serialization_failure, :deadlock_detected]

  # ── allocate ─────────────────────────────────────────────────────────────

  @doc """
  Reserves `path` as the canonical address of an active page.

  Idempotent: allocating a page's own canonical again returns it and writes
  nothing, and a page's own alias or tombstone is restored rather than
  refused. A subject or edition page needs its target's current decision to be
  `mapped` to the path's family, recorded on the ledger row.

  Options: `:actor_id` and `:reason` (both required).
  """
  def allocate(page_id, path, opts) do
    with {:ok, parsed} <- Address.parse(path),
         {:ok, actor} <- actor(opts, :allocate),
         {:ok, reason} <- reason(opts) do
      transact(fn -> do_allocate(page_id, parsed, actor, reason) end)
    end
  end

  defp do_allocate(page_id, parsed, actor, reason) do
    lock_paths([parsed.path])
    page = Pages.lock!(page_id) || Repo.rollback(:page_not_found)
    if page.lifecycle_state != :active, do: Repo.rollback(:page_not_active)
    decision = addressable!(page, parsed)
    existing = lock_path(parsed.path)
    op = new_op(:allocate, actor, reason, decision: decision)

    cond do
      existing && existing.destination_page_id != page.id ->
        Repo.rollback({:path_taken, owner(existing)})

      existing && existing.kind == :canonical ->
        existing

      page.canonical_path_id ->
        Repo.rollback({:page_has_canonical, Repo.get!(PublicPath, page.canonical_path_id).path})

      existing ->
        {op, path} = transition_path(op, existing, :canonical, page.id)
        {_op, _page} = transition_page(op, page, %{canonical_path_id: path.id})
        path

      true ->
        {op, path} = insert_path(op, page, parsed.path)
        {_op, _page} = transition_page(op, page, %{canonical_path_id: path.id})
        path
    end
  end

  # ── move ─────────────────────────────────────────────────────────────────

  @doc """
  An approved move: `path` becomes the page's canonical and the old canonical
  a permanent alias, answered with one 301. The target path must be new or
  already one of this page's own aliases or tombstones.

  Options: `:actor_id` (a human) and `:reason`.
  """
  def move(page_id, path, opts) do
    with {:ok, parsed} <- Address.parse(path),
         {:ok, actor} <- actor(opts, :move),
         {:ok, reason} <- reason(opts) do
      transact(fn -> do_move(page_id, parsed, actor, reason) end)
    end
  end

  defp do_move(page_id, parsed, actor, reason) do
    lock_paths([parsed.path])
    page = Pages.lock!(page_id) || Repo.rollback(:page_not_found)
    if page.lifecycle_state != :active, do: Repo.rollback(:page_not_active)
    if is_nil(page.canonical_path_id), do: Repo.rollback(:no_canonical)
    decision = addressable!(page, parsed)
    current = lock_path_id(page.canonical_path_id)
    existing = lock_path(parsed.path)

    cond do
      current.path == parsed.path ->
        current

      existing && existing.destination_page_id != page.id ->
        Repo.rollback({:path_taken, owner(existing)})

      true ->
        op = new_op(:move, actor, reason, decision: decision)
        {op, _old} = transition_path(op, current, :alias, page.id)

        {op, path} =
          if existing,
            do: transition_path(op, existing, :canonical, page.id),
            else: insert_path(op, page, parsed.path)

        {_op, _page} = transition_page(op, page, %{canonical_path_id: path.id})
        path
    end
  end

  # ── merge ────────────────────────────────────────────────────────────────

  @doc """
  An approved page merge after an identity merge: every path that served
  `from_page_id` serves `into_page_id`, canonicals becoming aliases, so each
  old address is one 301 from the survivor's canonical. The merged page keeps
  its identity and history and records its successor.

  For pages about registry objects, the registry must already have merged the
  source identity into the survivor's. Editorial pages merge on the approving
  human's judgement. A published page cannot merge into an unpublished one.

  Options: `:actor_id` (a human) and `:reason`.
  """
  def merge(from_page_id, into_page_id, opts) do
    with :ok <- different(from_page_id, into_page_id),
         {:ok, actor} <- actor(opts, :merge),
         {:ok, reason} <- reason(opts) do
      transact(fn -> do_merge(from_page_id, into_page_id, actor, reason) end)
    end
  end

  defp do_merge(from_id, into_id, actor, reason) do
    pages = lock_pages([from_id, into_id])
    from = Map.get(pages, from_id) || Repo.rollback(:page_not_found)
    into = Map.get(pages, into_id) || Repo.rollback(:page_not_found)

    cond do
      from.lifecycle_state != :active or into.lifecycle_state != :active ->
        Repo.rollback(:page_not_active)

      from.role != into.role or from.locale != into.locale ->
        Repo.rollback(:pages_not_equivalent)

      not same_identity?(from, into) ->
        Repo.rollback(:identity_not_merged)

      from.publication_state == :published and into.publication_state != :published ->
        Repo.rollback(:survivor_not_published)

      true ->
        op = new_op(:merge, actor, reason, details: %{"into_page_id" => into.id})

        op =
          from.id
          |> lock_paths_of()
          |> Enum.reduce(op, fn path, op ->
            kind = if path.kind == :canonical, do: :alias, else: path.kind
            {op, _path} = transition_path(op, path, kind, into.id)
            op
          end)

        {_op, page} =
          transition_page(op, from, %{
            lifecycle_state: :merged,
            canonical_path_id: nil,
            merged_into_page_id: into.id
          })

        page
    end
  end

  defp same_identity?(%Page{target_object_id: nil}, %Page{target_object_id: nil}), do: true

  defp same_identity?(%Page{target_object_id: from}, %Page{target_object_id: into})
       when is_integer(from) and is_integer(into) do
    match?(%Object{lifecycle_state: :merged}, Registry.object(from)) and
      Registry.canonical_id(from) == Registry.canonical_id(into)
  end

  defp same_identity?(_from, _into), do: false

  # ── split ────────────────────────────────────────────────────────────────

  @doc """
  An approved page split after an identity split. The page keeps its paths and
  becomes a choice among `successor_page_ids`, each the page of one of the
  registry split's outputs, in the given order. It never redirects to one of
  them: choosing a successor is a reader's decision, and unresolved
  attachments stay in the registry's reconciliation cases.

  Options: `:actor_id` (a human) and `:reason`.
  """
  def split(page_id, successor_page_ids, opts) do
    successors = Enum.uniq(successor_page_ids)

    with :ok <- successors_named(page_id, successors, successor_page_ids),
         {:ok, actor} <- actor(opts, :split),
         {:ok, reason} <- reason(opts) do
      transact(fn -> do_split(page_id, successors, actor, reason) end)
    end
  end

  defp successors_named(page_id, successors, given) do
    cond do
      successors == [] -> {:error, :successors_required}
      length(successors) != length(given) -> {:error, :duplicate_successor}
      page_id in successors -> {:error, :page_cannot_succeed_itself}
      true -> :ok
    end
  end

  defp do_split(page_id, successor_ids, actor, reason) do
    pages = lock_pages([page_id | successor_ids])
    page = Map.get(pages, page_id) || Repo.rollback(:page_not_found)
    if page.lifecycle_state != :active, do: Repo.rollback(:page_not_active)
    if is_nil(page.target_object_id), do: Repo.rollback(:not_an_identity_page)

    outputs =
      case Registry.resolve(page.target_object_id) do
        {:split, ids} -> ids
        _other -> Repo.rollback(:identity_not_split)
      end

    successors =
      Enum.map(successor_ids, fn id ->
        successor = Map.get(pages, id) || Repo.rollback(:page_not_found)

        cond do
          successor.lifecycle_state != :active ->
            Repo.rollback(:successor_not_active)

          successor.locale != page.locale ->
            Repo.rollback(:successor_locale_differs)

          successor.target_object_id not in outputs ->
            Repo.rollback(:successor_not_a_split_output)

          true ->
            successor
        end
      end)

    current = Pages.current_revision(page)

    carried =
      if current,
        do:
          Enum.map(current.memberships, fn m ->
            Map.take(m, [:relationship, :target_object_id, :target_page_id, :rationale, :evidence])
          end),
        else: []

    added =
      Enum.map(successors, fn successor ->
        %{
          relationship: :split_successor,
          target_page_id: successor.id,
          evidence: %{"split_output_object_id" => successor.target_object_id}
        }
      end)

    {:ok, revision} =
      Pages.insert_revision(
        page,
        %{
          title: current && current.title,
          body: current && current.body,
          body_format: current && current.body_format,
          evidence: %{"identity_split_outputs" => Enum.sort(outputs)}
        },
        carried ++ added,
        actor.id
      )

    op = new_op(:split, actor, reason, details: %{"successor_page_ids" => successor_ids})

    {_op, page} =
      transition_page(op, page, %{lifecycle_state: :split, current_revision_id: revision.id})

    page
  end

  # ── retire ───────────────────────────────────────────────────────────────

  @doc """
  An approved retirement: every path of the page becomes a tombstone, which
  stays reserved forever and answers 410. The page keeps its identity and
  history.

  Options: `:actor_id` (a human) and `:reason`.
  """
  def retire(page_id, opts) do
    with {:ok, actor} <- actor(opts, :retire),
         {:ok, reason} <- reason(opts) do
      transact(fn -> do_retire(page_id, actor, reason) end)
    end
  end

  defp do_retire(page_id, actor, reason) do
    page = Pages.lock!(page_id) || Repo.rollback(:page_not_found)
    if page.lifecycle_state not in [:active, :split], do: Repo.rollback(:page_not_active)
    op = new_op(:retire, actor, reason)

    op =
      page.id
      |> lock_paths_of()
      |> Enum.reject(&(&1.kind == :tombstone))
      |> Enum.reduce(op, fn path, op ->
        {op, _path} = transition_path(op, path, :tombstone, page.id)
        op
      end)

    {_op, page} = transition_page(op, page, %{lifecycle_state: :retired, canonical_path_id: nil})
    page
  end

  # ── rollback ─────────────────────────────────────────────────────────────

  @doc """
  An approved rollback of one earlier operation: every path and page it
  changed returns to its recorded before-state, in reverse order. The rollback
  is itself an operation on the ledger; nothing is deleted.

  A path the operation created cannot be un-created — a reservation is
  permanent — so it becomes a tombstone of the page it was allocated for.
  Refused as `{:stale, ...}` when anything the operation changed has changed
  again since; roll back the later operation first.

  Options: `:actor_id` (a human) and `:reason`.
  """
  def rollback(operation_id, opts) do
    with {:ok, operation_id} <- Ecto.UUID.cast(operation_id),
         {:ok, actor} <- actor(opts, :rollback),
         {:ok, reason} <- reason(opts) do
      transact(fn -> do_rollback(operation_id, actor, reason) end)
    end
  end

  defp do_rollback(operation_id, actor, reason) do
    changes = operation(operation_id)
    if changes == [], do: Repo.rollback(:unknown_operation)

    if Repo.exists?(from c in RouteChange, where: c.reverts_operation_id == ^operation_id),
      do: Repo.rollback(:already_rolled_back)

    page_ids =
      Enum.flat_map(changes, &[&1.page_id, &1.before_destination_id, &1.after_destination_id])

    pages = lock_pages(page_ids)
    paths = changes |> Enum.map(& &1.path_id) |> lock_path_ids()
    Enum.each(changes, &current!(&1, pages, paths))
    op = new_op(:rollback, actor, reason, reverts: operation_id)

    changes
    |> Enum.reverse()
    |> Enum.reduce(op, fn change, op -> invert(op, change) end)

    operation_id
  end

  defp current!(%RouteChange{path_id: nil} = change, pages, _paths) do
    page = Map.fetch!(pages, change.page_id)

    unless page.lifecycle_state == change.after_lifecycle and
             page.canonical_path_id == change.after_canonical_path_id and
             page.merged_into_page_id == change.after_merged_into_id and
             page.current_revision_id == change.after_revision_id,
           do: Repo.rollback({:stale, %{page_id: page.id, route_change_id: change.id}})

    if page.publication_state == :published and change.before_lifecycle in [:active, :split] and
         is_nil(change.before_canonical_path_id),
       do: Repo.rollback({:published_page_needs_canonical, page.id})
  end

  defp current!(%RouteChange{} = change, _pages, paths) do
    path = Map.fetch!(paths, change.path_id)

    unless path.kind == change.after_kind and
             path.destination_page_id == change.after_destination_id,
           do: Repo.rollback({:stale, %{path: path.path, route_change_id: change.id}})
  end

  defp invert(op, %RouteChange{path_id: nil} = change) do
    {op, _page} =
      transition_page(op, Repo.get!(Page, change.page_id), %{
        lifecycle_state: change.before_lifecycle,
        canonical_path_id: change.before_canonical_path_id,
        merged_into_page_id: change.before_merged_into_id,
        current_revision_id: change.before_revision_id
      })

    op
  end

  # A path the operation created stays reserved, as a tombstone.
  defp invert(op, %RouteChange{before_kind: nil} = change) do
    path = Repo.get!(PublicPath, change.path_id)
    {op, _path} = transition_path(op, path, :tombstone, path.destination_page_id)
    op
  end

  defp invert(op, %RouteChange{} = change) do
    path = Repo.get!(PublicPath, change.path_id)
    {op, _path} = transition_path(op, path, change.before_kind, change.before_destination_id)
    op
  end

  @doc "The ledger rows of one operation, in order."
  def operation(operation_id) do
    Repo.all(from c in RouteChange, where: c.operation_id == ^operation_id, order_by: c.sequence)
  end

  @doc "The ledger rows that touched a path or page, oldest first."
  def history(page_id: page_id) do
    Repo.all(
      from c in RouteChange,
        where:
          c.page_id == ^page_id or c.before_destination_id == ^page_id or
            c.after_destination_id == ^page_id,
        order_by: c.id
    )
  end

  def history(path_id: path_id) do
    Repo.all(from c in RouteChange, where: c.path_id == ^path_id, order_by: c.id)
  end

  # ── the writes every operation shares ────────────────────────────────────

  defp new_op(operation, actor, reason, opts \\ []) do
    decision = opts[:decision]

    %{
      id: Ecto.UUID.generate(),
      operation: operation,
      sequence: 0,
      actor_id: actor.id,
      reason: reason,
      reverts: opts[:reverts],
      decision_id: decision && decision.id,
      policy_version: decision && decision.policy_version,
      details: opts[:details] || %{}
    }
  end

  defp record(op, attrs) do
    op = %{op | sequence: op.sequence + 1}

    change =
      Repo.insert!(
        struct(
          RouteChange,
          Map.merge(attrs, %{
            operation_id: op.id,
            sequence: op.sequence,
            operation: op.operation,
            actor_id: op.actor_id,
            reason: op.reason,
            reverts_operation_id: op.reverts,
            classification_decision_id: op.decision_id,
            policy_version: op.policy_version,
            details: op.details
          })
        )
      )

    {op, change}
  end

  # The ledger row comes first, naming the id the path is about to take.
  defp insert_path(op, %Page{} = page, path) do
    %{rows: [[id]]} = Repo.query!("SELECT nextval('public_paths_id_seq')")

    {op, change} =
      record(op, %{path_id: id, after_kind: :canonical, after_destination_id: page.id})

    {op,
     Repo.insert!(%PublicPath{
       id: id,
       path: path,
       kind: :canonical,
       original_page_id: page.id,
       destination_page_id: page.id,
       last_route_change_id: change.id
     })}
  end

  defp transition_path(op, %PublicPath{} = path, kind, destination_id) do
    {op, change} =
      record(op, %{
        path_id: path.id,
        before_kind: path.kind,
        after_kind: kind,
        before_destination_id: path.destination_page_id,
        after_destination_id: destination_id
      })

    {op,
     path
     |> Ecto.Changeset.change(
       kind: kind,
       destination_page_id: destination_id,
       last_route_change_id: change.id
     )
     |> Repo.update!()}
  end

  @page_fields [:lifecycle_state, :canonical_path_id, :merged_into_page_id, :current_revision_id]

  defp transition_page(op, %Page{} = page, attrs) do
    after_state = Map.merge(Map.take(page, @page_fields), attrs)

    {op, change} =
      record(op, %{
        page_id: page.id,
        before_lifecycle: page.lifecycle_state,
        after_lifecycle: after_state.lifecycle_state,
        before_canonical_path_id: page.canonical_path_id,
        after_canonical_path_id: after_state.canonical_path_id,
        before_merged_into_id: page.merged_into_page_id,
        after_merged_into_id: after_state.merged_into_page_id,
        before_revision_id: page.current_revision_id,
        after_revision_id: after_state.current_revision_id
      })

    {op,
     page
     |> Ecto.Changeset.change(Map.put(attrs, :last_route_change_id, change.id))
     |> Repo.update!()}
  end

  # ── validation ───────────────────────────────────────────────────────────

  # The namespace must be one the page's role may use, in the page's locale,
  # and a subject or edition must be currently mapped to that family.
  defp addressable!(%Page{} = page, parsed) do
    with {:ok, namespaces} <- Address.namespaces_for(page.role),
         :ok <- same(parsed.locale, page.locale, :locale_mismatch),
         :ok <- member(parsed.namespace, namespaces, {:namespace_not_allowed, page.role}),
         {:ok, decision} <- classified(page, parsed.namespace) do
      decision
    else
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp same(value, value, _error), do: :ok
  defp same(_value, _other, error), do: {:error, error}

  defp member(value, values, error), do: if(value in values, do: :ok, else: {:error, error})

  defp classified(%Page{role: role, target_object_id: target}, namespace)
       when role in [:subject, :edition] do
    cond do
      not match?(%Object{lifecycle_state: :active}, Registry.object(target)) ->
        {:error, :target_not_active}

      true ->
        case Classifications.current(target) do
          nil ->
            {:error, :unclassified}

          %{status: :mapped, family: family} = decision ->
            if Atom.to_string(family) == namespace,
              do: {:ok, decision},
              else: {:error, {:family_mismatch, family}}

          %{status: status} ->
            {:error, {:classification_not_mapped, status}}
        end
    end
  end

  defp classified(_page, _namespace), do: {:ok, nil}

  # Allocation may be a batch job's; everything else is an approved decision.
  defp actor(opts, operation) do
    case opts[:actor_id] && Repo.get(Actor, opts[:actor_id]) do
      nil -> {:error, :actor_required}
      %Actor{actor_kind: :user} = actor -> {:ok, actor}
      %Actor{} = actor when operation == :allocate -> {:ok, actor}
      %Actor{} -> {:error, :human_approval_required}
    end
  end

  defp reason(opts) do
    case opts[:reason] |> to_string() |> String.trim() do
      "" -> {:error, :reason_required}
      reason -> {:ok, reason}
    end
  end

  defp different(same, same), do: {:error, :same_page}
  defp different(_from, _into), do: :ok

  defp owner(%PublicPath{} = path),
    do: %{path: path.path, kind: path.kind, page_id: path.destination_page_id}

  # ── locks, in the one order every operation uses ─────────────────────────

  defp lock_paths(paths) do
    paths
    |> Enum.uniq()
    |> Enum.sort()
    |> Enum.each(
      &Repo.query!("SELECT pg_advisory_xact_lock(hashtextextended($1, 0))", ["route-path:" <> &1])
    )
  end

  defp lock_pages(ids) do
    ids = ids |> Enum.reject(&is_nil/1) |> Enum.uniq()

    from(p in Page, where: p.id in ^ids, order_by: p.id, lock: "FOR UPDATE")
    |> Repo.all()
    |> Map.new(&{&1.id, &1})
  end

  defp lock_path(path) do
    Repo.one(from p in PublicPath, where: p.path == ^path, lock: "FOR UPDATE")
  end

  defp lock_path_id(id) do
    Repo.one!(from p in PublicPath, where: p.id == ^id, lock: "FOR UPDATE")
  end

  defp lock_path_ids(ids) do
    ids = ids |> Enum.reject(&is_nil/1) |> Enum.uniq()

    from(p in PublicPath, where: p.id in ^ids, order_by: p.id, lock: "FOR UPDATE")
    |> Repo.all()
    |> Map.new(&{&1.id, &1})
  end

  defp lock_paths_of(page_id) do
    Repo.all(
      from p in PublicPath,
        where: p.destination_page_id == ^page_id,
        order_by: p.id,
        lock: "FOR UPDATE"
    )
  end

  # ── bounded retries ──────────────────────────────────────────────────────

  @doc false
  # Runs `fun` in a transaction, making at most `attempts` attempts when it
  # loses a race. Public so the bound itself can be tested. Each retry emits
  # `[:devils_dictionary, :routing, :retry]` with the attempt that failed.
  def transact(fun, attempts \\ @max_attempts), do: attempt(fun, 1, attempts)

  defp attempt(fun, n, attempts) do
    Repo.transaction(fun)
  rescue
    error in [Postgrex.Error, Ecto.ConstraintError] ->
      cond do
        not retryable?(error) or Repo.in_transaction?() ->
          reraise error, __STACKTRACE__

        n < attempts ->
          :telemetry.execute([:devils_dictionary, :routing, :retry], %{attempt: n}, %{
            error: error.__struct__
          })

          attempt(fun, n + 1, attempts)

        true ->
          {:error, :allocation_conflict}
      end
  end

  defp retryable?(%Postgrex.Error{postgres: %{code: code}}), do: code in @retryable
  defp retryable?(%Ecto.ConstraintError{type: :unique}), do: true
  defp retryable?(_error), do: false
end
