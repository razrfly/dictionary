defmodule DevilsDictionaryWeb.WordLive do
  @moduledoc """
  `/define/:slug` — a page for every word in the index (#71 §8a).

  The whole page is one round of queries in `handle_params/3`, well under the
  150 ms #71 §7 budgets and nowhere near the 2.5 s long-poll fallback the S4
  audit drew the line at: `mount/3` runs three times over a page's life (dead
  render, connected mount, and again on every reconnect), so anything slow
  there is slow three times and can abandon its own websocket.

  For the same reason the page is rebuilt only when the word or the walk
  changes. Opening the ⓘ drawer is a patch to the same word, so it re-runs
  `handle_params/3`; without the guard every ⓘ click would re-run ten queries
  to render the page it is already on.

  Nothing here raises. `/define/zzzz` is a page that says *no such word* and
  offers the nearest words the trigram can find; a bare index row is a page with
  a headword and a promise. X1 renders 200 random index lexemes and most of the
  index is bare.
  """

  use DevilsDictionaryWeb, :live_view

  alias DevilsDictionary.Lexicon
  alias DevilsDictionary.Lexicon.WordPage
  alias DevilsDictionaryWeb.{Provenance, Thing, Word}

  @trail_cap 12
  @suggestions 5

  @impl true
  def mount(_params, _session, socket) do
    {:ok, assign(socket, slug: nil, trail: [], page: nil)}
  end

  @impl true
  def handle_params(%{"slug" => slug} = params, _uri, socket) do
    trail = parse_trail(params["trail"])

    socket =
      if slug == socket.assigns.slug and trail == socket.assigns.trail do
        socket
      else
        load(socket, slug, trail)
      end

    {:noreply,
     assign(socket, :provenance, WordPage.provenance(socket.assigns.page, params["provenance"]))}
  end

  defp load(socket, slug, trail) do
    page = slug |> Lexicon.lookup() |> WordPage.build(trail: trail)

    socket
    |> assign(:slug, slug)
    |> assign(:trail, trail)
    |> assign(:page, page)
    |> assign(:page_title, title(page, slug))
    |> assign(:scopes, Lexicon.scopes_for(Enum.map(page.headword.lexemes, & &1.id)))
    |> assign(:all_scopes, Lexicon.list_scopes())
    |> assign(:card_sources, page.cards |> Enum.map(& &1.source.name) |> Enum.uniq())
    |> assign(:suggestions, suggestions(page, slug))
  end

  # Only a miss pays for suggestions: on every other page the trigram would be
  # answering a question nobody asked.
  defp suggestions(%{headword: %{lexemes: []}}, slug) do
    slug
    |> Lexicon.search(limit: @suggestions)
    |> Enum.uniq_by(& &1.slug)
  end

  defp suggestions(_page, _slug), do: []

  # The trail is user input arriving in a URL, so it is parsed rather than
  # trusted: slugs only, deduplicated, and the most recent twelve. #71 §10
  # keeps it here instead of in socket state so a walk survives a reload and
  # can be pasted to someone else.
  defp parse_trail(nil), do: []

  defp parse_trail(param) do
    param
    |> String.split(",", trim: true)
    |> Enum.map(&String.trim/1)
    |> Enum.filter(&Regex.match?(~r/\A[a-z0-9-]{1,120}\z/, &1))
    |> Enum.uniq()
    |> Enum.take(-@trail_cap)
  end

  defp title(%{headword: %{lemma: nil}}, slug), do: "#{slug} — no such word"
  defp title(%{headword: %{lemma: lemma}}, _slug), do: lemma

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <.container class="py-10">
        <Word.trail trail={@page.trail} current={@page.headword.lemma || @slug} />

        <%= if @page.headword.lexemes == [] do %>
          <.miss slug={@slug} suggestions={@suggestions} />
        <% else %>
          <Word.headword headword={@page.headword} />

          <Word.scope_line scopes={@scopes} all={@all_scopes} sources={@card_sources} />

          <div :if={@page.cards != []} class="mt-8 space-y-6">
            <Word.source_card
              :for={card <- @page.cards}
              card={card}
              trail={trail_here(@page)}
              info={Word.info_path(@slug, @page.trail, "card:" <> card.id)}
            />
          </div>

          <Word.bare_row :if={@page.cards == []} />

          <Word.related_block
            :for={related <- @page.related}
            related={related}
            trail={trail_here(@page)}
          />

          <Thing.thing_panel
            :if={@page.thing}
            thing={@page.thing}
            trail={trail_here(@page)}
            info={Word.info_path(@slug, @page.trail, "thing")}
          />
        <% end %>
      </.container>
    </Layouts.app>

    <%!--
      Outside `Layouts.app` on purpose. The kit's `<main>` carries
      `overflow-clip`, which — unlike `overflow: hidden` — clips fixed-position
      descendants too, so a drawer rendered inside the container is trimmed to
      the article column and scrolled out of its own header.
    --%>
    <Provenance.provenance
      :if={@provenance}
      provenance={@provenance}
      close={Word.info_path(@slug, @page.trail)}
      record_path={&Word.info_path(@slug, @page.trail, "#{@provenance.ref}:#{&1}")}
    />
    """
  end

  attr :slug, :string, required: true
  attr :suggestions, :list, default: []

  defp miss(assigns) do
    ~H"""
    <div id="no-such-word" class="py-12">
      <.heading>“{@slug}”</.heading>
      <.text class="mt-4">
        No such word. Nothing in the index — not as a headword, not as a spelling, not as an
        inflected form of anything else.
      </.text>
      <Word.did_you_mean suggestions={@suggestions} />
      <.a navigate={~p"/"} class="mt-6">Start somewhere else</.a>
    </div>
    """
  end

  # A chip leaves this word, so the trail it writes is the one that arrived
  # plus this word. Capping here as well as in the parser keeps a long walk
  # from growing a long URL.
  defp trail_here(%{trail: trail, headword: %{lemma: nil}}), do: trail

  defp trail_here(%{trail: trail, headword: headword}) do
    (trail ++ [%{slug: headword.slug, lemma: headword.lemma}])
    |> Enum.uniq_by(& &1.slug)
    |> Enum.take(-@trail_cap)
  end
end
