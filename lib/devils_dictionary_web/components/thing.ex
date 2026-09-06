defmodule DevilsDictionaryWeb.Thing do
  @moduledoc """
  The other half of the page (#71 §2.4, U1b): the **thing** a word names.

  Words and things are different tables, so they are different modules. What
  arrives here is `%WordPage{}.thing`, already resolved, walked and capped by
  `Lexicon.WordPage` — the same contract `DevilsDictionaryWeb.Word` works to,
  and for the same reason.

  This is the only place Wikidata appears on a word page. It is not a source
  badge and never enters `lexemes.source_ids`: it attests the thing, so it
  shows up as the concept's `Q… ↗` and nowhere else (the S4 audit's rule).
  """

  use DevilsDictionaryWeb, :html

  alias DevilsDictionaryWeb.Word

  @doc """
  The thing panel. The disagreement comes first, because a word whose sources
  name two different things qualifies everything under it.
  """
  attr :thing, :map, required: true
  attr :trail, :list, default: []

  def thing_panel(assigns) do
    ~H"""
    <section id="thing" class="mt-10 border-t border-mist-950/10 pt-8 dark:border-white/10">
      <.eyebrow>the thing</.eyebrow>

      <.disagreement :if={@thing.disagreement != []} concepts={@thing.disagreement} />
      <.concept_card :if={@thing.concept} concept={@thing.concept} thing={@thing} />
      <.thing_chain :if={@thing.chain != []} chain={@thing.chain} trail={@trail} />

      <.thing_chips id="thing-kinds" label="kinds" chips={@thing.kinds} trail={@trail} />
      <.thing_chips id="thing-examples" label="examples" chips={@thing.examples} trail={@trail} />

      <.may_refer_to :if={@thing.may_refer_to != []} concepts={@thing.may_refer_to} />
    </section>
    """
  end

  @doc "Label, description, picture and the two ways out — Wikipedia and Wikidata."
  attr :concept, :map, required: true
  attr :thing, :map, required: true

  def concept_card(assigns) do
    ~H"""
    <div
      id="concept-card"
      class="mt-4 flex flex-col gap-4 rounded-xl bg-mist-950/2.5 p-4 sm:flex-row dark:bg-white/5"
    >
      <figure :if={@concept.image_url} class="shrink-0 sm:w-48">
        <img
          src={@concept.image_url}
          alt={@concept.label}
          loading="lazy"
          class="w-full rounded-lg object-cover"
        />
        <figcaption :if={@concept.image_attribution} class="mt-1 text-xs/5 text-mist-500">
          {@concept.image_attribution}
        </figcaption>
      </figure>

      <div class="min-w-0">
        <h2 class="font-display text-2xl/8 text-mist-950 dark:text-white">{@concept.label}</h2>
        <p :if={@concept.description} class="mt-1 text-sm/7 text-mist-700 dark:text-mist-400">
          {@concept.description}
        </p>
        <p
          :if={@concept.taxon["scientific_name"]}
          id="concept-card-scientific-name"
          class="mt-1 text-sm/7 text-mist-500 italic"
        >
          {@concept.taxon["scientific_name"]}
        </p>

        <p class="mt-3 flex flex-wrap items-center gap-x-4 text-sm/7">
          <.link
            :if={@thing.wikipedia_url}
            id="concept-card-wikipedia"
            href={@thing.wikipedia_url}
            target="_blank"
            rel="noopener"
            class="text-mist-500 hover:text-mist-950 hover:underline dark:hover:text-white"
          >
            Wikipedia <span aria-hidden="true">↗</span>
          </.link>
          <.link
            :if={@thing.wikidata_url}
            id="concept-card-wikidata"
            href={@thing.wikidata_url}
            target="_blank"
            rel="noopener"
            class="text-mist-500 hover:text-mist-950 hover:underline dark:hover:text-white"
          >
            {@concept.qid} <span aria-hidden="true">↗</span>
          </.link>
        </p>
      </div>
    </div>
    """
  end

  @doc """
  The walk upward — *Bivalvia › Mollusca › protostome*. A step that has a word
  is a hop; a step that does not is still printed, because the gap is part of
  the chain.
  """
  attr :chain, :list, required: true
  attr :trail, :list, default: []

  def thing_chain(assigns) do
    ~H"""
    <p id="thing-chain" class="mt-4 flex flex-wrap items-center gap-x-2 text-sm/7">
      <span class="text-mist-500">a kind of</span>
      <span :for={{step, i} <- Enum.with_index(@chain)} class="flex items-center gap-x-2">
        <span :if={i > 0} aria-hidden="true" class="text-mist-400">›</span>
        <.link
          :if={step.slug}
          id={"thing-chain-#{step.slug}"}
          navigate={Word.hop(step.slug, @trail)}
          class={[
            "hover:underline",
            step.enriched? && "text-mist-950 dark:text-white",
            not step.enriched? && "text-mist-500"
          ]}
        >
          {step.lemma}
        </.link>
        <span :if={is_nil(step.slug)} class="text-mist-400">{step.label}</span>
      </span>
    </p>
    """
  end

  @doc """
  The things under this one that have a word — its kinds, its examples — capped
  with the exact count of the rest. Only worded children are here: a chip that
  cannot be clicked is furniture.
  """
  attr :id, :string, required: true
  attr :label, :string, required: true
  attr :chips, :map, required: true
  attr :trail, :list, default: []

  def thing_chips(assigns) do
    ~H"""
    <div
      :if={@chips.shown != []}
      id={@id}
      class="mt-3 flex flex-wrap items-baseline gap-x-2 gap-y-1"
    >
      <span class="w-20 shrink-0 text-sm/7 text-mist-500">{@label}</span>
      <.link
        :for={chip <- @chips.shown}
        id={"#{@id}-#{chip.slug}"}
        navigate={Word.hop(chip.slug, @trail)}
        title={"#{@label} · #{chip.label}"}
        class={[
          "rounded-full px-3 py-0.5 text-sm/6",
          chip.enriched? &&
            "bg-mist-950/5 font-medium text-mist-950 hover:bg-mist-950/10 dark:bg-white/10 dark:text-white dark:hover:bg-white/15",
          not chip.enriched? &&
            "bg-mist-950/2.5 text-mist-500 hover:bg-mist-950/5 dark:bg-white/5 dark:hover:bg-white/10"
        ]}
      >
        {chip.lemma}
      </.link>
      <span :if={@chips.total > length(@chips.shown)} class="text-sm/7 text-mist-500">
        +{@chips.total - length(@chips.shown)}
      </span>
    </div>
    """
  end

  @doc """
  The 0.40 links a disambiguation page suggested and nothing has corroborated.
  A possibility, not a claim — which is why it is a list and not a card.
  """
  attr :concepts, :list, required: true

  def may_refer_to(assigns) do
    ~H"""
    <div id="may-refer-to" class="mt-6">
      <p class="text-sm/7 text-mist-500">may also refer to</p>
      <ul class="mt-1 space-y-1 text-sm/7 text-mist-700 dark:text-mist-400">
        <li :for={concept <- @concepts} id={"may-refer-to-#{concept.qid}"}>
          <span class="text-mist-950 dark:text-white">{concept.label}</span>
          <span :if={concept.description} class="text-mist-500">— {concept.description}</span>
        </li>
      </ul>
    </div>
    """
  end

  @doc """
  Two sources, two different things, both asserted. #69 says disagreement is
  content: it is shown with the method and the confidence that put it there,
  and nothing here picks a winner.
  """
  attr :concepts, :list, required: true

  def disagreement(assigns) do
    ~H"""
    <div
      id="disagreement"
      class="mt-4 rounded-xl border border-mist-950/10 p-4 text-sm/7 dark:border-white/15"
    >
      <p class="text-mist-500">the sources name more than one thing</p>
      <ul class="mt-1 space-y-1">
        <li :for={concept <- @concepts} id={"disagreement-#{concept.qid}"}>
          <span class="text-mist-950 dark:text-white">{concept.label}</span>
          <span :if={concept.description} class="text-mist-700 dark:text-mist-400">
            — {concept.description}
          </span>
          <span class="text-mist-500">
            ({concept.qid} · {concept.method} · {concept.confidence})
          </span>
        </li>
      </ul>
    </div>
    """
  end
end
