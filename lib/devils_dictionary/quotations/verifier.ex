defmodule DevilsDictionary.Quotations.Verifier do
  @moduledoc """
  Checks every stored quotation credited to — or misattributed to — a person
  against the sources that can confirm or contradict it, and records what it
  finds (#158 build 5).

  A pass is **per person** (`verify_author/2`): their own Wikiquote page, the
  works Wikidata says they wrote, and those works' texts are one set of
  requests for every line credited to them, and each is cached as a source
  record (`Verifier.Fetch`). What the checks find (`Verifier.Checks`) plus the
  claims already held go to `Badge.compute/2`.

  ## What it writes

    * **`assertion_evidence`** — on each credit (`authored_by`) to this person,
      one row per finding: `:supports` for the author's page listing the line
      under a cited work or a primary text containing it (with its line),
      `:contradicts` for a row in the author's own page's register;
      `source_record_revision_id` is the fetched record, `locator` says where.
      On a `misattributed_to`, a register that agrees is `:supports` — the
      author's page or *Misquotations*. A *Misquotations* row is never evidence
      against a credit: it names no one by identifier, and its note usually
      names the true author, whom it would otherwise dispute.
    * **a new revision of each credit**, `method: "verifier"`, `confidence` =
      the #65 score, `metadata["verifier"]` set — which is what makes it
      *protected*: a provider refresh never overwrites a verifier's revision
      (#164 C3). Written only when the findings changed, so re-verifying an
      unchanged line writes nothing. A credit a person has reviewed is left
      alone.
    * **the badge**, on `content_items.metadata["provenance"]` — derived,
      recomputed each pass, never authoritative. On the item and not on a
      content revision, because a revision is immutable (a review cites it).
      It is the item's: every current credit and misattribution on the line,
      whoever it names, plus this pass's checks and the checks other people's
      passes left on their credits — so two people's passes over one line
      agree on its badge.

  ## When

  `run_due/1`, from `VerifyWorker` on Oban's cron: every person with a
  quotation claim and no pass newer than their `refresh_after`. A deferral (a
  `429`, an exhausted budget) sets the clock to the retry time; a success to
  the refresh window; a failure — an exception included, so one person cannot
  stop the batch — to the failure backoff. Re-verification is the clock, not a
  rerun of the shelf.
  """

  import Ecto.Query

  alias DevilsDictionary.Claims
  alias DevilsDictionary.Claims.{Assertion, AssertionEvidence, AssertionReview, AssertionRevision}
  alias DevilsDictionary.Claims.Predicate
  alias DevilsDictionary.Quotations.{Badge, VerificationRun}
  alias DevilsDictionary.Quotations.Verifier.Checks

  alias DevilsDictionary.Registry.{
    ContentItem,
    ContentRevision,
    ExternalIdentifier,
    PersonDetails
  }

  alias DevilsDictionary.Repo
  alias DevilsDictionary.Sources.Source

  require Logger

  @method "verifier"
  @predicates ~w(authored_by misattributed_to)

  @doc "The method a verifier revision carries."
  def method, do: @method

  # ── when ────────────────────────────────────────────────────────────────

  @doc "The people with a quotation claim whose verification is due, oldest first."
  def due(limit \\ 5) do
    now = DateTime.utc_now()

    fresh =
      from run in VerificationRun,
        where:
          (run.status in [:succeeded, :deferred, :failed] and run.refresh_after > ^now) or
            (run.status == :running and run.started_at > ^DateTime.add(now, -3_600, :second)),
        select: run.subject_object_id

    Repo.all(
      from r in AssertionRevision,
        join: p in Predicate,
        on: p.id == r.predicate_id and p.key in @predicates,
        where:
          r.is_current and r.lifecycle_state == :active and r.subject_kind == "content" and
            r.subject_subkind == "quotation" and r.object_object_id not in subquery(fresh),
        distinct: true,
        order_by: r.object_object_id,
        limit: ^limit,
        select: r.object_object_id
    )
  end

  @doc "Verifies every due person, one pass each. Returns the runs."
  def run_due(limit \\ 5), do: Enum.map(due(limit), &verify_author/1)

  # ── one pass ────────────────────────────────────────────────────────────

  @doc """
  One pass over everything credited or misattributed to `person_id`.
  Returns the finished `VerificationRun`.
  """
  def verify_author(person_id, opts \\ []) do
    now = DateTime.utc_now()

    run =
      %VerificationRun{}
      |> VerificationRun.changeset(%{
        subject_object_id: person_id,
        status: :running,
        started_at: now
      })
      |> Repo.insert!()

    try do
      pass(run, person_id, opts)
    rescue
      exception ->
        Logger.error(
          "quotation verifier: pass #{run.id} for #{person_id} raised " <>
            Exception.format(:error, exception, __STACKTRACE__)
        )

        finish(run, :failed, failure_seconds(), %{}, "exception")
    end
  end

  defp pass(run, person_id, opts) do
    lines = lines(person_id)
    max_age = Keyword.get(opts, :max_age, refresh_seconds())

    with {:ok, qid} <- qid(person_id),
         {:ok, page} <- Checks.author_page(run, qid, max_age),
         {:ok, misquotations} <- Checks.misquotations(run, max_age),
         {:ok, texts} <- texts(run, qid, lines, max_age) do
      verdicts =
        Repo.transaction(fn ->
          Enum.map(lines, &record_line(&1, person_id, page, misquotations, texts))
        end)
        |> elem(1)

      finish(run, :succeeded, refresh_seconds(), summary(verdicts))
    else
      {:deferred, seconds} ->
        finish(run, :deferred, seconds, %{"lines" => length(lines)}, "deferred")

      {:error, code} ->
        finish(run, :failed, failure_seconds(), %{"lines" => length(lines)}, code)
    end
  end

  defp texts(run, qid, lines, max_age) do
    if Enum.any?(lines, &(&1.credits != [])),
      do: Checks.gutenberg_texts(run, qid, max_age),
      else: {:ok, []}
  end

  defp qid(person_id) do
    case Repo.one(
           from i in ExternalIdentifier,
             where:
               i.object_id == ^person_id and i.namespace == "wikidata" and i.status == :verified,
             select: i.external_id,
             limit: 1
         ) do
      nil -> {:error, "no_qid"}
      qid -> {:ok, qid}
    end
  end

  defp dated?(person_ids) do
    Repo.exists?(
      from d in PersonDetails,
        where:
          d.entity_id in ^person_ids and (not is_nil(d.birth_date) or not is_nil(d.death_date))
    )
  end

  defp finish(run, status, seconds, summary, error \\ nil) do
    now = DateTime.utc_now()

    run
    |> Repo.reload!()
    |> VerificationRun.changeset(%{
      status: status,
      completed_at: now,
      refresh_after: DateTime.add(now, seconds, :second),
      summary: summary,
      error_code: error
    })
    |> Repo.update!()
  end

  defp summary(verdicts) do
    %{
      "lines" => length(verdicts),
      "badges" => Enum.frequencies_by(verdicts, &(&1.badge || "none"))
    }
  end

  # ── the lines ───────────────────────────────────────────────────────────

  # Every quotation with a current, active credit or misattribution to this
  # person, with its current words and every current claim on it — this
  # person's and anyone else's — with each claim's source.
  defp lines(person_id) do
    content_ids =
      Repo.all(
        from r in current_claims(),
          where: r.object_object_id == ^person_id,
          distinct: true,
          select: r.subject_object_id
      )

    claims =
      Repo.all(
        from [r, p, a, s] in current_claims(),
          where: r.subject_object_id in ^content_ids,
          select: %{revision: r, predicate: p.key, source: s.slug}
      )

    bodies =
      Repo.all(
        from c in ContentRevision,
          where:
            c.content_id in ^Enum.map(claims, & &1.revision.subject_object_id) and c.is_current,
          select: {c.content_id, %{body: c.body, year: c.year}}
      )
      |> Map.new()

    claims
    |> Enum.group_by(& &1.revision.subject_object_id)
    |> Enum.flat_map(fn {content_id, claims} ->
      {own, others} = Enum.split_with(claims, &(&1.revision.object_object_id == person_id))

      case Map.get(bodies, content_id) do
        %{body: body} = content when is_binary(body) ->
          [
            %{
              content_id: content_id,
              body: body,
              year: content.year,
              credits: Enum.filter(own, &(&1.predicate == "authored_by")),
              misattributions: Enum.filter(own, &(&1.predicate == "misattributed_to")),
              others: others
            }
          ]

        _ ->
          []
      end
    end)
  end

  defp current_claims do
    from r in AssertionRevision,
      join: p in Predicate,
      on: p.id == r.predicate_id and p.key in @predicates,
      join: a in Assertion,
      on: a.id == r.assertion_id,
      left_join: s in Source,
      on: s.id == a.source_id,
      where:
        r.is_current and r.lifecycle_state == :active and r.subject_kind == "content" and
          r.subject_subkind == "quotation"
  end

  defp record_line(line, person_id, page, misquotations, texts) do
    # What this person's own page and texts say: reached by their identifier,
    # so it may count for or against a credit to them.
    checks =
      Checks.match_page(page, line.body, "wikiquote") ++
        if(line.credits != [], do: Checks.match_texts(texts, line.body), else: [])

    # *Misquotations* names no one by identifier: it only ever agrees with a
    # misattribution already held, and never counts against a credit.
    registered =
      if line.misattributions != [],
        do: Checks.match_page(misquotations, line.body, "wikiquote"),
        else: []

    own = line.credits ++ line.misattributions

    verdict =
      Badge.compute(claim_findings(own, line) ++ checks, author_dated?: dated?([person_id]))

    for claim <- line.credits, do: record_credit(claim.revision, checks, verdict)

    for claim <- line.misattributions,
        do: record_misattribution(claim.revision, checks ++ registered)

    # The item's badge: every claim on the line, whoever it names; this pass's
    # checks; and the checks other people's passes left on their credits.
    everyone = own ++ line.others
    held = Enum.flat_map(line.others, &held_checks/1)

    credited =
      for claim <- everyone, claim.predicate == "authored_by", do: claim.revision.object_object_id

    item_verdict =
      Badge.compute(claim_findings(everyone, line) ++ checks ++ held,
        author_dated?: credited != [] and dated?(credited)
      )

    record_provenance(line.content_id, item_verdict)

    item_verdict
  end

  defp claim_findings(claims, line) do
    Enum.map(claims, fn
      %{predicate: "authored_by"} = claim ->
        %{source: claim.source || "unknown", kind: :cited, role: :supports, year: line.year}

      %{predicate: "misattributed_to"} = claim ->
        %{
          source: claim.source || "unknown",
          kind: :register,
          role: :contradicts,
          note: claim.revision.rationale
        }
    end)
  end

  @kinds %{"cited" => :cited, "primary" => :primary, "register" => :register}
  @roles %{"supports" => :supports, "contradicts" => :contradicts}

  # The checks another person's pass recorded on their credit.
  defp held_checks(%{predicate: "authored_by", revision: revision}) do
    for %{"source" => source, "kind" => kind, "role" => role} = check <-
          (revision.metadata || %{})["checks"] || [],
        Map.has_key?(@kinds, kind) and Map.has_key?(@roles, role) do
      %{source: source, kind: @kinds[kind], role: @roles[role], locator: check["locator"]}
    end
  end

  defp held_checks(_claim), do: []

  # A credit's verifier revision, and its evidence — only when what the
  # checks found changed, and never over a person's review.
  defp record_credit(%AssertionRevision{} = revision, checks, verdict) do
    digest = digest(checks, verdict)

    cond do
      revision.metadata["verifier_digest"] == digest ->
        :unchanged

      Repo.exists?(from r in AssertionReview, where: r.assertion_revision_id == ^revision.id) ->
        :reviewed

      true ->
        {:ok, verified} =
          Claims.revise(revision.assertion_id, %{
            method: @method,
            confidence: verdict.score,
            metadata:
              Map.merge(revision.metadata || %{}, %{
                "verifier" => "quotations.verifier.v#{Badge.version()}",
                "verifier_digest" => digest,
                "badge" => verdict.badge,
                "agreements" => verdict.agreements,
                "checks" => Enum.map(checks, &describe/1)
              })
          })

        for check <- checks, do: evidence!(verified.id, check, check.role)
        :revised
    end
  end

  # A register on the author's page or on *Misquotations* agrees with a
  # misattribution: supporting evidence on it, added once.
  defp record_misattribution(%AssertionRevision{} = revision, checks) do
    for check <- checks, check.role == :contradicts do
      held? =
        Repo.exists?(
          from e in AssertionEvidence,
            where:
              e.assertion_revision_id == ^revision.id and
                e.source_record_revision_id == ^check.record_revision_id and
                e.locator == ^check.locator
        )

      unless held?, do: evidence!(revision.id, check, :supports)
    end
  end

  defp evidence!(revision_id, check, role) do
    {:ok, _} =
      Claims.add_evidence(revision_id, %{
        evidence_role: role,
        source_record_revision_id: check.record_revision_id,
        locator: String.slice(to_string(check.locator), 0, 255),
        attribution_text: check[:note]
      })
  end

  defp record_provenance(content_id, verdict) do
    item = Repo.get!(ContentItem, content_id)

    provenance = %{
      "badge" => verdict.badge,
      "score" => verdict.score,
      "agreements" => verdict.agreements,
      "sources" => verdict.sources,
      "computed_at" => DateTime.to_iso8601(DateTime.utc_now()),
      "verifier_version" => Badge.version()
    }

    item
    |> ContentItem.changeset(%{metadata: Map.put(item.metadata || %{}, "provenance", provenance)})
    |> Repo.update!()
  end

  defp describe(check) do
    %{
      "source" => check.source,
      "kind" => Atom.to_string(check.kind),
      "role" => Atom.to_string(check.role),
      "locator" => check.locator
    }
  end

  defp digest(checks, verdict) do
    [Enum.map(checks, &describe/1) |> Enum.sort(), verdict.badge, verdict.score]
    |> :erlang.term_to_binary()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
    |> binary_part(0, 16)
  end

  defp config, do: Application.get_env(:devils_dictionary, :verification, [])
  defp refresh_seconds, do: config()[:refresh_seconds] || 30 * 86_400
  defp failure_seconds, do: config()[:failure_backoff_seconds] || 86_400
end
