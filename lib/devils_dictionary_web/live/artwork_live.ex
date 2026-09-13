defmodule DevilsDictionaryWeb.ArtworkLive do
  @moduledoc "Local artwork catalog with an explicitly transient Artsy availability check."

  use DevilsDictionaryWeb, :live_view

  alias DevilsDictionary.Artsy.Client
  alias DevilsDictionary.Artworks
  alias DevilsDictionary.Claims.Contributions
  alias DevilsDictionary.Registry
  alias DevilsDictionaryWeb.Artwork

  on_mount {DevilsDictionaryWeb.UserAuth, :mount_current_scope}

  @impl true
  def mount(_params, _session, socket) do
    client = Client.new()
    available? = Client.available?(client)
    catalog = Artworks.catalog("")

    {:ok,
     socket
     |> assign(
       page_title: "artworks",
       search_form: to_form(%{"q" => ""}, as: :search),
       artsy_form: to_form(%{"q" => ""}, as: :artsy),
       artsy_configured: available?,
       artsy_status: :idle,
       artsy_items: [],
       artsy_query: "",
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

  def handle_event("search-artsy", %{"artsy" => %{"q" => query}}, socket) do
    query = String.trim(query)

    cond do
      not Client.available?(Client.new()) ->
        {:noreply, assign(socket, artsy_status: :disabled, artsy_items: [])}

      query == "" ->
        {:noreply, assign(socket, artsy_status: :idle, artsy_items: [], artsy_query: "")}

      true ->
        # The credential-bearing client exists only inside this server task;
        # it is never retained in LiveView assigns or rendered state.
        config = Application.get_env(:devils_dictionary, :artsy, [])

        client =
          Client.new(
            request_limit: config[:interactive_request_limit] || 30,
            shared_scope: :interactive_search,
            shared_request_limit: config[:interactive_request_limit] || 30,
            shared_request_window_ms: config[:interactive_request_window_ms] || 60_000
          )

        {:noreply,
         socket
         |> assign(
           artsy_form: to_form(%{"q" => query}, as: :artsy),
           artsy_status: :loading,
           artsy_query: query,
           artsy_items: []
         )
         |> start_async(:artsy_search, fn -> Client.search_artworks(client, query, size: 8) end)}
    end
  end

  @impl true
  def handle_async(:artsy_search, {:ok, {:ok, result, _client}}, socket) do
    items = Enum.map(result.items, &decorate_result/1)

    {:noreply,
     assign(socket,
       artsy_status: if(items == [], do: :empty, else: :ready),
       artsy_items: items
     )}
  end

  def handle_async(:artsy_search, {:ok, {:error, failure, _client}}, socket) do
    status =
      if failure.code in ["request_limit", "shared_request_limit"], do: :quota, else: :failed

    {:noreply,
     assign(socket,
       artsy_status: status,
       artsy_items: []
     )}
  end

  def handle_async(:artsy_search, {:exit, _reason}, socket),
    do: {:noreply, assign(socket, artsy_status: :failed, artsy_items: [])}

  defp decorate_result(%{status: :available, artwork: %{"slug" => slug}} = item) do
    Map.put(item, :local, local_artwork(slug))
  end

  defp decorate_result(item), do: Map.put(item, :local, nil)

  defp local_artwork(slug) do
    case Registry.by_external_id("artsy_artwork_slug", slug) do
      nil -> nil
      object_id -> Artworks.get(object_id)
    end
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

        <section
          id="artsy-lookup"
          class="mt-12 max-w-3xl border-y border-mist-950/10 py-8 dark:border-white/10"
        >
          <.eyebrow>source availability check</.eyebrow>
          <.subheading class="mt-2">Look in Artsy without adding a claim</.subheading>
          <.text class="mt-2">
            This bounded server-side lookup is temporary discovery. A result is neither a saved
            Dictionary work nor evidence for a meaning. Unavailable records are shown honestly.
          </.text>

          <.form
            for={@artsy_form}
            id="artsy-search"
            phx-submit="search-artsy"
            class="mt-5 flex max-w-xl items-end gap-3"
          >
            <div class="min-w-0 flex-1">
              <.input
                field={@artsy_form[:q]}
                type="search"
                label="Check Artsy"
                placeholder="The Third of May"
                disabled={!@artsy_configured}
              />
            </div>
            <.button
              id="artsy-search-submit"
              type="submit"
              disabled={!@artsy_configured || @artsy_status == :loading}
            >
              {if @artsy_status == :loading, do: "Checking…", else: "Check source"}
            </.button>
          </.form>

          <p :if={!@artsy_configured} id="artsy-disabled" class="mt-4 text-sm/6 text-mist-500">
            Artsy is not configured on this server. The saved local collection remains available.
          </p>
          <p
            :if={@artsy_status in [:failed, :quota]}
            id="artsy-failed"
            class="mt-4 text-sm/6 text-mist-500"
          >
            {if @artsy_status == :quota,
              do: "This lookup reached its request bound.",
              else: "Artsy is temporarily unavailable."}
          </p>
          <p :if={@artsy_status == :empty} id="artsy-empty" class="mt-4 text-sm/6 text-mist-500">
            No artwork results were returned for “{@artsy_query}”.
          </p>

          <ul
            :if={@artsy_status == :ready}
            id="artsy-results"
            role="list"
            class="mt-6 divide-y divide-mist-950/10 dark:divide-white/10"
          >
            <li
              :for={{item, index} <- Enum.with_index(@artsy_items)}
              id={"artsy-result-#{index}"}
              class="py-4"
            >
              <%= if item.local do %>
                <.link
                  navigate={
                    ~p"/entities/#{item.local.object_id}/#{DevilsDictionary.Claims.Connection.slugify(item.local.title)}"
                  }
                  class="font-medium underline underline-offset-4"
                >
                  {item.local.title}
                </.link>
                <p class="mt-1 text-sm/6 text-mist-500">Already saved · exact P11005 match</p>
              <% else %>
                <div class="grid grid-cols-[3.5rem_minmax(0,1fr)] gap-3">
                  <div class="aspect-[4/5] overflow-hidden rounded-sm bg-mist-950/5 dark:bg-white/5">
                    <img
                      :if={item.search["thumbnail_url"]}
                      src={item.search["thumbnail_url"]}
                      alt=""
                      referrerpolicy="no-referrer"
                      class="size-full object-cover"
                    />
                  </div>
                  <div class="min-w-0">
                    <p class="font-medium">{item.search["title"] || "Untitled result"}</p>
                    <p class="mt-1 text-sm/6 text-mist-500">{artsy_result_label(item.status)}</p>
                    <a
                      :if={item.search["permalink"]}
                      href={item.search["permalink"]}
                      target="_blank"
                      rel="noreferrer"
                      class="mt-1 inline-flex text-sm/6 underline underline-offset-4"
                    >Open source ↗</a>
                  </div>
                </div>
              <% end %>
            </li>
          </ul>
        </section>
      </.container>
    </Layouts.app>
    """
  end

  defp artsy_result_label(:available),
    do: "Available at source · not saved and not a meaning claim"

  defp artsy_result_label(:unavailable), do: "Search hit, but the artwork endpoint is unavailable"
  defp artsy_result_label(:unsupported_type), do: "Unsupported non-artwork result"
  defp artsy_result_label(:invalid_endpoint), do: "Ignored unsafe provider endpoint"
  defp artsy_result_label(_), do: "Source lookup failed for this result"

  defp parse_page(value) when is_integer(value) and value > 0, do: value

  defp parse_page(value) when is_binary(value) do
    case Integer.parse(value) do
      {page, ""} when page > 0 -> page
      _ -> 1
    end
  end

  defp parse_page(_), do: 1
end
