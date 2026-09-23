defmodule DevilsDictionary.Claims do
  @moduledoc """
  Typed, attributed, revisioned relationships between identities.

  One directional row per claim; the inverse is derived for display. #73 is
  explicit that an independently editable mirror edge is a way for the two
  halves of one fact to disagree, so there is no `create_inverse`.

  ## The write contract

  Adding a revision takes `SELECT … FOR UPDATE` on the assertion row **first**.
  Gate 0 measured why: with the statements ordered the other way, two writers
  each compute the same next revision number and one loses to a duplicate-key
  error. Relying on a later `UPDATE` to take the lock happens to work and is not
  a contract.

  ## What the database refuses, not this module

  Incompatible endpoint kinds, out-of-range confidence, a vote on a revision of
  a different assertion, a review context belonging to another revision. All are
  foreign keys and check constraints, so `insert_all` and raw SQL are covered
  too — which matters because the linker is entirely raw SQL.
  """

  import Ecto.Query

  alias DevilsDictionary.Claims.{
    Assertion,
    AssertionEvidence,
    AssertionRevision,
    AssertionReview,
    AssertionVote,
    Predicate,
    PredicateEndpointRule,
    ReviewContext,
    ReviewContextItem
  }

  alias DevilsDictionary.Registry

  alias DevilsDictionary.Registry.{
    ContentItem,
    ContentRevision,
    Entity,
    Lexeme,
    Object,
    Sense,
    SenseRevision
  }

  alias DevilsDictionary.Repo
  alias DevilsDictionary.Sources.{Actor, Source}

  # ── predicates ────────────────────────────────────────────────────────────

  @doc "Registers a relationship type."
  def create_predicate(attrs) do
    %Predicate{} |> Predicate.changeset(attrs) |> Repo.insert()
  end

  @doc "A predicate by its key, or nil."
  def predicate(key), do: Repo.get_by(Predicate, key: key)

  @doc "A predicate by its key. Raises — importers should fail loudly on a typo."
  def predicate!(key), do: Repo.get_by!(Predicate, key: key)

  @doc """
  Declares one allowed endpoint combination.

  Subkinds default to `"-"`. Passing nil is normalised rather than stored,
  because a NULL in this composite key would silently disable the foreign key
  that enforces it.
  """
  def allow_endpoints(%Predicate{id: id}, subject_kind, object_kind, opts \\ []) do
    %PredicateEndpointRule{}
    |> PredicateEndpointRule.changeset(%{
      predicate_id: id,
      subject_kind: to_string(subject_kind),
      subject_subkind: to_string(opts[:subject_subkind] || PredicateEndpointRule.none()),
      object_kind: to_string(object_kind),
      object_subkind: to_string(opts[:object_subkind] || PredicateEndpointRule.none())
    })
    |> Repo.insert(on_conflict: :nothing)
  end

  @doc "Every endpoint combination a predicate allows."
  def endpoint_rules(key) do
    Repo.all(
      from r in PredicateEndpointRule,
        join: p in assoc(r, :predicate),
        where: p.key == ^key,
        order_by: [r.subject_kind, r.subject_subkind, r.object_kind, r.object_subkind]
    )
  end

  # ── asserting ─────────────────────────────────────────────────────────────

  @doc """
  Records a claim: the assertion identity and its first revision, current.

  `origin_key` with a `source_id` makes a re-import idempotent — the same
  source-native claim seen twice is one assertion, not two.
  """
  def assert(subject_id, predicate_key, object_id, attrs \\ %{}) do
    predicate = predicate!(predicate_key)

    Repo.transaction(fn ->
      assertion =
        %Assertion{}
        |> Assertion.changeset(Map.take(attrs, assertion_keys()))
        |> Repo.insert!()

      revision_attrs =
        attrs
        |> Map.drop(assertion_keys())
        |> Map.merge(%{
          assertion_id: assertion.id,
          revision_number: 1,
          subject_object_id: subject_id,
          predicate_id: predicate.id,
          object_object_id: object_id,
          is_current: true
        })

      case %AssertionRevision{} |> AssertionRevision.changeset(revision_attrs) |> Repo.insert() do
        {:ok, revision} -> %{assertion | revisions: [revision]}
        {:error, changeset} -> Repo.rollback(changeset)
      end
    end)
  end

  defp assertion_keys, do: [:source_id, :origin_key, :origin_actor_id, :submitted_by_actor_id]

  # Everything a revision means, as opposed to everything it is. `assertion_id`,
  # `revision_number` and `is_current` are bookkeeping and are set here; the
  # denormalised endpoint kinds are filled by a database trigger. Every other
  # column carries forward, because a revision that changes only the rationale
  # must still mean what it meant — the audit found `valid_from`, `valid_to`,
  # `jurisdiction_entity_id`, `context_object_id` and `metadata` silently
  # dropped, so a date-bounded claim became unbounded on a typo fix.
  @carried [
    :subject_object_id,
    :predicate_id,
    :object_object_id,
    :rationale,
    :valid_from,
    :valid_to,
    :language_tag,
    :jurisdiction_entity_id,
    :context_object_id,
    :method,
    :confidence,
    :lifecycle_state,
    :metadata
  ]

  @doc "The context columns `revise/2` carries forward from the current revision."
  def carried_fields, do: @carried

  @doc """
  Adds a revision to an existing claim and makes it current.

  Changing endpoints or meaning is a revision, never an edit: a review or a vote
  cites a revision id, so this is what stops old approval from carrying forward
  onto a claim that now says something else.

  Everything in `carried_fields/0` carries forward unless `attrs` names it.
  Naming it with `nil` clears it — "absent" and "present and nil" are different
  instructions, which is why this reads keys rather than values.
  """
  def revise(assertion_id, attrs) do
    attrs = normalize(attrs)

    Repo.transaction(fn ->
      Repo.query!("SELECT 1 FROM assertions WHERE id = $1 FOR UPDATE", [assertion_id])

      current = current_revision(assertion_id)

      next =
        Repo.one(
          from r in AssertionRevision,
            where: r.assertion_id == ^assertion_id,
            select: max(r.revision_number)
        ) + 1

      # Only currentness moves. The outgoing revision's `lifecycle_state` is
      # what it asserted, and rewriting it to `superseded` would destroy that —
      # #74 is explicit that currentness and lifecycle are separate columns.
      from(r in AssertionRevision, where: r.assertion_id == ^assertion_id and r.is_current)
      |> Repo.update_all(set: [is_current: false])

      revision_attrs =
        current
        |> Map.take(@carried)
        |> Map.merge(attrs)
        |> Map.merge(%{
          assertion_id: assertion_id,
          revision_number: next,
          is_current: true
        })

      case %AssertionRevision{} |> AssertionRevision.changeset(revision_attrs) |> Repo.insert() do
        {:ok, revision} -> revision
        {:error, changeset} -> Repo.rollback(changeset)
      end
    end)
  end

  @doc """
  Withdraws a claim by adding a revision that says so.

  Not a delete and not a lifecycle flip on the existing revision: the current
  revision reads `withdrawn` while the history that shows the claim was once
  made stays exactly as it was.

  A `:reason` replaces the rationale; omitting one leaves the rationale alone
  rather than erasing it, since `revise/2` treats a named `nil` as a clear.
  """
  def withdraw(assertion_id, opts \\ []) do
    attrs = %{lifecycle_state: :withdrawn}
    attrs = if opts[:reason], do: Map.put(attrs, :rationale, opts[:reason]), else: attrs

    revise(assertion_id, attrs)
  end

  @doc """
  Puts a withdrawn or rejected claim back into force, as a new revision.

  The counterpart of `withdraw/2`. It exists because `lifecycle_state` now
  carries forward: without it, reviving a claim would mean relying on a caller
  to remember the column's name.
  """
  def reinstate(assertion_id, opts \\ []) do
    attrs = %{lifecycle_state: :active}
    attrs = if opts[:reason], do: Map.put(attrs, :rationale, opts[:reason]), else: attrs

    revise(assertion_id, attrs)
  end

  defp normalize(attrs) when is_list(attrs), do: normalize(Map.new(attrs))

  defp normalize(attrs) when is_map(attrs) do
    Map.new(attrs, fn
      {k, v} when is_binary(k) -> {String.to_existing_atom(k), v}
      {k, v} -> {k, v}
    end)
  end

  # ── reading ───────────────────────────────────────────────────────────────

  @doc "The current revision of a claim, or nil."
  def current_revision(assertion_id) do
    Repo.one(
      from r in AssertionRevision,
        where: r.assertion_id == ^assertion_id and r.is_current
    )
  end

  @doc "Every revision of a claim, oldest first."
  def history(assertion_id) do
    Repo.all(
      from r in AssertionRevision,
        where: r.assertion_id == ^assertion_id,
        order_by: r.revision_number
    )
  end

  @doc """
  Current claims where this object is the subject. **A public read.**

  Served by the partial `is_current` index — Gate 0 measured 0.256 ms p95 on the
  1,229-degree node against 2.576 ms for a pointer join. Bounded by `:limit`
  because #73 forbids an unbounded "everything related" query on page load.

  Options: `:predicate`, `:exclude_predicates`, `:subject_kind`,
  `:lifecycle_state` (`:any` for all), `:limit`, `:after` (a cursor from
  `next_cursor/1`), and `:visibility` — `:public` by default, `:internal` for a
  review queue or a health check. See `visible/2`.
  """
  def outgoing(subject_id, opts \\ [])

  # Many subjects in one read, for a reader that renders many things at once —
  # a shelf's creator lines (#164 C5). The same filters and visibility; the
  # limit is the caller's to size, because a page of claims across a dozen
  # subjects is not a page of one subject's.
  def outgoing(subject_ids, opts) when is_list(subject_ids) do
    case subject_ids |> Registry.canonical_ids() |> Map.values() |> Enum.uniq() do
      [] ->
        []

      ids ->
        AssertionRevision
        |> where([r], r.subject_object_id in ^ids and r.is_current)
        |> common_filters(opts)
        |> page(opts)
    end
  end

  def outgoing(subject_id, opts) do
    subject_id |> outgoing_query(opts) |> page(opts)
  end

  @doc """
  Current claims where this object is the object. **A public read.**

  The same claim, read from the other end. #73: "The same claim revision appears
  from either endpoint" — there is one row, so they cannot disagree. That
  includes being hidden: the visibility filter is the same one, applied before
  the cursor and before `count_incoming/2`, so a rejected claim is missing from
  the counts too and not merely from the first page.
  """
  def incoming(object_id, opts \\ []) do
    object_id |> incoming_query(opts) |> page(opts)
  end

  @doc "How many claims `outgoing/2` would return, unpaginated."
  def count_outgoing(subject_id, opts \\ []),
    do: subject_id |> outgoing_query(opts) |> Repo.aggregate(:count, :id)

  @doc "How many claims `incoming/2` would return, unpaginated."
  def count_incoming(object_id, opts \\ []),
    do: object_id |> incoming_query(opts) |> Repo.aggregate(:count, :id)

  @doc """
  The cursor to pass as `:after` for the next page, or nil at the end.

  Keyset, not offset: the ordering is `(id)` on a table whose rows are only ever
  inserted, so a page boundary cannot move under a concurrent writer and no row
  is skipped or repeated.
  """
  def next_cursor([]), do: nil
  def next_cursor(revisions), do: List.last(revisions).id

  defp outgoing_query(subject_id, opts) do
    query =
      case Registry.canonical_family(subject_id) do
        [canonical_id] ->
          where(
            AssertionRevision,
            [r],
            r.subject_object_id == ^canonical_id and r.is_current
          )

        subject_ids ->
          where(AssertionRevision, [r], r.subject_object_id in ^subject_ids and r.is_current)
      end

    common_filters(query, opts)
  end

  defp incoming_query(object_id, opts) do
    query =
      case Registry.canonical_family(object_id) do
        [canonical_id] ->
          where(
            AssertionRevision,
            [r],
            r.object_object_id == ^canonical_id and r.is_current
          )

        object_ids ->
          where(AssertionRevision, [r], r.object_object_id in ^object_ids and r.is_current)
      end

    common_filters(query, opts)
  end

  defp common_filters(query, opts) do
    query
    |> filter_predicate(opts[:predicate])
    |> exclude_predicates(opts[:exclude_predicates])
    |> filter_subject_kind(opts[:subject_kind])
    |> filter_state(opts[:lifecycle_state] || :active)
    |> visible(opts[:visibility] || :public)
  end

  defp filter_subject_kind(query, nil), do: query
  defp filter_subject_kind(query, kind), do: where(query, [r], r.subject_kind == ^to_string(kind))

  defp exclude_predicates(query, nil), do: query
  defp exclude_predicates(query, []), do: query

  defp exclude_predicates(query, keys) do
    predicate_ids = from p in Predicate, where: p.key in ^keys, select: p.id
    where(query, [r], r.predicate_id not in subquery(predicate_ids))
  end

  # Filters, then cursor, then limit -- in that order, so the page is a page of
  # what the reader is allowed to see rather than a filtered page.
  defp page(query, opts) do
    query
    |> after_cursor(opts[:after])
    |> order_by([r], asc: r.id)
    |> limit(^(opts[:limit] || 100))
    |> preload(:predicate)
    |> Repo.all()
  end

  defp after_cursor(query, nil), do: query
  defp after_cursor(query, id), do: where(query, [r], r.id > ^id)

  @doc """
  Applies the editorial visibility policy.

  `:public` hides a claim revision whose most recent review decision is
  `rejected` or `withdrawn`. `:internal` hides nothing and is what a review
  queue, an importer or a health check reads.

  Lifecycle and review are separate axes and are filtered separately: a claim
  whose current revision is `active` can still have been rejected by a
  reviewer, and #74 requires that such a claim appear from **neither** endpoint.
  The decision is derived from `assertion_reviews` rather than stored, so no
  importer can write it — the same property `review_state/1` relies on.
  """
  def visible(query, :internal), do: query

  def visible(query, :public) do
    latest_review_states =
      from review in AssertionReview,
        distinct: review.assertion_revision_id,
        order_by: [
          asc: review.assertion_revision_id,
          desc: review.inserted_at,
          desc: review.id
        ],
        select: %{
          assertion_revision_id: review.assertion_revision_id,
          decision: review.decision
        }

    query
    |> join(:left, [r], review in subquery(latest_review_states),
      on: review.assertion_revision_id == r.id,
      as: :latest_review
    )
    |> where(
      [latest_review: review],
      is_nil(review.decision) or review.decision not in [:rejected, :withdrawn]
    )
    |> where(
      [r],
      fragment(
        """
        NOT EXISTS (
          SELECT 1
            FROM objects endpoint
           WHERE endpoint.id IN (?, ?, ?, ?)
             AND endpoint.lifecycle_state IN ('retired', 'split')
        )
        """,
        r.subject_object_id,
        r.object_object_id,
        r.context_object_id,
        r.jurisdiction_entity_id
      )
    )
    |> where(
      [r],
      fragment(
        """
        NOT EXISTS (
          SELECT 1
            FROM content_revisions content
           WHERE content.is_current
             AND content.content_id IN (?, ?, ?)
             AND content.lifecycle_state <> 'active'
        )
        """,
        r.subject_object_id,
        r.object_object_id,
        r.context_object_id
      )
    )
    |> where(
      [r],
      fragment(
        """
        NOT EXISTS (
          SELECT 1
            FROM sense_revisions sense
           WHERE sense.is_current
             AND sense.sense_id IN (?, ?, ?)
             AND sense.lifecycle_state <> 'active'
        )
        """,
        r.subject_object_id,
        r.object_object_id,
        r.context_object_id
      )
    )
  end

  @doc "The review decisions that hide a claim from a public read."
  def hidden_decisions, do: [:rejected, :withdrawn]

  @doc "Whether one revision passes the same policy as public list/count reads."
  def publicly_visible_revision?(%AssertionRevision{id: id}) do
    AssertionRevision
    |> where([r], r.id == ^id and r.lifecycle_state == :active)
    |> visible(:public)
    |> Repo.exists?()
  end

  def publicly_visible_revision?(_), do: false

  @doc "The revision ids that pass the public visibility policy, in one query."
  def publicly_visible_revision_ids(ids) when is_list(ids) do
    AssertionRevision
    |> where([r], r.id in ^ids and r.lifecycle_state == :active)
    |> visible(:public)
    |> select([r], r.id)
    |> Repo.all()
    |> MapSet.new()
  end

  defp filter_predicate(query, nil), do: query

  defp filter_predicate(query, keys) when is_list(keys) do
    from r in query,
      join: p in assoc(r, :predicate),
      where: p.key in ^Enum.map(keys, &to_string/1)
  end

  defp filter_predicate(query, key), do: filter_predicate(query, [key])

  defp filter_state(query, :any), do: query
  defp filter_state(query, state), do: where(query, [r], r.lifecycle_state == ^state)

  # ── evidence ──────────────────────────────────────────────────────────────

  @doc """
  Attaches evidence to a claim revision.

  `role: :contradicts` is how counterevidence is kept beside the claim rather
  than being an absence of support.
  """
  def add_evidence(revision_id, attrs) do
    %AssertionEvidence{}
    |> AssertionEvidence.changeset(
      Map.merge(normalize(attrs), %{assertion_revision_id: revision_id})
    )
    |> Repo.insert()
  end

  @doc "Everything cited for or against a claim revision."
  def evidence(revision_id) do
    Repo.all(
      from e in AssertionEvidence,
        where: e.assertion_revision_id == ^revision_id,
        order_by: [e.evidence_role, e.id]
    )
  end

  # ── review ────────────────────────────────────────────────────────────────

  @doc """
  Pins what a reviewer is looking at, so a later edit cannot inherit approval.

  `items` is a list of `{role, [content_revision_id: id]}` or
  `{role, [sense_revision_id: id]}`. An entity endpoint contributes no item;
  that is not the same as an item with no target.
  """
  def open_review_context(revision_id, items \\ []) do
    Repo.transaction(fn ->
      snapshot = review_snapshot(revision_id, items)

      context =
        %ReviewContext{}
        |> ReviewContext.changeset(%{
          assertion_revision_id: revision_id,
          snapshot: snapshot,
          fingerprint: snapshot_fingerprint(snapshot)
        })
        |> Repo.insert!()

      for {role, target} <- items do
        %ReviewContextItem{}
        |> ReviewContextItem.changeset(
          target
          |> Map.new()
          |> Map.merge(%{context_id: context.id, endpoint_role: role})
        )
        |> Repo.insert!()
      end

      context
    end)
  end

  @doc """
  Records an editorial decision. Append-only.

  An importer cannot undo this: reviews are their own rows and the effective
  state is derived from the sequence, which is the fix for a `rejected` link
  returning to `auto` when its linking rung reran.
  """
  def review(revision_id, decision, attrs \\ %{}) do
    %AssertionReview{}
    |> AssertionReview.changeset(
      Map.merge(normalize(attrs), %{assertion_revision_id: revision_id, decision: decision})
    )
    |> Repo.insert()
  end

  @doc """
  The effective review state of a claim revision, derived from its reviews.

  Deterministic: the most recent decision wins, and `:needs_review` when there
  are none. Derived rather than stored, so no importer can write it.
  """
  def review_state(revision_id) do
    Repo.one(
      from r in AssertionReview,
        where: r.assertion_revision_id == ^revision_id,
        order_by: [desc: r.inserted_at, desc: r.id],
        limit: 1,
        select: r.decision
    ) || :needs_review
  end

  @doc """
  The review state that is safe to present beside the currently displayed text.

  The append-only decision remains available through `review_state/1`. An
  accepted or disputed decision is presented as `:changed_since_review` when
  its immutable review snapshot no longer matches current endpoint revisions,
  evidence or attribution. Rejected/withdrawn decisions remain hiding
  decisions, regardless of freshness.
  """
  def display_review_state(revision_id) do
    case latest_review(revision_id) do
      nil ->
        :needs_review

      %{decision: decision} when decision in [:rejected, :withdrawn, :needs_review] ->
        decision

      %{decision: decision, review_context_id: context_id} ->
        if review_context_fresh?(revision_id, context_id),
          do: decision,
          else: :changed_since_review
    end
  end

  @doc "The display-safe review states for many revisions, with bounded snapshot reads."
  def display_review_states([]), do: %{}

  def display_review_states(revision_ids) when is_list(revision_ids) do
    ids = Enum.uniq(revision_ids)

    latest =
      Repo.all(
        from review in AssertionReview,
          where: review.assertion_revision_id in ^ids,
          distinct: review.assertion_revision_id,
          order_by: [asc: review.assertion_revision_id, desc: review.inserted_at, desc: review.id]
      )
      |> Map.new(&{&1.assertion_revision_id, &1})

    context_ids =
      latest
      |> Map.values()
      |> Enum.map(& &1.review_context_id)
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()

    contexts =
      if context_ids == [] do
        %{}
      else
        Repo.all(from context in ReviewContext, where: context.id in ^context_ids)
        |> Map.new(&{&1.id, &1})
      end

    fresh_ids =
      latest
      |> Enum.filter(fn {_id, review} ->
        case Map.get(contexts, review.review_context_id) do
          %ReviewContext{fingerprint: fingerprint} when is_binary(fingerprint) -> true
          _ -> false
        end
      end)
      |> Enum.map(&elem(&1, 0))

    snapshots = batch_review_snapshots(fresh_ids)

    Map.new(ids, fn id ->
      state =
        case Map.get(latest, id) do
          nil ->
            :needs_review

          %{decision: decision} when decision in [:rejected, :withdrawn, :needs_review] ->
            decision

          %{decision: decision, review_context_id: context_id} ->
            with %ReviewContext{fingerprint: fingerprint} when is_binary(fingerprint) <-
                   Map.get(contexts, context_id),
                 snapshot when is_map(snapshot) <- Map.get(snapshots, id),
                 true <- snapshot_fingerprint(snapshot) == fingerprint do
              decision
            else
              _ -> :changed_since_review
            end
        end

      {id, state}
    end)
  end

  @doc "Whether a review context still describes exactly what is displayed now."
  def review_context_fresh?(_revision_id, nil), do: false

  def review_context_fresh?(revision_id, context_id) do
    case Repo.get(ReviewContext, context_id) do
      %ReviewContext{fingerprint: fingerprint} when is_binary(fingerprint) ->
        snapshot_fingerprint(review_snapshot(revision_id)) == fingerprint

      _ ->
        false
    end
  end

  @doc "The exact versioned content/sense endpoint items currently displayed for a revision."
  def current_context_items(%AssertionRevision{} = revision) do
    roles = [
      {:subject, revision.subject_object_id},
      {:object, revision.object_object_id},
      {:context, revision.context_object_id}
    ]

    ids = roles |> Enum.map(&elem(&1, 1)) |> Enum.reject(&is_nil/1) |> Enum.uniq()

    targets =
      Repo.all(
        from r in ContentRevision,
          where: r.content_id in ^ids and r.is_current,
          select: {r.content_id, %{content_revision_id: r.id}}
      )
      |> Map.new()
      |> Map.merge(
        Repo.all(
          from r in SenseRevision,
            where: r.sense_id in ^ids and r.is_current,
            select: {r.sense_id, %{sense_revision_id: r.id}}
        )
        |> Map.new()
      )

    roles
    |> Enum.flat_map(fn {role, id} ->
      case targets[id] do
        nil -> []
        target -> [{role, Enum.sort(target)}]
      end
    end)
  end

  @doc "A client-safe token for every meaningful input currently shown to a reviewer."
  def current_review_input(%AssertionRevision{} = revision) do
    items = current_context_items(revision)
    snapshot = review_snapshot(revision.id, items)

    %{
      items: items,
      fingerprint: snapshot_fingerprint(snapshot)
    }
  end

  @doc "An immutable, JSON-safe description of what a reviewer saw."
  def review_snapshot(revision_id, items \\ nil) do
    revision = Repo.get!(AssertionRevision, revision_id)
    assertion = Repo.get!(Assertion, revision.assertion_id)
    items = items || current_context_items(revision)

    %{
      "assertion" => %{
        "origin_actor_id" => assertion.origin_actor_id,
        "submitted_by_actor_id" => assertion.submitted_by_actor_id,
        "source_id" => assertion.source_id,
        "origin_key" => assertion.origin_key,
        "actors" => snapshot_actors(assertion)
      },
      "revision" => snapshot_revision(revision),
      "displayed_items" => snapshot_items(items),
      "displayed_endpoints" => snapshot_endpoints(revision),
      "evidence" => snapshot_evidence(revision.id)
    }
  end

  defp latest_review(revision_id) do
    Repo.one(
      from r in AssertionReview,
        where: r.assertion_revision_id == ^revision_id,
        order_by: [desc: r.inserted_at, desc: r.id],
        limit: 1
    )
  end

  defp batch_review_snapshots([]), do: %{}

  defp batch_review_snapshots(revision_ids) do
    revisions =
      Repo.all(from revision in AssertionRevision, where: revision.id in ^revision_ids)
      |> Map.new(&{&1.id, &1})

    assertions =
      revisions
      |> Map.values()
      |> Enum.map(& &1.assertion_id)
      |> Enum.uniq()
      |> then(fn ids -> Repo.all(from assertion in Assertion, where: assertion.id in ^ids) end)
      |> Map.new(&{&1.id, &1})

    actors = batch_snapshot_actors(assertions)

    endpoint_ids =
      revisions
      |> Map.values()
      |> Enum.flat_map(&revision_endpoint_ids/1)
      |> Enum.uniq()

    canonical = Registry.canonical_ids(endpoint_ids)
    display = endpoint_display_rows(canonical |> Map.values() |> Enum.uniq())
    items = batch_context_items(revisions)
    evidence = batch_snapshot_evidence(Map.keys(revisions))

    Map.new(revisions, fn {revision_id, revision} ->
      assertion = Map.fetch!(assertions, revision.assertion_id)

      snapshot = %{
        "assertion" => %{
          "origin_actor_id" => assertion.origin_actor_id,
          "submitted_by_actor_id" => assertion.submitted_by_actor_id,
          "source_id" => assertion.source_id,
          "origin_key" => assertion.origin_key,
          "actors" => Map.get(actors, assertion.id, [])
        },
        "revision" => snapshot_revision(revision),
        "displayed_items" => snapshot_items(Map.get(items, revision_id, [])),
        "displayed_endpoints" => snapshot_endpoints(revision, canonical, display),
        "evidence" => Map.get(evidence, revision_id, [])
      }

      {revision_id, snapshot}
    end)
  end

  defp batch_snapshot_actors(assertions) do
    actor_ids =
      assertions
      |> Map.values()
      |> Enum.flat_map(&[&1.origin_actor_id, &1.submitted_by_actor_id])
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()

    actors =
      Repo.all(from actor in Actor, where: actor.id in ^actor_ids)
      |> Map.new(&{&1.id, &1})

    canonical =
      actors
      |> Map.values()
      |> Enum.map(& &1.entity_id)
      |> Enum.reject(&is_nil/1)
      |> Registry.canonical_ids()

    Map.new(assertions, fn {assertion_id, assertion} ->
      views =
        [assertion.origin_actor_id, assertion.submitted_by_actor_id]
        |> Enum.reject(&is_nil/1)
        |> Enum.uniq()
        |> Enum.map(&Map.fetch!(actors, &1))
        |> Enum.map(fn actor ->
          %{
            "id" => actor.id,
            "actor_kind" => to_string(actor.actor_kind),
            "label" => actor.label,
            "user_id" => actor.user_id,
            "bot_source_id" => actor.bot_source_id,
            "entity_id" => actor.entity_id,
            "canonical_entity_id" => actor.entity_id && Map.fetch!(canonical, actor.entity_id)
          }
        end)
        |> Enum.sort_by(& &1["id"])

      {assertion_id, views}
    end)
  end

  defp batch_context_items(revisions) do
    endpoint_ids =
      revisions
      |> Map.values()
      |> Enum.flat_map(fn revision ->
        [revision.subject_object_id, revision.object_object_id, revision.context_object_id]
      end)
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()

    targets =
      Repo.all(
        from revision in ContentRevision,
          where: revision.content_id in ^endpoint_ids and revision.is_current,
          select: {revision.content_id, %{content_revision_id: revision.id}}
      )
      |> Map.new()
      |> Map.merge(
        Repo.all(
          from revision in SenseRevision,
            where: revision.sense_id in ^endpoint_ids and revision.is_current,
            select: {revision.sense_id, %{sense_revision_id: revision.id}}
        )
        |> Map.new()
      )

    Map.new(revisions, fn {revision_id, revision} ->
      roles = [
        {:subject, revision.subject_object_id},
        {:object, revision.object_object_id},
        {:context, revision.context_object_id}
      ]

      items =
        Enum.flat_map(roles, fn {role, id} ->
          case targets[id] do
            nil -> []
            target -> [{role, Enum.sort(target)}]
          end
        end)

      {revision_id, items}
    end)
  end

  defp batch_snapshot_evidence(revision_ids) do
    rows =
      Repo.all(
        from item in AssertionEvidence,
          where: item.assertion_revision_id in ^revision_ids,
          order_by: [item.assertion_revision_id, item.evidence_role, item.id]
      )

    content_ids =
      rows |> Enum.map(& &1.content_revision_id) |> Enum.reject(&is_nil/1) |> Enum.uniq()

    sense_ids = rows |> Enum.map(& &1.sense_revision_id) |> Enum.reject(&is_nil/1) |> Enum.uniq()

    cited_content =
      Repo.all(from revision in ContentRevision, where: revision.id in ^content_ids)
      |> Map.new(&{&1.id, &1.content_id})

    cited_senses =
      Repo.all(from revision in SenseRevision, where: revision.id in ^sense_ids)
      |> Map.new(&{&1.id, &1.sense_id})

    current_content =
      Repo.all(
        from revision in ContentRevision,
          where: revision.content_id in ^Map.values(cited_content) and revision.is_current
      )
      |> Map.new(&{&1.content_id, &1})

    current_senses =
      Repo.all(
        from revision in SenseRevision,
          where: revision.sense_id in ^Map.values(cited_senses) and revision.is_current
      )
      |> Map.new(&{&1.sense_id, &1})

    rows
    |> Enum.map(fn item ->
      target_current =
        cond do
          item.content_revision_id ->
            current = current_content[Map.fetch!(cited_content, item.content_revision_id)]

            %{
              "revision_id" => current && current.id,
              "lifecycle_state" => current && to_string(current.lifecycle_state)
            }

          item.sense_revision_id ->
            current = current_senses[Map.fetch!(cited_senses, item.sense_revision_id)]

            %{
              "revision_id" => current && current.id,
              "lifecycle_state" => current && to_string(current.lifecycle_state)
            }

          true ->
            nil
        end

      {item.assertion_revision_id,
       %{
         "id" => item.id,
         "role" => to_string(item.evidence_role),
         "source_record_revision_id" => item.source_record_revision_id,
         "content_revision_id" => item.content_revision_id,
         "sense_revision_id" => item.sense_revision_id,
         "locator" => item.locator,
         "attribution_text" => item.attribution_text,
         "target_current" => target_current
       }}
    end)
    |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
  end

  @snapshot_revision_fields [
    :subject_object_id,
    :predicate_id,
    :object_object_id,
    :rationale,
    :valid_from,
    :valid_to,
    :language_tag,
    :jurisdiction_entity_id,
    :context_object_id,
    :method,
    :confidence,
    :lifecycle_state,
    :metadata
  ]

  defp snapshot_revision(revision) do
    Map.new(@snapshot_revision_fields, fn field ->
      {to_string(field), snapshot_value(Map.fetch!(revision, field))}
    end)
  end

  defp snapshot_endpoints(revision) do
    roles = [
      {"subject", revision.subject_object_id},
      {"object", revision.object_object_id},
      {"context", revision.context_object_id},
      {"jurisdiction", revision.jurisdiction_entity_id}
    ]

    original_ids = roles |> Enum.map(&elem(&1, 1)) |> Enum.reject(&is_nil/1) |> Enum.uniq()
    canonical = canonical_object_ids(original_ids)
    display = endpoint_display_rows(canonical |> Map.values() |> Enum.uniq())

    roles
    |> Enum.reject(fn {_role, id} -> is_nil(id) end)
    |> Enum.map(fn {role, id} ->
      canonical_id = Map.fetch!(canonical, id)

      %{
        "role" => role,
        "object_id" => id,
        "canonical_object_id" => canonical_id,
        "display" => Map.get(display, canonical_id)
      }
    end)
  end

  defp snapshot_endpoints(revision, canonical, display) do
    revision
    |> endpoint_roles()
    |> Enum.map(fn {role, id} ->
      canonical_id = Map.fetch!(canonical, id)

      %{
        "role" => role,
        "object_id" => id,
        "canonical_object_id" => canonical_id,
        "display" => Map.get(display, canonical_id)
      }
    end)
  end

  defp revision_endpoint_ids(revision), do: revision |> endpoint_roles() |> Enum.map(&elem(&1, 1))

  defp endpoint_roles(revision) do
    [
      {"subject", revision.subject_object_id},
      {"object", revision.object_object_id},
      {"context", revision.context_object_id},
      {"jurisdiction", revision.jurisdiction_entity_id}
    ]
    |> Enum.reject(fn {_role, id} -> is_nil(id) end)
  end

  defp canonical_object_ids([]), do: %{}

  defp canonical_object_ids(ids) do
    objects =
      Repo.all(from object in Object, where: object.id in ^ids)
      |> Map.new(&{&1.id, &1})

    Map.new(ids, fn id ->
      canonical_id =
        case objects[id] do
          %Object{lifecycle_state: :merged} -> Registry.canonical_id(id)
          _ -> id
        end

      {id, canonical_id}
    end)
  end

  defp endpoint_display_rows([]), do: %{}

  defp endpoint_display_rows(ids) do
    Repo.all(
      from object in Object,
        left_join: entity in Entity,
        on: entity.object_id == object.id,
        left_join: lexeme in Lexeme,
        on: lexeme.object_id == object.id,
        left_join: sense in Sense,
        on: sense.object_id == object.id,
        left_join: sense_lexeme in Lexeme,
        on: sense_lexeme.object_id == sense.lexeme_id,
        left_join: sense_revision in SenseRevision,
        on: sense_revision.sense_id == sense.object_id and sense_revision.is_current,
        left_join: sense_source in Source,
        on: sense_source.id == sense.source_id,
        left_join: content in ContentItem,
        on: content.object_id == object.id,
        left_join: content_revision in ContentRevision,
        on: content_revision.content_id == content.object_id and content_revision.is_current,
        left_join: content_source in Source,
        on: content_source.id == content.source_id,
        where: object.id in ^ids,
        select:
          {object.id,
           %{
             "object_kind" => object.kind,
             "lifecycle_state" => object.lifecycle_state,
             "entity_kind" => entity.entity_kind,
             "entity_label" => entity.preferred_label,
             "entity_description" => entity.description,
             "entity_qid" =>
               fragment(
                 "(SELECT external_id FROM external_identifiers WHERE object_id = ? AND namespace = 'wikidata' AND status = 'verified' ORDER BY external_id LIMIT 1)",
                 entity.object_id
               ),
             "lexeme_language" => lexeme.language_tag,
             "lexeme_lemma" => lexeme.lemma,
             "lexeme_part_of_speech" => lexeme.part_of_speech,
             "lexeme_slug" => lexeme.slug,
             "sense_revision_id" => sense_revision.id,
             "sense_lexeme_lemma" => sense_lexeme.lemma,
             "sense_lexeme_slug" => sense_lexeme.slug,
             "sense_source_id" => sense_source.id,
             "sense_source_name" => sense_source.name,
             "content_revision_id" => content_revision.id,
             "content_kind" => content.content_kind,
             "content_source_id" => content_source.id,
             "content_source_name" => content_source.name
           }}
    )
    |> Map.new(fn {id, view} ->
      {id, Map.new(view, fn {key, value} -> {key, snapshot_value(value)} end)}
    end)
  end

  defp snapshot_actors(assertion) do
    ids =
      [assertion.origin_actor_id, assertion.submitted_by_actor_id]
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()

    actors = Repo.all(from actor in Actor, where: actor.id in ^ids)

    canonical =
      actors
      |> Enum.map(& &1.entity_id)
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()
      |> canonical_object_ids()

    actors
    |> Enum.map(fn actor ->
      %{
        "id" => actor.id,
        "actor_kind" => to_string(actor.actor_kind),
        "label" => actor.label,
        "user_id" => actor.user_id,
        "bot_source_id" => actor.bot_source_id,
        "entity_id" => actor.entity_id,
        "canonical_entity_id" => actor.entity_id && Map.fetch!(canonical, actor.entity_id)
      }
    end)
    |> Enum.sort_by(& &1["id"])
  end

  defp snapshot_items(items) do
    items
    |> Enum.map(fn {role, target} ->
      target = Map.new(target)

      %{
        "role" => to_string(role),
        "content_revision_id" => target[:content_revision_id] || target["content_revision_id"],
        "sense_revision_id" => target[:sense_revision_id] || target["sense_revision_id"]
      }
    end)
    |> Enum.sort_by(&{&1["role"], &1["content_revision_id"] || 0, &1["sense_revision_id"] || 0})
  end

  defp snapshot_evidence(revision_id) do
    evidence(revision_id)
    |> Enum.map(fn item ->
      %{
        "id" => item.id,
        "role" => to_string(item.evidence_role),
        "source_record_revision_id" => item.source_record_revision_id,
        "content_revision_id" => item.content_revision_id,
        "sense_revision_id" => item.sense_revision_id,
        "locator" => item.locator,
        "attribution_text" => item.attribution_text,
        "target_current" => evidence_target_current(item)
      }
    end)
  end

  defp evidence_target_current(%{content_revision_id: id}) when not is_nil(id) do
    cited = Repo.get!(ContentRevision, id)
    current = Registry.current_content_revision(cited.content_id)

    %{
      "revision_id" => current && current.id,
      "lifecycle_state" => current && to_string(current.lifecycle_state)
    }
  end

  defp evidence_target_current(%{sense_revision_id: id}) when not is_nil(id) do
    cited = Repo.get!(SenseRevision, id)
    current = Registry.current_sense_revision(cited.sense_id)

    %{
      "revision_id" => current && current.id,
      "lifecycle_state" => current && to_string(current.lifecycle_state)
    }
  end

  defp evidence_target_current(_), do: nil

  defp snapshot_value(%DateTime{} = value), do: DateTime.to_iso8601(value)
  defp snapshot_value(value) when is_atom(value), do: to_string(value)
  defp snapshot_value(value), do: value

  defp snapshot_fingerprint(snapshot) do
    :sha256
    |> :crypto.hash(Jason.encode!(snapshot))
    |> Base.encode16(case: :lower)
  end

  @doc "Every review of a claim revision, newest first."
  def reviews(revision_id) do
    Repo.all(
      from r in AssertionReview,
        where: r.assertion_revision_id == ^revision_id,
        order_by: [desc: r.inserted_at, desc: r.id]
    )
  end

  # ── votes ─────────────────────────────────────────────────────────────────

  @doc """
  Records a relevance vote on a claim revision.

  Relevance only. A vote is not a truth claim and not a source, and it can never
  mutate a definition — the four dimensions #73 lists stay four.
  """
  def vote(revision_id, actor_id, value, attrs \\ %{}) do
    %AssertionVote{}
    |> AssertionVote.changeset(
      Map.merge(normalize(attrs), %{
        assertion_revision_id: revision_id,
        actor_id: actor_id,
        value: value
      })
    )
    |> Repo.insert(
      on_conflict: {:replace, [:value, :updated_at]},
      conflict_target: [:assertion_revision_id, :actor_id]
    )
  end

  @doc "The net relevance score of a claim revision."
  def score(revision_id) do
    Repo.one(
      from v in AssertionVote,
        where: v.assertion_revision_id == ^revision_id,
        select: coalesce(sum(v.value), 0)
    )
  end
end
