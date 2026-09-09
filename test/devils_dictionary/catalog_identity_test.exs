defmodule DevilsDictionary.CatalogIdentityTest do
  use ExUnit.Case, async: true

  test "Bierce has the verified identity and no fabricated precise death date" do
    bierce = Enum.find(DevilsDictionary.Sources.Catalog.people(), &(&1.slug == "ambrose-bierce"))
    assert bierce.wikidata_id == "Q191050"
    refute bierce.wikidata_id == "Q310190"
    assert bierce.death_date == nil
  end
end
