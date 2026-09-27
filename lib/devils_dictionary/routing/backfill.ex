defmodule DevilsDictionary.Routing.Backfill do
  @moduledoc """
  Stage 2 of #194: classification decisions, pages and — only where a named
  human reviewer approved them — addresses, for a bounded candidate
  population, in resumable batches (ADR 0004 §8, step 3).

  ## What a run is bound to

  A run is keyed by four digests, and refuses inputs that do not agree:

    * the read-only policy export it evaluates (`Routing.AuditSnapshot`);
    * the routing policy (`AuditSnapshot.policy_digest/0`);
    * the population (`docs/routing/stage-2/candidates.py`'s output, whose
      own inputs must name that export and that policy);
    * the reviews, if any. The file names the population's digest, and each
      confirmation names the decision fingerprint the reviewer saw (from a
      run's manifest), so a review cannot outlive the evidence it was made
      on.

  The same four digests are the same run: its checkpoint is reused. A new
  review file is a new run over the same population, and its writes are the
  same idempotent writes, so identities carry over.

  ## Per record, in object-id order

    1. The record's evaluator input is read back from the database and
       compared with the export, and every revision the evaluator pins must
       still be its record's current one. Anything else is a deferral with
       its reason, never a classification of stale evidence.
    2. `Policy.classify/3`, then `Classifications.record/1` — which writes
       nothing when the evidence is unchanged, and keeps a standing override.
    3. What the population and the reviews say:
       * **excluded or deferred** in the population: nothing more;
       * **heading for an address** (an allocation candidate or a collision
         to qualify): `Pages.ensure/3` — a subject page, or an edition's own
         page — and then, only with a reviewer's `confirm` of the current
         evidence, the reviewer's override (once) and `Ledger.allocate/3` of
         the approved path. Every check that could refuse the confirmation
         is made before the override is written;
       * **awaiting a classification or identity review**: no page until a
         reviewer confirms a family;
       * a reviewer's `defer`: nothing more, with the reviewer's reason.
    4. One checkpoint row (`routing_backfill_items`) with the disposition and
       the ids it produced.

  A batch is one transaction: its writes and its checkpoints commit
  together, so an interruption loses at most the batch in hand, and a resumed
  run starts after the last committed record. Every writer it calls refuses
  per record without rolling the batch back (Stage 1, decision 7). A defect,
  or an allocation that loses a race three times, raises: the batch rolls
  back, the run stops, and running it again resumes it.

  Nothing here publishes: pages stay `draft`, and candidate status grants no
  publication approval.
  """

  import Ecto.Query
  import DevilsDictionary.Routing.Input, only: [json?: 1, text?: 1]

  alias DevilsDictionary.Accounts.User
  alias DevilsDictionary.Repo

  alias DevilsDictionary.Routing.{
    Address,
    AuditSnapshot,
    BackfillItem,
    BackfillRun,
    Classifications,
    Ledger,
    Page,
    Pages,
    Policy,
    PublicPath,
    RouteChange
  }

  alias DevilsDictionary.Routing.ClassificationDecision, as: Decision
  alias DevilsDictionary.Sources.Actor

  @version "routing-backfill/1"

  # The population's dispositions, as candidates.py writes them.
  @heading_for_address ["allocation candidate", "collision review:", "collision review blocked"]
  @awaiting_review ["classification review", "duplicate-identity review"]
  @not_addressed ["deferred", "excluded"]

  # ── loading ──────────────────────────────────────────────────────────────

  @doc """
  Reads and cross-checks a run's inputs. Returns `{:ok, plan}` or `{:error,
  message}`; nothing is written.

  A review file marked `"rehearsal": true` — rule-made reviews for exercising
  allocation on an isolated copy — is refused unless `allow_rehearsal: true`.
  """
  def load(snapshot_path, population_path, reviews_path \\ nil, opts \\ []) do
    with {:ok, snapshot} <- AuditSnapshot.read(snapshot_path),
         {:ok, population} <- population(population_path),
         policy_sha256 = AuditSnapshot.policy_digest(),
         :ok <- bound(population, snapshot, policy_sha256),
         {:ok, reviews, reviews_sha256} <-
           reviews(reviews_path, population, Keyword.get(opts, :allow_rehearsal, false)) do
      key =
        AuditSnapshot.digest(
          Enum.join(
            [
              @version,
              snapshot.sha256,
              policy_sha256,
              population.sha256,
              reviews_sha256 || "none"
            ],
            "\n"
          )
        )

      {:ok,
       %{
         run_key: key,
         input_sha256: snapshot.sha256,
         policy_sha256: policy_sha256,
         policy: Policy.load(),
         population_sha256: population.sha256,
         reviews_sha256: reviews_sha256,
         records: Enum.sort_by(population.records, & &1["object_id"]),
         contested: population.contested,
         entities: Map.new(snapshot.entities, &{&1["object_id"], &1}),
         graph: snapshot.graph,
         reviews: reviews
       }}
    end
  end

  defp population(path) do
    with {:ok, bytes} <- File.read(path),
         {:ok, %{"records" => records, "summary" => summary} = file} <- Jason.decode(bytes),
         :ok <- population_records(path, records) do
      {:ok,
       %{
         records: records,
         inputs: summary["inputs"] || %{},
         # Every candidate path shared by a collision group the population
         # touches: never an uncontested address.
         contested: file |> Map.get("groups", %{}) |> Map.keys() |> MapSet.new(),
         sha256: AuditSnapshot.digest(bytes)
       }}
    else
      {:ok, _other} ->
        {:error, "population #{path}: not a candidates file (records, summary)"}

      {:error, %Jason.DecodeError{}} ->
        {:error, "population #{path}: not JSON"}

      {:error, reason} when is_atom(reason) ->
        {:error, "cannot read #{path}: #{:file.format_error(reason)}"}

      {:error, _message} = error ->
        error
    end
  end

  defp population_records(path, records) do
    ids = Enum.map(records, & &1["object_id"])

    cond do
      not Enum.all?(ids, &(is_integer(&1) and &1 > 0)) ->
        {:error, "population #{path}: every record needs a positive object_id"}

      length(ids) != length(Enum.uniq(ids)) ->
        {:error, "population #{path}: an object id appears twice"}

      bad = Enum.find(records, &(population_kind(&1["disposition"]) == :unknown)) ->
        {:error,
         "population #{path}: object #{bad["object_id"]} has an unknown disposition #{inspect(bad["disposition"])}"}

      true ->
        :ok
    end
  end

  # The population was derived from this export under this policy, or it
  # proposes addresses for a different snapshot.
  defp bound(population, snapshot, policy_sha256) do
    cond do
      population.inputs["input_sha256"] != snapshot.sha256 ->
        {:error,
         "the population was derived from export #{inspect(population.inputs["input_sha256"])}, " <>
           "not from #{snapshot.sha256}"}

      population.inputs["policy_sha256"] != policy_sha256 ->
        {:error,
         "the population was derived under policy #{inspect(population.inputs["policy_sha256"])}, " <>
           "not the current #{policy_sha256}"}

      true ->
        :ok
    end
  end

  defp reviews(nil, _population, _allow_rehearsal), do: {:ok, %{}, nil}

  defp reviews(path, population, allow_rehearsal) do
    with {:ok, bytes} <- File.read(path),
         {:ok, %{"reviews" => entries} = file} when is_list(entries) <- Jason.decode(bytes),
         :ok <- review_file(path, file, population, allow_rehearsal),
         {:ok, reviews} <- review_entries(entries, population) do
      {:ok, reviews, AuditSnapshot.digest(bytes)}
    else
      {:ok, _other} ->
        {:error, "reviews #{path}: expected {\"reviews\": [...]}"}

      {:error, %Jason.DecodeError{}} ->
        {:error, "reviews #{path}: not JSON"}

      {:error, reason} when is_atom(reason) ->
        {:error, "cannot read #{path}: #{:file.format_error(reason)}"}

      {:error, _message} = error ->
        error
    end
  end

  defp review_file(path, file, population, allow_rehearsal) do
    cond do
      file["population_sha256"] != population.sha256 ->
        {:error,
         "reviews #{path} were made on population #{inspect(file["population_sha256"])}, " <>
           "not on #{population.sha256}"}

      file["rehearsal"] == true and not allow_rehearsal ->
        {:error,
         "reviews #{path} are rehearsal reviews, made by a rule; they approve nothing here"}

      true ->
        :ok
    end
  end

  defp review_entries(entries, population) do
    records = Map.new(population.records, &{&1["object_id"], &1})

    # Each record's own qualifier belongs to that record alone.
    proposals =
      for r <- population.records,
          is_binary(r["proposed_path"]),
          into: %{},
          do: {r["proposed_path"], r["object_id"]}

    Enum.reduce_while(entries, {:ok, %{}}, fn entry, {:ok, acc} ->
      with {:ok, review} <- review(entry, records, proposals),
           :ok <- unique(review, acc) do
        {:cont, {:ok, Map.put(acc, review.object_id, review)}}
      else
        {:error, message} -> {:halt, {:error, message}}
      end
    end)
  end

  defp unique(review, acc) do
    cond do
      Map.has_key?(acc, review.object_id) ->
        {:error, "two reviews for object #{review.object_id}"}

      review.path && Enum.any?(Map.values(acc), &(&1.path == review.path)) ->
        {:error, "two reviews approve #{review.path}; import order may not choose between them"}

      true ->
        :ok
    end
  end

  defp review(%{"object_id" => id, "action" => action} = entry, records, proposals) do
    record = Map.get(records, id)
    path = entry["path"]

    cond do
      is_nil(record) ->
        {:error, "review for object #{inspect(id)}, which is not in the population"}

      action not in ["confirm", "defer"] ->
        {:error, "review for object #{id}: unknown action #{inspect(action)}"}

      population_kind(record["disposition"]) == :not_addressed ->
        {:error,
         "review for object #{id}: the population does not address it (#{record["disposition"]})"}

      not (is_binary(entry["reason"]) and String.trim(entry["reason"]) != "" and
               text?(entry["reason"])) ->
        {:error, "review for object #{id}: a reason is required, as plain text"}

      not (is_binary(entry["reviewer"]) and text?(entry["reviewer"])) ->
        {:error, "review for object #{id}: name the reviewer's account by email"}

      not json?(entry) ->
        {:error, "review for object #{id}: the entry holds something JSON cannot store"}

      action == "confirm" and entry["family"] not in families() ->
        {:error,
         "review for object #{id}: a confirmation names a family, one of #{Enum.join(families(), ", ")}"}

      action == "confirm" and not fingerprint?(entry["evidence_fingerprint"]) ->
        {:error,
         "review for object #{id}: a confirmation names the evidence_fingerprint of the decision reviewed"}

      not (is_nil(path) or is_binary(path)) ->
        {:error, "review for object #{id}: a path is a string"}

      is_binary(path) and not match?({:ok, _}, Address.parse(path)) ->
        {:error, "review for object #{id}: #{inspect(path)} is not an address"}

      is_binary(path) and elem(Address.parse(path), 1).namespace != entry["family"] ->
        {:error, "review for object #{id}: #{path} is not in /#{entry["family"]}"}

      is_binary(path) and Map.get(proposals, path, id) != id ->
        {:error,
         "review for object #{id}: #{path} is object #{proposals[path]}'s proposed qualifier"}

      true ->
        {:ok,
         %{
           object_id: id,
           action: String.to_existing_atom(action),
           family: entry["family"],
           path: path,
           fingerprint: entry["evidence_fingerprint"],
           reviewer: entry["reviewer"],
           reason: entry["reason"],
           entry: entry
         }}
    end
  end

  defp review(_entry, _records, _proposals), do: {:error, "a review needs object_id and action"}

  defp families, do: Enum.map(Ecto.Enum.values(Decision, :family), &Atom.to_string/1)

  defp fingerprint?(value), do: is_binary(value) and value =~ ~r/\A[0-9a-f]{64}\z/

  # ── running ──────────────────────────────────────────────────────────────

  @doc """
  Runs `plan` (from `load/4`) with the import actor `actor_id`, resuming its
  checkpoint if one exists. Options: `batch_size` (default 25);
  `crash_after`, for tests, raises after that many records of this call have
  been processed, inside their batch.

  Returns `{:ok, summary}`, or `{:error, message}` for a refusal made before
  anything is written (an unknown reviewer, say).
  """
  def run(plan, actor_id, opts \\ []) do
    with {:ok, users} <- reviewers(plan.reviews) do
      reviewers = Map.new(users, fn {email, user} -> {email, user_actor!(user)} end)
      run = open!(plan, actor_id)
      done = done(run.id)
      crash_after = Keyword.get(opts, :crash_after)

      plan.records
      |> Enum.with_index()
      |> Enum.reject(fn {r, _i} -> MapSet.member?(done, r["object_id"]) end)
      |> Enum.chunk_every(Keyword.get(opts, :batch_size, 25))
      |> Enum.reduce(0, fn batch, processed ->
        {:ok, processed} =
          Repo.transaction(
            fn -> batch!(plan, run, reviewers, actor_id, batch, processed, crash_after) end,
            timeout: :infinity
          )

        processed
      end)

      finish!(run)
      {:ok, summary(run.id)}
    end
  end

  defp batch!(plan, run, reviewers, actor_id, batch, processed, crash_after) do
    inputs = current_inputs(Enum.map(batch, fn {r, _i} -> r["object_id"] end))

    Enum.reduce(batch, processed, fn {record, position}, processed ->
      if crash_after && processed >= crash_after, do: raise("crash injected by the test")

      item = process(plan, reviewers, actor_id, record, Map.get(inputs, record["object_id"]))

      Repo.insert!(
        struct(
          BackfillItem,
          Map.merge(item, %{run_id: run.id, object_id: record["object_id"], position: position})
        )
      )

      processed + 1
    end)
  end

  # Every reviewer named is an account with the reviewer role — all of them
  # checked before anything is written.
  defp reviewers(reviews) do
    reviews
    |> Map.values()
    |> Enum.map(& &1.reviewer)
    |> Enum.uniq()
    |> Enum.reduce_while({:ok, %{}}, fn email, {:ok, acc} ->
      case Repo.get_by(User, email: email) do
        %User{reviewer: true} = user -> {:cont, {:ok, Map.put(acc, email, user)}}
        %User{} -> {:halt, {:error, "#{email} does not hold the reviewer role"}}
        nil -> {:halt, {:error, "no account #{email}"}}
      end
    end)
  end

  # The account's `user` actor — the only kind the database lets override.
  defp user_actor!(user) do
    Repo.get_by(Actor, actor_kind: :user, user_id: user.id) ||
      Repo.insert!(%Actor{actor_kind: :user, user_id: user.id, label: "Reviewer ##{user.id}"})
  end

  defp open!(plan, actor_id) do
    case Repo.get_by(BackfillRun, run_key: plan.run_key) do
      nil ->
        Repo.insert!(%BackfillRun{
          run_key: plan.run_key,
          input_sha256: plan.input_sha256,
          policy_sha256: plan.policy_sha256,
          policy_version: plan.policy.rules["version"],
          population_sha256: plan.population_sha256,
          reviews_sha256: plan.reviews_sha256,
          records: length(plan.records),
          actor_id: actor_id,
          started_at: DateTime.utc_now()
        })

      run ->
        run
    end
  end

  defp done(run_id) do
    from(i in BackfillItem, where: i.run_id == ^run_id, select: i.object_id)
    |> Repo.all()
    |> MapSet.new()
  end

  defp finish!(%BackfillRun{id: id}) do
    Repo.update_all(from(r in BackfillRun, where: r.id == ^id and is_nil(r.finished_at)),
      set: [finished_at: DateTime.utc_now()]
    )
  end

  # ── one record ───────────────────────────────────────────────────────────

  defp process(plan, reviewers, actor_id, record, current) do
    id = record["object_id"]
    exported = Map.get(plan.entities, id)
    proposed = record["proposed_path"] || record["candidate_path"]

    cond do
      is_nil(exported) ->
        deferral("missing_from_export", nil, proposed)

      is_nil(current) ->
        deferral("missing_from_database", nil, proposed)

      comparable(current) != comparable(exported) ->
        deferral(
          "input_changed",
          "the entity's evaluator input differs from the export",
          proposed
        )

      true ->
        result = Policy.classify(exported, plan.graph, plan.policy)

        case stale_pins(result) do
          [] ->
            case Classifications.record(result) do
              {:ok, _outcome, decision} ->
                context = %{
                  plan: plan,
                  record: record,
                  result: result,
                  decision: decision,
                  role: role(result),
                  proposed: proposed,
                  actor_id: actor_id
                }

                act(context, Map.get(plan.reviews, id), reviewers)

              {:error, reason} ->
                deferral("classification_refused", inspect(reason), proposed)
            end

          stale ->
            deferral("evidence_changed", "not current: " <> Enum.join(stale, ", "), proposed)
        end
    end
  end

  # The page an entity gets: an edition's own role, whose addresses live in
  # /works; every other entity a subject page (Stage 1, decision 1).
  defp role(%{page_role: "edition"}), do: :edition
  defp role(_result), do: :subject

  defp act(ctx, review, reviewers) do
    kind = population_kind(ctx.record["disposition"])

    cond do
      kind == :not_addressed ->
        %{
          disposition: "not_addressed",
          reason: ctx.record["disposition"],
          decision_id: ctx.decision.id
        }

      review && review.action == :defer ->
        %{
          disposition: "deferred_by_review",
          reason: review.reason,
          decision_id: ctx.decision.id,
          proposed_path: ctx.proposed,
          review: review.entry
        }

      review && review.action == :confirm ->
        confirm(ctx, review, Map.fetch!(reviewers, review.reviewer))

      kind == :heading_for_address ->
        case Pages.ensure(ctx.role, ctx.record["object_id"]) do
          {:ok, page} ->
            %{
              disposition: "awaiting_review",
              reason: ctx.record["disposition"],
              decision_id: ctx.decision.id,
              page_id: page.id,
              proposed_path: ctx.proposed
            }

          {:error, reason} ->
            refused(ctx, "page: #{inspect(reason)}", ctx.proposed, nil)
        end

      true ->
        %{
          disposition: "awaiting_review",
          reason: ctx.record["disposition"],
          decision_id: ctx.decision.id,
          proposed_path: ctx.proposed
        }
    end
  end

  # A reviewer's confirmation of the evidence they saw. Everything that could
  # refuse it is checked first; only then the override (once), the page and
  # the address.
  defp confirm(ctx, review, reviewer) do
    path = review.path || uncontested(ctx)

    with {:ok, parsed} <- address(path, review.family, ctx.role),
         :ok <- seen(ctx.decision, review),
         :ok <- available(parsed.path, ctx),
         {:ok, decision} <- override(ctx, review, reviewer),
         {:ok, page} <- page(ctx) do
      reason =
        "Stage 2 backfill: address approved by reviewer ##{reviewer.user_id} — #{review.reason}"

      case Ledger.allocate(page.id, parsed.path, actor_id: ctx.actor_id, reason: reason) do
        {:ok, _} ->
          %{
            disposition: "allocated",
            decision_id: decision.id,
            page_id: page.id,
            path_id: Repo.get!(Page, page.id).canonical_path_id,
            proposed_path: parsed.path,
            review: review.entry
          }

        {:error, refusal} ->
          %{refused(ctx, inspect(refusal), parsed.path, review.entry) | decision_id: decision.id}
          |> Map.put(:page_id, page.id)
      end
    else
      {:refused, reason} -> refused(ctx, reason, path, review.entry)
    end
  end

  defp refused(ctx, reason, path, entry) do
    %{
      disposition: "refused",
      reason: reason,
      decision_id: ctx.decision.id,
      proposed_path: path,
      review: entry
    }
  end

  # The evaluator's own candidate path, only when nothing else proposes it:
  # the population calls it a candidate, the evaluator derives the same path
  # from this evidence, and no collision group the population touches shares
  # it. A collision is qualified by its reviewer, never by import order.
  defp uncontested(%{record: record, result: result, plan: plan}) do
    path = record["candidate_path"]

    if record["address_status"] == "candidate" and is_binary(path) and
         AuditSnapshot.candidate_path(result) == path and not MapSet.member?(plan.contested, path),
       do: path
  end

  defp address(nil, _family, _role),
    do: {:refused, "no approved path: a collision is qualified by its reviewer"}

  defp address(path, family, role) do
    case Address.parse(path) do
      {:ok, %{namespace: ^family} = parsed} ->
        if role == :edition and family != "works",
          do: {:refused, "an edition's address is in /works, not /#{family}"},
          else: {:ok, parsed}

      {:ok, %{namespace: namespace}} ->
        {:refused, "the approved path is in /#{namespace}, the confirmed family is #{family}"}

      {:error, reason} ->
        {:refused, "the approved path is not an address: #{inspect(reason)}"}
    end
  end

  # The reviewer confirmed this decision's evidence, not other evidence.
  defp seen(%Decision{evidence_fingerprint: fingerprint}, %{fingerprint: fingerprint}), do: :ok

  defp seen(_decision, _review),
    do: {:refused, "stale review: the evidence changed after the reviewer saw it"}

  # The path is free, or already this record's own page's.
  defp available(path, ctx) do
    owner =
      Repo.one(
        from pp in PublicPath,
          join: p in Page,
          on: p.id == pp.original_page_id,
          where: pp.path == ^path,
          select: {p.target_object_id, p.role, pp.kind}
      )

    page =
      Repo.get_by(Page, target_object_id: ctx.record["object_id"], role: ctx.role, locale: "en")

    canonical =
      page && page.canonical_path_id && Repo.get!(PublicPath, page.canonical_path_id).path

    cond do
      canonical && canonical != path ->
        {:refused, "the page already has the address #{canonical}"}

      is_nil(owner) ->
        :ok

      elem(owner, 0) == ctx.record["object_id"] and elem(owner, 2) != :tombstone ->
        :ok

      elem(owner, 2) == :tombstone ->
        {:refused, "#{path} is a tombstone; only a human restoration brings it back"}

      true ->
        {:refused, "#{path} belongs to object #{elem(owner, 0)}"}
    end
  end

  # The reviewer's own current override for this family is already the
  # decision: nothing to write. Otherwise an override of the evidence the
  # reviewer saw — which replaces the reviewer's own earlier one.
  defp override(
         %{decision: %Decision{origin: :override, status: :mapped} = decision},
         review,
         reviewer
       )
       when decision.reviewer_actor_id == reviewer.id do
    if Atom.to_string(decision.family) == review.family,
      do: {:ok, decision},
      else: write_override(decision.object_id, review, reviewer)
  end

  defp override(%{decision: decision}, review, reviewer),
    do: write_override(decision.object_id, review, reviewer)

  defp write_override(object_id, review, reviewer) do
    attrs = %{
      status: :mapped,
      family: String.to_existing_atom(review.family),
      reason: review.reason,
      evidence_fingerprint: review.fingerprint
    }

    case Classifications.override(object_id, attrs, reviewer.id) do
      {:ok, override} -> {:ok, override}
      {:error, reason} -> {:refused, "the reviewer's override was refused: #{inspect(reason)}"}
    end
  end

  defp page(ctx) do
    case Pages.ensure(ctx.role, ctx.record["object_id"]) do
      {:ok, page} -> {:ok, page}
      {:error, reason} -> {:refused, "page: #{inspect(reason)}"}
    end
  end

  defp deferral(disposition, reason, proposed),
    do: %{disposition: disposition, reason: reason, proposed_path: proposed}

  defp population_kind(disposition) when is_binary(disposition) do
    cond do
      starts_with_any?(disposition, @not_addressed) -> :not_addressed
      starts_with_any?(disposition, @heading_for_address) -> :heading_for_address
      starts_with_any?(disposition, @awaiting_review) -> :awaiting_review
      true -> :unknown
    end
  end

  defp population_kind(_disposition), do: :unknown

  defp starts_with_any?(text, prefixes), do: Enum.any?(prefixes, &String.starts_with?(text, &1))

  # ── the evidence is still what the export saw ───────────────────────────

  # The evaluator input for these entities, read as the export reads it.
  defp current_inputs(object_ids) do
    %{rows: rows} =
      Repo.query!(
        """
        SELECT jsonb_build_object('object_id',e.object_id,
          'entity_kind',e.entity_kind,'label',e.preferred_label,'description',e.description,
          'lifecycle',o.lifecycle_state,
          'instance_of',coalesce(e.metadata->'wikidata_instance_of','[]'::jsonb),
          'subclass_of',coalesce(e.metadata->'wikidata_subclass_of','[]'::jsonb),
          'disambiguation',coalesce(e.metadata->'disambiguation','false'::jsonb),
          'taxon',e.metadata->'taxon','work_kind',w.work_kind,
          'edition_work_id',ed.work_id,
          'qids',coalesce((SELECT jsonb_agg(x.external_id ORDER BY x.external_id)
            FROM external_identifiers x WHERE x.object_id=e.object_id
            AND x.namespace='wikidata' AND x.status='verified'),'[]'::jsonb))
        FROM entities e JOIN objects o ON o.id=e.object_id
        LEFT JOIN work_details w ON w.entity_id=e.object_id
        LEFT JOIN edition_details ed ON ed.entity_id=e.object_id
        WHERE e.object_id = ANY($1)
        """,
        [object_ids]
      )

    Map.new(rows, fn [row] -> {row["object_id"], row} end)
  end

  defp comparable(row), do: Map.drop(row, ["record_type"])

  # The pinned revisions that are no longer their record's current one: the
  # revision whose key is the record's content hash, which may be an earlier
  # row when a payload returns to what it was.
  defp stale_pins(result) do
    pins = Enum.reject([result.source_revision | result.evidence], &is_nil/1)

    current =
      if pins == [] do
        %{}
      else
        %{rows: rows} =
          Repo.query!(
            """
            SELECT r.external_id, v.id, v.checksum
              FROM source_records r
              JOIN sources s ON s.id = r.source_id AND s.slug = 'wikidata'
              JOIN source_record_revisions v
                ON v.source_record_id = r.id AND v.revision_key = r.content_hash
             WHERE r.external_id = ANY($1)
            """,
            [Enum.map(pins, & &1["qid"])]
          )

        Map.new(rows, fn [qid, id, checksum] -> {qid, {id, checksum}} end)
      end

    for pin <- pins,
        Map.get(current, pin["qid"]) != {pin["revision_id"], pin["checksum"]},
        uniq: true,
        do: pin["qid"]
  end

  # ── what a run produced ──────────────────────────────────────────────────

  @doc "Counts by disposition for a run."
  def summary(run_id) do
    counts =
      from(i in BackfillItem,
        where: i.run_id == ^run_id,
        group_by: i.disposition,
        select: {i.disposition, count(i.id)}
      )
      |> Repo.all()
      |> Map.new()

    %{run_id: run_id, items: Enum.sum(Map.values(counts)), dispositions: counts}
  end

  @doc """
  The candidate launch manifest for a run: every population record, its
  disposition, its current decision (with the evidence fingerprint a
  reviewer confirms), its page and its address — allocated, or proposed and
  awaiting review. `publication_approved` counts its pages that are
  published: candidate status grants no publication approval.
  """
  def manifest(run_key) do
    run = Repo.get_by!(BackfillRun, run_key: run_key)

    items =
      Repo.all(
        from i in BackfillItem,
          where: i.run_id == ^run.id,
          left_join: d in Decision,
          on: d.object_id == i.object_id and d.is_current,
          left_join: p in Page,
          on: p.id == i.page_id,
          left_join: c in PublicPath,
          on: c.id == p.canonical_path_id,
          order_by: i.position,
          select: %{
            object_id: i.object_id,
            disposition: i.disposition,
            reason: i.reason,
            status: d.status,
            family: d.family,
            decided_by: d.origin,
            evidence_fingerprint: d.evidence_fingerprint,
            page_id: p.id,
            page_role: p.role,
            publication_state: p.publication_state,
            address: c.path,
            proposed_path: i.proposed_path
          }
      )

    %{
      "run_key" => run.run_key,
      "inputs" => %{
        "input_sha256" => run.input_sha256,
        "policy_sha256" => run.policy_sha256,
        "policy_version" => run.policy_version,
        "population_sha256" => run.population_sha256,
        "reviews_sha256" => run.reviews_sha256
      },
      "publication_approved" => Enum.count(items, &(&1.publication_state == :published)),
      "dispositions" => Enum.frequencies_by(items, & &1.disposition),
      "records" => items
    }
  end

  @doc """
  What a run left for each of its objects, by identity rather than by
  numeric id: its checkpoint row and what it references, every decision in
  order, the page, every address the page owns, and every ledger row about
  the page. Two runs over the same database state — one interrupted and
  resumed, one not — must answer the same, whatever sequence values a
  rolled-back batch used.
  """
  def state(run_key) do
    run = Repo.get_by!(BackfillRun, run_key: run_key)
    ids = done(run.id) |> MapSet.to_list()

    decision_row = fn d ->
      reviewer =
        d.reviewer_actor_id &&
          Repo.one(from a in Actor, where: a.id == ^d.reviewer_actor_id, select: a.user_id)

      {d.origin, d.status, d.family, d.evidence_fingerprint, d.policy_version, d.is_current,
       reviewer}
    end

    decisions =
      Repo.all(from d in Decision, where: d.object_id in ^ids, order_by: d.id)
      |> Enum.group_by(& &1.object_id, decision_row)

    pages = Repo.all(from p in Page, where: p.target_object_id in ^ids)
    page_of = Map.new(pages, &{&1.id, &1})

    path_of = fn
      nil -> nil
      id -> Repo.get!(PublicPath, id).path
    end

    paths =
      Repo.all(
        from pp in PublicPath,
          join: p in Page,
          on: p.id == pp.original_page_id,
          where: p.target_object_id in ^ids,
          order_by: pp.path,
          select: {p.target_object_id, {pp.path, pp.kind}}
      )
      |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))

    # Path rows name their destination page, page rows the page itself. The
    # operation's random id is left out; its sequence and content are not.
    ledger =
      Repo.all(
        from c in RouteChange,
          join: p in Page,
          on:
            p.id == c.page_id or p.id == c.after_destination_id or p.id == c.before_destination_id,
          where: p.target_object_id in ^ids,
          order_by: c.id,
          select: {p.target_object_id, c}
      )
      |> Enum.group_by(&elem(&1, 0), fn {_id, c} ->
        decision =
          c.classification_decision_id && Repo.get!(Decision, c.classification_decision_id)

        {c.operation, c.sequence, path_of.(c.path_id), c.before_kind, c.after_kind,
         path_of.(c.before_canonical_path_id), path_of.(c.after_canonical_path_id),
         c.before_lifecycle, c.after_lifecycle, c.policy_version, c.reason,
         decision && decision_row.(decision)}
      end)

    items =
      Repo.all(from i in BackfillItem, where: i.run_id == ^run.id)
      |> Map.new(fn i ->
        decision = i.decision_id && Repo.get!(Decision, i.decision_id)
        page = i.page_id && page_of[i.page_id]

        {i.object_id,
         {i.position, i.disposition, i.reason, i.proposed_path,
          decision && decision_row.(decision), page && {page.role, page.locale},
          path_of.(i.path_id)}}
      end)

    Map.new(ids, fn id ->
      page = Enum.find(pages, &(&1.target_object_id == id))

      {id,
       %{
         item: items[id],
         decisions: Map.get(decisions, id, []),
         page:
           page &&
             {page.role, page.locale, page.publication_state, page.lifecycle_state,
              path_of.(page.canonical_path_id)},
         paths: Map.get(paths, id, []),
         ledger: Map.get(ledger, id, [])
       }}
    end)
  end
end
