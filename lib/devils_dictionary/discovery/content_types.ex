defmodule DevilsDictionary.Discovery.ContentTypes do
  @moduledoc """
  What a content type looks like on a shelf. Data, not code.

  A provider declares `content_types` in its capabilities; the reader asks this
  table how to present them. Adding a content type is an entry here, not a new
  branch in `DevilsDictionaryWeb.Culture` or `WordLive`, which is the whole
  point: the shared code stops knowing which providers exist.

  `thumbnail_keys` is the ordered ladder read from a result's preview metadata.
  A type with no `aspect` has no image slot at all, so a text result renders as
  a title and its source rather than an empty poster frame.
  """

  @table %{
    film: %{
      heading: "Films",
      label: "film",
      badge: "Film",
      aspect: "aspect-[2/3]",
      icon: "hero-film",
      thumbnail_keys: ~w(poster_url still_url image_url media_url)
    },
    artwork: %{
      heading: "Artworks",
      label: "artwork",
      badge: "Artwork",
      aspect: "aspect-square",
      icon: "hero-photo",
      thumbnail_keys: ~w(image_url thumbnail_url)
    },
    # A photograph of a soldier is a visual work but it is not an artwork, and a
    # shelf headed *Artworks* over a US Army photograph is the page misnaming
    # what it shows. Wikimedia Commons (#109 Phase 3a) is the first provider
    # whose files are mostly photographs, and this row is the whole of the
    # change it needed in shared code.
    image: %{
      heading: "Images",
      label: "images",
      badge: "Image",
      aspect: "aspect-square",
      icon: "hero-camera",
      thumbnail_keys: ~w(thumbnail_url image_url)
    },
    gif: %{
      heading: "GIFs",
      label: "GIFs",
      badge: nil,
      aspect: "aspect-square",
      icon: "hero-photo",
      thumbnail_keys: ~w(media_url image_url)
    },
    text: %{
      heading: "Texts",
      label: "text",
      badge: "Text",
      aspect: nil,
      icon: "hero-document-text",
      thumbnail_keys: []
    }
  }

  # Shelf order (K2 of #109), not insertion order: a page shows films, then
  # artworks, then images, then texts, then GIFs.
  @known [:film, :artwork, :image, :text, :gif]

  @doc "Every content type the reader can present, in shelf order."
  def known, do: @known

  @doc "True when at least one of `types` can be presented."
  def any_known?(types), do: Enum.any?(types, &(&1 in @known))

  @doc "The presentation entry for a known content type."
  def fetch!(type) when is_map_key(@table, type), do: Map.fetch!(@table, type)

  @doc "The presentation entry, or the entry for `default` when the type is unknown."
  def get(type, default \\ :film)

  def get(type, _default) when is_map_key(@table, type), do: Map.fetch!(@table, type)
  def get(_type, default), do: fetch!(default)

  @doc "Reads a preview thumbnail using this content type's key ladder."
  def thumbnail_url(type, metadata) when is_map(metadata) do
    type
    |> get()
    |> Map.fetch!(:thumbnail_keys)
    |> Enum.find_value(&metadata[&1])
  end
end
