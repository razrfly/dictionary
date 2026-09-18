defmodule DevilsDictionaryWeb.ArtworkLive do
  @moduledoc """
  The local artwork catalog: search and page through the works Dictionary
  already holds.

  Until #109 Phase 3a this page also carried a bounded live lookup against
  Artsy's API. That client was retired with the API; the 43 pilot works and
  their gene mappings remain as catalog rows, and this page makes no network
  request at all.
  """

  use DevilsDictionaryWeb, :live_view

  alias DevilsDictionary.Artworks
  alias DevilsDictionary.Claims.Contributions
  alias DevilsDictionaryWeb.Artwork

  on_mount {DevilsDictionaryWeb.UserAuth, :mount_current_scope}

  @impl true
  def mount(_params, _session, socket) do
    catalog = Artworks.catalog("")

    {:ok,
     socket
     |> assign(
       page_title: "artworks",
       search_form: to_form(%{"q" => ""}, as: :search),
       contributor: Contributions.internal_contributor?(socket.assigns[:current_scope]),
       catalog_query: "",
       catalog_page: catalog.page,
       catalog_count: catalog.count,
       catalog_previous_page: catalog.previous_page,
       catalog_next_page: catalog.next_page
     )
     |> stream(:artworks, catalog.items, dom_id: &"artwork-#{&1.object_id}")}
  end

  @impl true
  def handle_event("search-local", %{"search" => %{"q" => query}}, socket) do
    catalog = Artworks.catalog(query)

    {:noreply,
     socket
     |> assign(
       search_form: to_form(%{"q" => query}, as: :search),
       catalog_query: query,
       catalog_page: catalog.page,
       catalog_count: catalog.count,
       catalog_previous_page: catalog.previous_page,
       catalog_next_page: catalog.next_page
     )
     |> stream(:artworks, catalog.items, reset: true)}
  end

  def handle_event("catalog-page", %{"page" => page}, socket) do
    page = parse_page(page)
    catalog = Artworks.catalog(socket.assigns.catalog_query, page: page)

    {:noreply,
     socket
     |> assign(
       catalog_page: catalog.page,
       catalog_count: catalog.count,
       catalog_previous_page: catalog.previous_page,
       catalog_next_page: catalog.next_page
     )
     |> stream(:artworks, catalog.items, reset: true)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <.container class="py-10">
        <header class="max-w-3xl">
          <.eyebrow>the collection</.eyebrow>
          <.heading>Artworks, connected by identity</.heading>
          <.text class="mt-3">
            Search the works already held in Dictionary. Each title and creator opens the same
            reusable identity used by meanings, evidence, and review—not a copied search result.
          </.text>
        </header>

        <.form
          for={@search_form}
          id="artwork-search"
          phx-change="search-local"
          class="mt-8 max-w-xl"
        >
          <.input
            field={@search_form[:q]}
            type="search"
            label="Search saved artworks or creators"
            placeholder="Goya, The Third of May…"
            phx-debounce="250"
          />
        </.form>

        <section id="artwork-catalog" class="mt-8 max-w-3xl">
          <p id="artwork-result-count" class="mb-3 text-sm/6 text-mist-500">
            {@catalog_count} saved {if @catalog_count == 1, do: "artwork", else: "artworks"}
          </p>
          <div id="artwork-results" phx-update="stream">
            <p id="artwork-results-empty" class="hidden only:block py-8 text-mist-500">
              No saved artwork matches that search.
            </p>
            <Artwork.card
              :for={{dom_id, artwork} <- @streams.artworks}
              id={dom_id}
              artwork={artwork}
              connect={@contributor}
            />
          </div>
          <nav
            :if={@catalog_previous_page || @catalog_next_page}
            id="artwork-pagination"
            aria-label="Artwork catalog pages"
            class="mt-6 flex items-center justify-between border-t border-mist-950/10 pt-4 text-sm/6 dark:border-white/10"
          >
            <button
              id="artwork-previous-page"
              type="button"
              phx-click="catalog-page"
              phx-value-page={@catalog_previous_page}
              disabled={!@catalog_previous_page}
              class="underline underline-offset-4 disabled:invisible"
            >
              Previous
            </button>
            <span class="text-mist-500">Page {@catalog_page}</span>
            <button
              id="artwork-next-page"
              type="button"
              phx-click="catalog-page"
              phx-value-page={@catalog_next_page}
              disabled={!@catalog_next_page}
              class="underline underline-offset-4 disabled:invisible"
            >
              Next
            </button>
          </nav>
        </section>
      </.container>
    </Layouts.app>
    """
  end

  defp parse_page(value) when is_integer(value) and value > 0, do: value

  defp parse_page(value) when is_binary(value) do
    case Integer.parse(value) do
      {page, ""} when page > 0 -> page
      _ -> 1
    end
  end

  defp parse_page(_), do: 1
end
