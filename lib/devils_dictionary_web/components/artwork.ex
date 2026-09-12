defmodule DevilsDictionaryWeb.Artwork do
  @moduledoc "Reusable, identity-addressed artwork entries and meaning candidates."

  use DevilsDictionaryWeb, :html

  alias DevilsDictionary.Claims.Connection

  attr :artwork, :map, required: true
  attr :candidate, :map, default: nil
  attr :connect, :boolean, default: false
  attr :id, :string, required: true

  def card(assigns) do
    ~H"""
    <article
      id={@id}
      class="group grid grid-cols-[4.5rem_minmax(0,1fr)] gap-4 border-t border-mist-950/10 py-5 first:border-t-0 dark:border-white/10 sm:grid-cols-[6rem_minmax(0,1fr)]"
    >
      <.link
        navigate={entity_path(@artwork)}
        class="aspect-[4/5] overflow-hidden rounded-sm bg-mist-950/5 transition-transform duration-200 group-hover:-translate-y-0.5 dark:bg-white/5"
        aria-label={"Open #{@artwork.title}"}
      >
        <img
          :if={@artwork.image_url}
          src={@artwork.image_url}
          alt=""
          loading="lazy"
          referrerpolicy="no-referrer"
          class="size-full object-cover"
        />
        <span
          :if={!@artwork.image_url}
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
        <p
          :if={@artwork.description}
          class="mt-2 line-clamp-2 text-sm/6 text-mist-600 dark:text-mist-300"
        >
          {@artwork.description}
        </p>

        <div :if={@candidate} class="mt-3 text-sm/6">
          <p id={"#{@id}-meaning"} class="text-mist-700 dark:text-mist-200">
            Candidate for “{@candidate.meaning}”
            <span class="text-mist-500">({@candidate.language})</span>
          </p>
          <p class="text-mist-500">
            Direct Artsy gene “{@candidate.match_reason.gene_name}” · not yet reviewed
          </p>
        </div>

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
