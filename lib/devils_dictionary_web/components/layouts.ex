defmodule DevilsDictionaryWeb.Layouts do
  @moduledoc """
  This module holds layouts and related functionality
  used by your application.
  """
  use DevilsDictionaryWeb, :html

  # Embed all files in layouts/* within this module.
  # The default root.html.heex file contains the HTML
  # skeleton of your application, namely HTML headers
  # and other static content.
  embed_templates "layouts/*"

  @doc """
  Renders your app layout.

  This function is typically invoked from every template,
  and it often contains your application menu, sidebar,
  or similar.

  ## Examples

      <Layouts.app flash={@flash}>
        <h1>Content</h1>
      </Layouts.app>

  """
  attr :flash, :map, required: true, doc: "the map of flash messages"

  attr :current_scope, :map,
    default: nil,
    doc: "the current [scope](https://phoenix.hexdocs.pm/scopes.html)"

  slot :inner_block, required: true

  def app(assigns) do
    ~H"""
    <.navbar>
      <:logo>
        <.link navigate={~p"/"} class="font-display text-2xl/8 text-mist-950 dark:text-white">
          wordhoard
        </.link>
      </:logo>
      <:links>
        <.nav_link navigate={~p"/s/animals"}>Animals</.nav_link>
        <.nav_link navigate={~p"/health"}>Health</.nav_link>
        <.nav_link navigate={~p"/admin/imports"}>Imports</.nav_link>
      </:links>
      <:actions>
        <.theme_toggle />
      </:actions>
    </.navbar>

    <.main>
      {render_slot(@inner_block)}
    </.main>

    <.footer>
      <:links>
        <.footer_category title="Browse">
          <.footer_link navigate={~p"/s/animals"}>Animals</.footer_link>
          <.footer_link navigate={~p"/health"}>Health</.footer_link>
          <.footer_link navigate={~p"/admin/imports"}>Imports</.footer_link>
        </.footer_category>
        <.footer_category title="Sources">
          <.footer_link :for={source <- sources()} navigate={~p"/sources/#{source.slug}"}>
            {source.name}
          </.footer_link>
        </.footer_category>
      </:links>
      <:fineprint>
        <p>
          An aggregator, not an author. Every definition belongs to the source that wrote it and
          links back to it. WordNet CC BY 4.0 · Wiktionary and Wikipedia CC BY-SA 4.0 ·
          Wikidata CC0 · Bierce public domain.
        </p>
      </:fineprint>
    </.footer>

    <.flash_group flash={@flash} />
    """
  end

  # The footer names every source we absorb: the attribution #69 backbone rule 1
  # asks for, and the fastest way to a source page. Five rows, read straight —
  # there is no cache process in the tree and this does not deserve the first.
  defp sources, do: DevilsDictionary.Sources.list_sources()

  @doc """
  Shows the flash group with standard titles and content.

  ## Examples

      <.flash_group flash={@flash} />
  """
  attr :flash, :map, required: true, doc: "the map of flash messages"
  attr :id, :string, default: "flash-group", doc: "the optional id of flash container"

  def flash_group(assigns) do
    ~H"""
    <div id={@id} aria-live="polite">
      <.flash kind={:info} flash={@flash} />
      <.flash kind={:error} flash={@flash} />

      <.flash
        id="client-error"
        kind={:error}
        title={gettext("We can't find the internet")}
        phx-disconnected={
          show(".phx-client-error #client-error")
          |> JS.remove_attribute("hidden", to: ".phx-client-error #client-error")
        }
        phx-connected={hide("#client-error") |> JS.set_attribute({"hidden", ""})}
        hidden
      >
        {gettext("Attempting to reconnect")}
        <.icon name="hero-arrow-path" class="ml-1 size-3 motion-safe:animate-spin" />
      </.flash>

      <.flash
        id="server-error"
        kind={:error}
        title={gettext("Something went wrong!")}
        phx-disconnected={
          show(".phx-server-error #server-error")
          |> JS.remove_attribute("hidden", to: ".phx-server-error #server-error")
        }
        phx-connected={hide("#server-error") |> JS.set_attribute({"hidden", ""})}
        hidden
      >
        {gettext("Attempting to reconnect")}
        <.icon name="hero-arrow-path" class="ml-1 size-3 motion-safe:animate-spin" />
      </.flash>
    </div>
    """
  end

  @doc """
  Provides dark vs light theme toggle based on themes defined in app.css.

  See <head> in root.html.heex which applies the theme before page load.
  """
  def theme_toggle(assigns) do
    ~H"""
    <div class="relative flex flex-row items-center rounded-full bg-mist-950/10 dark:bg-white/10">
      <div class="absolute left-0 h-full w-1/3 rounded-full bg-white transition-[left] [[data-theme=dark]_&]:left-2/3 [[data-theme=light]_&]:left-1/3 [[data-theme-source=system]_&]:!left-0 dark:bg-mist-700" />

      <button
        class="flex w-1/3 cursor-pointer p-2"
        phx-click={JS.dispatch("phx:set-theme")}
        data-phx-theme="system"
      >
        <.icon name="hero-computer-desktop-micro" class="size-4 opacity-75 hover:opacity-100" />
      </button>

      <button
        class="flex w-1/3 cursor-pointer p-2"
        phx-click={JS.dispatch("phx:set-theme")}
        data-phx-theme="light"
      >
        <.icon name="hero-sun-micro" class="size-4 opacity-75 hover:opacity-100" />
      </button>

      <button
        class="flex w-1/3 cursor-pointer p-2"
        phx-click={JS.dispatch("phx:set-theme")}
        data-phx-theme="dark"
      >
        <.icon name="hero-moon-micro" class="size-4 opacity-75 hover:opacity-100" />
      </button>
    </div>
    """
  end
end
