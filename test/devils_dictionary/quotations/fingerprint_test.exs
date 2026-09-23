defmodule DevilsDictionary.Quotations.FingerprintTest do
  use ExUnit.Case, async: true

  alias DevilsDictionary.Quotations.Fingerprint

  doctest Fingerprint, import: true

  test "the #158 fixture's line, punctuated three ways, is one fingerprint" do
    variants = [
      "We must cultivate our garden.",
      "we must cultivate our garden",
      "“We must cultivate our garden…”",
      "WE MUST CULTIVATE  OUR GARDEN!"
    ]

    assert variants |> Enum.map(&Fingerprint.fingerprint/1) |> Enum.uniq() |> length() == 1
  end

  test "different words are different fingerprints: no stemming, no paraphrase" do
    assert Fingerprint.fingerprint("cultivate our garden") !=
             Fingerprint.fingerprint("cultivate one's garden")

    assert Fingerprint.fingerprint("We must cultivate our garden.") !=
             Fingerprint.fingerprint("Let us cultivate our garden.")

    assert Fingerprint.fingerprint("gardens") != Fingerprint.fingerprint("garden")
  end

  test "a translation is a different line" do
    assert Fingerprint.fingerprint("Il faut cultiver notre jardin.") !=
             Fingerprint.fingerprint("We must cultivate our garden.")
  end
end
