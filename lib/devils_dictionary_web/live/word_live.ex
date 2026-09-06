defmodule DevilsDictionaryWeb.WordLive do
  @moduledoc """
  `/define/:slug` — a page for every word in the index (#71 §8a).

  The whole page is one round of queries in `handle_params/3`, well under the
  150 ms #71 §7 budgets and nowhere near the 2.5 s long-poll fallback the S4
  audit drew the line at: `mount/3` runs three times over a page's life (dead
  render, connected mount, and again on every reconnect), so anything slow
  there is slow three times and can abandon its own websocket.

  Nothing here raises. `/define/zzzz` is a page that says *no such word*, and a
  bare index row is a page with a headword and nothing under it — scorecard row
  X1 renders 200 random index lexemes and most of the index is bare. The
  finished sparse-state treatment is U2's; not crashing is U1a's.
  """

  use DevilsDictionaryWeb, :live_view

  alias DevilsDictionary.Lexicon
  alias DevilsDictionary.Lexicon.WordPage
  alias DevilsDictionaryWeb.Word

  @trail_cap 12

  @impl true
  def mount(_params, _session, socket), do: {:ok, socket}

  @impl true
  def handle_params(%{"slug" => slug} = params, _uri, socket) do
    trail = parse_trail(params["trail"])
    page = slug |> Lexicon.lookup() |> WordPage.build(trail: trail)

    {:noreply,
     socket
     |> assign(:slug, slug)
     |> assign(:page, page)
     |> assign(:page_title, title(page, slug))}
  end

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
          <.miss slug={@slug} />
        <% else %>
          <Word.headword headword={@page.headword} />

          <div :if={@page.cards != []} class="mt-8 space-y-6">
            <Word.source_card :for={card <- @page.cards} card={card} trail={trail_here(@page)} />
          </div>

          <p :if={@page.cards == []} id="bare-row" class="mt-8 text-sm/7 text-mist-500">
            known to exist, nothing absorbed yet
          </p>

          <Word.related_block
            :for={related <- @page.related}
            related={related}
            trail={trail_here(@page)}
          />
        <% end %>
      </.container>
    </Layouts.app>
    """
  end

  attr :slug, :string, required: true

  defp miss(assigns) do
    ~H"""
    <div id="no-such-word" class="py-12">
      <.heading>“{@slug}”</.heading>
      <.text class="mt-4">
        No such word. Nothing in the index — not as a headword, not as a spelling, not as an
        inflected form of anything else.
      </.text>
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
