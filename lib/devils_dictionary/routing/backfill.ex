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
    * the reviews, if any: each names one population record, an action, the
      reviewer's account and a reason.

  The same four digests are the same run: its checkpoint is reused. A new
  review file is a new run over the same population, and its writes are the
  same idempotent writes, so identities carry over.

  ## Per record, in object-id order

    1. The record's evaluator input is read back from the database and
       compared with the export, and the evidence the evaluator pins must
       still be current. Anything else is a deferral with its reason, never
       a classification of stale evidence.
    2. `Policy.classify/3`, then `Classifications.record/1` — which writes
       nothing when the evidence is unchanged, and keeps a standing override.
    3. What the population and the reviews say:
       * **excluded or deferred** in the population: nothing more;
       * **heading for an address** (an allocation candidate or a collision
         to qualify): `Pages.ensure/3`, then, only with a reviewer's
         `confirm`, the reviewer's override (once) and `Ledger.allocate/3`
         of the approved path;
       * **awaiting a classification or identity review**: no page until a
         reviewer confirms a family;
       * a reviewer's `defer`: nothing more, with the reviewer's reason.
    4. One checkpoint row (`routing_backfill_items`) with the disposition and
       the ids it produced.

  A batch is one transaction: its writes and its checkpoints commit
  together, so an interruption loses at most the batch in hand, and a resumed
  run starts after the last committed record. Every writer it calls refuses
  per record without rolling the batch back (Stage 1, decision 7).

  Nothing here publishes: pages stay `draft`, and candidate status grants no
  publication approval.
  """

  import Ecto.Query

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
    PublicPath
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
  """
  def load(snapshot_path, population_path, reviews_path \\ nil) do
    with {:ok, snapshot} <- AuditSnapshot.read(snapshot_path),
         {:ok, population} <- population(population_path),
         policy_sha256 = AuditSnapshot.policy_digest(),
         :ok <- bound(population, snapshot, policy_sha256),
         {:ok, reviews, reviews_sha256} <- reviews(reviews_path, population.records) do
      entities = Map.new(snapshot.entities, &{&1["object_id"], &1})

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
         entities: entities,
         graph: snapshot.graph,
         reviews: reviews
       }}
    end
  end

  defp population(path) do
    with {:ok, bytes} <- File.read(path),
         {:ok, %{"records" => records, "summary" => summary}} <- Jason.decode(bytes) do
      ids = Enum.map(records, & &1["object_id"])

      cond do
        not Enum.all?(ids, &(is_integer(&1) and &1 > 0)) ->
          {:error, "population #{path}: every record needs a positive object_id"}

        length(ids) != length(Enum.uniq(ids)) ->
          {:error, "population #{path}: an object id appears twice"}

        true ->
          {:ok,
           %{
             records: records,
             inputs: summary["inputs"] || %{},
             sha256: AuditSnapshot.digest(bytes)
           }}
      end
    else
      {:ok, _other} -> {:error, "population #{path}: not a candidates file (records, summary)"}
      {:error, %Jason.DecodeError{}} -> {:error, "population #{path}: not JSON"}
      {:error, reason} -> {:error, "cannot read #{path}: #{:file.format_error(reason)}"}
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

  defp reviews(nil, _records), do: {:ok, %{}, nil}

  defp reviews(path, records) do
    known = MapSet.new(records, & &1["object_id"])

    with {:ok, bytes} <- File.read(path),
         {:ok, %{"reviews" => entries}} when is_list(entries) <- Jason.decode(bytes),
         {:ok, reviews} <- review_entries(entries, known) do
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

  defp review_entries(entries, known) do
    Enum.reduce_while(entries, {:ok, %{}}, fn entry, {:ok, acc} ->
      case review(entry, known) do
        {:ok, review} ->
          if Map.has_key?(acc, review.object_id),
            do: {:halt, {:error, "two reviews for object #{review.object_id}"}},
            else: {:cont, {:ok, Map.put(acc, review.object_id, review)}}

        {:error, message} ->
          {:halt, {:error, message}}
      end
    end)
  end

  defp review(%{"object_id" => id, "action" => action} = entry, known) do
    reviewer = entry["reviewer"]
    reason = entry["reason"]

    cond do
      not MapSet.member?(known, id) ->
        {:error, "review for object #{inspect(id)}, which is not in the population"}

      action not in ["confirm", "defer"] ->
        {:error, "review for object #{id}: unknown action #{inspect(action)}"}

      not (is_binary(reason) and String.trim(reason) != "") ->
        {:error, "review for object #{id}: a reason is required"}

      not is_binary(reviewer) ->
        {:error, "review for object #{id}: name the reviewer's account by email"}

      action == "confirm" and entry["family"] not in families() ->
        {:error,
         "review for object #{id}: a confirmation names a family, one of #{Enum.join(families(), ", ")}"}

      not (is_nil(entry["path"]) or is_binary(entry["path"])) ->
        {:error, "review for object #{id}: a path is a string"}

      true ->
        {:ok,
         %{
           object_id: id,
           action: String.to_existing_atom(action),
           family: entry["family"],
           path: entry["path"],
           reviewer: reviewer,
           reason: reason,
           entry: entry
         }}
    end
  end

  defp review(_entry, _known), do: {:error, "a review needs object_id and action"}

  defp families, do: Enum.map(Ecto.Enum.values(Decision, :family), &Atom.to_string/1)

  # ── running ──────────────────────────────────────────────────────────────

  @doc """
  Runs `plan` (from `load/3`) with the import actor `actor_id`, resuming its
  checkpoint if one exists. Options: `batch_size` (default 25);
  `crash_after`, for tests, raises after that many records of this call have
  been processed, inside their batch.

  Returns `{:ok, summary}` or `{:error, message}` for a refusal made before
  anything is written (an unknown reviewer, say).
  """
  def run(plan, actor_id, opts \\ []) do
    with {:ok, reviewers} <- reviewers(plan.reviews) do
      run = open!(plan, actor_id)
      done = done(run.id)

      todo =
        Enum.reject(Enum.with_index(plan.records), fn {r, _i} ->
          MapSet.member?(done, r["object_id"])
        end)

      crash_after = Keyword.get(opts, :crash_after)

      todo
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

  # Every reviewer named is an account with the reviewer role, answered as a
  # `user` actor — the only kind the database lets override or approve.
  defp reviewers(reviews) do
    reviews
    |> Map.values()
    |> Enum.map(& &1.reviewer)
    |> Enum.uniq()
    |> Enum.reduce_while({:ok, %{}}, fn email, {:ok, acc} ->
      case Repo.get_by(User, email: email) do
        %User{reviewer: true} = user -> {:cont, {:ok, Map.put(acc, email, user_actor!(user))}}
        %User{} -> {:halt, {:error, "#{email} does not hold the reviewer role"}}
        nil -> {:halt, {:error, "no account #{email}"}}
      end
    end)
  end

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
            classified(result, record, Map.get(plan.reviews, id), reviewers, actor_id, proposed)

          stale ->
            deferral("evidence_changed", "not current: " <> Enum.join(stale, ", "), proposed)
        end
    end
  end

  defp classified(result, record, review, reviewers, actor_id, proposed) do
    case Classifications.record(result) do
      {:ok, _outcome, decision} ->
        act(record, review, decision, reviewers, actor_id, proposed)

      {:error, reason} ->
        deferral("classification_refused", inspect(reason), proposed)
    end
  end

  defp act(record, review, decision, reviewers, actor_id, proposed) do
    kind = population_kind(record["disposition"])

    cond do
      kind == :not_addressed ->
        %{
          disposition: "not_addressed",
          reason: record["disposition"],
          decision_id: decision.id,
          proposed_path: nil
        }

      review && review.action == :defer ->
        %{
          disposition: "deferred_by_review",
          reason: review.reason,
          decision_id: decision.id,
          proposed_path: proposed,
          review: review.entry
        }

      review && review.action == :confirm ->
        confirm(record, review, decision, Map.fetch!(reviewers, review.reviewer), actor_id)

      kind == :heading_for_address ->
        with_page(record, decision, fn page ->
          %{
            disposition: "awaiting_review",
            reason: record["disposition"],
            decision_id: decision.id,
            page_id: page.id,
            proposed_path: proposed
          }
        end)

      true ->
        %{
          disposition: "awaiting_review",
          reason: record["disposition"],
          decision_id: decision.id,
          proposed_path: proposed
        }
    end
  end

  # A reviewer's confirmation: their override of the decision they saw (once),
  # the page, and the approved address.
  defp confirm(record, review, decision, reviewer, actor_id) do
    path = review.path || uncontested(record)

    with {:ok, parsed} <- path_for(path),
         :ok <- same_family(parsed, review.family),
         {:ok, decision} <- confirmed(record["object_id"], review, decision, reviewer) do
      with_page(record, decision, fn page ->
        reason =
          "Stage 2 backfill: address approved by reviewer ##{reviewer.user_id} — #{review.reason}"

        case Ledger.allocate(page.id, parsed.path, actor_id: actor_id, reason: reason) do
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
            %{
              disposition: "refused",
              reason: inspect(refusal),
              decision_id: decision.id,
              page_id: page.id,
              proposed_path: parsed.path,
              review: review.entry
            }
        end
      end)
    else
      {:refused, reason} ->
        %{
          disposition: "refused",
          reason: reason,
          decision_id: decision.id,
          proposed_path: path,
          review: review.entry
        }
    end
  end

  # The candidate path only when nothing else in the population proposes it:
  # a collision group is qualified by a reviewer, never by import order.
  defp uncontested(%{"address_status" => "candidate", "candidate_path" => path}), do: path
  defp uncontested(_record), do: nil

  defp path_for(nil), do: {:refused, "no approved path: a collision is qualified by its reviewer"}

  defp path_for(path) do
    case Address.parse(path) do
      {:ok, parsed} -> {:ok, parsed}
      {:error, reason} -> {:refused, "the approved path is not an address: #{inspect(reason)}"}
    end
  end

  defp same_family(%{namespace: family}, family), do: :ok

  defp same_family(%{namespace: namespace}, family),
    do: {:refused, "the approved path is in /#{namespace}, the confirmed family is #{family}"}

  # Already the reviewer's current decision for this family: nothing to write.
  defp confirmed(
         _id,
         %{family: family},
         %Decision{origin: :override, status: :mapped} = decision,
         reviewer
       )
       when decision.reviewer_actor_id == reviewer.id do
    if Atom.to_string(decision.family) == family,
      do: {:ok, decision},
      else: {:refused, "a standing override maps it to #{decision.family}"}
  end

  defp confirmed(id, review, decision, reviewer) do
    attrs = %{
      status: :mapped,
      family: String.to_existing_atom(review.family),
      reason: review.reason,
      evidence_fingerprint: decision.evidence_fingerprint
    }

    case Classifications.override(id, attrs, reviewer.id) do
      {:ok, override} -> {:ok, override}
      {:error, reason} -> {:refused, "the reviewer's override was refused: #{inspect(reason)}"}
    end
  end

  defp with_page(record, decision, fun) do
    case Pages.ensure(:subject, record["object_id"]) do
      {:ok, page} ->
        fun.(page)

      {:error, reason} ->
        %{
          disposition: "refused",
          reason: "page: #{inspect(reason)}",
          decision_id: decision.id,
          proposed_path: record["proposed_path"] || record["candidate_path"]
        }
    end
  end

  defp deferral(disposition, reason, proposed),
    do: %{disposition: disposition, reason: reason, proposed_path: proposed}

  defp population_kind(disposition) do
    cond do
      starts_with_any?(disposition, @not_addressed) -> :not_addressed
      starts_with_any?(disposition, @heading_for_address) -> :heading_for_address
      starts_with_any?(disposition, @awaiting_review) -> :awaiting_review
      true -> :awaiting_review
    end
  end

  defp starts_with_any?(text, prefixes),
    do: Enum.any?(prefixes, &String.starts_with?(text || "", &1))

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

  # The pinned revisions that are no longer their record's latest.
  defp stale_pins(result) do
    pins = Enum.reject([result.source_revision | result.evidence], &is_nil/1)

    latest =
      if pins == [] do
        %{}
      else
        %{rows: rows} =
          Repo.query!(
            """
            SELECT r.external_id, max(v.id)
              FROM source_records r
              JOIN sources s ON s.id = r.source_id AND s.slug = 'wikidata'
              JOIN source_record_revisions v ON v.source_record_id = r.id
             WHERE r.external_id = ANY($1)
             GROUP BY r.external_id
            """,
            [Enum.map(pins, & &1["qid"])]
          )

        Map.new(rows, fn [qid, id] -> {qid, id} end)
      end

    for pin <- pins, Map.get(latest, pin["qid"]) != pin["revision_id"], uniq: true, do: pin["qid"]
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
  disposition, decision, page and address (allocated, or proposed and
  awaiting review). Candidate status grants no publication approval.
  """
  def manifest(run_key) do
    run = Repo.get_by!(BackfillRun, run_key: run_key)

    items =
      Repo.all(
        from i in BackfillItem,
          where: i.run_id == ^run.id,
          left_join: d in Decision,
          on: d.id == i.decision_id,
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
            page_id: p.id,
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
      "publication_approved" => 0,
      "dispositions" => Enum.frequencies_by(items, & &1.disposition),
      "records" => items
    }
  end

  @doc """
  What a run left for each of its objects, by identity rather than by
  numeric id: the current decision, the page and its addresses. Two runs
  over the same database state — one interrupted and resumed, one not —
  must answer the same, whatever sequence values a rolled-back batch used.
  """
  def state(run_key) do
    run = Repo.get_by!(BackfillRun, run_key: run_key)
    ids = done(run.id) |> MapSet.to_list()

    decisions =
      Repo.all(
        from d in Decision,
          where: d.object_id in ^ids and d.is_current,
          select:
            {d.object_id,
             {d.origin, d.status, d.family, d.evidence_fingerprint, d.policy_version}}
      )
      |> Map.new()

    pages =
      Repo.all(
        from p in Page,
          where: p.target_object_id in ^ids,
          left_join: c in PublicPath,
          on: c.id == p.canonical_path_id,
          select:
            {p.target_object_id,
             {p.role, p.locale, p.publication_state, p.lifecycle_state, c.path}}
      )
      |> Map.new()

    paths =
      Repo.all(
        from pp in PublicPath,
          join: p in Page,
          on: p.id == pp.original_page_id,
          where: p.target_object_id in ^ids,
          select: {p.target_object_id, {pp.path, pp.kind}}
      )
      |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
      |> Map.new(fn {id, list} -> {id, Enum.sort(list)} end)

    items =
      Repo.all(
        from i in BackfillItem,
          where: i.run_id == ^run.id,
          select: {i.object_id, {i.position, i.disposition, i.reason, i.proposed_path}}
      )
      |> Map.new()

    Map.new(ids, fn id ->
      {id,
       %{
         item: items[id],
         decision: decisions[id],
         page: pages[id],
         paths: Map.get(paths, id, [])
       }}
    end)
  end
end
