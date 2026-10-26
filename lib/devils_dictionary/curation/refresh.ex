defmodule DevilsDictionary.Curation.Refresh do
  @moduledoc """
  The curation refresh clock (#259, #253 §6a and §7, #198): admission on
  visit, the worker's fenced claim and completion, the dirty triggers and the
  owner's rules. It copies discovery's design (`Discovery.request/3`,
  `Discovery.RunWorker`) on its own queue, `:curation`.

  **No model, no proposal, no publication.** A run builds the page's inputs
  fingerprint and compares it with the last one. It completes as
  `:unchanged`, or as `:needs_editor`, which means the inputs were
  **checked, not judged** (P6 turns it into an editor's proposal). Nothing
  here reserves a review unit or inference time: P5 writes no reviewable
  work and calls no model (#259 §3).

  **Scope.** Pilot allowlist only during the MVP; later expansion disabled
  (`Curation.Pilot`). A page without a composition has no refresh identity
  and admits nothing; it gets one when a composition is provisioned.

  **The contracts** (#259 §5), each enforced here:

    * the published parent is captured **at admission**
      (`admitted_parent_version_id`), and a completion that finds it moved
      persists `superseded_on_arrival`;
    * a change arriving during a run is never lost: every trigger moves
      `dirty_seq`, a claim records it as `run_dirty_seq`, and completion
      clears `dirty_at` only when the two still agree;
    * `inputs_last_changed_at` is history, never cleared by a completion;
    * an absent row is initialised under a transaction-scoped advisory lock
      on the composition, and a visit that cannot take it at once writes
      nothing (`:busy`);
    * an expired lease is recovered with the same generation and a new
      token, at most three times, then deferred with backoff;
    * every worker write carries the token it claimed with and is refused if
      the token, the generation, the state or the lease moved, so a
      suppression (which moves the token) or a configuration change during
      the run writes nothing.

  The correctness boundary is the advisory lock, the row lock and the
  partial unique index (one run in flight per composition), never Oban's
  uniqueness, which only coalesces.
  """

  import Ecto.Query

  require Logger

  alias DevilsDictionary.Claims.AssertionRevision

  alias DevilsDictionary.Curation.{
    Composition,
    CompositionItem,
    CompositionMembership,
    CompositionVersion,
    Compositions,
    Configurations,
    Digest,
    Opening,
    Pilot,
    Published,
    PublishedReader,
    RefreshState,
    RefreshWorker,
    Standing
  }

  alias DevilsDictionary.Curation.Runtime.Packet
  alias DevilsDictionary.Lexicon
  alias DevilsDictionary.Lexicon.WordPage
  alias DevilsDictionary.Registry.Sense
  alias DevilsDictionary.Repo

  # #253 D7: 48 hours, for an unchanged check and an editor-needed one alike.
  @window_seconds 48 * 3600
  # A queued run's lease covers the wait for the queue; a running one's, the run.
  @queued_lease_seconds 15 * 60
  @running_lease_seconds 10 * 60
  @max_lease_attempts 3
  @backoff_base_seconds 60
  @backoff_cap_seconds 6 * 3600
  # The fingerprint names its own version: P5 wrote `candidates-v1`, P4's
  # packet digest writes `Packet.fingerprint_version/1` (`packet-v2/` and the
  # cut's policies). A stored fingerprint of another version never equals a
  # new one, and a visit admits its page once for it (`decision/2`), so a
  # switch costs one `needs_editor` check and never a silent match or a loop.
  # The advisory-lock class: a namespace for `pg_try_advisory_xact_lock/2`.
  @lock_class 259

  @doc "The periodic window, in seconds."
  def window_seconds, do: @window_seconds

  @doc "The fingerprint version this build writes (`Packet.fingerprint_version/1`)."
  def fingerprint_version, do: Packet.fingerprint_version()

  # ── the visit ─────────────────────────────────────────────────────────────

  @doc """
  The visit check (#259 §5.6), for every visit to an On page: plain HTTP
  render and LiveView mount alike. `opening` is what the page's reader
  answered; `opts`: `:slug` (required), `:public?` (whether this viewer's
  page is the public one; only a public page's withheld set is compared,
  default `true`), `:withheld` (a precomputed withheld digest, for tests)
  and `:now`.

  **Bounded:** nothing for a page off the allowlist or without a
  composition; one indexed read when nothing is due; one short transaction
  when something is; never a wait on another visit's lock. A failure is
  logged and answered as `{:error, :failed}`; it never reaches the page.

  Answers `:skip`, `{:ok, outcome}` (see `admit/2`) or `{:error, reason}`.
  """
  def visit(page, opening, opts) do
    slug = Keyword.get(opts, :slug)

    with true <- Pilot.page?(slug),
         {:ok, composition_id, version_id} <- composition_for(page) do
      now = now(opts)

      withheld =
        Keyword.get_lazy(opts, :withheld, fn ->
          if Keyword.get(opts, :public?, true), do: withheld_digest(opening), else: :unknown
        end)

      row = state_for(composition_id, version_id)

      case precheck(row, withheld, now) do
        :admit ->
          admit(composition_id, slug: slug, withheld: withheld, now: now)

        outcome ->
          emit(outcome, %{composition_id: composition_id, source: :visit})
          {:ok, outcome}
      end
    else
      _not_in_scope -> :skip
    end
  rescue
    error ->
      Logger.warning("curation refresh: visit check failed: " <> Exception.message(error))
      {:error, :failed}
  end

  # The page's composition under the resolved global default, found as the
  # reader finds it: by the page's words (K2).
  defp composition_for(%{headword: %{lexemes: [_ | _] = lexemes}}) do
    with {:ok, %{configuration: configuration, version: version}} <-
           Configurations.resolve_default(),
         [language] when is_binary(language) <- lexemes |> Enum.map(& &1.language) |> Enum.uniq(),
         %Composition{id: id} <-
           Compositions.active(
             configuration.id,
             :lexical_page,
             language,
             Compositions.signature(Enum.map(lexemes, & &1.id))
           ) do
      {:ok, id, version.id}
    else
      _none -> :none
    end
  end

  defp composition_for(_page), do: :none

  # What a visit needs to know without a lock: whether to open the admission
  # transaction at all.
  defp precheck(row, withheld, now) do
    decision = decision(row, now)

    cond do
      decision in [:admit, :recover] -> :admit
      withheld_mark?(row, withheld) -> :admit
      true -> decision
    end
  end

  @doc """
  What a row asks of a visit now, with no lock: `:admit` (never checked,
  dirty, due, checked under another fingerprint version, or a deferred run
  whose backoff has passed), `:recover` (a queued or running run whose
  lease expired), `:in_flight`, `:suppressed`, `:backoff` or `:fresh`.
  `nil` (no row) is never checked.
  """
  def decision(nil, _now), do: :admit
  def decision(%RefreshState{state: :suppressed}, _now), do: :suppressed

  def decision(%RefreshState{state: state} = row, now) when state in [:queued, :running],
    do: if(reached?(now, row.lease_expires_at), do: :recover, else: :in_flight)

  def decision(%RefreshState{state: :deferred} = row, now),
    do: if(reached?(now, row.next_retry_at), do: :admit, else: :backoff)

  def decision(%RefreshState{state: :idle} = row, now) do
    cond do
      is_nil(row.last_completed_at) -> :admit
      not is_nil(row.dirty_at) -> :admit
      reached?(now, row.refresh_after) -> :admit
      another_version?(row.input_fingerprint) -> :admit
      true -> :fresh
    end
  end

  # A baseline written under another fingerprint version is re-checked once:
  # the completion stores this build's version, and the next visit is fresh.
  defp another_version?(nil), do: false
  defp another_version?(fingerprint), do: version_of(fingerprint) != fingerprint_version()

  # ── admission ─────────────────────────────────────────────────────────────

  @doc """
  Admits a run for a composition, in one transaction (#259 §5.2). `opts`:
  `:slug` (the On page whose visit admits, required), `:withheld` (the
  reader's withheld digest, or `:unknown`) and `:now`.

  Under a transaction-scoped advisory lock on the composition: initialise
  the row for the active configuration version if absent (it inherits
  `suppressed`), lock it, note a new read-time withholding as dirty, then
  decide. Admitting captures the published parent, allocates the generation
  (a retry from `:deferred` keeps it) and inserts the job in the same
  transaction; recovery re-queues an expired lease with a new token.

  Answers `{:ok, outcome}`, outcome one of `:admitted`, `:recovered`,
  `:deferred` (the third expired lease), `:fresh`, `:in_flight`,
  `:suppressed`, `:backoff` or `:busy`; or `{:error, reason}` for a
  composition that is gone or a configuration that is unavailable.
  """
  def admit(composition_id, opts) do
    now = now(opts)
    slug = Keyword.fetch!(opts, :slug)
    withheld = Keyword.get(opts, :withheld, :unknown)

    result =
      try do
        Repo.transaction(fn ->
          # A visit never waits on another transaction for long: a row
          # another admission, a withdrawal or a trigger holds is `:busy`.
          Repo.query!("SET LOCAL lock_timeout = '1s'")

          with :ok <- composition_lock(composition_id),
               {:ok, composition} <- active_composition(composition_id),
               {:ok, version_id} <- configuration_version(composition) do
            row =
              composition.id
              |> ensure_row!(version_id, now)
              |> maybe_withheld!(withheld, now)

            act(decision(row, now), row, composition, slug, now)
          else
            {:ok, :busy} -> :busy
            {:error, reason} -> Repo.rollback(reason)
          end
        end)
      rescue
        error in Postgrex.Error ->
          if error.postgres[:code] == :lock_not_available,
            do: {:ok, :busy},
            else: reraise(error, __STACKTRACE__)
      end

    case result do
      {:ok, outcome} ->
        emit(outcome, %{composition_id: composition_id, source: :admission})
        {:ok, outcome}

      error ->
        error
    end
  end

  defp composition_lock(composition_id) do
    %{rows: [[taken]]} =
      Repo.query!("SELECT pg_try_advisory_xact_lock($1, $2)", [
        @lock_class,
        rem(composition_id, 2_147_483_647)
      ])

    if taken, do: :ok, else: {:ok, :busy}
  end

  defp active_composition(id) do
    case Repo.get(Composition, id) do
      %Composition{state: :active} = composition -> {:ok, composition}
      _gone -> {:error, :no_composition}
    end
  end

  defp configuration_version(%Composition{curation_configuration_id: id}) do
    case Configurations.current(id) do
      {:ok, _configuration, version} -> {:ok, version.id}
      {:error, reason} -> {:error, reason}
    end
  end

  # The row for this configuration version, created if absent and locked.
  # Suppression belongs to the composition, so a new row inherits it.
  defp ensure_row!(composition_id, version_id, now) do
    suppressed? =
      Repo.exists?(
        from r in RefreshState,
          where: r.composition_id == ^composition_id and r.state == :suppressed
      )

    Repo.insert_all(
      RefreshState,
      [
        %{
          composition_id: composition_id,
          configuration_version_id: version_id,
          state: if(suppressed?, do: :suppressed, else: :idle),
          inserted_at: now,
          updated_at: now
        }
      ],
      on_conflict: :nothing,
      conflict_target: [:composition_id, :configuration_version_id]
    )

    Repo.one!(
      from r in RefreshState,
        where: r.composition_id == ^composition_id and r.configuration_version_id == ^version_id,
        lock: "FOR UPDATE NOWAIT"
    )
  end

  # A withheld set the last completion did not see is an input change,
  # noted once: and once more while a run is running (only if nothing was
  # marked since its claim), so a withholding that lands after the worker
  # read its inputs is kept for the next run.
  defp maybe_withheld!(row, withheld, now) do
    if withheld_mark?(row, withheld) do
      mark_row!(row, "item_withheld", now)
    else
      row
    end
  end

  defp withheld_mark?(nil, _withheld), do: false
  defp withheld_mark?(_row, :unknown), do: false
  defp withheld_mark?(%RefreshState{last_completed_at: nil}, _withheld), do: false
  defp withheld_mark?(%RefreshState{state: :suppressed}, _withheld), do: false

  defp withheld_mark?(%RefreshState{} = row, withheld) do
    withheld != row.withheld_digest and
      (is_nil(row.dirty_at) or (row.state == :running and row.dirty_seq == row.run_dirty_seq))
  end

  defp act(:admit, row, composition, slug, now) do
    case in_flight_elsewhere(row, now) do
      :in_flight ->
        :in_flight

      :clear ->
        # A retry from `:deferred` keeps its generation and why it was admitted.
        {generation, periodic?} =
          if row.state == :deferred,
            do: {row.refresh_generation, row.run_periodic},
            else: {row.refresh_generation + 1, periodic?(row, now)}

        row
        |> Ecto.Changeset.change(
          state: :queued,
          refresh_generation: generation,
          run_periodic: periodic?,
          lease_expires_at: shift(now, @queued_lease_seconds),
          lease_attempts: 1,
          admitted_parent_version_id: composition.current_published_version_id,
          next_retry_at: nil,
          run_dirty_seq: nil,
          updated_at: now
        )
        |> Repo.update!()
        |> enqueue!(slug)

        :admitted
    end
  end

  defp act(:recover, row, _composition, slug, now) do
    if row.lease_attempts < @max_lease_attempts do
      row
      |> Ecto.Changeset.change(
        state: :queued,
        lease_token: row.lease_token + 1,
        lease_expires_at: shift(now, @queued_lease_seconds),
        lease_attempts: row.lease_attempts + 1,
        run_dirty_seq: nil,
        updated_at: now
      )
      |> Repo.update!()
      |> enqueue!(slug)

      :recovered
    else
      defer!(row, "the run's lease expired #{row.lease_attempts} times", now, &jitter/1)
      :deferred
    end
  end

  defp act(outcome, _row, _composition, _slug, _now), do: outcome

  # Admitted only because the window passed: checked before, nothing pending.
  defp periodic?(row, now),
    do:
      not is_nil(row.last_completed_at) and is_nil(row.dirty_at) and
        reached?(now, row.refresh_after)

  # Another configuration version's row of this composition in flight: one
  # run per composition. An expired one is released, never resumed: its
  # configuration version is no longer the active one.
  defp in_flight_elsewhere(row, now) do
    other =
      Repo.one(
        from r in RefreshState,
          where:
            r.composition_id == ^row.composition_id and r.id != ^row.id and
              r.state in [:queued, :running],
          lock: "FOR UPDATE NOWAIT"
      )

    cond do
      is_nil(other) ->
        :clear

      reached?(now, other.lease_expires_at) ->
        release!(other, now)
        :clear

      true ->
        :in_flight
    end
  end

  # One waiting job per row: a job of this row that has not started yet takes
  # the new arguments (its generation) instead of standing beside them, so a
  # job of an older generation never sits in front of the new one.
  defp enqueue!(row, slug) do
    %{refresh_state_id: row.id, generation: row.refresh_generation, slug: slug}
    |> RefreshWorker.new(replace: [available: [:args], scheduled: [:args], retryable: [:args]])
    |> Oban.insert!()

    row
  end

  # ── the worker's run ──────────────────────────────────────────────────────

  @doc """
  The worker's claim, in one transaction: refused unless the row is
  `:queued` on `generation`. Moves the token (the worker keeps the one it
  set), takes the running lease and records `run_dirty_seq`.

  Answers `{:ok, claim}` or `{:error, :missing | :not_queued |
  :stale_generation}`. A claim is `%{row_id, composition_id,
  configuration_version_id, token, generation, periodic?, pending_reason}`:
  `periodic?` is a run admitted only because its window passed (decided at
  admission), an intentional re-assessment (#253 §7) that never completes as
  unchanged; `pending_reason` is the change pending when the run started.
  """
  def claim(row_id, generation, opts \\ []) do
    now = now(opts)

    Repo.transaction(fn ->
      row = lock_row(row_id)

      cond do
        is_nil(row) ->
          Repo.rollback(:missing)

        row.state != :queued ->
          Repo.rollback(:not_queued)

        row.refresh_generation != generation ->
          Repo.rollback(:stale_generation)

        true ->
          row =
            row
            |> Ecto.Changeset.change(
              state: :running,
              lease_token: row.lease_token + 1,
              lease_expires_at: shift(now, @running_lease_seconds),
              run_dirty_seq: row.dirty_seq,
              updated_at: now
            )
            |> Repo.update!()

          %{
            row_id: row.id,
            composition_id: row.composition_id,
            configuration_version_id: row.configuration_version_id,
            token: row.lease_token,
            generation: row.refresh_generation,
            periodic?: row.run_periodic,
            pending_reason: row.dirty_reason
          }
      end
    end)
  end

  @doc """
  A claimed run, from its inputs to its completion: `inputs/2`, then
  `complete/3`. Any failure reading the inputs defers the run under the
  same fence (`fail/3`). Answers what `complete/3` or `fail/3` answer.
  """
  def check(claim, slug, opts \\ []) do
    inputs =
      try do
        {:ok, inputs(claim, slug)}
      rescue
        error -> {:error, Exception.message(error)}
      end

    case inputs do
      {:ok, inputs} -> complete(claim, inputs, opts)
      {:error, message} -> fail(claim, message, opts)
    end
  end

  @doc """
  A composition's inputs now, read for its On page `slug`:

      %{fingerprint, eligibility, accepted, candidates, withheld_digest,
        published_version_id}

  `fingerprint` is the fingerprint version (`fingerprint_version/0`) + the
  published version's eligibility fingerprint evaluated now (`unpublished`
  when none) + the digest of the page's packet (`Packet.digest/1`: the cut
  an editor would be offered, by ids, revisions and hashes, never text; or
  the packet's refusal) and of the version's standing as a whole
  (`Published.current/1`'s reasons for withholding all of it: a withdrawn
  approval, a changed scope or configuration), which the item-level
  eligibility fingerprint does not carry. A candidate eligible outside the
  cut changes it only where it changes what the packet sends (#253 §5a).
  `accepted` is
  the fingerprint the published version was accepted with, the baseline of
  a composition's first check. Reads only.
  """
  def inputs(%{composition_id: composition_id}, slug) do
    composition = Repo.get!(Composition, composition_id)
    page = slug |> Lexicon.lookup() |> WordPage.build(viewer: :public)

    standing =
      case Published.current(composition.id) do
        {:withheld, reasons} -> Enum.map(reasons, &to_string/1)
        _shown_or_unpublished -> []
      end

    candidate_digest =
      Digest.term(%{
        "page" => Compositions.signature(Enum.map(page.headword.lexemes, & &1.id)),
        "packet" => packet_identity(page),
        "standing" => standing
      })

    {published_id, eligibility, accepted} =
      case composition.current_published_version_id do
        nil ->
          {nil, "unpublished", nil}

        version_id ->
          version = Repo.get!(CompositionVersion, version_id)
          evaluation = Standing.evaluate(version, composition)
          {version_id, evaluation.fingerprint, version.eligibility_fingerprint}
      end

    %{
      fingerprint: Enum.join([fingerprint_version(), eligibility, candidate_digest], ":"),
      eligibility: eligibility,
      accepted: accepted,
      standing: standing,
      candidates: candidate_digest,
      withheld_digest: withheld_digest(Opening.for_page(page, PublishedReader)),
      published_version_id: published_id
    }
  end

  # What identifies the page's packet: the digest of its cut, whose order is
  # the cut's own and deterministic, or the reason it is refused (an
  # applicable Bierce entry the screen cannot offer, too many of them, no
  # candidates), which is an input as much as a candidate is.
  defp packet_identity(page) do
    case Packet.for_page(page) do
      {:ok, packet} -> Packet.digest(packet)
      {:error, reason} -> %{"refused" => canonical(reason)}
    end
  end

  defp canonical(value) when is_tuple(value), do: value |> Tuple.to_list() |> canonical()
  defp canonical(value) when is_list(value), do: Enum.map(value, &canonical/1)

  defp canonical(%{} = value) when not is_struct(value),
    do: Map.new(value, fn {k, v} -> {to_string(k), canonical(v)} end)

  defp canonical(value) when is_atom(value) and not is_boolean(value) and not is_nil(value),
    do: to_string(value)

  defp canonical(value), do: value

  @doc """
  What a completed check found, from the claim, the row as it was before
  completion and the inputs: `{:unchanged | :needs_editor, reason}`.

    * a periodic run → `{:needs_editor, "due"}`;
    * the stored fingerprint equal → `{:unchanged, "unchanged"}`; different
      → `{:needs_editor, "inputs_changed"}`, or `"fingerprint_version"` when
      it was written by another fingerprint version;
    * no stored fingerprint (never checked, or a publication reset the
      baseline): a published version that still stands as a whole, whose
      eligibility now is the one it was accepted with, and with no change
      pending but its own publication → `{:unchanged, "accepted"}`;
      otherwise `{:needs_editor, "inputs_changed"}`, or `"nothing_accepted"`
      when nothing is published.
  """
  def outcome(%{periodic?: true}, _row, _inputs), do: {:needs_editor, "due"}

  def outcome(_claim, %RefreshState{input_fingerprint: old}, %{fingerprint: new})
      when is_binary(old) do
    cond do
      old == new -> {:unchanged, "unchanged"}
      version_of(old) != version_of(new) -> {:needs_editor, "fingerprint_version"}
      true -> {:needs_editor, "inputs_changed"}
    end
  end

  def outcome(_claim, _row, %{accepted: nil}), do: {:needs_editor, "nothing_accepted"}

  def outcome(%{pending_reason: pending}, _row, %{
        accepted: accepted,
        eligibility: accepted,
        standing: []
      })
      when pending in [nil, "published"],
      do: {:unchanged, "accepted"}

  def outcome(_claim, _row, _inputs), do: {:needs_editor, "inputs_changed"}

  defp version_of(fingerprint), do: fingerprint |> String.split(":", parts: 2) |> hd()

  @doc """
  The completion, in one transaction (#259 §5.3 step 4). Refused with
  `{:error, :lease_lost}` unless the row is `:running` on the claim's token
  and generation with its lease held: a suppression, a recovery or a stale
  worker writes nothing. A configuration version that is no longer the
  active one is refused too (`{:error, :configuration_changed}`), and the row
  is released to `:idle` without a completion.

  Otherwise writes the check: `last_completed_at`, `refresh_after`, the
  outcome and its reason, the new fingerprint and withheld digest; clears
  `dirty_at` only when no change arrived during the run; sets
  `inputs_last_changed_at` when the check found a change no trigger
  reported; persists `superseded_on_arrival`. Answers `{:ok, row}`.
  """
  def complete(claim, inputs, opts \\ []) do
    now = now(opts)

    result =
      Repo.transaction(fn ->
        row = lock_row(claim.row_id)

        with :ok <- fenced(row, claim, now),
             {:ok, composition} <- still_configured(row, now) do
          {outcome, reason} = outcome(claim, row, inputs)
          clean? = row.dirty_seq == row.run_dirty_seq
          superseded? = composition.current_published_version_id != row.admitted_parent_version_id
          # Inputs read from a version no longer published are not a baseline.
          current_inputs? =
            inputs.published_version_id == composition.current_published_version_id

          changed? = reason in ["inputs_changed", "fingerprint_version"]

          unreported? =
            is_nil(row.inputs_last_changed_at) or
              (not is_nil(row.last_completed_at) and
                 DateTime.compare(row.inputs_last_changed_at, row.last_completed_at) != :gt)

          {changed_at, changed_reason} =
            if changed? and unreported?,
              do: {now, "inputs_changed"},
              else: {row.inputs_last_changed_at, row.inputs_last_changed_reason}

          row =
            row
            |> Ecto.Changeset.change(
              state: :idle,
              last_completed_at: now,
              refresh_after: shift(now, @window_seconds),
              last_outcome: outcome,
              last_outcome_reason: reason,
              # A publication during the run reset the baseline (`published/2`):
              # unless these inputs were read from it, the next check measures
              # against the version now accepted.
              input_fingerprint: if(current_inputs?, do: inputs.fingerprint, else: nil),
              withheld_digest: inputs.withheld_digest,
              superseded_on_arrival: superseded?,
              failures: 0,
              next_retry_at: nil,
              last_error: nil,
              lease_expires_at: nil,
              lease_attempts: 0,
              run_dirty_seq: nil,
              dirty_at: if(clean?, do: nil, else: row.dirty_at),
              dirty_reason: if(clean?, do: nil, else: row.dirty_reason),
              inputs_last_changed_at: changed_at,
              inputs_last_changed_reason: changed_reason,
              updated_at: now
            )
            |> Repo.update!()

          {:ok, row}
        end
      end)

    case result do
      {:ok, {:ok, row}} ->
        emit(:completed, %{
          composition_id: row.composition_id,
          outcome: row.last_outcome,
          reason: row.last_outcome_reason,
          superseded_on_arrival: row.superseded_on_arrival
        })

        {:ok, row}

      {:ok, {:error, reason}} ->
        emit(:refused, %{composition_id: claim.composition_id, reason: reason})
        {:error, reason}
    end
  end

  @doc """
  A failed run, under the same fence: `:deferred`, `failures + 1`,
  `next_retry_at` by the backoff, `last_error`; `last_completed_at`
  untouched. The next visit after `next_retry_at` retries the same
  generation. `opts`: `:now`, `:jitter` (a function of the backoff in
  seconds, for tests). Answers `{:ok, row}` or `{:error, :lease_lost}`.
  """
  def fail(claim, error, opts \\ []) do
    now = now(opts)
    jitter = Keyword.get(opts, :jitter, &jitter/1)

    result =
      Repo.transaction(fn ->
        row = lock_row(claim.row_id)

        with :ok <- fenced(row, claim, now),
             {:ok, _composition} <- still_configured(row, now) do
          {:ok, defer!(row, error, now, jitter)}
        end
      end)

    case result do
      {:ok, {:ok, row}} ->
        emit(:deferred, %{composition_id: row.composition_id, reason: :failure})
        {:ok, row}

      {:ok, error} ->
        error
    end
  end

  defp fenced(nil, _claim, _now), do: {:error, :lease_lost}

  defp fenced(%RefreshState{} = row, claim, now) do
    if row.state == :running and row.lease_token == claim.token and
         row.refresh_generation == claim.generation and
         not reached?(now, row.lease_expires_at),
       do: :ok,
       else: {:error, :lease_lost}
  end

  # The run was admitted under a configuration version; if it is no longer
  # the active one, its result is not this composition's any more.
  defp still_configured(row, now) do
    composition = Repo.get!(Composition, row.composition_id)

    case configuration_version(composition) do
      {:ok, version_id} when version_id == row.configuration_version_id ->
        {:ok, composition}

      _changed ->
        release!(row, now)
        {:error, :configuration_changed}
    end
  end

  defp release!(row, now) do
    row
    |> Ecto.Changeset.change(
      state: :idle,
      lease_token: row.lease_token + 1,
      lease_expires_at: nil,
      lease_attempts: 0,
      run_dirty_seq: nil,
      updated_at: now
    )
    |> Repo.update!()
  end

  defp defer!(row, error, now, jitter) do
    failures = row.failures + 1

    row
    |> Ecto.Changeset.change(
      state: :deferred,
      failures: failures,
      next_retry_at: shift(now, backoff_seconds(failures, jitter)),
      last_error: error |> to_string() |> String.slice(0, 500),
      lease_token: row.lease_token + 1,
      lease_expires_at: nil,
      lease_attempts: 0,
      run_dirty_seq: nil,
      updated_at: now
    )
    |> Repo.update!()
  end

  @doc """
  The backoff after `failures` consecutive failures: one minute, doubling,
  capped at six hours, with `jitter` applied (by default ±10%) and the cap
  holding after it.
  """
  def backoff_seconds(failures, jitter \\ &jitter/1) when failures >= 1 do
    base = min(@backoff_base_seconds * Integer.pow(2, failures - 1), @backoff_cap_seconds)
    base |> jitter.() |> round() |> min(@backoff_cap_seconds) |> max(1)
  end

  defp jitter(seconds), do: seconds * (0.9 + :rand.uniform() * 0.2)

  defp lock_row(id),
    do: Repo.one(from r in RefreshState, where: r.id == ^id, lock: "FOR UPDATE")

  # ── triggers ──────────────────────────────────────────────────────────────

  @doc """
  Marks compositions' inputs changed (#259 §5.4): one update per call over
  the compositions' existing rows. `dirty_seq + 1` always; `dirty_at` set if
  unset; the reason and `inputs_last_changed_at` updated. Enqueues nothing:
  the next visit admits. A composition with no row has never been checked,
  so its next visit admits anyway. Answers the number of rows marked.
  """
  def mark_dirty(composition_ids, reason, opts \\ []) do
    now = now(opts)
    ids = composition_ids |> Enum.reject(&is_nil/1) |> Enum.uniq()

    if ids == [] do
      0
    else
      {count, _} =
        Repo.update_all(
          from(r in RefreshState,
            where: r.composition_id in ^ids,
            update: [
              set: [
                dirty_at: fragment("COALESCE(?, ?)", r.dirty_at, ^now),
                dirty_reason: ^reason,
                inputs_last_changed_at: ^now,
                inputs_last_changed_reason: ^reason,
                # A queued run is no longer admitted only for its window.
                run_periodic: false,
                updated_at: ^now
              ],
              inc: [dirty_seq: 1]
            ]
          ),
          []
        )

      count
    end
  end

  defp mark_row!(row, reason, now) do
    row
    |> Ecto.Changeset.change(
      dirty_at: row.dirty_at || now,
      dirty_reason: reason,
      dirty_seq: row.dirty_seq + 1,
      inputs_last_changed_at: now,
      inputs_last_changed_reason: reason,
      run_periodic: false,
      updated_at: now
    )
    |> Repo.update!()
  end

  @doc """
  A claim was reviewed: dirty the compositions whose items cite one of its
  revisions, and those whose scope holds a sense the claim is about (a
  newly accepted `illustrates` claim is a new exemplar candidate).
  """
  def claim_reviewed(assertion_id, opts \\ []) do
    citing =
      Repo.all(
        from i in CompositionItem,
          join: v in CompositionVersion,
          on: v.id == i.composition_version_id,
          join: ar in AssertionRevision,
          on: ar.id == i.assertion_revision_id,
          where: ar.assertion_id == ^assertion_id,
          distinct: true,
          select: v.composition_id
      )

    about =
      Repo.all(
        from m in CompositionMembership,
          join: s in Sense,
          on: s.lexeme_id == m.object_id,
          join: ar in AssertionRevision,
          on: ar.object_object_id == s.object_id or ar.subject_object_id == s.object_id,
          where: ar.assertion_id == ^assertion_id,
          distinct: true,
          select: m.composition_id
      )

    mark_dirty(citing ++ about, "claim_reviewed", opts)
  end

  @doc """
  A sense got a new revision, superseding `old_revision_id`: compositions
  whose items cite the old revision are `revision_superseded`; the others
  whose scope holds the sense's lexeme gained candidates
  (`candidate_added`: its quotations may be new).
  """
  def sense_revised(sense_id, old_revision_id, opts \\ []) do
    citing =
      if old_revision_id do
        Repo.all(
          from i in CompositionItem,
            join: v in CompositionVersion,
            on: v.id == i.composition_version_id,
            where:
              i.sense_revision_id == ^old_revision_id or
                i.meaning_sense_revision_id == ^old_revision_id,
            distinct: true,
            select: v.composition_id
        )
      else
        []
      end

    scoped =
      Repo.all(
        from m in CompositionMembership,
          join: s in Sense,
          on: s.lexeme_id == m.object_id,
          where: s.object_id == ^sense_id,
          distinct: true,
          select: m.composition_id
      )

    mark_dirty(citing, "revision_superseded", opts) +
      mark_dirty(scoped -- citing, "candidate_added", opts)
  end

  @doc "A content item got a new revision: compositions citing the old one are `revision_superseded`."
  def content_revised(old_revision_id, opts \\ [])
  def content_revised(nil, _opts), do: 0

  def content_revised(old_revision_id, opts) do
    Repo.all(
      from i in CompositionItem,
        join: v in CompositionVersion,
        on: v.id == i.composition_version_id,
        where: i.content_revision_id == ^old_revision_id,
        distinct: true,
        select: v.composition_id
    )
    |> mark_dirty("revision_superseded", opts)
  end

  # ── the owner's rules (#253 §6a) ──────────────────────────────────────────

  @doc """
  Withdrawal means keep this off the page: every row of the composition is
  `suppressed`, its token moved (an in-flight worker's write is then
  refused) and its lease cleared; the active configuration version's row is
  created suppressed if absent. Call inside the withdrawal's transaction.
  """
  def suppress(composition_id, opts \\ []) do
    now = now(opts)

    Repo.update_all(
      from(r in RefreshState, where: r.composition_id == ^composition_id),
      set: [
        state: :suppressed,
        lease_expires_at: nil,
        lease_attempts: 0,
        run_dirty_seq: nil,
        updated_at: now
      ],
      inc: [lease_token: 1]
    )

    with {:ok, composition} <- active_composition(composition_id),
         {:ok, version_id} <- configuration_version(composition) do
      Repo.insert_all(
        RefreshState,
        [
          %{
            composition_id: composition_id,
            configuration_version_id: version_id,
            state: :suppressed,
            inserted_at: now,
            updated_at: now
          }
        ],
        on_conflict: :nothing,
        conflict_target: [:composition_id, :configuration_version_id]
      )
    end

    :ok
  end

  @doc """
  "Re-open" (#253 §6a): a suppressed composition is curated again. Its rows
  go `idle`, dirty with `reason` (`"reopened"`), so the next visit admits
  one run. Answers the number of rows re-opened.
  """
  def reopen(composition_id, reason \\ "reopened", opts \\ []) do
    now = now(opts)

    {count, _} =
      Repo.update_all(
        from(r in RefreshState,
          where: r.composition_id == ^composition_id and r.state == :suppressed,
          update: [
            set: [
              state: :idle,
              next_retry_at: nil,
              dirty_at: fragment("COALESCE(?, ?)", r.dirty_at, ^now),
              dirty_reason: ^reason,
              inputs_last_changed_at: ^now,
              inputs_last_changed_reason: ^reason,
              updated_at: ^now
            ],
            inc: [dirty_seq: 1]
          ]
        ),
        []
      )

    count
  end

  @doc """
  A version was published: the next check measures against it (the stored
  fingerprint is cleared, so the baseline is the eligibility it was accepted
  with) and is due on the next visit. A suppressed composition is curated
  again. Not an input change: `inputs_last_changed_at` is untouched. Call
  inside the publication's transaction.
  """
  def published(composition_id, opts \\ []) do
    now = now(opts)

    Repo.update_all(
      from(r in RefreshState,
        where: r.composition_id == ^composition_id,
        update: [
          set: [
            state:
              fragment("CASE WHEN ? = 'suppressed' THEN 'idle' ELSE ? END", r.state, r.state),
            input_fingerprint: nil,
            run_periodic: false,
            dirty_at: fragment("COALESCE(?, ?)", r.dirty_at, ^now),
            # A real change already pending keeps its reason.
            dirty_reason:
              fragment(
                "CASE WHEN ? IS NULL THEN 'published' ELSE ? END",
                r.dirty_at,
                r.dirty_reason
              ),
            updated_at: ^now
          ],
          inc: [dirty_seq: 1]
        ]
      ),
      []
    )

    :ok
  end

  # ── reads ─────────────────────────────────────────────────────────────────

  @doc "The row of a composition under a configuration version, or `nil`."
  def state_for(composition_id, configuration_version_id) do
    Repo.one(
      from r in RefreshState,
        where:
          r.composition_id == ^composition_id and
            r.configuration_version_id == ^configuration_version_id
    )
  end

  @doc "The rows of compositions under a configuration version, by composition id."
  def states_for(composition_ids, configuration_version_id) do
    Repo.all(
      from r in RefreshState,
        where:
          r.composition_id in ^composition_ids and
            r.configuration_version_id == ^configuration_version_id
    )
    |> Map.new(&{&1.composition_id, &1})
  end

  @doc "Whether a composition is suppressed (withdrawn and not re-opened)."
  def suppressed?(composition_id) do
    Repo.exists?(
      from r in RefreshState,
        where: r.composition_id == ^composition_id and r.state == :suppressed
    )
  end

  @doc """
  What the page's disclosure says about a row (#259 §2.1): `nil` when there
  is none (never checked), else `%{state, last_completed_at, last_outcome,
  last_outcome_reason, refresh_after, next_retry_at, dirty_at, dirty_reason,
  inputs_last_changed_at, inputs_last_changed_reason}`.
  """
  def assessment(nil), do: nil

  def assessment(%RefreshState{} = row) do
    Map.take(row, [
      :state,
      :last_completed_at,
      :last_outcome,
      :last_outcome_reason,
      :refresh_after,
      :next_retry_at,
      :dirty_at,
      :dirty_reason,
      :inputs_last_changed_at,
      :inputs_last_changed_reason
    ])
  end

  @doc """
  Why a row is stale (#259 §2.2): `:never` (never checked), `:suppressed`
  (withdrawn), `{:deferred, error}`, `{:changed, reason}` (a pending input
  change), `:due` (the window passed), or `nil` when it is fresh.
  """
  def stale_reason(row, now \\ DateTime.utc_now())
  def stale_reason(nil, _now), do: :never
  def stale_reason(%RefreshState{state: :suppressed}, _now), do: :suppressed
  def stale_reason(%RefreshState{state: :deferred} = row, _now), do: {:deferred, row.last_error}

  def stale_reason(%RefreshState{dirty_at: %DateTime{}} = row, _now),
    do: {:changed, row.dirty_reason}

  def stale_reason(%RefreshState{last_completed_at: nil}, _now), do: :never

  def stale_reason(%RefreshState{} = row, now),
    do: if(reached?(now, row.refresh_after), do: :due, else: nil)

  @doc "An input change's reason in plain words, as the page, the queue and the editor say it."
  def change_label("claim_reviewed"), do: "a claim was reviewed"
  def change_label("revision_superseded"), do: "a cited revision was superseded"
  def change_label("candidate_added"), do: "a new candidate"
  def change_label("item_withheld"), do: "an item was withheld"
  def change_label("reopened"), do: "re-opened by the operator"
  def change_label("published"), do: "a version was published"
  def change_label("pin_revised"), do: "a pinned work was revised"
  def change_label(_found), do: "found by a check"

  @doc """
  The counts the Health page lists (#259 §5.6), all read from the record:
  the oldest queued or running run's age, runs admitted today (curation
  jobs inserted since UTC midnight), pages whose last check completed today
  by outcome, and pages deferred now. "Coalesced" visits are telemetry
  only.
  """
  def counts(now \\ DateTime.utc_now()) do
    midnight = DateTime.new!(DateTime.to_date(now), ~T[00:00:00], "Etc/UTC")

    oldest =
      Repo.one(
        from j in "oban_jobs",
          where: j.queue == "curation" and j.state in ["available", "scheduled", "executing"],
          select: min(j.inserted_at)
      )

    # Only rows under their configuration's current version: a row left by
    # an earlier version is history, not a page's clock.
    current =
      from r in RefreshState,
        join: c in Composition,
        on: c.id == r.composition_id,
        join: cc in "curation_configurations",
        on:
          cc.id == c.curation_configuration_id and
            cc.current_version_id == r.configuration_version_id

    outcomes =
      Repo.all(
        from r in current,
          where: r.last_completed_at >= ^midnight,
          group_by: r.last_outcome,
          select: {r.last_outcome, count(r.id)}
      )
      |> Map.new()

    %{
      queue_age_seconds: oldest && max(NaiveDateTime.diff(DateTime.to_naive(now), oldest), 0),
      admitted_today:
        Repo.one(
          from j in "oban_jobs",
            where: j.queue == "curation" and j.inserted_at >= ^DateTime.to_naive(midnight),
            select: count(j.id)
        ),
      unchanged_today: Map.get(outcomes, :unchanged, 0),
      needs_editor_today: Map.get(outcomes, :needs_editor, 0),
      deferred_now: Repo.one(from r in current, where: r.state == :deferred, select: count(r.id))
    }
  end

  @doc """
  The digest of what a reader withheld: `nil` for no opening, else the
  sorted `{role, position, reason}` of every withheld item. The visit and
  the worker compute it the same way, from the same reader.
  """
  def withheld_digest(nil), do: nil

  def withheld_digest(%Opening{withheld: withheld}) do
    withheld
    |> Enum.map(&[to_string(&1.role), &1.position, to_string(&1.reason)])
    |> Enum.sort()
    |> Digest.term()
  end

  # ── helpers ───────────────────────────────────────────────────────────────

  defp now(opts), do: Keyword.get_lazy(opts, :now, &DateTime.utc_now/0)

  defp shift(datetime, seconds), do: DateTime.add(datetime, seconds, :second)

  # Whether `now` has reached `datetime`. A missing time is reached.
  defp reached?(_now, nil), do: true
  defp reached?(now, datetime), do: DateTime.compare(now, datetime) != :lt

  @events %{
    admitted: :admitted,
    recovered: :admitted,
    in_flight: :coalesced,
    deferred: :deferred,
    completed: :completed,
    refused: :refused
  }

  defp emit(outcome, metadata) do
    case Map.fetch(@events, outcome) do
      {:ok, event} ->
        :telemetry.execute(
          [:curation, :refresh, event],
          %{count: 1},
          Map.put_new(metadata, :outcome, outcome)
        )

      :error ->
        :ok
    end
  end
end
