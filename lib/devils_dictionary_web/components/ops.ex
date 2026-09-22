defmodule DevilsDictionaryWeb.Ops do
  @moduledoc """
  The bits of chrome the population-scoped operational consoles share (#77 §1,
  §2). `/ops/discovery` is not one of them: a discovery provider answers for
  the whole registry and for no population, so it has nothing to choose.

  `/ops/health` and `/ops/imports` both grade or describe *one* population, and
  neither may pick one on the reader's behalf. Before #77 they defaulted to
  `animals` — so a page nobody had chosen a population for reported the test
  population's numbers, and read as though they were the corpus's.

  The chooser is the alternative to that default: no selection is a state the
  page renders, not a value it invents.
  """
  use DevilsDictionaryWeb, :html

  @doc """
  The population picker: one chip per `scopes` row, linking the page to itself
  with `?scope=<slug>`.

  `path` is a function of a slug, because `/ops/health` and `/ops/imports` are
  different pages asking the same question.
  """
  attr :scopes, :list, required: true
  attr :selected, :string, default: nil
  attr :path, :any, required: true
  attr :class, :string, default: nil

  def population_chooser(assigns) do
    ~H"""
    <div id="population-chooser" class={["flex flex-wrap items-center gap-2", @class]}>
      <span class="text-sm/7 text-mist-500">Population</span>
      <.link
        :for={scope <- @scopes}
        id={"population-#{scope.slug}"}
        patch={@path.(scope.slug)}
        class={[
          "inline-flex items-center rounded-full px-3 py-1 text-sm/7",
          scope.slug == @selected && "bg-mist-950 text-white dark:bg-mist-300 dark:text-mist-950",
          scope.slug != @selected &&
            "bg-mist-950/10 text-mist-950 hover:bg-mist-950/15 dark:bg-white/10 dark:text-white"
        ]}
      >
        {scope.name}
      </.link>
      <span :if={@scopes == []} class="text-sm/7 text-mist-500">
        none yet — <code>mix dd.scope.new</code>
      </span>
    </div>
    """
  end

  @doc """
  What a console shows in place of a population-specific section when nothing is
  selected. Says which question it cannot answer, and why that is not a zero.
  """
  attr :scopes, :list, required: true
  attr :path, :any, required: true
  attr :what, :string, required: true

  def no_population(assigns) do
    ~H"""
    <div id="no-population" class="flex flex-col gap-4">
      <.text class="max-w-2xl text-pretty">
        {@what} is measured over one population at a time, and none is selected.
        There is deliberately no default: the figures used to come back for
        Animals, which made a test population read as the whole corpus.
      </.text>
      <.population_chooser scopes={@scopes} path={@path} />
    </div>
    """
  end
end
