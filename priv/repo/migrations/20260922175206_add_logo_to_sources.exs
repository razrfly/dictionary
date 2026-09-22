defmodule DevilsDictionary.Repo.Migrations.AddLogoToSources do
  use Ecto.Migration

  @moduledoc """
  A source's mark, for the badge every card header and the rail's stack draw
  (#152 Phase 4): a path under `priv/static` and never a URL, the same rule
  as a licence mark. Backfilled by slug, because `Discovery.ensure_source/1`
  inserts `on_conflict: :nothing` and a row that exists would otherwise keep
  drawing a monogram until somebody remembered the psql line.
  """

  @logos %{
    "wordnet" => "/images/sources/wordnet.png",
    "wiktionary" => "/images/sources/wiktionary.png",
    "wikidata" => "/images/sources/wikidata.png",
    "wikipedia" => "/images/sources/wikipedia.png",
    "bierce" => "/images/sources/bierce.png",
    "johnson" => "/images/sources/johnson.png",
    "artsy" => "/images/sources/artsy.png",
    "urban-dictionary" => "/images/sources/urban-dictionary.png",
    "cinegraph" => "/images/sources/cinegraph.svg",
    "commons" => "/images/sources/commons.png",
    "bing-news" => "/images/sources/bing-news.svg",
    "giphy" => "/images/sources/giphy.png",
    "guardian" => "/images/sources/guardian.png",
    "met" => "/images/sources/met.png",
    "open-library" => "/images/sources/open-library.png",
    "openverse" => "/images/sources/openverse.svg",
    "pexels" => "/images/sources/pexels.png",
    "spotify" => "/images/sources/spotify.svg",
    "unsplash" => "/images/sources/unsplash.png"
  }

  def up do
    alter table(:sources) do
      add :logo, :string
    end

    flush()

    for {slug, path} <- @logos do
      execute("UPDATE sources SET logo = '#{path}' WHERE slug = '#{slug}' AND logo IS NULL")
    end
  end

  def down do
    alter table(:sources) do
      remove :logo
    end
  end
end
