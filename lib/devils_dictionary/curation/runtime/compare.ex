defmodule DevilsDictionary.Curation.Runtime.Compare do
  @moduledoc """
  Matched, non-publishing comparisons on the pilot pages (#298 C2, C9):

      mix dd.runtime compare --batch ID --pilot --arms A0=CONFIG,P=CONFIG:text,... [--dry-run]

  **Arms.** An arm is a label, a pinned model config (which pins its
  instruction) and a packet cut: `current` (`whole-entry-cut-v1`, the live
  one) or `text` (`whole-entry-text-cut-v1`, which offers no metadata-only
  kind and refills from text-bearing ones). Arms that differ in instruction
  or model config (C2) share a cut; the policy arms (C9) differ in cut and,
  through the fixed-lead instruction, in lead.

  **One frozen snapshot per batch.** `freeze/4` reads each page once: its
  word page and the screen's candidates, from which it records the page's
  snapshot (`Packet.snapshot_identity/3`, ids and hashes only, with its own
  sha256) and cuts every arm's packet. The caller runs `freeze/4` inside
  one repeatable-read, read-only transaction (`mix dd.runtime compare`
  does), so every page and every arm is cut from the same database
  snapshot. Nothing is written and nothing is called.

  **Cases.** Each page is a case, `BATCH:SLUG:1`. Within a case, arms that
  share a cut must have equal evidence fingerprints
  (`Packet.evidence_fingerprint/1`), so A0 and L match each other, P and
  PL match each other, and an instruction-only arm matches its baseline.
  `run/2` sends a case's arms back to back, one call each, on the one slot
  and the shared daily budget, as `purpose: :comparison` attempts carrying
  their arm, case and snapshot. It never writes a composition version, a
  proposal or a publication: it only calls `Runtime.run/3`, and the database
  refuses any such row that names a comparison attempt.

  **Unmatched cases.** A case is unmatched when its arms' fingerprints
  differ at the freeze, when its snapshot's earliest shelf expiry has
  passed before an arm runs, or when an arm's packet no longer matches the
  registry (`packet_stale`). Every result it has is kept, as unmatched.
  The complete page and arm set is then tried once more on a new snapshot
  (read through `opts[:in_snapshot]`), as case `BATCH:SLUG:2`; arms from two
  snapshots are never combined, and an expired payload is never archived to
  make a case reproducible.

  **Stops.** Any other refusal (the slot busy, paused or quarantined, the
  budget spent, readiness failing) or an uncertain call halts the batch;
  the pages after it are recorded `not_run`. So is a case that would start
  after the batch window (`:window_minutes`, 60, from the freeze).
  """

  alias DevilsDictionary.Curation.{Candidates, Digest, Pilot}
  alias DevilsDictionary.Curation.Runtime

  alias DevilsDictionary.Curation.Runtime.{
    Contract,
    EvidenceGuidance,
    ModelConfig,
    Packet
  }

  alias DevilsDictionary.Lexicon
  alias DevilsDictionary.Lexicon.WordPage
  alias DevilsDictionary.Repo

  @record_version "comparison-batch-v1"
  @batch_format ~r/^[a-z0-9][a-z0-9._-]{2,63}$/
  @label_format ~r/^[A-Za-z0-9][A-Za-z0-9_-]{0,31}$/
  @cuts %{"current" => nil, "text" => "whole-entry-text-cut-v1"}
  @max_arms 8

  @doc "The batch record's version."
  def record_version, do: @record_version

  # ── arms ──────────────────────────────────────────────────────────────────

  @doc """
  Parses an arm list: `LABEL=CONFIG[:CUT]` items, comma-separated, where
  CONFIG is a model config slug and CUT `current` (the default) or `text`.
  A bare `CONFIG[:CUT]` is labelled by its slug. Returns `{:ok, arms}` or
  `{:error, reason}`: `:no_arms`, `{:too_many_arms, n}`,
  `{:invalid_arm, item}`, `{:invalid_label, label}`, `{:unknown_cut, cut}`
  or `{:duplicate_label, label}`.
  """
  def parse_arms(spec) when is_binary(spec) do
    items = spec |> String.split(",", trim: true) |> Enum.map(&String.trim/1)

    with :ok <- arm_count(items),
         {:ok, arms} <- collect(items, &parse_arm/1),
         :ok <- unique_labels(arms) do
      {:ok, arms}
    end
  end

  defp arm_count([]), do: {:error, :no_arms}

  defp arm_count(items) when length(items) > @max_arms,
    do: {:error, {:too_many_arms, length(items)}}

  defp arm_count(_items), do: :ok

  defp parse_arm(item) do
    {label, rest} =
      case String.split(item, "=", parts: 2) do
        [label, rest] -> {label, rest}
        [rest] -> {nil, rest}
      end

    {slug, cut} =
      case String.split(rest, ":", parts: 2) do
        [slug, cut] -> {slug, cut}
        [slug] -> {slug, "current"}
      end

    label = label || slug

    cond do
      slug == "" -> {:error, {:invalid_arm, item}}
      not Regex.match?(@label_format, label) -> {:error, {:invalid_label, label}}
      not Map.has_key?(@cuts, cut) -> {:error, {:unknown_cut, cut}}
      true -> {:ok, %{label: label, config_slug: slug, cut: cut}}
    end
  end

  defp unique_labels(arms) do
    case arms |> Enum.frequencies_by(& &1.label) |> Enum.find(fn {_l, n} -> n > 1 end) do
      nil -> :ok
      {label, _n} -> {:error, {:duplicate_label, label}}
    end
  end

  @doc """
  Resolves parsed arms to their model configs: `{:ok, arms}` with `:config`,
  or `{:error, {:model_config_unknown, slug}}`.
  """
  def resolve_arms(arms) do
    collect(arms, fn arm ->
      case Repo.get_by(ModelConfig, slug: arm.config_slug) do
        nil -> {:error, {:model_config_unknown, arm.config_slug}}
        config -> {:ok, Map.put(arm, :config, config)}
      end
    end)
  end

  defp collect(items, fun) do
    Enum.reduce_while(items, {:ok, []}, fn item, {:ok, acc} ->
      case fun.(item) do
        {:ok, value} -> {:cont, {:ok, acc ++ [value]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  @doc "What a batch record keeps of an arm: its identity, by ids and hashes."
  def arm_record(%{config: c} = arm) do
    instruction = c.instruction_version

    %{
      "label" => arm.label,
      "cut" => arm.cut,
      "cut_version" => Map.fetch!(@cuts, arm.cut) || "default",
      "model_config_id" => c.id,
      "model_config_slug" => c.slug,
      "model_config_hash" => c.config_hash,
      "model_name" => c.model_name,
      "manifest_digest" => c.manifest_digest,
      "weights_digest" => c.weights_digest,
      "generation" => c.generation,
      "instruction_version" => instruction,
      "instruction_sha256" => Digest.sha256(Packet.instruction!(instruction)),
      "output_contract" => Contract.version(instruction),
      "evidence_guidance" => EvidenceGuidance.policy(instruction)
    }
  end

  # ── the frozen snapshot ───────────────────────────────────────────────────

  @doc """
  Freezes a batch: one snapshot of each page and every arm's packet cut from
  it. `{:ok, batch}` or `{:error, reason}`: `{:invalid_batch, id}`,
  `{:outside_pilot, slugs}`, `:no_pages` or `{:duplicate_pages, slugs}`.
  Reads only; run it inside one repeatable-read, read-only transaction.

  `opts`: `:generation` (the shelf rotation, 0), `:language` (`"en"`) and
  `:now`.
  """
  def freeze(batch_id, slugs, arms, opts \\ []) do
    with :ok <- valid_batch(batch_id),
         :ok <- valid_pages(slugs) do
      now = Keyword.get_lazy(opts, :now, &DateTime.utc_now/0)
      pages = Enum.map(slugs, &freeze_page(batch_id, &1, 1, arms, opts))

      {:ok,
       %{
         batch: batch_id,
         frozen_at: now,
         generation: Keyword.get(opts, :generation, 0),
         language: Keyword.get(opts, :language, "en"),
         arms: arms,
         pages: pages,
         snapshot_sha256: Digest.term(Enum.map(pages, &[&1.slug, &1.snapshot_sha256]))
       }}
    end
  end

  defp valid_batch(id) when is_binary(id) do
    if Regex.match?(@batch_format, id), do: :ok, else: {:error, {:invalid_batch, id}}
  end

  defp valid_batch(id), do: {:error, {:invalid_batch, id}}

  defp valid_pages([]), do: {:error, :no_pages}

  defp valid_pages(slugs) do
    outside = Enum.uniq(slugs) -- Pilot.autonomous_pages()
    repeated = slugs -- Enum.uniq(slugs)

    cond do
      outside != [] -> {:error, {:outside_pilot, outside}}
      repeated != [] -> {:error, {:duplicate_pages, Enum.uniq(repeated)}}
      true -> :ok
    end
  end

  @doc """
  One page's case: its snapshot and every arm's packet. Reads only. Case
  `n` is 1, or 2 for the one retry of an unmatched case.
  """
  def freeze_page(batch_id, slug, n, arms, opts) do
    generation = Keyword.get(opts, :generation, 0)

    page =
      slug
      |> Lexicon.lookup(Keyword.get(opts, :language, "en"))
      |> WordPage.build(viewer: :public)

    candidates = Candidates.for_page(page)

    snapshot =
      if candidates.scope.ids == [],
        do: %{"snapshot_version" => "comparison-snapshot-v1", "lexeme_ids" => []},
        else: Packet.snapshot_identity(page, candidates, generation: generation)

    snapshot = Map.put(snapshot, "slug", slug)
    prepared = Enum.map(arms, &prepare_arm(&1, page, candidates, generation))

    %{
      slug: slug,
      n: n,
      case_id: "#{batch_id}:#{slug}:#{n}",
      snapshot: snapshot,
      snapshot_sha256: Digest.term(snapshot),
      arms: prepared,
      fingerprints: fingerprint_groups(prepared),
      matched: matched?(prepared)
    }
  end

  defp prepare_arm(arm, page, candidates, generation) do
    base = %{label: arm.label, config: arm.config, cut: arm.cut}

    with {:ok, packet} <-
           Packet.for_page(page,
             instruction_version: arm.config.instruction_version,
             candidates: candidates,
             generation: generation,
             cut: Map.fetch!(@cuts, arm.cut)
           ),
         {:ok, frozen} <- Packet.freeze(packet),
         :ok <- Packet.fits?(frozen, arm.config.generation) do
      Map.merge(base, %{
        status: :ready,
        frozen: frozen,
        packet_hash: frozen.hash,
        prompt_sha256: Packet.prompt_sha256(frozen),
        evidence_fingerprint: Packet.evidence_fingerprint(frozen),
        cut_version: frozen.packet["policy"]["cut"]
      })
    else
      {:error, reason} -> Map.merge(base, %{status: :refused, reason: reason})
    end
  end

  # The fingerprints of a case's ready arms, by cut.
  defp fingerprint_groups(arms) do
    arms
    |> Enum.filter(&(&1.status == :ready))
    |> Enum.group_by(& &1.cut, & &1.evidence_fingerprint)
    |> Map.new(fn {cut, prints} -> {cut, Enum.uniq(prints)} end)
  end

  @doc """
  Whether a case's arms are matched: every arm is ready, and arms that
  share a cut share one evidence fingerprint (each equal to the first arm
  of its cut).
  """
  def matched?(arms) do
    Enum.all?(arms, &(&1.status == :ready)) and
      arms |> fingerprint_groups() |> Map.values() |> Enum.all?(&(length(&1) == 1))
  end

  # ── the run ───────────────────────────────────────────────────────────────

  @doc """
  Runs a frozen batch, case by case. Returns `{:ok, %{cases, halted}}`:
  every case tried (a retried page has two), each with its status
  (`matched`, `unmatched`, `not_runnable` or `not_run`) and every arm's
  attempt id, outcome and hashes, and `halted`, the reason the batch
  stopped early, or nil.

  `opts`: `:actor_id` (required); `:in_snapshot`, a function running a
  zero-arity function in a repeatable-read, read-only transaction, for a
  retry's new snapshot (default: it just calls it); `:window_minutes` (60);
  `:now` (a zero-arity function); and the runtime's own (`:service_key`, …).
  """
  def run(batch, opts) do
    in_snapshot = Keyword.get(opts, :in_snapshot, fn fun -> fun.() end)
    deadline = DateTime.add(batch.frozen_at, Keyword.get(opts, :window_minutes, 60) * 60)

    {cases, halted} =
      Enum.reduce(batch.pages, {[], nil}, fn
        page, {cases, nil} ->
          {done, halted} = run_page(page, batch, deadline, in_snapshot, opts)
          {cases ++ done, halted}

        page, {cases, halted} ->
          {cases ++ [not_run(page, :batch_halted)], halted}
      end)

    {:ok, %{cases: cases, halted: halted}}
  end

  defp run_page(page, batch, deadline, in_snapshot, opts) do
    case run_case(page, deadline, opts) do
      {%{status: :unmatched} = first, nil} when page.n == 1 ->
        retry =
          in_snapshot.(fn ->
            freeze_page(batch.batch, page.slug, 2, batch.arms, freeze_opts(batch))
          end)

        {second, halted} = run_case(retry, deadline, opts)
        {[first, second], halted}

      {result, halted} ->
        {[result], halted}
    end
  end

  defp freeze_opts(batch), do: [generation: batch.generation, language: batch.language]

  defp run_case(page, deadline, opts) do
    cond do
      Enum.any?(page.arms, &(&1.status == :refused)) ->
        {case_result(page, :not_runnable, :arm_refused_at_freeze, []), nil}

      not page.matched ->
        {case_result(page, :unmatched, :fingerprint_mismatch, []), nil}

      DateTime.compare(now(opts), deadline) != :lt ->
        {not_run(page, :batch_window_passed), :batch_window_passed}

      true ->
        call_arms(page, opts)
    end
  end

  defp call_arms(page, opts) do
    page.arms
    |> Enum.reduce_while([], fn arm, done ->
      case call_arm(arm, page, opts) do
        {:ok, result} -> {:cont, done ++ [result]}
        {:unmatched, reason} -> {:halt, {:unmatched, reason, done}}
        {:halt, reason, result} -> {:halt, {:halt, reason, done ++ List.wrap(result)}}
      end
    end)
    |> case do
      done when is_list(done) ->
        {case_result(page, :matched, nil, done), nil}

      {:unmatched, reason, done} ->
        {case_result(page, :unmatched, reason, done), nil}

      {:halt, reason, done} ->
        {case_result(page, :not_run, reason, done), reason}
    end
  end

  defp call_arm(arm, page, opts) do
    expiry = Packet.earliest_expiry(arm.frozen.packet["candidates"])

    if expiry && DateTime.compare(now(opts), elem(DateTime.from_iso8601(expiry), 1)) != :lt do
      {:unmatched, :snapshot_expired}
    else
      runtime_opts =
        opts
        |> Keyword.drop([:in_snapshot, :window_minutes, :now])
        |> Keyword.merge(
          request_key: "comparison:#{page.case_id}:#{arm.label}",
          purpose: :comparison,
          comparison: %{arm: arm.label, case: page.case_id, snapshot: page.snapshot_sha256}
        )

      case Runtime.run(arm.config, arm.frozen, runtime_opts) do
        {status, receipt} when status in [:ok, :replay] ->
          {:ok, arm_result(arm, status, receipt)}

        {:uncertain, receipt} ->
          {:halt, :uncertain, arm_result(arm, :uncertain, receipt)}

        {:refused, {:packet_stale, _reasons}} ->
          {:unmatched, :packet_stale}

        {:refused, reason} ->
          {:halt, reason, nil}
      end
    end
  end

  defp arm_result(arm, status, receipt) do
    %{
      label: arm.label,
      status: status,
      attempt_id: receipt.attempt_id,
      outcome: receipt.outcome,
      decision: receipt.result && receipt.result["decision"],
      evidence_fingerprint: receipt.evidence_fingerprint,
      packet_hash: receipt.packet_hash
    }
  end

  defp case_result(page, status, reason, results) do
    %{
      case_id: page.case_id,
      slug: page.slug,
      n: page.n,
      snapshot_sha256: page.snapshot_sha256,
      status: status,
      reason: reason,
      fingerprints: page.fingerprints,
      prepared: Enum.map(page.arms, &prepared_record/1),
      results: results
    }
  end

  defp not_run(page, reason), do: case_result(page, :not_run, reason, [])

  defp prepared_record(%{status: :ready} = arm) do
    packet = arm.frozen.packet

    %{
      label: arm.label,
      status: :ready,
      cut_version: arm.cut_version,
      packet_hash: arm.packet_hash,
      prompt_sha256: arm.prompt_sha256,
      evidence_fingerprint: arm.evidence_fingerprint,
      candidates: length(packet["candidates"]),
      by_section:
        Enum.frequencies_by(packet["candidates"], &DevilsDictionary.Curation.WholeEntry.section/1),
      omitted_by_reason: Enum.frequencies_by(packet["omitted"] || [], & &1["reason"]),
      meanings: length(packet["meanings"]),
      priority_candidates: packet["priority_candidates"],
      fixed_lead: packet["fixed_lead"],
      earliest_expiry: Packet.earliest_expiry(packet["candidates"])
    }
  end

  defp prepared_record(arm), do: %{label: arm.label, status: :refused, reason: arm.reason}

  defp now(opts) do
    case Keyword.get(opts, :now) do
      nil -> DateTime.utc_now()
      fun when is_function(fun, 0) -> fun.()
    end
  end

  # ── the record ────────────────────────────────────────────────────────────

  @doc """
  The batch record a run writes: the batch, its arms' identities, each
  page's snapshot and every case's result. Ids, hashes and counts only,
  never excerpt, label or reason text.
  """
  def record(batch, result, extra \\ %{}) do
    Map.merge(
      %{
        "record_version" => @record_version,
        "batch" => batch.batch,
        "frozen_at" => batch.frozen_at,
        "generation" => batch.generation,
        "language" => batch.language,
        "snapshot_sha256" => batch.snapshot_sha256,
        "fingerprint_scheme" => Packet.fingerprint_scheme(),
        "arms" => Enum.map(batch.arms, &arm_record/1),
        "snapshots" =>
          Map.new(batch.pages, &{&1.slug, Map.put(&1.snapshot, "sha256", &1.snapshot_sha256)}),
        "cases" => result && result.cases,
        "halted" => result && result.halted
      },
      extra
    )
    |> json()
  end

  defp json(%DateTime{} = dt), do: DateTime.to_iso8601(dt)
  defp json(%{__struct__: _} = struct), do: struct |> Map.from_struct() |> json()
  defp json(%{} = map), do: Map.new(map, fn {k, v} -> {to_string(k), json(v)} end)
  defp json(list) when is_list(list), do: Enum.map(list, &json/1)
  defp json(tuple) when is_tuple(tuple), do: tuple |> Tuple.to_list() |> json()
  defp json(atom) when is_atom(atom) and atom not in [nil, true, false], do: to_string(atom)
  defp json(other), do: other
end
