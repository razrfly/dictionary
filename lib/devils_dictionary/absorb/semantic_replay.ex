defmodule DevilsDictionary.Absorb.SemanticReplay do
  @moduledoc """
  Scorecard M2: re-materializing every record of a source from its stored
  payloads, with the network off, must change nothing derived.

  The comparison is `Health.StateFingerprint` taken before and after, so it
  sees changed content at unchanged row counts. Its boundary is explicit:

    * `resolve: false` — the materialize pass alone. It re-creates, as
      `pending_relations`, every string-target edge the resolver had already
      drained, so pending relations are **not compared** and the report says
      so.
    * `resolve: true` — the materialize pass followed by
      `Absorb.Resolver.run/1` for the same source, which drains them again.
      Pending relations are compared like every other table, provenance and
      endpoints included.

  A recovery re-projection uses `resolve: true` (`mix dd.materialize --all
  --resolve`). The resolve pass drains only this source's edges, but its
  canonical linking (`Resolver.link_canonical/0`) spans every source, so a
  variant link another source's claim now supports shows as a `lexemes`
  change here. On a re-projection that has already run once, there is none
  left to make.
  """

  alias DevilsDictionary.Absorb.{Batch, Resolver}
  alias DevilsDictionary.Health.StateFingerprint

  @uncompared_without_resolve ["pending_relations"]

  @doc """
  Runs one source's materialize pass — every record with `all: true`, only
  the stale ones otherwise — and, with `resolve: true`, the resolver.

  Returns `%{counts:, resolved:, identical:, changed:, compared:,
  not_compared:}`. `identical` is nil when nothing was compared (a stale-only
  pass), otherwise whether every compared table fingerprints the same.
  """
  def run(module, source, opts \\ []) do
    all? = Keyword.get(opts, :all, false)
    resolve? = Keyword.get(opts, :resolve, false)

    compared =
      if resolve?,
        do: StateFingerprint.tables(),
        else: StateFingerprint.tables() -- @uncompared_without_resolve

    before = if all?, do: StateFingerprint.capture(compared)

    counts =
      Batch.run(
        module,
        source,
        Keyword.merge([only_stale: not all?], Keyword.take(opts, [:run_id]))
      )

    resolved = if resolve?, do: Resolver.run(source_id: source.id, run_id: opts[:run_id])

    {identical, changed} =
      if all? do
        now = StateFingerprint.capture(compared)

        changed =
          for {table, fingerprint} <- before, now[table] != fingerprint, into: %{} do
            {table, %{"before" => fingerprint, "after" => now[table]}}
          end

        {changed == %{}, changed}
      else
        {nil, %{}}
      end

    %{
      counts: counts,
      resolved: resolved,
      identical: identical,
      changed: changed,
      compared: if(all?, do: compared, else: []),
      not_compared: if(all?, do: StateFingerprint.tables() -- compared, else: [])
    }
  end
end
