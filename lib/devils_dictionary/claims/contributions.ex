defmodule DevilsDictionary.Claims.Contributions do
  @moduledoc "Authenticated contribution and reviewer commands; imported assertions use Claims directly."
  import Ecto.Query
  alias DevilsDictionary.{Claims, Registry, Repo}
  alias DevilsDictionary.Accounts.User
  alias DevilsDictionary.Registry.Entity
  alias DevilsDictionary.Sources.{Actor, ReconciliationCase}

  @local_entity_kinds ~w(person work artifact event concept)a

  def reviewer?(%{user: %{id: id}}),
    do: Repo.exists?(from u in User, where: u.id == ^id and u.reviewer)

  def reviewer?(_), do: false

  def internal_contributor?(%{user: %{id: id}}),
    do:
      Repo.exists?(
        from u in User,
          where: u.id == ^id and (u.internal_contributor or u.reviewer)
      )

  def internal_contributor?(_), do: false

  @doc "Whether the current account may revise this assertion (submitter or reviewer)."
  def can_revise?(%{user: %{id: id}}, assertion_id) do
    case Repo.get(User, id) do
      %User{reviewer: true} ->
        true

      %User{internal_contributor: true} ->
        Repo.exists?(
          from a in Claims.Assertion,
            join: actor in Actor,
            on: actor.id == a.submitted_by_actor_id,
            where: a.id == ^assertion_id and actor.user_id == ^id
        )

      _ ->
        false
    end
  end

  def can_revise?(_, _), do: false

  def propose(%{user: %{id: id}}, subject, predicate, object, attrs, evidence_id, locator) do
    evidence =
      if evidence_id do
        case revision_target(evidence_id) do
          nil -> [%{invalid_target: true}]
          target -> [Map.merge(target, %{locator: locator, evidence_role: :supports})]
        end
      else
        []
      end

    if String.trim(locator || "") != "" and evidence == [] do
      {:error, :evidence_required}
    else
      propose(%{user: %{id: id}}, subject, predicate, object, attrs, evidence)
    end
  end

  def propose(_, _, _, _, _, _, _), do: {:error, :unauthorized}

  @doc """
  Creates an attributed proposal with zero or more exact revision citations.

  Every nomination path reaches this function — the `/connect` form and
  `mix dd.exemplars.seed` today, a persona later (#181 C6) — so its refusals
  are the rules, not a form's:

    * `{:error, :rationale_required}` — no why.
    * `{:error, :evidence_required_for_person}` — a person is the subject and
      nothing is cited (#105 rule 2). A claim about a living person under
      *coward* is never a bare name.
    * `{:error, {:held, assertion_id}}` — a current, active claim already says
      the same `(subject, predicate, object)`, and no reviewer has rejected or
      withdrawn it. Nothing is written: a replayed
      manifest is a no-op, and a second nominator's agreement waits for
      endorsements (#181 build 3) rather than becoming a second claim.

  `attrs[:metadata]`, a map, is kept whole on the revision — where a manifest
  row records which file and row it came from and the sense it resolved.
  """
  def propose(%{user: %{id: id}}, subject, predicate, object, attrs, evidence)
      when is_list(evidence) do
    Repo.transaction(fn ->
      user = internal_user!(id)
      submitter = actor!(user)
      attrs = atomize_known(attrs)
      claimant = claimant_actor!(user, attrs[:claimant] || :me)
      if String.trim(attrs[:rationale] || "") == "", do: Repo.rollback(:rationale_required)

      if evidence == [] and person?(subject),
        do: Repo.rollback(:evidence_required_for_person)

      hold_duplicate!(subject, predicate, object)

      attrs =
        attrs
        |> atomize_known()
        |> Map.take([
          :rationale,
          :context_object_id,
          :jurisdiction_entity_id,
          :language_tag,
          :valid_from,
          :valid_to,
          :metadata
        ])
        |> then(fn attrs ->
          if is_map(attrs[:metadata]), do: attrs, else: Map.delete(attrs, :metadata)
        end)

      attrs =
        Map.merge(attrs, %{
          submitted_by_actor_id: submitter.id,
          origin_actor_id: claimant.id,
          source_id: community_source_id(),
          method: "curated"
        })

      claim = unwrap(Claims.assert(subject, predicate, object, attrs))
      revision = Claims.current_revision(claim.id)

      Enum.each(evidence, &add_exact_evidence!(revision.id, &1, user, subject))

      claim
    end)
  end

  def propose(_, _, _, _, _, _), do: {:error, :unauthorized}

  # Every claim has a source (#181): one a person makes here is the
  # community's. Nil on a database seeded before the row existed, which is
  # what every nomination before build 2 was.
  defp community_source_id do
    Repo.one(
      from s in DevilsDictionary.Sources.Source,
        where: s.slug == ^DevilsDictionary.Examples.Community.slug(),
        select: s.id
    )
  end

  defp person?(object_id) do
    Repo.exists?(from e in Entity, where: e.object_id == ^object_id and e.entity_kind == :person)
  end

  # The semantic key is `(subject, predicate, object)` (#105, #181 R4). The
  # advisory lock serialises two nominations of one key, so the second finds
  # the first's claim rather than both finding none.
  defp hold_duplicate!(subject, predicate, object) do
    Repo.query!("SELECT pg_advisory_xact_lock(hashtextextended($1, 0))", [
      "claim:#{subject}:#{predicate}:#{object}"
    ])

    # A claim a reviewer rejected or withdrew holds nothing: it is on nobody's
    # page, and a nomination with new evidence has to be able to return to
    # review (CodeRabbit on #186).
    hidden =
      from review in Claims.AssertionReview,
        where: review.assertion_revision_id == parent_as(:current).id,
        order_by: [desc: review.inserted_at, desc: review.id],
        limit: 1,
        select: review.decision

    existing =
      Repo.one(
        from r in Claims.AssertionRevision,
          as: :current,
          join: p in assoc(r, :predicate),
          left_lateral_join: decision in subquery(hidden),
          on: true,
          where:
            r.subject_object_id == ^subject and r.object_object_id == ^object and
              p.key == ^to_string(predicate) and r.is_current and r.lifecycle_state == :active,
          where: is_nil(decision.decision) or decision.decision not in ^Claims.hidden_decisions(),
          order_by: [asc: r.assertion_id],
          limit: 1,
          select: r.assertion_id
      )

    if existing, do: Repo.rollback({:held, existing})
  end

  @doc "Entity kinds the internal local-object form may create."
  def local_entity_kinds, do: @local_entity_kinds

  @doc "Potential duplicates are warnings, never identity matches."
  def duplicate_candidates(label, limit \\ 8)

  def duplicate_candidates(label, _limit) when not is_binary(label) or byte_size(label) < 2,
    do: []

  def duplicate_candidates(label, limit) do
    Repo.all(
      from e in Entity,
        join: o in Registry.Object,
        on: o.id == e.object_id and o.lifecycle_state == :active,
        where: ilike(e.preferred_label, ^"%#{String.trim(label)}%"),
        order_by: [asc: e.preferred_label, asc: e.object_id],
        limit: ^limit
    )
  end

  @doc "Creates one local identity, with optional evidence-backed candidate external ID."
  def create_local_entity(%{user: %{id: id}}, attrs) do
    Repo.transaction(fn ->
      user = internal_user!(id)
      submitter = actor!(user)
      attrs = atomize_known(attrs)
      kind = parse_kind(attrs[:entity_kind])
      label = String.trim(attrs[:preferred_label] || "")

      if kind not in @local_entity_kinds, do: Repo.rollback(:invalid_entity_kind)
      if label == "", do: Repo.rollback(:label_required)

      metadata =
        %{}
        |> put_present("source_url", attrs[:source_url])
        |> put_present("event_start", attrs[:event_start])
        |> put_present("event_end", attrs[:event_end])
        |> put_present("created_by_actor_id", submitter.id)

      entity_attrs = %{
        preferred_label: label,
        description: blank_to_nil(attrs[:description]),
        metadata: metadata
      }

      entity =
        case kind do
          :person ->
            unwrap(
              Registry.create_person(
                Map.merge(entity_attrs, %{
                  birth_date: blank_to_nil(attrs[:birth_date]),
                  death_date: blank_to_nil(attrs[:death_date])
                })
              )
            )

          :work ->
            unwrap(
              Registry.create_work(
                Map.merge(entity_attrs, %{
                  work_kind: blank_to_nil(attrs[:work_kind]),
                  original_language: blank_to_nil(attrs[:original_language]),
                  first_published_year: blank_to_nil(attrs[:first_published_year])
                })
              )
            )

          other ->
            unwrap(Registry.create_entity(Map.put(entity_attrs, :entity_kind, other)))
        end

      add_candidate_external_id!(entity, attrs, submitter)
      add_authorship!(entity, kind, attrs[:author_entity_id], submitter)
      entity
    end)
  end

  def create_local_entity(_, _), do: {:error, :unauthorized}

  @doc "Adds an accountable revision; only its submitter or a reviewer may edit it."
  def revise(scope, assertion_id, expected_revision_id, attrs, evidence \\ []) do
    change_claim(scope, :revise, assertion_id, expected_revision_id, attrs, evidence)
  end

  @doc "Challenges a current claim with rationale and exact counterevidence."
  def challenge(scope, assertion_id, expected_revision_id, reason, counterevidence) do
    attrs = %{change_reason: reason}
    change_claim(scope, :challenge, assertion_id, expected_revision_id, attrs, counterevidence)
  end

  def review(scope, assertion_id, revision_id, decision, reason, displayed_items) do
    if reviewer?(scope) do
      Repo.transaction(fn ->
        # Recheck the role while locked, so a revoked reviewer cannot act through an old LiveView.
        user = Repo.one!(from u in User, where: u.id == ^scope.user.id, lock: "FOR UPDATE")
        unless user.reviewer, do: Repo.rollback(:unauthorized)
        Repo.query!("SELECT id FROM assertions WHERE id = $1 FOR UPDATE", [assertion_id])
        current = Claims.current_revision(assertion_id)
        if is_nil(current) or current.id != revision_id, do: Repo.rollback(:stale_revision)
        if String.trim(reason || "") == "", do: Repo.rollback(:reason_required)
        unless decision in ~w(accepted disputed rejected), do: Repo.rollback(:invalid_decision)
        current_input = context_items(current)
        if current_input != displayed_items, do: Repo.rollback(:stale_context)
        context = unwrap(Claims.open_review_context(revision_id, current_input.items))

        # `open_review_context/2` re-reads the display snapshot. If an endpoint
        # or actor changed after the comparison above, do not record a review
        # against that different second view.
        if context.fingerprint != current_input.fingerprint,
          do: Repo.rollback(:stale_context)

        unwrap(
          Claims.review(revision_id, decision, %{
            reason: reason,
            reviewer_actor_id: actor!(user).id,
            review_context_id: context.id
          })
        )
      end)
    else
      {:error, :unauthorized}
    end
  end

  def context_items(revision) do
    Claims.current_review_input(revision)
  end

  @doc "The exact current revision target for a content item or sense."
  def revision_target(nil), do: nil

  def revision_target(id) do
    case Registry.current_content_revision(id) do
      %{id: revision_id} ->
        %{content_revision_id: revision_id}

      nil ->
        case Registry.current_sense_revision(id) do
          %{id: revision_id} -> %{sense_revision_id: revision_id}
          nil -> nil
        end
    end
  end

  @doc "Open split-reconciliation cases, available only to current reviewers."
  def list_reconciliation_cases(scope) do
    if reviewer?(scope) do
      Repo.all(
        from c in ReconciliationCase,
          where: c.status == :open and c.kind == "identity_split",
          order_by: [asc: c.inserted_at, asc: c.id],
          preload: [:object, :assertion]
      )
    else
      []
    end
  end

  @doc """
  Records a deliberate split decision without rewriting history.

  Mapping creates a new assertion revision and copies its exact evidence,
  replacing only evidence that cited the split identity. Leaving unresolved
  keeps the case open with an accountable note. Declining dismisses the case.
  """
  def reconcile(scope, case_id, decision, replacement_id, reason) do
    if reviewer?(scope) do
      Repo.transaction(fn ->
        user = Repo.one!(from u in User, where: u.id == ^scope.user.id, lock: "FOR UPDATE")
        unless user.reviewer, do: Repo.rollback(:unauthorized)

        reason = String.trim(reason || "")
        if reason == "", do: Repo.rollback(:reason_required)

        actor = actor!(user)

        case to_string(decision) do
          "map" ->
            map_reconciliation(case_id, replacement_id, reason, actor)

          "unresolved" ->
            case_id |> lock_reconciliation_case!() |> note_unresolved(reason, actor)

          "decline" ->
            case_id
            |> lock_reconciliation_case!()
            |> close_reconciliation(:dismissed, nil, reason, actor)

          _ ->
            Repo.rollback(:invalid_decision)
        end
      end)
    else
      {:error, :unauthorized}
    end
  end

  defp lock_reconciliation_case!(case_id) do
    kase =
      Repo.one!(from c in ReconciliationCase, where: c.id == ^case_id, lock: "FOR UPDATE")

    if kase.status != :open, do: Repo.rollback(:case_closed)
    kase
  end

  defp map_reconciliation(case_id, replacement_id, reason, actor) do
    # Lock the assertion before any of its cases. Two reviewers can resolve
    # different split attachments concurrently, so every mapping transaction
    # must take the shared locks in the same order and then rebase its siblings.
    preview = Repo.get!(ReconciliationCase, case_id)
    if preview.status != :open, do: Repo.rollback(:case_closed)

    Repo.one!(
      from assertion in Claims.Assertion,
        where: assertion.id == ^preview.assertion_id,
        lock: "FOR UPDATE"
    )

    open_cases =
      Repo.all(
        from c in ReconciliationCase,
          where:
            c.assertion_id == ^preview.assertion_id and c.kind == "identity_split" and
              c.status == :open,
          order_by: c.id,
          lock: "FOR UPDATE"
      )

    kase = Enum.find(open_cases, &(&1.id == case_id)) || Repo.rollback(:case_closed)
    replacement_id = parse_id(replacement_id)
    candidates = kase.payload["candidate_output_ids"] || []

    unless replacement_id in candidates, do: Repo.rollback(:invalid_replacement)

    unless Registry.object(replacement_id).lifecycle_state == :active,
      do: Repo.rollback(:invalid_replacement)

    revision_id = kase.payload["assertion_revision_id"]
    current = Claims.current_revision(kase.assertion_id)

    if is_nil(current) or current.id != revision_id, do: Repo.rollback(:stale_revision)

    roles = kase.payload["attachment_roles"] || List.wrap(kase.payload["endpoint_role"])

    reconciliation = %{
      "case_id" => kase.id,
      "from_object_id" => kase.object_id,
      "to_object_id" => replacement_id,
      "reason" => reason
    }

    metadata =
      (current.metadata || %{})
      |> Map.put("identity_split_reconciliation", reconciliation)
      |> Map.update("identity_split_reconciliations", [reconciliation], &(&1 ++ [reconciliation]))

    attrs =
      roles
      |> Enum.reduce(%{}, fn
        "subject", acc -> Map.put(acc, :subject_object_id, replacement_id)
        "object", acc -> Map.put(acc, :object_object_id, replacement_id)
        "context", acc -> Map.put(acc, :context_object_id, replacement_id)
        "jurisdiction", acc -> Map.put(acc, :jurisdiction_entity_id, replacement_id)
        _role, acc -> acc
      end)
      |> Map.put(:metadata, metadata)

    revision = unwrap(Claims.revise(kase.assertion_id, attrs))
    copy_reconciled_evidence(current, revision, kase.object_id, replacement_id)
    rebase_open_split_cases(open_cases, kase, current, revision)
    close_reconciliation(kase, :resolved, replacement_id, reason, actor)
  end

  defp rebase_open_split_cases(cases, resolved_case, from_revision, to_revision) do
    cases
    |> Enum.reject(&(&1.id == resolved_case.id))
    |> Enum.filter(&(&1.payload["assertion_revision_id"] == from_revision.id))
    |> Enum.filter(&case_attached_to_revision?(&1, to_revision))
    |> Enum.each(fn kase ->
      lineage =
        (kase.payload["revision_lineage"] || []) ++
          [
            %{
              "from_assertion_revision_id" => from_revision.id,
              "to_assertion_revision_id" => to_revision.id,
              "via_reconciliation_case_id" => resolved_case.id
            }
          ]

      payload =
        kase.payload
        |> Map.put("assertion_revision_id", to_revision.id)
        |> Map.put("revision_lineage", lineage)

      kase |> ReconciliationCase.changeset(%{payload: payload}) |> Repo.update!()
    end)
  end

  defp case_attached_to_revision?(kase, revision) do
    roles = kase.payload["attachment_roles"] || List.wrap(kase.payload["endpoint_role"])

    Enum.any?(roles, fn
      "subject" -> revision.subject_object_id == kase.object_id
      "object" -> revision.object_object_id == kase.object_id
      "context" -> revision.context_object_id == kase.object_id
      "jurisdiction" -> revision.jurisdiction_entity_id == kase.object_id
      "evidence" -> evidence_attached_to_revision?(revision.id, kase.object_id)
      "review_context" -> false
      _ -> false
    end)
  end

  defp evidence_attached_to_revision?(revision_id, object_id) do
    Repo.exists?(
      from evidence in Claims.AssertionEvidence,
        left_join: content in Registry.ContentRevision,
        on: content.id == evidence.content_revision_id,
        left_join: sense in Registry.SenseRevision,
        on: sense.id == evidence.sense_revision_id,
        where:
          evidence.assertion_revision_id == ^revision_id and
            (content.content_id == ^object_id or sense.sense_id == ^object_id)
    )
  end

  defp copy_reconciled_evidence(from_revision, to_revision, split_id, replacement_id) do
    Enum.each(Claims.evidence(from_revision.id), fn evidence ->
      attrs =
        evidence
        |> Map.take([
          :source_record_revision_id,
          :content_revision_id,
          :sense_revision_id,
          :evidence_role,
          :locator,
          :attribution_text
        ])
        |> replace_split_evidence(split_id, replacement_id)

      unwrap(Claims.add_evidence(to_revision.id, attrs))
    end)
  end

  defp replace_split_evidence(%{content_revision_id: id} = attrs, split_id, replacement_id)
       when not is_nil(id) do
    cited = Repo.get!(Registry.ContentRevision, id)

    if cited.content_id == split_id do
      case revision_target(replacement_id) do
        %{content_revision_id: target_id} ->
          attrs
          |> Map.put(:content_revision_id, target_id)
          |> Map.put(:sense_revision_id, nil)

        _ ->
          Repo.rollback(:replacement_revision_missing)
      end
    else
      attrs
    end
  end

  defp replace_split_evidence(%{sense_revision_id: id} = attrs, split_id, replacement_id)
       when not is_nil(id) do
    cited = Repo.get!(Registry.SenseRevision, id)

    if cited.sense_id == split_id do
      case revision_target(replacement_id) do
        %{sense_revision_id: target_id} ->
          attrs
          |> Map.put(:sense_revision_id, target_id)
          |> Map.put(:content_revision_id, nil)

        _ ->
          Repo.rollback(:replacement_revision_missing)
      end
    else
      attrs
    end
  end

  defp replace_split_evidence(attrs, _split_id, _replacement_id), do: attrs

  defp note_unresolved(kase, reason, actor) do
    payload = put_case_decision(kase.payload, "unresolved", nil, reason, actor)
    kase |> ReconciliationCase.changeset(%{payload: payload}) |> Repo.update!()
  end

  defp close_reconciliation(kase, status, replacement_id, reason, actor) do
    payload =
      put_case_decision(kase.payload, to_string(status), replacement_id, reason, actor)

    kase
    |> ReconciliationCase.changeset(%{
      status: status,
      payload: payload,
      resolved_by_actor_id: actor.id,
      resolved_at: DateTime.utc_now(:microsecond)
    })
    |> Repo.update!()
  end

  defp put_case_decision(payload, decision, replacement_id, reason, actor) do
    Map.put(payload, "decision", %{
      "kind" => decision,
      "replacement_object_id" => replacement_id,
      "reason" => reason,
      "actor_id" => actor.id,
      "recorded_at" => DateTime.utc_now(:microsecond) |> DateTime.to_iso8601()
    })
  end

  defp parse_id(id) when is_integer(id), do: id

  defp parse_id(id) when is_binary(id) do
    case Integer.parse(id) do
      {value, ""} -> value
      _ -> nil
    end
  end

  defp parse_id(_), do: nil

  defp change_claim(
         %{user: %{id: user_id}},
         action,
         assertion_id,
         expected_revision_id,
         attrs,
         evidence
       )
       when action in [:revise, :challenge] and is_list(evidence) do
    Repo.transaction(fn ->
      user = internal_user!(user_id)
      editor = actor!(user)

      assertion =
        Repo.one!(
          from a in Claims.Assertion,
            where: a.id == ^assertion_id,
            lock: "FOR UPDATE"
        )

      if action == :revise and not user.reviewer and assertion.submitted_by_actor_id != editor.id,
        do: Repo.rollback(:unauthorized)

      current = Claims.current_revision(assertion_id)

      if is_nil(current) or current.id != expected_revision_id,
        do: Repo.rollback(:stale_revision)

      if action == :challenge and current.lifecycle_state != :active,
        do: Repo.rollback(:inactive_claim)

      attrs = atomize_known(attrs)
      reason = String.trim(attrs[:change_reason] || "")
      if reason == "", do: Repo.rollback(:reason_required)

      evidence =
        if action == :challenge do
          if evidence == [], do: Repo.rollback(:counterevidence_required)
          Enum.map(evidence, &Map.put(atomize_known(&1), :evidence_role, :contradicts))
        else
          evidence
        end

      metadata =
        Map.put(current.metadata || %{}, "last_editorial_change", %{
          "action" => to_string(action),
          "actor_id" => editor.id,
          "reason" => reason,
          "recorded_at" => DateTime.utc_now(:microsecond) |> DateTime.to_iso8601()
        })

      revision_attrs =
        attrs
        |> Map.take([
          :rationale,
          :context_object_id,
          :jurisdiction_entity_id,
          :language_tag,
          :valid_from,
          :valid_to
        ])
        |> clean_optional_revision_attrs()
        |> Map.put(:metadata, metadata)

      revision = unwrap(Claims.revise(assertion_id, revision_attrs))
      copy_evidence!(current.id, revision.id)
      Enum.each(evidence, &add_exact_evidence!(revision.id, &1, user, current.subject_object_id))
      revision
    end)
  end

  defp change_claim(_, _, _, _, _, _), do: {:error, :unauthorized}

  defp copy_evidence!(from_revision_id, to_revision_id) do
    Enum.each(Claims.evidence(from_revision_id), fn evidence ->
      attrs =
        Map.take(evidence, [
          :source_record_revision_id,
          :content_revision_id,
          :sense_revision_id,
          :evidence_role,
          :locator,
          :attribution_text
        ])

      unwrap(Claims.add_evidence(to_revision_id, attrs))
    end)
  end

  defp add_exact_evidence!(revision_id, attrs, user, subject_object_id) do
    attrs = atomize_known(attrs)
    if attrs[:invalid_target], do: Repo.rollback(:invalid_evidence)

    target =
      Map.take(attrs, [
        :source_record_revision_id,
        :content_revision_id,
        :sense_revision_id,
        :expected_source_slug,
        :expected_object_id
      ])

    validate_evidence_target!(target, subject_object_id)

    role = parse_evidence_role(attrs[:evidence_role])
    locator = String.trim(attrs[:locator] || "")
    if locator == "", do: Repo.rollback(:locator_required)

    evidence_attrs =
      target
      |> Map.take([:source_record_revision_id, :content_revision_id, :sense_revision_id])
      |> Map.put(:evidence_role, role)
      |> Map.put(:locator, locator)
      |> Map.put(
        :attribution_text,
        blank_to_nil(attrs[:attribution_text]) || "Submitted by account ##{user.id}"
      )

    unwrap(Claims.add_evidence(revision_id, evidence_attrs))
  end

  defp validate_evidence_target!(target, subject_object_id) do
    valid? =
      case target do
        %{
          source_record_revision_id: id,
          expected_source_slug: source_slug,
          expected_object_id: expected_object_id
        }
        when is_integer(id) and is_binary(source_slug) and is_integer(expected_object_id) ->
          expected_object_id == subject_object_id and
            Repo.exists?(
              from revision in DevilsDictionary.Corpus.SourceRecordRevision,
                join: record in DevilsDictionary.Sources.SourceRecord,
                on: record.id == revision.source_record_id and record.display_allowed,
                join: source in DevilsDictionary.Sources.Source,
                on:
                  source.id == record.source_id and source.slug == ^source_slug and source.active,
                join: output in DevilsDictionary.Sources.MaterializedOutput,
                on:
                  output.source_record_id == record.id and
                    output.output_object_id == ^expected_object_id and is_nil(output.retired_at),
                where: revision.id == ^id
            )

        %{source_record_revision_id: id} when is_integer(id) ->
          Repo.exists?(from r in DevilsDictionary.Corpus.SourceRecordRevision, where: r.id == ^id)

        %{content_revision_id: id} when is_integer(id) ->
          Repo.exists?(from r in Registry.ContentRevision, where: r.id == ^id)

        %{sense_revision_id: id} when is_integer(id) ->
          Repo.exists?(from r in Registry.SenseRevision, where: r.id == ^id)

        _ ->
          false
      end

    unless valid?, do: Repo.rollback(:invalid_evidence)
  end

  defp parse_evidence_role(role) when role in [:supports, "supports"], do: :supports
  defp parse_evidence_role(role) when role in [:contradicts, "contradicts"], do: :contradicts
  defp parse_evidence_role(_), do: Repo.rollback(:invalid_evidence_role)

  defp claimant_actor!(user, claimant) when claimant in [:me, "me", nil], do: actor!(user)

  defp claimant_actor!(_user, claimant) when claimant in [:unknown, "unknown"] do
    Repo.insert!(%Actor{actor_kind: :unknown, label: "Unknown claimant"})
  end

  defp claimant_actor!(_user, claimant) do
    entity_id = parse_id(claimant)
    if is_nil(entity_id), do: Repo.rollback(:invalid_claimant)

    entity =
      Repo.one(
        from e in Entity,
          join: o in Registry.Object,
          on: o.id == e.object_id and o.lifecycle_state == :active,
          where: e.object_id == ^entity_id and e.entity_kind in [:person, :organization]
      )

    if is_nil(entity), do: Repo.rollback(:invalid_claimant)

    Repo.get_by(Actor, actor_kind: :external, entity_id: entity.object_id) ||
      Repo.insert!(%Actor{
        actor_kind: :external,
        entity_id: entity.object_id,
        label: entity.preferred_label
      })
  end

  defp add_candidate_external_id!(entity, attrs, submitter) do
    namespace = blank_to_nil(attrs[:external_namespace])
    external_id = blank_to_nil(attrs[:external_id])
    source_url = blank_to_nil(attrs[:source_url])

    case {namespace, external_id, source_url} do
      {nil, nil, _} ->
        :ok

      {namespace, external_id, source_url}
      when is_binary(namespace) and is_binary(external_id) and is_binary(source_url) ->
        unless http_url?(source_url), do: Repo.rollback(:external_id_evidence_required)

        unwrap(
          Registry.add_external_id(entity.object_id, namespace, external_id, %{
            status: :candidate,
            metadata: %{
              "evidence_url" => source_url,
              "submitted_by_actor_id" => submitter.id
            }
          })
        )

      _ ->
        Repo.rollback(:external_id_evidence_required)
    end
  end

  defp add_authorship!(_entity, kind, author_id, _submitter)
       when kind != :work or author_id in [nil, ""],
       do: :ok

  defp add_authorship!(entity, :work, author_id, submitter) do
    author_id = parse_id(author_id)

    if is_nil(author_id), do: Repo.rollback(:invalid_author)

    author =
      Repo.one(
        from e in Entity,
          where: e.object_id == ^author_id and e.entity_kind in [:person, :organization]
      )

    if is_nil(author), do: Repo.rollback(:invalid_author)

    unwrap(
      Claims.assert(entity.object_id, "authored_by", author.object_id, %{
        origin_actor_id: submitter.id,
        submitted_by_actor_id: submitter.id,
        rationale: "Creator selected during local work creation",
        method: "curated"
      })
    )
  end

  defp internal_user!(id) do
    user = Repo.one!(from u in User, where: u.id == ^id, lock: "FOR UPDATE")
    unless user.internal_contributor or user.reviewer, do: Repo.rollback(:unauthorized)
    user
  end

  defp parse_kind(value) do
    Enum.find(@local_entity_kinds, &(to_string(&1) == to_string(value)))
  end

  defp clean_optional_revision_attrs(attrs) do
    Enum.reduce([:rationale, :language_tag, :valid_from, :valid_to], attrs, fn key, acc ->
      if Map.has_key?(acc, key), do: Map.update!(acc, key, &blank_to_nil/1), else: acc
    end)
  end

  @known_keys %{
    "rationale" => :rationale,
    "context_object_id" => :context_object_id,
    "jurisdiction_entity_id" => :jurisdiction_entity_id,
    "language_tag" => :language_tag,
    "valid_from" => :valid_from,
    "valid_to" => :valid_to,
    "claimant" => :claimant,
    "change_reason" => :change_reason,
    "source_record_revision_id" => :source_record_revision_id,
    "content_revision_id" => :content_revision_id,
    "sense_revision_id" => :sense_revision_id,
    "evidence_role" => :evidence_role,
    "locator" => :locator,
    "attribution_text" => :attribution_text,
    "invalid_target" => :invalid_target,
    "expected_source_slug" => :expected_source_slug,
    "expected_object_id" => :expected_object_id,
    "entity_kind" => :entity_kind,
    "preferred_label" => :preferred_label,
    "description" => :description,
    "source_url" => :source_url,
    "external_namespace" => :external_namespace,
    "external_id" => :external_id,
    "birth_date" => :birth_date,
    "death_date" => :death_date,
    "work_kind" => :work_kind,
    "original_language" => :original_language,
    "first_published_year" => :first_published_year,
    "event_start" => :event_start,
    "event_end" => :event_end,
    "author_entity_id" => :author_entity_id,
    "metadata" => :metadata
  }

  defp atomize_known(attrs) when is_list(attrs), do: attrs |> Map.new() |> atomize_known()

  defp atomize_known(attrs) when is_map(attrs) do
    Map.new(attrs, fn
      {key, value} when is_binary(key) -> {Map.get(@known_keys, key, key), value}
      pair -> pair
    end)
  end

  defp put_present(map, _key, nil), do: map
  defp put_present(map, _key, ""), do: map
  defp put_present(map, key, value), do: Map.put(map, key, value)

  defp blank_to_nil(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp blank_to_nil(value), do: value

  defp http_url?(value) do
    case URI.parse(value) do
      %URI{scheme: scheme, host: host} when scheme in ["http", "https"] and is_binary(host) ->
        true

      _ ->
        false
    end
  end

  defp actor!(user) do
    # Serializes first-use actor creation for this account.
    Repo.one!(from u in User, where: u.id == ^user.id, lock: "FOR UPDATE")

    Repo.get_by(Actor, user_id: user.id) ||
      Repo.insert!(%Actor{actor_kind: :user, user_id: user.id, label: "Account ##{user.id}"})
  end

  defp unwrap({:ok, result}), do: result
  defp unwrap({:error, reason}), do: Repo.rollback(reason)
end
