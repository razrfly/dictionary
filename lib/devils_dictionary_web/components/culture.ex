defmodule DevilsDictionaryWeb.Culture do
  @moduledoc "Compact, provider-neutral shelf for automatic cultural discovery."
  use DevilsDictionaryWeb, :html

  alias DevilsDictionary.Discovery.ContentTypes

  attr :states, :map, required: true
  attr :return_path, :string, default: nil

  def section(assigns) do
    assigns =
      assign(
        assigns,
        :provider_states,
        assigns.states |> Map.values() |> Enum.sort_by(& &1.provider)
      )

    ~H"""
    <.compact_section
      :if={@provider_states != []}
      states={@provider_states}
      return_path={@return_path}
    />
    """
  end

  attr :states, :list, required: true
  attr :return_path, :string, default: nil

  defp compact_section(assigns) do
    assigns = assign(assigns, :provider_count, length(assigns.states))

    ~H"""
    <section
      id="in-culture"
      aria-label="Related discoveries"
      class="mt-6 border-y border-mist-950/10 py-5 dark:border-white/10"
    >
      <div :for={state <- @states} id={"culture-provider-#{state.provider}"} class="space-y-3">
        <%= if state.status == :ready do %>
          <div class="flex flex-wrap items-baseline justify-between gap-2">
            <h2
              id={"culture-filter-#{content_type(state)}"}
              class="font-display text-xl text-balance text-mist-950 dark:text-white"
            >
              {content_heading(state)}
            </h2>
            <p class="text-base text-mist-500 sm:text-sm">
              {state.provider_name}{provider_detail(state)}
            </p>
          </div>
          <ul
            role="list"
            tabindex="0"
            aria-label={"#{content_heading(state)} matches; scroll for more"}
            id={status_id("culture-results", state, @provider_count)}
            class="flex snap-x snap-proximity gap-5 overflow-x-auto overscroll-x-contain pb-3 focus-visible:outline-2 focus-visible:outline-offset-2"
          >
            <li
              :for={item <- state.items}
              id={"culture-result-#{item.external_namespace}-#{item.external_id}"}
              class="w-24 shrink-0 snap-start sm:w-28"
            >
              <.culture_thumbnail
                item={item}
                type={content_type(state)}
                return_path={@return_path}
              />
            </li>
          </ul>
          <div class="flex flex-wrap items-baseline justify-between gap-x-6 gap-y-2">
            <.compact_note state={state} />
            <.compact_more state={state} />
          </div>
        <% else %>
          <h2 class="font-display text-xl text-mist-950 dark:text-white">
            In {content_label(state)}
          </h2>
          <p
            id={status_id(status_base(state.status), state, @provider_count)}
            role="status"
            class="text-base text-mist-500 sm:text-sm"
          >
            <%= case state.status do %>
              <% :empty -> %>
                No matching {content_label(state)} for this term yet.
              <% :failed -> %>
                {content_heading(state)} discovery is temporarily unavailable.
              <% status when status in [:deferred, :expired, :withdrawn] -> %>
                {content_heading(state)} discovery will retry when available.
              <% _ -> %>
                Looking for matching {content_label(state)}…
            <% end %>
          </p>
        <% end %>
      </div>
    </section>
    """
  end

  attr :item, :map, required: true
  attr :type, :atom, required: true
  attr :return_path, :string, default: nil

  defp culture_thumbnail(assigns) do
    presentation = ContentTypes.get(assigns.type)

    assigns =
      assigns
      |> assign(:image, ContentTypes.thumbnail_url(assigns.type, assigns.item.preview_metadata))
      |> assign(:entry_path, entry_path(assigns.item, assigns.return_path))
      |> assign(:aspect, presentation.aspect)
      |> assign(:badge, presentation.badge)

    ~H"""
    <div class="group flex min-w-0 flex-col gap-2 rounded-sm">
      <.link
        :if={@entry_path && @aspect}
        navigate={@entry_path}
        id={"culture-entry-image-#{@item.external_id}"}
        aria-label={"Open #{@item.preview_metadata["title"]} in Dictionary"}
        class="rounded-sm focus-visible:outline-2 focus-visible:outline-offset-2"
      >
        <.culture_image item={@item} image={@image} type={@type} />
      </.link>
      <a
        :if={is_nil(@entry_path) && @aspect}
        href={@item.preview_metadata["source_url"]}
        target="_blank"
        rel="noreferrer"
        aria-label={"Open source for #{@item.preview_metadata["title"]}"}
        class="rounded-sm focus-visible:outline-2 focus-visible:outline-offset-2"
      >
        <.culture_image item={@item} image={@image} type={@type} />
      </a>
      <div class="min-w-0 space-y-1">
        <h3 class="line-clamp-2 text-base font-medium text-balance text-mist-950 sm:text-sm dark:text-white">
          <.link
            :if={@entry_path}
            navigate={@entry_path}
            id={"culture-entry-title-#{@item.external_id}"}
            class="rounded-sm group-hover:underline focus-visible:outline-2 focus-visible:outline-offset-2"
          >
            {@item.preview_metadata["title"]}
          </.link>
          <a
            :if={is_nil(@entry_path)}
            href={@item.preview_metadata["source_url"]}
            target="_blank"
            rel="noreferrer"
            class="rounded-sm group-hover:underline focus-visible:outline-2 focus-visible:outline-offset-2"
          >
            {@item.preview_metadata["title"]}
          </a>
        </h3>
        <p class="text-base tabular-nums text-mist-500 sm:text-sm">
          {@item.preview_metadata["year"] || "Year unknown"}
          <span :if={@badge}>· {@badge}</span>
        </p>
        <a
          href={@item.preview_metadata["source_url"]}
          target="_blank"
          rel="noreferrer"
          id={"culture-source-#{@item.external_id}"}
          class="inline-flex rounded-sm text-sm text-mist-500 underline-offset-4 transition-colors hover:text-mist-950 hover:underline focus-visible:outline-2 focus-visible:outline-offset-2 dark:hover:text-white"
        >
          Source ↗
        </a>
      </div>
    </div>
    """
  end

  attr :item, :map, required: true
  attr :image, :string, default: nil
  attr :type, :atom, required: true

  defp culture_image(assigns) do
    presentation = ContentTypes.get(assigns.type)

    assigns =
      assigns
      |> assign(:aspect, presentation.aspect)
      |> assign(:icon, presentation.icon)

    ~H"""
    <div class={[
      "w-full shrink-0 overflow-hidden rounded-sm bg-mist-950/5 transition-transform duration-200 group-hover:-translate-y-0.5 dark:bg-white/5",
      @aspect
    ]}>
      <img
        :if={@image}
        src={@image}
        alt=""
        loading="lazy"
        referrerpolicy="no-referrer"
        class="size-full object-cover"
      />
      <div
        :if={!@image}
        id={"culture-missing-poster-#{@item.external_id}"}
        class="flex size-full items-center justify-center text-mist-400"
      >
        <.icon name={@icon} class="size-5" />
      </div>
    </div>
    """
  end

  defp entry_path(%{object_id: object_id, preview_metadata: metadata}, return_path)
       when is_integer(object_id) do
    slug = DevilsDictionary.Claims.Connection.slugify(metadata["title"])
    query = if return_path, do: %{from: return_path}, else: %{}
    ~p"/entities/#{object_id}/#{slug}?#{query}"
  end

  defp entry_path(_item, _return_path), do: nil

  attr :state, :map, required: true

  defp compact_note(assigns) do
    ~H"""
    <details id={"culture-about-#{@state.provider}"}>
      <summary class="w-fit cursor-pointer text-base text-mist-500 hover:text-mist-700 sm:text-sm dark:text-mist-400">
        Matches for “{@state.term}” · About these results
      </summary>
      <div class="space-y-2 pt-2 text-base text-mist-600 sm:text-sm dark:text-mist-300">
        <p class="text-pretty">
          Search matches from {@state.provider_name}. These are provider results, not curated examples or dictionary interpretations.
        </p>
        <p :if={@state.relevance == "term_unverified"} class="text-pretty">
          Keyword relevance to this particular meaning is unverified.
        </p>
        <ul role="list" class="space-y-1">
          <li :for={item <- @state.items}>
            {item.preview_metadata["title"]}: {match_detail(item.match_details, @state.term)}
          </li>
        </ul>
      </div>
    </details>
    """
  end

  attr :state, :map, required: true

  defp compact_more(assigns) do
    ~H"""
    <button
      :if={@state[:next_cursor]}
      type="button"
      phx-click="discovery_more"
      phx-value-provider={@state.provider}
      disabled={@state[:loading_more] == true}
      class="rounded-sm py-1 text-sm text-mist-600 underline underline-offset-4 hover:text-mist-950 disabled:opacity-50 dark:text-mist-300"
    >{if @state[:loading_more], do: "Loading…", else: "Load more"}</button>
    """
  end

  defp status_id(base, _state, 1), do: base
  defp status_id(base, state, _count), do: "#{base}-#{state.provider}"
  defp status_base(:empty), do: "culture-empty"
  defp status_base(:failed), do: "culture-failed"

  defp status_base(status) when status in [:deferred, :expired, :withdrawn],
    do: "culture-deferred"

  defp status_base(_), do: "culture-loading"

  defp match_detail(details, term) do
    case keyword_names(details) do
      [] -> "The provider returned this result for “#{term}”."
      names -> "Matched #{keyword_label(names)} “#{Enum.join(names, "”, “")}” for this term."
    end
  end

  defp keyword_names(details),
    do:
      details
      |> Map.get("keywords", [])
      |> Enum.map(& &1["name"])
      |> Enum.filter(&(is_binary(&1) and &1 != ""))
      |> Enum.uniq()

  defp keyword_label([_one]), do: "the keyword"
  defp keyword_label(_many), do: "keywords"

  defp content_type(%{content_types: [_ | _] = types}) do
    Enum.find(types, :film, &(&1 in ContentTypes.known()))
  end

  defp content_type(_state), do: :film

  defp content_heading(state),
    do: state |> content_type() |> ContentTypes.fetch!() |> Map.fetch!(:heading)

  defp content_label(state),
    do: state |> content_type() |> ContentTypes.fetch!() |> Map.fetch!(:label)

  defp provider_detail(%{provider_detail: detail}) when is_binary(detail) and detail != "",
    do: " · " <> detail

  defp provider_detail(_state), do: ""
end
