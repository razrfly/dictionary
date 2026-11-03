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
  # The project's own records of Gutenberg #972, pinned by
  # priv/replay/MANIFEST.json; Sources.ManifestTest already needs it on disk.
  @bierce_replay Path.expand("../../../../priv/replay/bierce.jsonl.gz", __DIR__)
  @dossiers [{"hitchens", "v1"}, {"bierce", "v1"}]

  @top ~w(slug template_version dossier source_refs deceased_evidence_refs)
  @dossier ~w(disclosure selection principles blind_spots positive_example negative_example)
  @source ~w(url work edition locators rights basis passages)
  @passage ~w(locator speaker text)
  @deceased ~w(url authority field value)

  # Short quotation only, for a work still in copyright: per passage, and in
  # all from one work.
  @max_quoted_words 25
  @max_quoted_words_per_work 50

  defp read!(path), do: path |> File.read!() |> Jason.decode!()

  defp dossiers do
    for {slug, version} <- @dossiers do
      {slug, read!(Path.join([@personas, slug, version, "profile.json"]))}
    end
  end

  defp keys(map), do: map |> Map.keys() |> Enum.sort()

  defp present?(value), do: is_binary(value) and String.trim(value) != ""

  defp dossier!(slug), do: dossiers() |> List.keyfind!(slug, 0) |> elem(1)

  defp word_count(text), do: text |> String.split() |> length()

  defp squish(text), do: text |> String.split() |> Enum.join(" ")

  # {headword, pos marker} => the text of each record's first fragment.
  defp bierce_entries do
    @bierce_replay
    |> File.read!()
    |> :zlib.gunzip()
    |> String.split("\n", trim: true)
    |> Enum.map(&Jason.decode!/1)
    |> Enum.group_by(
      &{&1["raw"]["headword"], &1["raw"]["pos"]},
      &(&1["raw"]["html"] |> hd() |> Floki.parse_fragment!() |> Floki.text() |> squish())
    )
  end

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

      assert d["disclosure"] =~ "An AI selection lens inspired by "
      assert d["disclosure"] =~ "not his voice"
      # #300 §4: the lead rule sets the lead. The clause has to hold for a
      # single-editor comparison arm, whose v7 instruction still has the model
      # choose the lead by that rule (#298 C4, C9), and for a panel seat, which
      # never votes it. So the lens may not claim it cannot choose a lead.
      assert d["selection"] =~ ~r/The lead is set by the lead rule[^:]*, not by this lens:/

      assert d["selection"] =~
               "apply the lens to highlights only, and as a panel seat never vote the lead."

      assert d["selection"] =~ "The lens cannot change lead policy"
      refute d["selection"] =~ ~r/cannot choose|is never voted|Judge highlights only/
      assert d["selection"] =~ "Abstain when no supplied evidence fits."
      # The same budget the Voltaire persona test holds its compiled instruction to.
      assert byte_size(d["disclosure"] <> "\n" <> d["selection"]) < 1800
    end

    assert Enum.any?(
             dossier!("bierce")["dossier"]["blind_spots"],
             &(&1 =~ "Bierce-first lead rule")
           )
  end

  test "a passage kept as a documented prejudice is flagged and never becomes part of the lens" do
    flagged =
      for {slug, body} <- dossiers(),
          source <- body["source_refs"],
          passage <- source["passages"],
          passage["speaker"] =~ "period prejudice" do
        d = body["dossier"]
        [headword | _] = String.split(passage["locator"], ",")
        label = "#{slug}: #{headword}"

        assert passage["speaker"] =~ "no part of the lens", label
        assert source["basis"] =~ "#{headword} is quoted only as a documented period prejudice"
        assert Enum.any?(d["blind_spots"], &(&1 =~ headword)), label

        lens = [d["selection"], d["positive_example"], d["negative_example"] | d["principles"]]
        refute Enum.any?(lens, &(&1 =~ headword)), label
        {slug, headword}
      end

    assert flagged == [{"bierce", "INDISCRETION"}]
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

        words = Enum.map(source["passages"], &word_count(&1["text"]))
        assert Enum.all?(words, &(&1 <= @max_quoted_words)), label
        assert Enum.sum(words) <= @max_quoted_words_per_work, label

        # The rights note states the total, and the total is what is quoted.
        assert [_, stated] = Regex.run(~r/\((\d+) words/, source["rights"]), label
        assert String.to_integer(stated) == Enum.sum(words), label
      end
    end

    refute Enum.any?(
             dossier!("hitchens")["source_refs"],
             &String.starts_with?(&1["rights"], "Public domain")
           )
  end

  # The Hitchens passages come from web pages (Slate through an Internet Archive
  # capture, and Vanity Fair) and cannot be checked offline. They were checked
  # against the pages their source_refs name on 3 November 2026 (#302). Bierce's
  # can be: each must follow its own headword in the project's Gutenberg records.
  test "every Bierce passage is the exact text of its entry in the project's Gutenberg records" do
    entries = bierce_entries()

    for source <- dossier!("bierce")["source_refs"], passage <- source["passages"] do
      [headword, rest] = String.split(passage["locator"], ", ", parts: 2)
      pos = rest |> String.split(",", parts: 2) |> hd() |> String.trim_trailing(".")
      texts = Map.get(entries, {headword, pos}, [])

      assert Enum.any?(
               texts,
               &String.starts_with?(&1, "#{headword}, #{pos}. #{passage["text"]}")
             ),
             passage["locator"]
    end
  end

  test "deceased-status evidence comes from an authority record" do
    for {slug, body} <- dossiers() do
      refs = body["deceased_evidence_refs"]

      for ref <- refs do
        assert String.starts_with?(ref["url"], "https://"), slug
        assert Enum.all?(~w(authority field value), &present?(ref[&1])), slug
      end

      assert Enum.any?(refs, &(&1["url"] =~ "id.loc.gov/authorities/names/")), slug

      # The identifier named in `authority` is the one the URL resolves.
      for ref <- refs do
        id = ref["url"] |> URI.parse() |> Map.fetch!(:path) |> Path.basename()

        cond do
          ref["url"] =~ "id.loc.gov/authorities/names/" ->
            assert id =~ ~r/^n[a-z]?\d+$/, slug
            assert ref["authority"] =~ Regex.compile!("LCCN #{id}\\b"), slug

          ref["url"] =~ "www.wikidata.org/wiki/" ->
            assert id =~ ~r/^Q\d+$/, slug
            assert ref["authority"] =~ Regex.compile!("Wikidata item #{id}\\b"), slug

          true ->
            flunk("#{slug}: unexpected authority #{ref["url"]}")
        end
      end
    end
  end
end
