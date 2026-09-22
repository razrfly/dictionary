defmodule DevilsDictionaryWeb.CrowdCard do
  @moduledoc """
  The 📱 *Crowd* card whose body the reader's own browser fills (#136).

  A real `Word.source_card` and this one are the same card as far as the page
  is concerned — same badge, same tier class, same solid left border — and the
  difference is only where the words come from. Not `Demo.sample_badge`'s
  dashed border: this is not a sample. There is nothing invented here; there is
  simply nothing here *yet*, for the length of one `fetch`.

  What the shell may carry is fixed by what the server knows, which is the term
  and the endpoint and no more. The definition, the author, the date, the
  permalink and the plaque's `N` all arrive in `assets/js/urban_dictionary.mjs`,
  and if any of them does not arrive the hook removes this element from the
  document. So the `<noscript>`-equivalent state of this card is *absent*, and
  the status line below exists for the fraction of a second between the two.

  `phx-update="ignore"` for the same reason the definitions slab has it: what
  the hook wrote is DOM state the server does not model, and a LiveView patch
  that re-rendered the shell would wipe the card mid-read.
  """

  use DevilsDictionaryWeb, :html

  attr :config, :map, required: true, doc: "UrbanDictionary.browser_config/1; never nil"

  def urban_dictionary(assigns) do
    ~H"""
    <section
      id={"urban-dictionary-#{Base.url_encode64(@config.term, padding: false)}"}
      phx-hook="UrbanDictionary"
      phx-update="ignore"
      data-term={@config.term}
      data-endpoint={@config.endpoint}
      data-define-path="/define"
      aria-label="Urban Dictionary, fetched by your browser"
      class="mt-6 rounded-xl border-l-2 border-mist-950/10 py-6 pl-6 dark:border-white/10"
    >
      <header class="flex flex-wrap items-baseline justify-between gap-x-4 gap-y-1">
        <h2 class={[
          "flex items-center gap-2 text-base/8 font-medium",
          tier_class(@config.source.tier)
        ]}>
          <DevilsDictionaryWeb.SourceBadge.badge source={@config.source} decorative />
          {@config.source.name}
        </h2>
        <span class="flex items-baseline gap-3">
          <DevilsDictionaryWeb.Word.link_out
            id="urban-dictionary-out"
            href={"https://www.urbandictionary.com/define.php?term=#{URI.encode_www_form(@config.term)}"}
            label="Urban Dictionary"
          />
        </span>
      </header>

      <div data-body class="min-w-0">
        <p data-status role="status" class="mt-4 text-base text-mist-500 sm:text-sm">
          Asking Urban Dictionary…
        </p>
      </div>

      <%!-- Always visible, and written by the server rather than the hook, so
           the sentence that says what this card is cannot go missing because a
           script did. The hook replaces it with the same sentence plus the
           entry count, the author and the date once it has them. --%>
      <p data-plaque class="mt-4 text-sm text-mist-500">
        Crowd-sourced and unreviewed. Fetched by your browser; nothing is stored here.
      </p>
    </section>
    """
  end
end
