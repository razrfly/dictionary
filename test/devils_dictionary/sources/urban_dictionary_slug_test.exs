defmodule DevilsDictionary.Sources.UrbanDictionarySlugTest do
  @moduledoc """
  The Elixir half of the slug agreement (#136).

  An Urban Dictionary definition links its `[bracketed]` words to **our**
  `/define/<slug>`, and the slug is minted in the reader's browser by
  `assets/js/urban_dictionary.mjs`. That is a second implementation of
  `Lexeme.slug/1`, which is the kind of thing that agrees on the day it is
  written and quietly stops agreeing later.

  So both implementations are asserted against one file — `assets/js/slug_cases.json`
  — and neither test knows the expected values, it reads them. A change to the
  Elixir rule that the JS does not follow fails here; the reverse fails in
  `node --test assets/js/urban_dictionary.test.mjs`.
  """

  use ExUnit.Case, async: true

  alias DevilsDictionary.Registry.Lexeme

  @cases_path "assets/js/slug_cases.json"

  defp cases do
    @cases_path
    |> File.read!()
    |> Jason.decode!()
    |> Map.fetch!("cases")
  end

  test "Lexeme.slug/1 maps every shared case the way the JS rule must" do
    for %{"from" => from, "to" => to} <- cases() do
      assert Lexeme.slug(from) == to, "Lexeme.slug(#{inspect(from)}) is not #{inspect(to)}"
    end
  end

  test "the shared list still covers the range the card actually meets" do
    list = cases()

    assert length(list) >= 30,
           "the case list is the only thing holding the two slug rules together; do not shrink it"

    froms = Enum.map(list, & &1["from"])

    # One of each kind the bracket syntax puts in front of the rule: a phrase,
    # an accent, an apostrophe, punctuation that separates, punctuation that is
    # dropped entirely, and a lemma with no slug at all.
    for probe <- ["Sexual intercourse", "café", "don't", "W.T.F.", "C++", "++"] do
      assert probe in froms, "the shared case list lost its #{inspect(probe)} case"
    end
  end
end
