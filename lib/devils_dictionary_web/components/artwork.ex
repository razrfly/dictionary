defmodule DevilsDictionaryWeb.Artwork do
  @moduledoc """
  Reusable, identity-addressed artwork entries for the `/artworks` browse page.

  It used to carry a meaning candidate too, with a relation word and a match
  sentence of its own — the second of the three artwork chromes K2 of #109
  retired. A candidate is now a shelf item in `DevilsDictionaryWeb.Culture`, and
  its reason is a `DevilsDictionary.Discovery.MatchReason`. This is the browse
  card and nothing else.
  """

  use DevilsDictionaryWeb, :html

  alias DevilsDictionary.Claims.Connection

  attr :artwork, :map, required: true
  attr :connect, :boolean, default: false
  attr :id, :string, required: true

  def card(assigns) do
    ~H"""
    <article
      id={@id}
      class="group grid grid-cols-[4.5rem_minmax(0,1fr)] gap-4 border-t border-mist-950/10 py-5 first:border-t-0 dark:border-white/10 sm:grid-cols-[6rem_minmax(0,1fr)]"
    >
      <.link
        id={"#{@id}-image"}
        navigate={entity_path(@artwork)}
        phx-hook="ArtworkImage"
        phx-update="ignore"
        data-image-state={if(@artwork.image_url, do: "loading", else: "empty")}
        class="aspect-[4/5] overflow-hidden rounded-sm bg-mist-950/5 transition-transform duration-200 group-hover:-translate-y-0.5 dark:bg-white/5"
        aria-label={"Open #{@artwork.title}"}
      >
        <img
          :if={@artwork.image_url}
          src={@artwork.image_url}
          alt=""
          loading="lazy"
          referrerpolicy="no-referrer"
          data-artwork-image
          class="size-full object-cover"
        />
        <span
          data-artwork-fallback
          hidden={!!@artwork.image_url}
          class="flex size-full items-center justify-center text-mist-400"
        >
          <.icon name="hero-photo" class="size-6 stroke-current" />
        </span>
      </.link>

      <div class="min-w-0">
        <.link
          navigate={entity_path(@artwork)}
          class="font-display text-xl text-balance text-mist-950 underline-offset-4 group-hover:underline dark:text-white"
        >
          {@artwork.title}
        </.link>
        <p :if={@artwork.creators != []} class="mt-1 text-sm/6 text-mist-500">
          by
          <span :for={{creator, index} <- Enum.with_index(@artwork.creators)}>
            <span :if={index > 0}>, </span><.link
              navigate={creator_path(creator)}
              class="hover:underline"
            >{creator.label}</.link>
          </span>
        </p>
        <%!-- A catalog row names its artist without carrying a local identity
             for them, so the name is shown as text rather than as a dead link. --%>
        <p
          :if={@artwork.creators == [] && Map.get(@artwork, :artist)}
          class="mt-1 text-sm/6 text-mist-500"
        >
          by {@artwork.artist}
        </p>
        <p
          :if={@artwork.description}
          class="mt-2 line-clamp-2 text-sm/6 text-mist-600 dark:text-mist-300"
        >
          {@artwork.description}
        </p>
        <dl
          :if={@artwork.date || @artwork.medium || @artwork.collection}
          class="mt-2 flex flex-wrap gap-x-2 text-sm/6 text-mist-500"
        >
          <div :if={@artwork.date} class="contents">
            <dt class="sr-only">Date</dt><dd>{@artwork.date}</dd>
          </div>
          <div :if={@artwork.medium} class="contents">
            <dt class="sr-only">Medium</dt><dd>· {@artwork.medium}</dd>
          </div>
          <div :if={@artwork.collection} class="contents">
            <dt class="sr-only">Collection</dt><dd>· {@artwork.collection}</dd>
          </div>
        </dl>
        <p :if={@artwork.image_attribution} class="mt-1 text-xs/5 text-mist-400">
          Image: {@artwork.image_attribution}
        </p>

        <div class="mt-3 flex flex-wrap gap-x-4 gap-y-2 text-sm/6">
          <.link navigate={entity_path(@artwork)} class="font-medium underline underline-offset-4">Open work</.link>
          <.link
            :if={@connect}
            navigate={~p"/connect?subject=#{@artwork.object_id}"}
            class="font-medium underline underline-offset-4"
          >
            Connect to a meaning
          </.link>
          <a
            :if={@artwork.artsy && @artwork.artsy["permalink"]}
            href={@artwork.artsy["permalink"]}
            target="_blank"
            rel="noreferrer"
            class="text-mist-500 underline underline-offset-4 hover:text-mist-950 dark:hover:text-white"
          >Artsy source ↗</a>
        </div>
      </div>
    </article>
    """
  end

  defp entity_path(artwork),
    do: ~p"/entities/#{artwork.object_id}/#{Connection.slugify(artwork.title)}"

  defp creator_path(creator),
    do: ~p"/entities/#{creator.object_id}/#{Connection.slugify(creator.label)}"
end
