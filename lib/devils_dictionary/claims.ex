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

  alias DevilsDictionary.Repo

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

  Options: `:predicate`, `:lifecycle_state` (`:any` for all), `:limit`,
  `:after` (a cursor from `next_cursor/1`), and `:visibility` — `:public` by
  default, `:internal` for a review queue or a health check. See `visible/2`.
  """
  def outgoing(subject_id, opts \\ []) do
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
    AssertionRevision
    |> where([r], r.subject_object_id == ^subject_id and r.is_current)
    |> common_filters(opts)
  end

  defp incoming_query(object_id, opts) do
    AssertionRevision
    |> where([r], r.object_object_id == ^object_id and r.is_current)
    |> common_filters(opts)
  end

  defp common_filters(query, opts) do
    query
    |> filter_predicate(opts[:predicate])
    |> filter_state(opts[:lifecycle_state] || :active)
    |> visible(opts[:visibility] || :public)
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
    where(
      query,
      [r],
      fragment(
        """
        COALESCE(
          (SELECT ar.decision FROM assertion_reviews ar
            WHERE ar.assertion_revision_id = ?
            ORDER BY ar.inserted_at DESC, ar.id DESC
            LIMIT 1),
          'needs_review'
        ) NOT IN ('rejected', 'withdrawn')
        """,
        r.id
      )
    )
  end

  @doc "The review decisions that hide a claim from a public read."
  def hidden_decisions, do: [:rejected, :withdrawn]

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
      context =
        %ReviewContext{}
        |> ReviewContext.changeset(%{assertion_revision_id: revision_id})
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
