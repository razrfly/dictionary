defmodule DevilsDictionary.Routing.AddressTest do
  use ExUnit.Case, async: true

  alias DevilsDictionary.Routing.{Address, Policy}

  doctest Address

  test "stored addresses are the policy's own proposals: C++, C+ and c stay three" do
    built = for label <- ["C++", "C+", "c"], do: Address.build("concepts", Policy.slug(label))

    assert built == [
             {:ok, "/concepts/c-plus-plus"},
             {:ok, "/concepts/c-plus"},
             {:ok, "/concepts/c"}
           ]

    assert Address.build("people", Policy.slug("Чехов")) == {:ok, "/people/чехов"}
    assert Address.build("places", Policy.slug("Kraków")) == {:ok, "/places/kraków"}
    assert Address.build("concepts", "język-polski", "pl") == {:ok, "/l/pl/concepts/język-polski"}
  end

  test "an address outside the registry or not in stored form is refused, not repaired" do
    for {path, reason} <- [
          {"/users/settings", :unknown_namespace},
          {"/define/c", :unknown_namespace},
          {"/entities/voltaire", :unknown_namespace},
          {"/people/Voltaire", :not_normalized},
          {"/places/krako\u0301w", :not_normalized},
          {"/people/a--b", :invalid_segment},
          {"/people/c++", :invalid_segment},
          {"/people/" <> String.duplicate("é", 61), :segment_too_long},
          {"/people", :invalid_shape},
          {"/people/voltaire/extra", :invalid_shape},
          {"/l/en/people/voltaire", :invalid_locale},
          {"people/voltaire", :not_absolute}
        ] do
      assert Address.parse(path) == {:error, reason}, path
    end
  end

  test "a request is decoded once and folded, so each variant names one stored path" do
    assert Address.normalize_request("/people/voltaire") == {:ok, "/people/voltaire", true}

    for variant <- ["/People/Voltaire", "/people/voltaire/", "/PEOPLE/VOLTAIRE/"] do
      assert Address.normalize_request(variant) == {:ok, "/people/voltaire", false}
    end

    exact = Address.encode("/places/kraków")
    assert exact == "/places/krak%C3%B3w"
    assert Address.normalize_request(exact) == {:ok, "/places/kraków", true}
    assert Address.normalize_request(String.downcase(exact)) == {:ok, "/places/kraków", false}

    decomposed = Address.encode("/places/krako\u0301w")
    assert Address.normalize_request(decomposed) == {:ok, "/places/kraków", false}

    # A trailing slash is one byte, even after a prepended letter that would
    # join it into one grapheme (U+0D4E MALAYALAM LETTER DOT REPH).
    assert Address.normalize_request("/people/abc%E0%B5%8E/") ==
             {:ok, "/people/abc\u0D4E", false}

    # Case folds (Polish and polish request one address) but nothing is
    # re-slugified: a raw C++ is not c-plus-plus.
    assert Address.normalize_request("/concepts/Polish") == {:ok, "/concepts/polish", false}
    assert Address.normalize_request("/concepts/c%2B%2B") == {:error, :invalid_segment}
  end

  test "malformed requests are refused before any lookup" do
    for {raw, reason} <- [
          {"/people/%E0%A4%A", :malformed_encoding},
          {"/people/%FF", :invalid_utf8},
          {"/people/a%2Fb", :encoded_separator},
          {"/people/a%5cb", :encoded_separator},
          {"/people/a%00b", :nul},
          {"/people/a" <> <<0>> <> "b", :nul},
          {"/people/../admin", :dot_segment},
          {"/people/%2E%2E", :dot_segment},
          {"/people//voltaire", :empty_segment}
        ] do
      assert Address.normalize_request(raw) == {:error, reason}, inspect(raw)
    end
  end
end
