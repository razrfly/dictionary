defmodule Mix.Tasks.Dd.Discovery.Status do
  use Mix.Task
  @shortdoc "What every discovery provider has spent, holds, and is about to lose"

  @moduledoc """
  The ledger, one row per registered provider (#144 Phase 4).

      mix dd.discovery.status
      mix dd.discovery.status --retention-limit 2000

  Every number comes from `DevilsDictionary.Discovery.Status.rows/0`, which is
  what `/ops/discovery` renders — one implementation, so the page and the task
  cannot disagree, the arrangement `mix dd.health` and `/ops/imports` have had
  since #69.

  The columns:

    * **state** — `ready` when the provider's own `enabled?/0` says so,
      `no key` when it does not and nothing turned it off, `off` when its
      switch did, `inactive` when the source row is, `browser` for a provider
      the reader's browser drives and that therefore stores nothing
    * **runs** / **failed** — every run this provider has ever been given, and
      how many ended failed. The ledger of what was spent; `cleanup/0` prunes
      it by age and per position
    * **last success** — the newest `completed_at` of a succeeded run
    * **held** — rows in `discovery_results` now. Retention and the sweep both
      take these, and a provider with runs and nothing held is one whose
      retention has run
    * **roots** / **stale** — the display roots a reader would be served, and
      how many are past `refresh_after` and would be re-queued by the next
      visit. Nothing refreshes a page nobody visits, so a stale root is not a
      backlog — it is a page nobody has opened since it went stale
    * **due** — runs `Discovery.cleanup/0` would withdraw and purge on the next
      tick, from `Discovery.retention_due/1`, which is bounded (see
      `--retention-limit`)
    * **budget** — outbound requests claimed in this source's current rolling
      window, against its `request_budget_limit`
    * **backoff** — a provider-wide `Retry-After` the source is still under

  This needs no credential. A keyless checkout prints every registered
  provider, most of them `no key` with an empty ledger, which is the honest
  report of that machine and the point of the task.
  """

  @requirements ["app.start"]

  alias DevilsDictionary.Discovery.Status

  @switches [retention_limit: :integer]

  @impl Mix.Task
  def run(args) do
    {opts, rest, invalid} = OptionParser.parse(args, strict: @switches)

    if rest != [] or invalid != [],
      do: Mix.raise("invalid arguments; run `mix help dd.discovery.status`")

    limit = opts[:retention_limit] || 500
    if limit < 1, do: Mix.raise("--retention-limit must be a positive integer")

    now = DateTime.utc_now()
    rows = Status.rows(now: now, retention_limit: limit)

    say(
      "\nDISCOVERY (#{length(rows)} registered providers, read at " <>
        "#{Calendar.strftime(now, "%Y-%m-%d %H:%M:%S")} UTC)"
    )

    # The slug column is as wide as the widest slug and no wider: a fixed 14
    # put `offset-fixture` hard against the next column, and the registry is
    # the one thing here that is not fixed.
    width = width(rows)

    say("  " <> header(width))
    for row <- rows, do: say("  " <> row(row, now, width))

    footnotes(rows, limit)
  end

  defp width(rows) do
    rows
    |> Enum.map(&String.length(&1.slug))
    |> Enum.max(fn -> 0 end)
    |> max(12)
    |> Kernel.+(2)
  end

  defp header(width) do
    pad("provider", width) <>
      pad("state", 10) <>
      lead("runs", 6) <>
      lead("failed", 8) <>
      pad("  last success", 20) <>
      lead("held", 7) <>
      lead("roots", 7) <>
      lead("stale", 7) <> lead("due", 6) <> lead("budget", 9) <> "  backoff"
  end

  defp row(row, now, width) do
    pad(row.slug, width) <>
      pad(state(row), 10) <>
      lead(number(row.runs), 6) <>
      lead(number(row.failed), 8) <>
      pad("  " <> last_success(row.last_success, now), 20) <>
      lead(number(row.results), 7) <>
      lead(number(row.roots), 7) <>
      lead(number(row.stale), 7) <>
      lead(number(row.retention_due), 6) <> lead(budget(row.budget), 9) <> "  " <> backoff(row)
  end

  # The four reasons a shelf is not there, told apart. "Not enabled" is the one
  # answer an operator can do nothing with: a missing key, an owner's switch
  # and a withdrawn source row are three different mornings.
  defp state(%{kind: :browser}), do: "browser"
  defp state(%{active: false}), do: "inactive"
  defp state(%{enabled: true}), do: "ready"
  defp state(%{switch: :off}), do: "off"
  defp state(_row), do: "no key"

  defp last_success(nil, _now), do: "never"

  defp last_success(at, now) do
    "#{Calendar.strftime(at, "%b %d %H:%M")} (#{ago(DateTime.diff(now, at))})"
  end

  defp ago(seconds) when seconds < 90, do: "#{seconds}s"
  defp ago(seconds) when seconds < 5_400, do: "#{div(seconds, 60)}m"
  defp ago(seconds) when seconds < 172_800, do: "#{div(seconds, 3_600)}h"
  defp ago(seconds), do: "#{div(seconds, 86_400)}d"

  defp budget(%{limit: nil, used: used}), do: "#{used}/?"
  defp budget(%{used: used, limit: limit}), do: "#{used}/#{limit}"

  defp backoff(%{backoff: nil}), do: "—"

  defp backoff(%{backoff: %{seconds: seconds, reason: reason}}),
    do: "#{ago(seconds)} (#{reason || "no reason given"})"

  defp footnotes(rows, limit) do
    browser = Enum.count(rows, &(&1.kind == :browser))
    due = Enum.sum(Enum.map(rows, & &1.retention_due))
    stale = Enum.sum(Enum.map(rows, & &1.stale))

    say(
      "\n  #{stale} of #{Enum.sum(Enum.map(rows, & &1.roots))} display roots are past their " <>
        "refresh clock; each is re-queued by the next visit to its page."
    )

    say(
      "  #{due} run(s) are past retention and go on the next cleanup tick " <>
        "(counted over the next #{limit} due, oldest first)."
    )

    if browser > 0 do
      say(
        "  #{browser} provider(s) are driven by the reader's browser and store nothing here, " <>
          "by design."
      )
    end
  end

  defp number(value), do: Integer.to_string(value)
  defp pad(value, width), do: String.pad_trailing(value, width)
  defp lead(value, width), do: String.pad_leading(value, width)
  defp say(line), do: Mix.shell().info(line)
end
