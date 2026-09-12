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
      class="my-5 space-y-3 border-b border-mist-950/10 pb-5 dark:border-white/10"
    >
      <div class="flex items-center justify-between gap-3">
        <h2 class="font-display text-xl">GIFs</h2>
        <a href="https://giphy.com/" target="_blank" rel="noreferrer" aria-label="Powered by GIPHY">
          <img
            src="/images/giphy-powered-by.png"
            alt="Powered by GIPHY"
            width="100"
            class="rounded bg-white"
          />
        </a>
      </div>
      <p data-status role="status" class="text-sm text-mist-500">Looking for GIFs…</p>
      <ul
        data-results
        tabindex="0"
        aria-label="GIF matches; scroll for more"
        class="flex snap-x gap-4 overflow-x-auto pb-2 focus-visible:outline-2"
      >
      </ul>
      <p class="text-sm text-mist-500">
        Search matches, not reviewed interpretations. Select Play to animate.
      </p>
      <button data-more type="button" hidden class="text-sm underline">Load more</button>
    </section>
    """
  end
end
