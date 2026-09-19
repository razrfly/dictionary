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

  `column` is how wide that card is on the rail. It is here rather than in the
  shelf markup because the right width is a property of what the card holds: a
  poster frame sets its own width and the title sits under it, but a text card
  is *only* a title, and a 96 px poster column clipped “Ode in Memory of the
  American Volunteers Fallen for France” to two lines of a title that wanted
  seven. Measured on `/define/war` at 375 px (#109 Phase 3b).

  Two keys every row carries because a many-source shelf needs them as data
  rather than as a rule a reviewer remembers (#116 M4, M6):

    * `attribution` — what the card owes the item's maker, read by the
      renderer. `:required`: every item carries a credit and the card shows it
      beneath the thumbnail, always visible, standing in for the creator line
      (a required credit names the creator by construction; hiding it behind
      a hover is the mistake the sister project made). `:credited`: the card
      shows a credit line when the item carries one, beside the creator line.
      `:none`: the shelf byline is the whole credit and the card shows no line.
      The line is `preview_metadata["attribution"]` when present,
      `"credit_line"` otherwise.
    * `evidence` — the classes of match reason a row admits, from
      `DevilsDictionary.Discovery.MatchReason.evidence/1`: `:identity` (an
      identifier the encyclopedia already asserts), `:attestation` (the work
      uses the word, at a locator) or `:query` (a text search's own ranking,
      allowed only where M6 says so and always labelled as such). Conformance
      asserts every result's reasons against it; the renderer reads it to
      label an admitted `:query` reason as the search result it is.
  """

  @table %{
    film: %{
      heading: "Films",
      label: "film",
      badge: "Film",
      aspect: "aspect-[2/3]",
      icon: "hero-film",
      column: "w-24 sm:w-28",
      title_clamp: "line-clamp-2",
      thumbnail_keys: ~w(poster_url still_url image_url media_url),
      # A poster reaches us through CineGraph, which credits TMDb on its side;
      # nothing per item is owed, and the shelf byline names the source.
      attribution: :none,
      evidence: [:identity]
    },
    artwork: %{
      heading: "Artworks",
      label: "artwork",
      badge: "Artwork",
      aspect: "aspect-square",
      icon: "hero-photo",
      column: "w-24 sm:w-28",
      title_clamp: "line-clamp-2",
      thumbnail_keys: ~w(image_url thumbnail_url),
      # The Met is CC0, so nothing is required — but a credit line is what a
      # museum asks for and what the manifests record, so it is shown when
      # the item carries one.
      attribution: :credited,
      evidence: [:identity]
    },
    # A photograph of a soldier is a visual work but it is not an artwork, and a
    # shelf headed *Artworks* over a US Army photograph is the page misnaming
    # what it shows. Wikimedia Commons (#109 Phase 3a) is the first provider
    # whose files are mostly photographs, and this row is the whole of the
    # change it needed in shared code.
    #
    # Headed *Images*, not *Photos* (#116 M4 said *Photos*; settled in Phase 1):
    # the first and identity-bearing source on this shelf is Commons, whose
    # `image/*` files are photographs but also scanned engravings, maps,
    # posters and diagrams, and a shelf headed *Photos* over a 1916 recruiting
    # poster would be the same misnaming this row was added to end. The atom
    # is `:image`; the heading says what the atom says. Square, not 4:3: the
    # aspect a source's thumbnail ladder can fill is Phase 0's measurement,
    # and 3a measured square at 375 px.
    image: %{
      heading: "Images",
      label: "images",
      badge: "Image",
      aspect: "aspect-square",
      icon: "hero-camera",
      column: "w-24 sm:w-28",
      title_clamp: "line-clamp-2",
      thumbnail_keys: ~w(thumbnail_url image_url),
      # Every file on this shelf is shown under its own licence, and a CC
      # licence's one condition is the credit. Required, and never on hover.
      attribution: :required,
      # Commons matches on a `P180` depicts QID; a stock-photo search is text
      # and says so (M6). The only row that admits a search result.
      evidence: [:identity, :query]
    },
    gif: %{
      heading: "GIFs",
      label: "GIFs",
      badge: nil,
      aspect: "aspect-square",
      icon: "hero-photo",
      column: "w-24 sm:w-28",
      title_clamp: "line-clamp-2",
      thumbnail_keys: ~w(media_url image_url),
      # GIPHY's terms want the *Powered by GIPHY* mark on the shelf, not a
      # line per item; the shelf is still its own component (K10).
      attribution: :none,
      evidence: [:query]
    },
    text: %{
      heading: "Texts",
      label: "text",
      badge: "Text",
      aspect: nil,
      icon: "hero-document-text",
      # No poster frame to set the width, and a title that has to carry the card
      # on its own. Two of these fit a 375 px rail with the third showing that
      # the rail scrolls.
      column: "w-44 sm:w-52",
      title_clamp: "line-clamp-3",
      thumbnail_keys: [],
      # A text card is a title and its author; there is no image to owe a
      # credit for, and the source link reaches the work.
      attribution: :none,
      # A text is never *about* the word; it uses it (K11). A text shelf that
      # admitted a bare search result would be the results page this is not.
      evidence: [:attestation]
    }
  }

  @attributions [:required, :credited, :none]
  @evidence [:identity, :attestation, :query]

  # Every row registers every key, checked at compile time: the reader reads
  # `attribution` and `evidence` off whichever row it is handed, and a row
  # missing one would be a `KeyError` on the first page to show that type.
  @row_keys ~w(heading label badge aspect icon column title_clamp thumbnail_keys attribution evidence)a

  for {type, row} <- @table do
    if Enum.sort(Map.keys(row)) != Enum.sort(@row_keys) do
      raise "content type #{inspect(type)} registers #{inspect(Enum.sort(Map.keys(row)))}, " <>
              "not #{inspect(Enum.sort(@row_keys))}"
    end

    if row.attribution not in @attributions do
      raise "content type #{inspect(type)} declares attribution #{inspect(row.attribution)}"
    end

    if row.evidence == [] or Enum.any?(row.evidence, &(&1 not in @evidence)) do
      raise "content type #{inspect(type)} declares evidence #{inspect(row.evidence)}"
    end
  end

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

  @doc "The rail column width for a content type."
  def column(type), do: type |> get() |> Map.fetch!(:column)

  @doc "How many lines this content type's card gives its title."
  def title_clamp(type), do: type |> get() |> Map.fetch!(:title_clamp)

  @doc "What a card of this content type owes the item's maker: `:required`, `:credited` or `:none`."
  def attribution(type), do: type |> get() |> Map.fetch!(:attribution)

  @doc "The evidence classes a content type admits, from `MatchReason.evidence/1`."
  def evidence(type), do: type |> get() |> Map.fetch!(:evidence)

  @doc """
  True when this content type admits a reason of that evidence class.

  Takes a `MatchReason` or the class itself. The conformance suite asks it of
  every result a provider delivers; the renderer asks it to tell an admitted
  search result from a provider that simply named no reason.
  """
  def admits?(type, %DevilsDictionary.Discovery.MatchReason{} = reason),
    do: admits?(type, DevilsDictionary.Discovery.MatchReason.evidence(reason))

  def admits?(type, class) when class in @evidence, do: class in evidence(type)

  @doc "Reads a preview thumbnail using this content type's key ladder."
  def thumbnail_url(type, metadata) when is_map(metadata) do
    type
    |> get()
    |> Map.fetch!(:thumbnail_keys)
    |> Enum.find_value(&metadata[&1])
  end
end
