defmodule DevilsDictionaryWeb.KitLive do
  @moduledoc """
  The theme boilerplate check (#71 §3, session U0).

  Every primitive ported from the Tailwind Plus "Oatmeal" kit, rendered once, so
  the port can be held next to the kit's own demo (`npm run dev` in
  `tmp/oatmeal-mist-instrument/demo`) before any page is built on top of it. The
  composition at the bottom mirrors the kit's `pages/home-01.tsx`: hero, feature
  grid, stats. The navbar and footer are in the layout and frame this page
  already.

  Dev only — the route lives inside the router's `dev_routes` block.
  """
  use DevilsDictionaryWeb, :live_view

  @impl true
  def mount(_params, _session, socket), do: {:ok, assign(socket, page_title: "Kit")}

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <.section id="kit-type" eyebrow="Elements" headline="Type">
        <div class="flex flex-col gap-8">
          <.heading>Every word. Every source. One page.</.heading>
          <.subheading>The institutions, and the aristocracy of the dead</.subheading>
          <.text size="lg">
            Instrument Serif for display, Inter for everything else. Both are loaded from Google
            Fonts in <code>root.html.heex</code>, with a real fallback stack behind each.
          </.text>
          <.text>
            Body copy at the default size, on the mist scale. A dictionary is mostly this.
          </.text>
          <.a navigate={~p"/health"}>An inline link<span aria-hidden="true">→</span></.a>
        </div>
      </.section>

      <.section id="kit-document" eyebrow="Elements" headline="Document">
        <.document>
          <h2>What a source's prose looks like</h2>
          <p>
            <strong>OYSTER</strong>, n. A slimy, gobby shellfish which civilization gives men the
            hardihood to eat without removing its entrails.
          </p>
          <blockquote>
            The shells are sometimes given to the poor.
          </blockquote>
          <ul>
            <li>An unordered list, with the kit's square markers.</li>
            <li>A second item, so the marker colour is visible.</li>
          </ul>
          <ol>
            <li>An ordered list.</li>
            <li>Its second item.</li>
          </ol>
          <p>And <a href="https://www.gutenberg.org/ebooks/972">a link out</a>, underlined.</p>
        </.document>
      </.section>

      <.section id="kit-buttons" eyebrow="Elements" headline="Buttons">
        <div class="flex flex-col gap-6">
          <div class="flex flex-wrap items-center gap-3">
            <.button :for={size <- ~w(md lg)} variant="solid" size={size}>Solid {size}</.button>
            <.button :for={size <- ~w(md lg)} variant="soft" size={size}>Soft {size}</.button>
            <.button :for={size <- ~w(md lg)} variant="plain" size={size}>Plain {size}</.button>
            <.button_link variant="solid" navigate={~p"/"}>As a link</.button_link>
          </div>

          <div class="flex flex-wrap items-center gap-3 rounded-xl bg-mist-950 p-6 dark:bg-mist-900">
            <.button variant="solid" color="light">Solid on dark</.button>
            <.button variant="plain" color="light">Plain on dark</.button>
          </div>
        </div>
      </.section>

      <.section id="kit-stats" eyebrow="Elements" headline="Stats">
        <div class="grid grid-cols-1 gap-2 sm:grid-cols-2 lg:grid-cols-4">
          <.stat value="1,534,818">words indexed</.stat>
          <.stat value="21,277">animals in scope</.stat>
          <.stat value="997">entries by one dead man</.stat>
          <.stat value="5">sources</.stat>
        </div>
      </.section>

      <.section
        id="kit-features"
        eyebrow="Sections"
        headline="Three columns"
        subheadline="The kit's feature grid, which is the shape most of this app's summaries take."
      >
        <div class="grid grid-cols-1 gap-10 sm:grid-cols-2 lg:grid-cols-3">
          <div :for={feature <- features()} class="flex flex-col gap-2">
            <h3 class="text-base/8 font-medium text-mist-950 dark:text-white">{feature.title}</h3>
            <.text>{feature.body}</.text>
          </div>
        </div>
      </.section>

      <.section id="kit-forms" eyebrow="Elements" headline="Form controls">
        <div class="max-w-md">
          <.input type="text" name="q" value="" label="A text input" placeholder="oyster" />
          <.input
            type="select"
            name="sort"
            value="coverage"
            label="A select"
            options={[{"Coverage", "coverage"}, {"Lemma", "lemma"}]}
          />
          <.input type="checkbox" name="bare" value="false" label="A checkbox" />
          <.input type="text" name="bad" value="nope" label="With an error" errors={["is invalid"]} />
        </div>
      </.section>

      <.section id="kit-table" eyebrow="Elements" headline="Table">
        <.table id="kit-table-rows" rows={sources()}>
          <:col :let={source} label="source">{source.name}</:col>
          <:col :let={source} label="tier">{source.tier}</:col>
          <:col :let={source} label="licence">{source.license}</:col>
        </.table>
      </.section>
    </Layouts.app>
    """
  end

  defp features do
    [
      %{
        title: "Absorption first",
        body: "Every source lands as a raw record with the URL it came from, then materializes."
      },
      %{
        title: "Words and things",
        body: "A word links to a thing through concept_links, with a method and a confidence."
      },
      %{
        title: "Scope is data",
        body: "Animals is one row and a filter. The next scope is one task run."
      }
    ]
  end

  defp sources do
    [
      %{name: "Ambrose Bierce", tier: "aristocracy", license: "public domain"},
      %{name: "Open English WordNet", tier: "middle", license: "CC BY 4.0"},
      %{name: "Wiktionary", tier: "middle", license: "CC BY-SA 4.0"}
    ]
  end
end
