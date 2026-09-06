defmodule DevilsDictionaryWeb.SourceLive do
  @moduledoc """
  One source (#69 §6): its tier, kind and access, its licence and the
  attribution line we are obliged to show, what pins it in time, what it holds
  and what it materialized, how much of a scope it attests, its runs, and a few
  real rows.

  The samples are real records, not fixtures. A source page showing invented
  samples would be the one page in the app that lies about what was absorbed.
  """
  use DevilsDictionaryWeb, :live_view

  alias DevilsDictionary.Health

  @impl true
  def mount(%{"slug" => slug}, _session, socket) do
    detail = Health.source_detail(slug, scope: "animals")

    {:ok,
     assign(socket,
       page_title: detail.source.name,
       slug: slug,
       detail: detail
     )}
  rescue
    Ecto.NoResultsError ->
      {:ok,
       socket
       |> put_flash(:error, "No such source.")
       |> push_navigate(to: ~p"/admin/imports")}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <.section id="source-header" eyebrow={kind_line(@detail.source)} headline={@detail.source.name}>
        <:cta>
          <div class="flex flex-wrap items-center gap-3">
            <.button_link :if={@detail.source.homepage} href={@detail.source.homepage} target="_blank">
              Homepage <span aria-hidden="true">↗</span>
            </.button_link>
            <.button_link
              :if={@detail.source.license_url}
              href={@detail.source.license_url}
              target="_blank"
              variant="soft"
            >
              {@detail.source.license} ↗
            </.button_link>
          </div>
        </:cta>

        <div class="grid grid-cols-1 gap-2 sm:grid-cols-2 lg:grid-cols-4">
          <.stat value={to_string(@detail.source.tier)}>
            tier — {tier_glyph(@detail.source.tier)} inherited by every card this source fills
          </.stat>
          <.stat value={to_string(@detail.source.access)}>
            access — {access_note(@detail.source.access)}
          </.stat>
          <.stat value={@detail.snapshot || "unpinned"}>
            what pins it in time (#69 decision 8: pinned snapshots, re-absorbed by hand)
          </.stat>
          <%!-- A year is not a count: 1911, never 1,911. --%>
          <.stat value={to_string(@detail.source.era_year || "—")}>
            the year it speaks from
          </.stat>
        </div>

        <p :if={@detail.source.attribution} class="mt-6 text-sm/7 text-mist-700 dark:text-mist-400">
          <strong class="text-mist-950 dark:text-white">Attribution:</strong>
          {@detail.source.attribution}
        </p>
      </.section>

      <.section id="source-counts" eyebrow="Holdings" headline="What we hold, and what it became">
        <div class="grid grid-cols-1 gap-2 sm:grid-cols-2 lg:grid-cols-4">
          <.stat value={number(@detail.ledger.records)}>
            raw records, each with the URL it came from
          </.stat>
          <.stat value={number(@detail.ledger.absent)}>
            "the source had nothing" markers
          </.stat>
          <.stat value={number(@detail.ledger.needs_materialization)}>
            records whose derived rows are stale
          </.stat>
          <.stat value={number(@detail.ledger.needs_fetch)}>
            {(@detail.ledger.needs_fetch_of && "#{@detail.ledger.needs_fetch_of} still to fetch") ||
              "nothing to fetch: the file is the answer"}
          </.stat>
        </div>

        <div class="mt-2 grid grid-cols-1 gap-2 sm:grid-cols-2 lg:grid-cols-3">
          <.stat :for={{label, value} <- materialized(@detail.materialized)} value={number(value)}>
            {label}
          </.stat>
        </div>
      </.section>

      <.section
        id="source-coverage"
        eyebrow="Coverage"
        headline={"How much of #{@detail.coverage.scope} it attests"}
        subheadline="The same Health.coverage/2 the scorecard grades A5 on, so this page and mix dd.score cannot disagree."
      >
        <div class="flex flex-col gap-6">
          <div class="grid grid-cols-1 gap-2 sm:grid-cols-3">
            <.stat value={"#{@detail.coverage.pct}%"}>
              {number(@detail.coverage.covered)} of {number(@detail.coverage.total)} scope words
            </.stat>
            <.stat value={number(@detail.coverage.missing)}>words it does not attest</.stat>
            <.stat value={number(map_size(@detail.coverage.missing_by_kind))}>
              kinds of miss, below
            </.stat>
          </div>

          <div :if={@detail.coverage.missing > 0}>
            <h3 class="mb-2 text-base/8 font-medium text-mist-950 dark:text-white">
              The misses, by kind
            </h3>
            <.table id="source-misses" rows={Enum.sort(@detail.coverage.missing_by_kind)}>
              <:col :let={{kind, _}} label="kind">{kind}</:col>
              <:col :let={{_, count}} label="words">{number(count)}</:col>
              <:col :let={{kind, _}} label="why">{miss_note(kind)}</:col>
            </.table>

            <p class="mt-4 text-sm/7 text-mist-700 dark:text-mist-400">
              A sample:
              <span :for={lemma <- @detail.coverage.sample} class="font-mono text-xs/6">
                {lemma}&nbsp;
              </span>
            </p>
          </div>

          <p class="text-sm/7">
            <.link navigate={~p"/s/animals?missing=#{@slug}"} class="underline">
              Browse the words this source is missing →
            </.link>
          </p>
        </div>
      </.section>

      <.section id="source-runs" eyebrow="Runs" headline="Every task run leaves a row">
        <.table :if={@detail.runs != []} id="source-runs-table" rows={@detail.runs}>
          <:col :let={run} label="#">{run.id}</:col>
          <:col :let={run} label="task">{run.task}</:col>
          <:col :let={run} label="status">
            <span class={run.status == :failed && "font-semibold text-red-700 dark:text-red-400"}>
              {run.status}
            </span>
          </:col>
          <:col :let={run} label="started">{stamp(run.started_at)}</:col>
          <:col :let={run} label="took">{took(run)}</:col>
          <:col :let={run} label="stats">
            <span class="font-mono text-xs/6">{stats(run.stats)}</span>
          </:col>
        </.table>
        <.text :if={@detail.runs == []}>No run has touched this source yet.</.text>
      </.section>

      <.section
        id="source-samples"
        eyebrow="Samples"
        headline="Real rows, taken from the database"
      >
        <div class="flex flex-col gap-10">
          <div :if={@detail.senses != []}>
            <h3 class="mb-4 text-base/8 font-medium text-mist-950 dark:text-white">Senses</h3>
            <div class="flex flex-col gap-4">
              <div
                :for={sense <- @detail.senses}
                class="rounded-xl bg-mist-950/2.5 p-4 dark:bg-white/5"
              >
                <div class="text-sm/7 font-medium text-mist-950 dark:text-white">
                  {sense.lemma} <span class="font-normal text-mist-500">{sense.pos}</span>
                </div>
                <.text class="mt-1">{sense.gloss}</.text>
              </div>
            </div>
          </div>

          <div :if={@detail.entries != []}>
            <h3 class="mb-4 text-base/8 font-medium text-mist-950 dark:text-white">Entries</h3>
            <div class="flex flex-col gap-4">
              <div
                :for={entry <- @detail.entries}
                class="rounded-xl bg-mist-950/2.5 p-4 dark:bg-white/5"
              >
                <div class="text-sm/7 font-medium text-mist-950 dark:text-white">
                  {entry.headword}
                  <span class="font-normal text-mist-500">{entry.pos} · {entry.year}</span>
                </div>
                <.text class="mt-1">{String.slice(entry.body || "", 0, 400)}</.text>
              </div>
            </div>
          </div>

          <.text :if={@detail.senses == [] and @detail.entries == []}>
            This source materializes neither senses nor entries — it writes concepts and the
            edges between them. Its work shows up on a word's page as the thing behind the word.
          </.text>
        </div>
      </.section>
    </Layouts.app>
    """
  end

  defp kind_line(source), do: "#{source.kind} · #{source.access} · #{source.license}"

  defp access_note(:dump), do: "a pinned file, streamed"
  defp access_note(:api), do: "fetched on demand, politely, and cached forever"
  defp access_note(:static), do: "a book, checked in"
  defp access_note(:user), do: "people and bots"

  defp materialized(counts) do
    [
      {"senses — one meaning as this source asserts it", counts.senses},
      {"entries — a text it published about a word or a thing", counts.entries},
      {"lexical relations — its edges between words", counts.relations},
      {"concept relations — its edges between things", counts.concept_relations},
      {"concept links — word ↔ thing, with a method and a confidence", counts.concept_links},
      {"words it introduced to the index", counts.lexemes_introduced}
    ]
  end

  defp miss_note("scientific_name"),
    do:
      "a scientific name, any rank. Wiktionary files these as Translingual; Wikidata's P225 has them"

  defp miss_note("multiword"), do: "a phrase with no entry of its own"
  defp miss_note("single_word"), do: "a word this source simply does not have"
  defp miss_note(other), do: other

  defp stamp(nil), do: "—"
  defp stamp(at), do: Calendar.strftime(at, "%b %d %H:%M:%S")

  defp took(%{stats: %{"elapsed_ms" => ms}}) when is_integer(ms) and ms < 1000, do: "#{ms} ms"

  defp took(%{stats: %{"elapsed_ms" => ms}}) when is_integer(ms),
    do: "#{Float.round(ms / 1000, 1)} s"

  defp took(%{started_at: from, finished_at: to}) when not is_nil(from) and not is_nil(to),
    do: "#{DateTime.diff(to, from)} s"

  defp took(_run), do: "—"

  defp stats(stats) when is_map(stats) do
    stats
    |> Map.drop(["elapsed_ms"])
    |> Enum.sort()
    |> Enum.take(4)
    |> Enum.map_join(" · ", fn {k, v} -> "#{k}=#{inspect(v)}" end)
  end

  defp stats(_), do: ""
end
