defmodule DevilsDictionary.Routing.Classifications do
  @moduledoc """
  Persisted classification decisions (ADR 0004 §3, "Authorities, mappings and
  overrides").

  `record/1` stores a `Routing.Policy.classify/3` result; `override/3` stores a
  human reviewer's decision about the exact evidence they reviewed. Each object
  has at most one current decision, and every earlier one is kept.

  How an override survives a reimport:

    * **same evidence fingerprint** — the override stays current and nothing is
      written;
    * **changed evidence that is not new against it** — the evaluator reaches
      the outcome the reviewer already overrode, or still offers the override's
      family (a new Wikidata revision with the same types, say) — the override
      stays current, and the new evidence is kept in history as a non-current
      decision;
    * **contradictory evidence** — a new current `needs_review` decision,
      superseding the override, which stays in history. That review is sticky:
      later imports update its evidence but only a human's new override ends it.

  None of this touches an address. A decision has no foreign key to a path,
  and `Routing.Ledger` reads a decision only when it allocates or moves one;
  after that, a reclassification can put a page under review but cannot move it.
  """

  import Ecto.Query

  alias DevilsDictionary.Repo
  alias DevilsDictionary.Routing.ClassificationDecision, as: Decision
  alias DevilsDictionary.Sources.Actor

  @statuses Map.new(Decision.statuses(), &{Atom.to_string(&1), &1})
  @families Map.new(Decision.families(), &{Atom.to_string(&1), &1})
  @decisive [:excluded_source_page, :identity_review]

  @doc "The current decision for an entity, or nil."
  def current(object_id) do
    Repo.one(from d in Decision, where: d.object_id == ^object_id and d.is_current)
  end

  @doc "Every decision for an entity, newest first."
  def history(object_id) do
    Repo.all(from d in Decision, where: d.object_id == ^object_id, order_by: [desc: d.id])
  end

  @doc """
  The evidence an evaluator result considered, as a SHA-256.

  Covers the pinned source revision, the pinned class evidence, the matched
  rule paths, the warnings and the outcome — status, reasons and candidates,
  which also carry the inputs that are not evidence records, such as a merged
  identity or a disambiguation flag. Not the label, which never classifies.
  """
  def fingerprint(result) do
    %{
      "stored_kind" => result.stored_kind,
      "source_revision" => result.source_revision,
      "evidence" => result.evidence,
      "matches" =>
        Enum.map(result.matches, &%{"rule" => &1.id, "family" => &1.family, "path" => &1.path}),
      "warnings" => result.warnings,
      "status" => result.status,
      "reasons" => result.reasons,
      "candidate_families" => result.candidate_families
    }
    |> canonical()
    |> Jason.encode!()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  defp canonical(value) when is_map(value) do
    value
    |> Enum.map(fn {key, item} -> {to_string(key), canonical(item)} end)
    |> Enum.sort_by(&elem(&1, 0))
    |> Jason.OrderedObject.new()
  end

  defp canonical(value) when is_list(value), do: Enum.map(value, &canonical/1)
  defp canonical(value), do: value

  @doc """
  Records an evaluator result for an entity.

  Returns `{:ok, outcome, decision}` where `outcome` is `:recorded`,
  `:unchanged`, `:override_preserved` or `:override_contradicted`, and
  `decision` is the entity's current decision afterwards.
  """
  def record(%{object_id: object_id} = result) do
    attrs = evaluator_attrs(result)

    Repo.transaction(fn ->
      lock(object_id)
      current = current(object_id)

      case outcome(current, attrs) do
        {:keep, outcome} ->
          {outcome, current}

        {:note, outcome} ->
          note!(attrs)
          {outcome, current}

        {:write, outcome, attrs} ->
          {outcome, supersede!(current, attrs)}
      end
    end)
    |> case do
      {:ok, {outcome, decision}} -> {:ok, outcome, decision}
      error -> error
    end
  end

  defp outcome(nil, attrs), do: {:write, :recorded, attrs}

  defp outcome(%Decision{origin: :override} = override, attrs) do
    cond do
      attrs.evidence_fingerprint == override.evidence_fingerprint ->
        {:keep, :override_preserved}

      contradicts?(override, reviewed(override), attrs) ->
        {:write, :override_contradicted, review(attrs)}

      true ->
        {:note, :override_preserved}
    end
  end

  defp outcome(%Decision{} = current, attrs) do
    cond do
      current.evidence_fingerprint == attrs.evidence_fingerprint and
          current.policy_version == attrs.policy_version ->
        {:keep, :unchanged}

      # A contradicted override stays in review until a human decides again.
      "override_contradicted" in current.reasons ->
        {:write, :override_contradicted, review(attrs)}

      true ->
        {:write, :recorded, attrs}
    end
  end

  # The evaluator decision an override (or a chain of them) was made against.
  defp reviewed(%Decision{origin: :evaluator} = decision), do: decision
  defp reviewed(%Decision{supersedes_id: nil}), do: nil
  defp reviewed(%Decision{supersedes_id: id}), do: Decision |> Repo.get!(id) |> reviewed()

  # The outcome the reviewer already overrode is not new evidence against the
  # override, however its revision pins moved. Otherwise new evidence
  # contradicts it when it no longer offers the chosen family, or reaches an
  # outcome the reviewer ruled out.
  defp contradicts?(override, reviewed, attrs) do
    not already_reviewed?(reviewed, attrs) and against?(override, attrs)
  end

  # The reviewer saw these candidates. A contradiction review records
  # `needs_review` in place of the evaluator's own status, so status counts
  # only when it is decisive: an exclusion or an identity change.
  defp already_reviewed?(nil, _attrs), do: false

  defp already_reviewed?(%Decision{} = reviewed, attrs) do
    reviewed.candidate_families == attrs.candidate_families and
      (attrs.status not in @decisive or attrs.status == reviewed.status)
  end

  defp against?(%Decision{status: :mapped, family: family}, attrs) do
    attrs.status in @decisive or
      (attrs.candidate_families != [] and Atom.to_string(family) not in attrs.candidate_families)
  end

  defp against?(%Decision{status: status}, attrs) do
    attrs.status == :mapped or (attrs.status in @decisive and attrs.status != status)
  end

  # Evidence that moved under a standing override is kept, not made current.
  defp note!(attrs) do
    exists? =
      Repo.exists?(
        from d in Decision,
          where:
            d.object_id == ^attrs.object_id and d.origin == :evaluator and
              d.evidence_fingerprint == ^attrs.evidence_fingerprint and
              d.policy_version == ^attrs.policy_version
      )

    unless exists?, do: Repo.insert!(struct(Decision, Map.put(attrs, :is_current, false)))
  end

  defp review(attrs) do
    %{
      attrs
      | status: :needs_review,
        family: nil,
        reasons: ["override_contradicted" | attrs.reasons]
    }
  end

  defp evaluator_attrs(result) do
    %{
      object_id: result.object_id,
      origin: :evaluator,
      status: Map.fetch!(@statuses, result.status),
      # The evaluator names a sole candidate as `family` whatever the status;
      # only a mapping selects it.
      family: if(result.status == "mapped", do: Map.fetch!(@families, result.family)),
      candidate_families: result.candidate_families,
      rule_ids: result.matches |> Enum.map(& &1.id) |> Enum.uniq() |> Enum.sort(),
      reasons: result.reasons,
      warnings: result.warnings,
      policy_version: result.policy_version,
      evidence_fingerprint: fingerprint(result),
      source_pins: Enum.reject([result.source_revision | result.evidence], &is_nil/1)
    }
  end

  @doc """
  Records a human reviewer's decision about the evidence they reviewed.

  `attrs` takes `:status`, `:family` (only with `:mapped`), `:reason` and
  `:evidence_fingerprint` — the fingerprint of the current decision the
  reviewer saw. If the evidence has changed since, the override is refused as
  `:stale_evidence`: an override describes exact evidence. Only a `user` actor
  may override; the database refuses any other.
  """
  def override(object_id, attrs, reviewer_actor_id) do
    with :ok <- human(reviewer_actor_id),
         {:ok, status, family} <- verdict(attrs),
         {:ok, reason} <- present(attrs[:reason]) do
      seen = attrs[:evidence_fingerprint]

      Repo.transaction(fn ->
        lock(object_id)

        case current(object_id) do
          nil ->
            Repo.rollback(:no_evaluated_evidence)

          %Decision{evidence_fingerprint: ^seen} = current ->
            supersede!(current, %{
              object_id: object_id,
              origin: :override,
              status: status,
              family: family,
              candidate_families: current.candidate_families,
              rule_ids: ["editorial_override"],
              reasons: ["editorial_override"],
              warnings: current.warnings,
              policy_version: current.policy_version,
              evidence_fingerprint: seen,
              source_pins: current.source_pins,
              reviewer_actor_id: reviewer_actor_id,
              reason: reason
            })

          _stale ->
            Repo.rollback(:stale_evidence)
        end
      end)
    end
  end

  defp human(id) do
    if is_integer(id) and
         Repo.exists?(from a in Actor, where: a.id == ^id and a.actor_kind == :user),
       do: :ok,
       else: {:error, :human_reviewer_required}
  end

  defp verdict(%{status: :mapped, family: family}) when is_atom(family) and not is_nil(family) do
    if family in Decision.families(), do: {:ok, :mapped, family}, else: {:error, :unknown_family}
  end

  defp verdict(%{status: status} = attrs)
       when status in [:needs_review, :excluded_source_page, :identity_review] do
    if is_nil(attrs[:family]), do: {:ok, status, nil}, else: {:error, :family_requires_mapping}
  end

  defp verdict(_attrs), do: {:error, :invalid_verdict}

  defp present(reason) when is_binary(reason) do
    case String.trim(reason) do
      "" -> {:error, :reason_required}
      trimmed -> {:ok, trimmed}
    end
  end

  defp present(_reason), do: {:error, :reason_required}

  defp supersede!(nil, attrs),
    do: Repo.insert!(struct(Decision, Map.put(attrs, :is_current, true)))

  defp supersede!(%Decision{id: id}, attrs) do
    {1, _} = Repo.update_all(from(d in Decision, where: d.id == ^id), set: [is_current: false])
    Repo.insert!(struct(Decision, Map.merge(attrs, %{is_current: true, supersedes_id: id})))
  end

  defp lock(object_id) do
    Repo.query!("SELECT pg_advisory_xact_lock(hashtextextended($1, 0))", [
      "routing-classification:#{object_id}"
    ])
  end
end
