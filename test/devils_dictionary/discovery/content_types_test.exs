defmodule DevilsDictionary.Discovery.ContentTypesTest do
  @moduledoc """
  The content-type table is data the reader renders, so what it is missing is a
  page that renders wrong rather than a compile error.
  """

  use ExUnit.Case, async: true

  alias DevilsDictionary.Discovery.ContentTypes

  test "every known type carries a heading, a column and a title clamp" do
    for type <- ContentTypes.known() do
      entry = ContentTypes.fetch!(type)

      assert is_binary(entry.heading) and entry.heading != ""
      assert is_binary(ContentTypes.column(type))
      assert is_binary(ContentTypes.title_clamp(type))
    end
  end

  test "a text card is wider than a poster card and spends the extra line on its title" do
    # `:text` is the only type with no image slot, which is exactly why it needs
    # its own column: nothing else on the card sets a width. Measured on
    # `/define/war` at 375 px, where the poster column showed two lines of a
    # title that wanted seven (#109 Phase 3b).
    assert ContentTypes.fetch!(:text).aspect == nil
    assert ContentTypes.column(:text) != ContentTypes.column(:film)
    assert ContentTypes.title_clamp(:text) == "line-clamp-3"

    for type <- ContentTypes.known() -- [:text] do
      assert ContentTypes.fetch!(type).aspect
      assert ContentTypes.title_clamp(type) == "line-clamp-2"
    end
  end
end
