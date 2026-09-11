defmodule DevilsDictionaryWeb.HomeLive do
  @moduledoc """
  `/` — the way in (#71 §5 W1, U2).

  A search box over the whole index, a *Surprise me*, five seed words and the
  size of the thing. Until U2 this route was a static list of developer
  surfaces, which meant a reader had to know a slug to see anything at all.

  Three rules it keeps:

    * **Search keeps `Lexicon.search/2` and adds an entity query** — the trigram
      indexes over `lexemes.lemma` and `entities.preferred_label`. Words and
      people with the same label remain separate typed results. Inflected
      forms are index rows in their own right, so *oysters* is reachable by
      prefix; pressing enter runs `Lexicon.lookup/1`, which resolves a form by
      containment and lands on the word with its *redirected from* line.
    * **The query is in the URL** (`/?q=oyst`), patched, debounced at 300 ms —
      the browse page's idiom, and a search that can be linked to.
    * **Nothing slow in `mount/3`.** The index counts are three aggregates over
      1.5 million rows, so they arrive by `assign_async` through the same
      Cachex the health page uses.
  """

  use DevilsDictionaryWeb, :live_view

  alias DevilsDictionary.Claims.Connection
  alias DevilsDictionary.{Encyclopedia, Health, Lexicon, Sources}

  @seeds ~w(cat dog oyster joy grief)
  @limit 10
  @entity_limit 5
  @stats_ttl :timer.minutes(10)

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(q: "", results: [], seeds: @seeds)
     |> assign_async(:stats, fn -> {:ok, %{stats: stats()}} end)}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    q = params["q"] || ""

    {:noreply, assign(socket, q: q, results: results(q))}
  end

  defp results(""), do: []

  # One word, one row. The trigram answers per lexeme, so *oyster* comes back
  # three times — noun, verb, adjective — and a list that repeats a word eight
  # times is a list of nothing. The rows are folded by slug, keeping the order
  # the search ranked them in, and the parts of speech are joined rather than
  # picked from: showing *oyster · adj* because "adj" sorts first would be a
  # lie about the word.
  defp results(q), do: word_results(q) ++ entity_results(q)

  defp word_results(q) do
    rows = Lexicon.search(q, limit: @limit * 3)
    by_slug = Enum.group_by(rows, & &1.slug)

    rows
    |> Enum.map(& &1.slug)
    |> Enum.uniq()
    |> Enum.take(@limit)
    |> Enum.map(fn slug ->
      group = by_slug[slug]

      %{
        kind: :word,
        slug: slug,
        lemma: group |> hd() |> Map.get(:lemma),
        pos: group |> Enum.map(& &1.pos) |> Enum.uniq() |> Enum.join(" · "),
        enriched?: Enum.any?(group, &(not is_nil(&1.enriched_at)))
      }
    end)
  end

  defp entity_results(q) do
    q
    |> Encyclopedia.search_entities(limit: @entity_limit)
    |> Enum.map(fn entity ->
      %{
        kind: :entity,
        object_id: entity.object_id,
        slug: Connection.slugify(entity.label),
        label: entity.label,
        description: entity.description,
        type_label: entity_type_label(entity.kind)
      }
    end)
  end

  defp entity_type_label(kind) do
    kind
    |> to_string()
    |> String.replace("_", " ")
    |> String.capitalize()
  end

  @impl true
  def handle_event("search", %{"q" => q}, socket) do
    {:noreply, push_patch(socket, to: path(q))}
  end

  # Enter is a different question from typing: it means *this word*. A hit —
  # a headword, a spelling, or an inflected form — goes straight to the page;
  # a miss falls back to the results the trigram has already found.
  @impl true
  def handle_event("go", %{"q" => q}, socket) do
    case Lexicon.lookup(String.trim(q)) do
      %{lexemes: [lexeme | _]} ->
        {:noreply, push_navigate(socket, to: ~p"/define/#{lexeme.slug}")}

      _ ->
        {:noreply, push_patch(socket, to: path(q))}
    end
  end

  @impl true
  def handle_event("surprise", _params, socket) do
    case Lexicon.random_word() do
      nil -> {:noreply, socket}
      word -> {:noreply, push_navigate(socket, to: ~p"/define/#{word.slug}")}
    end
  end

  defp path(q) do
    case String.trim(q) do
      "" -> ~p"/"
      q -> ~p"/?#{[q: q]}"
    end
  end

  # Cached, because the three counts read 1.5 million rows and every visitor
  # would otherwise pay for them.
  defp stats do
    if Application.get_env(:devils_dictionary, :cache_scorecard, true) do
      {_status, stats} =
        Cachex.fetch(:health, :home_stats, fn ->
          {:commit, compute_stats(), expire: @stats_ttl}
        end)

      stats
    else
      compute_stats()
    end
  end

  # Three whole-corpus numbers (#77 §1). It used to add one clause per scope —
  # "25,385 animals enriched · 5 culture enriched · 809 emotions enriched" —
  # which named internal populations in public copy, presented a five-row pilot
  # as a product category, and grew a clause every time a test population was
  # added. `enriched` was already computed here and never rendered; it is the
  # honest headline, because it is the number that says how often a reader who
  # types a word finds anything.
  defp compute_stats do
    index = Health.index()

    %{
      words: index.total,
      enriched: index.enriched,
      sources: length(Sources.list_sources())
    }
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <section class="py-16">
        <.container class="flex flex-col items-center gap-6">
          <.heading class="max-w-5xl text-center">Every word. Every source. One page.</.heading>
          <.text size="lg" class="max-w-xl text-center">
            Dictionaries, encyclopedias and the culture, by who did the defining. Start anywhere and
            keep hopping.
          </.text>

          <.form
            for={%{}}
            id="search"
            phx-change="search"
            phx-submit="go"
            class="mt-4 w-full max-w-xl"
          >
            <div class="flex flex-col gap-3 sm:flex-row">
              <div class="grow">
                <.input
                  type="text"
                  name="q"
                  id="search-q"
                  value={@q}
                  placeholder="search a word…"
                  autocomplete="off"
                  phx-debounce="300"
                />
              </div>
              <.button type="button" id="surprise" phx-click="surprise" variant="soft" size="lg">
                Surprise me
              </.button>
            </div>
          </.form>

          <p id="seeds" class="text-sm/7 text-mist-500">
            <span :for={{seed, i} <- Enum.with_index(@seeds)}>
              <span :if={i > 0} aria-hidden="true">·</span>
              <.link
                id={"seed-#{seed}"}
                navigate={~p"/define/#{seed}"}
                class="underline underline-offset-4 hover:text-mist-950 dark:hover:text-white"
              >
                {seed}
              </.link>
            </span>
          </p>

          <div :if={@q != ""} id="results" class="w-full max-w-xl">
            <p :if={@results == []} id="results-empty" class="text-sm/7 text-mist-500">
              Nothing in the index matches “{@q}”. The index holds headwords and their spellings;
              try fewer letters.
            </p>

            <ol
              :if={@results != []}
              class="flex flex-col divide-y divide-mist-950/5 dark:divide-white/10"
            >
              <li :for={result <- @results}>
                <.link
                  :if={result.kind == :word}
                  id={"result-#{result.slug}"}
                  navigate={~p"/define/#{result.slug}"}
                  class="flex min-w-0 items-baseline justify-between gap-4 py-3 hover:bg-mist-950/2.5 dark:hover:bg-white/5"
                >
                  <span class="min-w-0">
                    <span class={[
                      result.enriched? && "font-medium text-mist-950 dark:text-white",
                      not result.enriched? && "text-mist-500"
                    ]}>
                      {result.lemma}
                    </span>
                  </span>
                  <span class="shrink-0 text-mist-500">Word · {result.pos}</span>
                </.link>
                <.link
                  :if={result.kind == :entity}
                  id={"result-entity-#{result.object_id}"}
                  navigate={~p"/entities/#{result.object_id}/#{result.slug}"}
                  class="flex min-w-0 items-start justify-between gap-4 py-3 hover:bg-mist-950/2.5 dark:hover:bg-white/5"
                >
                  <span class="min-w-0">
                    <span class="font-medium text-mist-950 dark:text-white">{result.label}</span>
                    <span :if={result.description} class="text-mist-500">
                      — {result.description}
                    </span>
                  </span>
                  <span class="shrink-0 text-mist-500">{result.type_label}</span>
                </.link>
              </li>
            </ol>
          </div>
        </.container>
      </section>

      <.container>
        <p
          id="stats"
          class="border-t border-mist-950/10 py-6 text-sm/7 text-mist-500 dark:border-white/10"
        >
          <.async_result :let={stats} assign={@stats}>
            <:loading>counting…</:loading>
            <:failed :let={_reason}>the index is there; the count is not</:failed>
            {number(stats.words)} words indexed · {number(stats.enriched)} with at least one
            definition · {stats.sources} sources so far
          </.async_result>
        </p>
      </.container>
    </Layouts.app>
    """
  end
end
