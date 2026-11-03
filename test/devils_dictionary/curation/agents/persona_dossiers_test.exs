defmodule DevilsDictionary.Curation.Agents.PersonaDossiersTest do
  @moduledoc """
  Fixture-only checks on the #300 L2 dossiers (Hitchens and Bierce). They are
  reviewed data files: nothing here loads them into `Agents.Persona`, admits
  a profile version or binds a seat. The shape is the newest Voltaire
  manifest's, `voltaire/v8/profile.json`, key for key.
  """
  use ExUnit.Case, async: true

  alias DevilsDictionary.Curation.Profiles

  @personas Path.expand("../../../../priv/curation/agents/personas", __DIR__)
  @reference Path.join(@personas, "voltaire/v8/profile.json")
  @dossiers [{"hitchens", "v1"}, {"bierce", "v1"}]

  @top ~w(slug template_version dossier source_refs deceased_evidence_refs)
  @dossier ~w(disclosure selection principles blind_spots positive_example negative_example)
  @source ~w(url work edition locators rights basis passages)
  @passage ~w(locator speaker text)
  @deceased ~w(url authority field value)

  # Short quotation only, for a work still in copyright.
  @max_quoted_words 25

  defp read!(path), do: path |> File.read!() |> Jason.decode!()

  defp dossiers do
    for {slug, version} <- @dossiers do
      {slug, read!(Path.join([@personas, slug, version, "profile.json"]))}
    end
  end

  defp keys(map), do: map |> Map.keys() |> Enum.sort()

  defp present?(value), do: is_binary(value) and String.trim(value) != ""

  test "the reference Voltaire v8 manifest still has the shape the dossiers copy" do
    ref = read!(@reference)
    assert keys(ref) == Enum.sort(@top)
    assert keys(ref["dossier"]) == Enum.sort(@dossier)
    assert Enum.all?(ref["source_refs"], &(keys(&1) == Enum.sort(@source)))

    assert Enum.all?(ref["source_refs"], fn s ->
             Enum.all?(s["passages"], &(keys(&1) == Enum.sort(@passage)))
           end)

    assert Enum.all?(ref["deceased_evidence_refs"], &(keys(&1) == Enum.sort(@deceased)))
  end

  test "each dossier parses and carries exactly the reference keys at every level" do
    for {slug, body} <- dossiers() do
      assert keys(body) == Enum.sort(@top), slug
      assert keys(body["dossier"]) == Enum.sort(@dossier), slug
      assert [_ | _] = body["source_refs"]
      assert [_ | _] = body["deceased_evidence_refs"]

      for source <- body["source_refs"] do
        assert keys(source) == Enum.sort(@source), "#{slug}: #{source["work"]}"
        assert Enum.all?(source["passages"], &(keys(&1) == Enum.sort(@passage)))
      end

      assert Enum.all?(body["deceased_evidence_refs"], &(keys(&1) == Enum.sort(@deceased)))
    end
  end

  test "slug, directory and template version agree with a proposed profile" do
    for {slug, body} <- dossiers() do
      assert body["slug"] == slug
      assert slug in Profiles.proposed_slugs()
      assert body["template_version"] == "#{slug}-whole-entry-v1"
    end
  end

  test "the dossier text is complete, and a seat judges highlights only" do
    for {slug, body} <- dossiers() do
      d = body["dossier"]

      for key <- ~w(disclosure selection positive_example negative_example),
          do: assert(present?(d[key]), "#{slug}: #{key}")

      for key <- ~w(principles blind_spots) do
        assert [_ | _] = d[key]
        assert Enum.all?(d[key], &present?/1), "#{slug}: #{key}"
      end

      assert d["disclosure"] =~ "not his voice"
      assert d["selection"] =~ "Judge highlights only"
      # #300 §4: the lead comes from the lead rule; personas never vote it.
      assert d["selection"] =~ ~r/cannot choose or vote the lead|lead rule and is never voted/
      assert d["selection"] =~ "Abstain when no supplied evidence fits."
      # The same budget the Voltaire persona test holds its compiled instruction to.
      assert byte_size(d["disclosure"] <> "\n" <> d["selection"]) < 1800
    end

    {_, bierce} = Enum.find(dossiers(), &(elem(&1, 0) == "bierce"))
    assert Enum.any?(bierce["dossier"]["blind_spots"], &(&1 =~ "Bierce-first lead rule"))
  end

  test "every source names its work, edition, locators and rights, with attributed passages" do
    for {slug, body} <- dossiers(), source <- body["source_refs"] do
      label = "#{slug}: #{source["work"]}"

      for key <- ~w(work edition rights basis), do: assert(present?(source[key]), label)
      assert String.starts_with?(source["url"], "https://"), label
      assert [_ | _] = source["locators"]
      assert Enum.all?(source["locators"], &present?/1), label
      assert [_ | _] = source["passages"]

      for passage <- source["passages"] do
        assert present?(passage["text"]), label
        assert present?(passage["locator"]), label
        assert present?(passage["speaker"]), label
      end
    end
  end

  test "a work in copyright is quoted briefly and says so; public domain is declared" do
    for {slug, body} <- dossiers(), source <- body["source_refs"] do
      label = "#{slug}: #{source["work"]}"

      if String.starts_with?(source["rights"], "Public domain") do
        assert source["rights"] =~ "check jurisdiction", label
      else
        assert source["rights"] =~ "In copyright", label
        assert source["rights"] =~ "fair use", label

        for passage <- source["passages"] do
          words = passage["text"] |> String.split() |> length()
          assert words <= @max_quoted_words, "#{label}: #{passage["locator"]}"
        end
      end
    end

    {_, hitchens} = Enum.find(dossiers(), &(elem(&1, 0) == "hitchens"))
    refute Enum.any?(hitchens["source_refs"], &String.starts_with?(&1["rights"], "Public domain"))
  end

  test "deceased-status evidence comes from an authority record" do
    for {slug, body} <- dossiers() do
      refs = body["deceased_evidence_refs"]

      for ref <- refs do
        assert String.starts_with?(ref["url"], "https://"), slug
        assert Enum.all?(~w(authority field value), &present?(ref[&1])), slug
      end

      assert Enum.any?(refs, &(&1["url"] =~ "id.loc.gov/authorities/names/")), slug
    end
  end
end
