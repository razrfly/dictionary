defmodule DevilsDictionary.Sources.OnDemand do
  @moduledoc """
  The third source registry: definitions fetched by the reader, never held.

  `Sources.Catalog.sources/0` is *what we absorb from* and A1 grades every row
  in it for a finished absorb. `:discovery_providers` is *what fills a culture
  shelf* and conformance grades every row in it for a presentable content type.
  Urban Dictionary (#136) is neither: it is a definition, it arrives in the
  reader's browser, and no server-side process will ever ask for it. Putting it
  in either of the other two would turn a green row red for a reason that is
  about bookkeeping rather than about the app.

  So this list is the home for **on-demand definition sources**, and its whole
  contract is three functions:

      source_attrs/0    the `sources` row, as data
      enabled?/0        the environment switch
      browser_config/1  what the hook needs, or nil for no shell at all

  ## Adding a second one

  Write the module beside `DevilsDictionary.Sources.UrbanDictionary`, add it to
  `@sources` below, give it a `config :devils_dictionary, :<slug>` stanza with
  an `enabled` key and a `runtime.exs` switch, and write its card component and
  hook the way `DevilsDictionaryWeb.CrowdCard` and `assets/js/urban_dictionary.mjs`
  are written. `seed!/0` then writes its row wherever the catalog is seeded.
  What it must *not* grow is a `retrieve/4`: the moment a server fetches it, it
  is a discovery provider or an absorb adapter and belongs in the registry that
  grades it.
  """

  alias DevilsDictionary.Repo
  alias DevilsDictionary.Sources
  alias DevilsDictionary.Sources.Source

  @sources [DevilsDictionary.Sources.UrbanDictionary]

  @doc "Every registered on-demand definition source."
  def all, do: @sources

  @doc """
  Their `sources` rows, as data.

  Deliberately *not* folded into `Catalog.sources/0`: see the moduledoc, and
  `demo_test.exs`, which unions the two so a demo sample still cannot
  impersonate one of these.
  """
  def source_catalog, do: Enum.map(@sources, & &1.source_attrs())

  @doc """
  Writes the rows, idempotently, with the providers' upsert.

  `on_conflict: :nothing` on the slug: an existing row keeps whatever the owner
  set on it, which is the point — `active: false` is a kill switch a re-seed
  must not undo.
  """
  def seed! do
    Map.new(all(), fn module ->
      attrs = module.source_attrs()

      %Source{}
      |> Source.changeset(attrs)
      |> Repo.insert(on_conflict: :nothing, conflict_target: [:slug])

      {attrs.slug, Sources.get_source_by_slug(attrs.slug)}
    end)
  end
end
