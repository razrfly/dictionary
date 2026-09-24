defmodule DevilsDictionaryWeb.Quotation do
  @moduledoc """
  The quotation-first card, drawn the same way wherever a line is shown
  (#158): the words first, then who said them and where, then who holds
  the line and how far it is trusted.

  Two surfaces draw it. `DevilsDictionaryWeb.Culture` puts it on the Quotes
  shelf for a discovery result (build 4), where the words link out to the
  source, the caption is the author line an `authored_by` earned or the
  citation the provider wrote, and the footer is the licence credit and the
  evidence link. `DevilsDictionaryWeb.Word` puts it under a sense for the
  quotations Wiktionary filed there (build 1), where nothing links and the
  caption is the `ref` verbatim. What the two share is here; what differs
  arrives in the slots, so neither copies the other and a change to how a
  quotation looks is made once.

  Two badges, and they are not the same thing (#152 for the first):

    * a **source badge** per source that holds the line — after build 3's
      fold that can be more than one, and each is the row's own mark;
    * a **provenance badge** — *Plausible*, *Disputed* or *Apocryphal* — that
      says how far the line is trusted, tinted by the answer and never by
      who supplied it. Absent when the caller has no answer at all.
  """

  use DevilsDictionaryWeb, :html

  alias DevilsDictionaryWeb.SourceBadge

  attr :id, :string, required: true
  attr :text, :string, required: true, doc: "the line, as the source gave it"

  attr :href, :string,
    default: nil,
    doc: "where the words link, or nothing — an absolute URL the caller has already vetted"

  attr :text_id, :string,
    default: nil,
    doc:
      "the id on the words themselves, when the caller's convention wants one; `<id>-text` otherwise"

  attr :sources, :list,
    required: true,
    doc:
      "every source holding the line, as `SourceBadge.badge/1` reads one: `slug`, `name`, `tier`, `logo`"

  attr :provenance, :string,
    default: nil,
    doc: "`plausible`, `disputed` or `apocryphal`; nothing when the caller has no answer"

  attr :note, :string, default: nil, doc: "a sentence beneath the badges, the register's verbatim"

  attr :clamp, :string,
    default: nil,
    doc: "a `line-clamp-*` for the words, or nothing to show them whole"

  attr :class, :any, default: nil

  slot :citation, doc: "who said it and where; text or links, the caller decides" do
    attr :class, :any
  end

  slot :footer, doc: "the credit line and any links beside it"

  def card(assigns) do
    assigns = assign_new(assigns, :words_id, fn -> assigns.text_id || "#{assigns.id}-text" end)

    ~H"""
    <figure id={@id} class={["flex min-w-0 flex-col gap-2", @class]}>
      <blockquote class={[
        "text-base/6 text-pretty text-mist-950 sm:text-sm/6 dark:text-white",
        @clamp
      ]}>
        <a
          :if={@href}
          href={@href}
          target="_blank"
          rel="noreferrer"
          id={@words_id}
          class="rounded-sm hover:underline focus-visible:outline-2 focus-visible:outline-offset-2"
        >“{@text}”</a>
        <span :if={is_nil(@href)} id={@words_id}>“{@text}”</span>
      </blockquote>
      <figcaption
        :for={citation <- @citation}
        class={["text-sm/5 text-pretty text-mist-500", citation[:class]]}
      >
        {render_slot(citation)}
      </figcaption>
      <div class="flex flex-wrap items-center gap-x-2 gap-y-1">
        <span
          :for={source <- @sources}
          id={"#{@id}-source-#{source.slug}"}
          class="inline-flex items-center gap-1 text-xs text-mist-500"
          title={source.name}
        >
          <SourceBadge.badge source={source} decorative />
          <span class="sr-only">{source.name}</span>
        </span>
        <span
          :if={@provenance}
          id={"#{@id}-provenance"}
          title={@note}
          class={[
            "inline-flex rounded-full px-2 py-0.5 text-xs",
            @provenance == "plausible" &&
              "bg-mist-950/5 text-mist-700 dark:bg-white/10 dark:text-mist-300",
            @provenance == "disputed" &&
              "bg-amber-100 text-amber-900 dark:bg-amber-400/20 dark:text-amber-100",
            @provenance == "apocryphal" &&
              "bg-rose-100 text-rose-900 dark:bg-rose-400/20 dark:text-rose-100"
          ]}
        >
          {label(@provenance)}
        </span>
      </div>
      <p :if={@note} id={"#{@id}-note"} class="line-clamp-2 text-xs text-pretty text-mist-500">
        {@note}
      </p>
      <p :for={footer <- @footer} class="flex flex-wrap gap-x-2 text-xs text-mist-500">
        {render_slot(footer)}
      </p>
    </figure>
    """
  end

  @doc "The badge's word for a provenance value."
  def label("plausible"), do: "Plausible"
  def label("disputed"), do: "Disputed"
  def label("apocryphal"), do: "Apocryphal"
  def label(other), do: other
end
