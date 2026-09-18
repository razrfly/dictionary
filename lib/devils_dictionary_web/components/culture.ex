defmodule DevilsDictionaryWeb.Culture do
  @moduledoc """
  The one reader surface for automatic cultural discovery.

  K2 of #109: every result renders here, live or from a corpus, and a shelf is
  keyed by **content type** rather than by provider. A page had three chromes
  for one content type before this — the Met's compact shelf, the tall
  `#artwork-candidates` cards and `/artworks` — and `/define/soldier` showed two
  of them at once. Now the Met's live results and the committed catalog's
  candidates share one *Artworks* shelf, live results first, each item carrying
  the reason it is there.

  A provider ships zero components. What a content type looks like is a row in
  `DevilsDictionary.Discovery.ContentTypes`; why an item matched is a
  `DevilsDictionary.Discovery.MatchReason`; nothing here knows which providers
  exist.
  """
  use DevilsDictionaryWeb, :html

  alias DevilsDictionary.Discovery.ContentTypes
  alias DevilsDictionary.Discovery.MatchReason

  attr :states, :map, required: true
  attr :return_path, :string, default: nil

  attr :contributor, :boolean,
    default: false,
    doc: "whether the reader may carry a corpus candidate into the review composer"

  def section(assigns) do
    states = assigns.states |> Map.values() |> Enum.sort_by(&{archetype_rank(&1), &1.provider})

    assigns =
      assigns
      |> assign(:shelves, shelves(states))
      |> assign(:provider_count, length(states))

    ~H"""
    <.compact_section
      :if={@shelves != []}
      shelves={@shelves}
      provider_count={@provider_count}
      return_path={@return_path}
      contributor={@contributor}
    />
    """
  end

  # One shelf per content type, in the table's order: film · artwork · text ·
  # gif. A provider that declares a type nobody can present is not a shelf.
  defp shelves(states) do
    for type <- ContentTypes.known(),
        group = Enum.filter(states, &(content_type(&1) == type)),
        group != [] do
      %{
        type: type,
        states: group,
        entries:
          Enum.flat_map(group, fn state ->
            Enum.map(state.items, &%{state: state, item: &1})
          end)
      }
    end
  end

  # A corpus candidate sorts after every live result on its shelf. It is the
  # same content type and the same identity rule, but it was not asked for on
  # this visit, and a shelf that opened with the catalog would bury the answer
  # the page actually went and got.
  defp archetype_rank(state), do: if(Map.get(state, :archetype) == :corpus, do: 1, else: 0)

  attr :shelves, :list, required: true
  attr :provider_count, :integer, required: true
  attr :return_path, :string, default: nil
  attr :contributor, :boolean, default: false

  defp compact_section(assigns) do
    assigns = assign(assigns, :shelf_count, length(assigns.shelves))

    ~H"""
    <section
      id="in-culture"
      aria-label="Related discoveries"
      class="mt-6 border-y border-mist-950/10 py-5 dark:border-white/10"
    >
      <div :for={shelf <- @shelves} id={"culture-shelf-#{shelf.type}"} class="space-y-3">
        <%= if shelf.entries != [] do %>
          <div class="flex flex-wrap items-baseline justify-between gap-2">
            <h2
              id={"culture-filter-#{shelf.type}"}
              class="font-display text-xl text-balance text-mist-950 dark:text-white"
            >
              {shelf_heading(shelf.type)}
            </h2>
            <p class="text-base text-mist-500 sm:text-sm">
              <span :for={{state, index} <- Enum.with_index(contributing(shelf))}>
                <span :if={index > 0} aria-hidden="true">·</span>
                <span id={"culture-provider-#{state.provider}"}>
                  {state.provider_name}{provider_detail(state)}
                </span>
              </span>
            </p>
          </div>
          <%!-- No scroll snapping on this rail, deliberately. A shelf's corpus
               items paint on the first, synchronous render and its live results
               are prepended when they arrive; CSS scroll snap re-snaps a
               container to its previously snapped box after a layout change, so
               the rail opened 1,584 px in — past every result the page had just
               gone and fetched. Measured on `/define/soldier`. --%>
          <ul
            role="list"
            tabindex="0"
            aria-label={"#{shelf_heading(shelf.type)} matches; scroll for more"}
            id={shelf_id("culture-results", shelf, @shelf_count)}
            class="flex gap-5 overflow-x-auto overscroll-x-contain pb-3 focus-visible:outline-2 focus-visible:outline-offset-2"
          >
            <li
              :for={entry <- shelf.entries}
              id={"culture-result-#{entry.item.external_namespace}-#{entry.item.external_id}"}
              class={["shrink-0", ContentTypes.column(shelf.type)]}
            >
              <.culture_thumbnail
                item={entry.item}
                type={shelf.type}
                return_path={@return_path}
              />
            </li>
          </ul>
          <%!-- A shelf can be one provider's answer and another's silence. The
               items are not a reason to stop saying that the other is still
               looking, or has failed — but they are a reason to name the
               provider rather than the content type, which is not empty. --%>
          <p
            :for={state <- pending(shelf)}
            id={status_id(status_base(state.status), state, @provider_count)}
            role="status"
            class="text-base text-mist-500 sm:text-sm"
          >
            <%= case state.status do %>
              <% :failed -> %>
                {state.provider_name} is temporarily unavailable.
              <% status when status in [:deferred, :expired, :withdrawn] -> %>
                {state.provider_name} will retry when available.
              <% _ -> %>
                Still looking at {state.provider_name}…
            <% end %>
          </p>
          <div class="flex flex-wrap items-baseline justify-between gap-x-6 gap-y-2">
            <div class="space-y-2">
              <.compact_note
                :for={state <- contributing(shelf)}
                state={state}
                contributor={@contributor}
              />
            </div>
            <.compact_more :for={state <- shelf.states} state={state} />
          </div>
        <% else %>
          <h2 class="font-display text-xl text-mist-950 dark:text-white">
            In {shelf_label(shelf.type)}
          </h2>
          <p
            :for={state <- shelf.states}
            id={status_id(status_base(state.status), state, @provider_count)}
            role="status"
            class="text-base text-mist-500 sm:text-sm"
          >
            <%= case state.status do %>
              <% :empty -> %>
                No matching {shelf_label(shelf.type)} for this term yet.
              <% :failed -> %>
                {shelf_heading(shelf.type)} discovery is temporarily unavailable.
              <% status when status in [:deferred, :expired, :withdrawn] -> %>
                {shelf_heading(shelf.type)} discovery will retry when available.
              <% _ -> %>
                Looking for matching {shelf_label(shelf.type)}…
            <% end %>
          </p>
        <% end %>
      </div>
    </section>
    """
  end

  # A shelf credits the providers that actually put something on it. A provider
  # whose own request failed while another's succeeded is reported in its note,
  # not in a byline for results it did not supply.
  defp contributing(shelf), do: Enum.filter(shelf.states, &(&1.items != []))

  # Worth reporting beside a shelf that is not empty. A provider whose own
  # answer was *nothing* is not: "no matching artwork for this term" under six
  # artworks would be the page contradicting itself.
  defp pending(shelf),
    do: Enum.filter(shelf.states, &(&1.items == [] and &1.status != :empty))

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
        <h3 class={[
          "text-base font-medium text-balance text-mist-950 sm:text-sm dark:text-white",
          ContentTypes.title_clamp(@type)
        ]}>
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
        <%!-- Whoever made it, when the provider or the catalog named them. It
             is a metadata key and not a content type's business: a film's
             director and an artwork's painter arrive under the same one. --%>
        <p
          :if={@item.preview_metadata["artist"]}
          class="line-clamp-2 text-sm text-mist-500 text-pretty"
        >
          {@item.preview_metadata["artist"]}
        </p>
        <a
          :if={@item.preview_metadata["source_url"]}
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
  attr :contributor, :boolean, default: false

  defp compact_note(assigns) do
    ~H"""
    <details id={"culture-about-#{@state.provider}"}>
      <summary class="w-fit cursor-pointer text-base text-mist-500 hover:text-mist-700 sm:text-sm dark:text-mist-400">
        {@state.provider_name} matches for “{@state.term}” · About these results
      </summary>
      <div class="space-y-2 pt-2 text-base text-mist-600 sm:text-sm dark:text-mist-300">
        <p :if={Map.get(@state, :archetype) == :corpus} class="text-pretty">
          Catalog matches from {Map.get(@state, :corpora, @state.provider_name)}, held locally
          rather than searched for on this visit. None is an accepted interpretation: a
          contributor connects an exact meaning and reviewers decide the claim.
          <.link navigate={~p"/artworks"} class="underline underline-offset-4">
            Browse saved artworks
          </.link>
        </p>
        <p :if={Map.get(@state, :archetype) != :corpus} class="text-pretty">
          Search matches from {@state.provider_name}. These are provider results, not curated examples or dictionary interpretations.
        </p>
        <%!-- Not "keyword relevance": one shelf now carries keyword matches,
             tag identities and depicted QIDs, and the caveat is about the page
             resolving to several meanings, not about how a match was made.
             Sense-level relevance is #101's. --%>
        <p :if={@state.relevance == "term_unverified"} class="text-pretty">
          Relevance to this particular meaning is unverified.
        </p>
        <ul role="list" class="space-y-1">
          <li :for={item <- @state.items}>
            {item.preview_metadata["title"]}: {MatchReason.describe_all(reasons(item, @state.term))}{review_note(
              item
            )}
            <.link
              :if={@contributor && connect_path(item)}
              navigate={connect_path(item)}
              id={"culture-connect-#{item.external_id}"}
              class="underline underline-offset-4"
            >
              Connect to a meaning
            </.link>
          </li>
        </ul>
      </div>
    </details>
    """
  end

  # A corpus item arrives with its reasons already built from the manifest and
  # the encyclopedia; a persisted or transient provider result carries the
  # `match_details` its provider wrote. Both end up as the same struct.
  defp reasons(%{match_reasons: reasons}, _term) when is_list(reasons), do: reasons
  defp reasons(item, term), do: MatchReason.from_result(item.match_details, term)

  defp review_note(%{review_state: :not_yet_reviewed}), do: " · not yet reviewed"
  defp review_note(_item), do: ""

  # The composer link a contributor had on the tall candidate cards, kept when
  # they left. Only a corpus candidate has a meaning and an evidence revision to
  # preselect; `/connect` is still gated on the server.
  defp connect_path(%{object_id: object_id, sense_id: sense_id} = item)
       when is_integer(object_id) and is_integer(sense_id) do
    reason = item.match_reasons |> List.first() || %MatchReason{}

    params =
      %{
        subject: object_id,
        object: sense_id,
        predicate: "illustrates",
        evidence_revision: item[:source_record_revision_id],
        evidence_locator: reason.locator,
        rationale: reason.note
      }
      |> Enum.reject(fn {_key, value} -> is_nil(value) end)
      |> Map.new()

    ~p"/connect?#{params}"
  end

  defp connect_path(_item), do: nil

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

  # A status paragraph is one provider's, so it is keyed by provider as it
  # always was; the results list is the shelf's, so it is keyed by content type.
  # Both drop the suffix when there is only one of them on the page.
  defp status_id(base, _state, 1), do: base
  defp status_id(base, state, _count), do: "#{base}-#{state.provider}"

  defp shelf_id(base, _shelf, 1), do: base
  defp shelf_id(base, shelf, _count), do: "#{base}-#{shelf.type}"

  defp status_base(:empty), do: "culture-empty"
  defp status_base(:failed), do: "culture-failed"

  defp status_base(status) when status in [:deferred, :expired, :withdrawn],
    do: "culture-deferred"

  defp status_base(_), do: "culture-loading"

  defp content_type(%{content_types: [_ | _] = types}) do
    Enum.find(types, :film, &(&1 in ContentTypes.known()))
  end

  defp content_type(_state), do: :film

  defp shelf_heading(type), do: type |> ContentTypes.fetch!() |> Map.fetch!(:heading)
  defp shelf_label(type), do: type |> ContentTypes.fetch!() |> Map.fetch!(:label)

  defp provider_detail(%{provider_detail: detail}) when is_binary(detail) and detail != "",
    do: " · " <> detail

  defp provider_detail(_state), do: ""
end
