defmodule DevilsDictionaryWeb.GiphyShelf do
  use DevilsDictionaryWeb, :html

  attr :config, :map, required: true

  def section(assigns) do
    ~H"""
    <section
      id={"giphy-#{Base.url_encode64(@config.term, padding: false)}"}
      phx-hook="GiphyShelf"
      phx-update="ignore"
      data-query={@config.term}
      data-language={@config.language}
      data-api-key={@config.api_key}
      aria-label="GIF discoveries"
      class="flex gap-4 py-4"
    >
      <div class="w-20 shrink-0 pt-1">
        <h3 class="text-base/6 font-medium text-mist-950 sm:text-sm/6 dark:text-white">GIFs</h3>
        <a
          href="https://giphy.com/"
          target="_blank"
          rel="noreferrer"
          aria-label="Powered by GIPHY"
          class="mt-1 block"
        >
          <img
            src="/images/giphy-powered-by.png"
            alt="Powered by GIPHY"
            width="80"
            class="rounded bg-white"
          />
        </a>
      </div>
      <div class="min-w-0 flex-1 space-y-2">
        <p data-status role="status" class="text-base text-mist-500 sm:text-sm">Looking for GIFs…</p>
        <ul
          data-results
          tabindex="0"
          aria-label="GIF matches; scroll for more"
          class="flex gap-4 overflow-x-auto overscroll-x-contain pb-2 focus-visible:outline-2 focus-visible:outline-offset-2"
        >
        </ul>
        <p class="flex flex-wrap items-baseline justify-between gap-x-6 text-base text-mist-500 sm:text-sm">
          <span>Search matches, not reviewed interpretations. Hover, focus or press Play to animate.</span>
          <button
            data-more
            type="button"
            hidden
            class="text-mist-600 underline underline-offset-4 hover:text-mist-950 dark:text-mist-300 dark:hover:text-white"
          >Load more</button>
        </p>
      </div>
    </section>
    """
  end
end
