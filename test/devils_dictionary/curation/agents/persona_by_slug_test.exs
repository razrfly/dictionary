defmodule DevilsDictionary.Curation.Agents.PersonaBySlugTest do
  @moduledoc """
  #298 C4, the seam only: a persona manifest is read by slug and version
  from `priv/curation/agents/personas/<slug>/v<n>/profile.json`. Every
  reviewed Voltaire version is the compiled one, so its hashes and the
  instructions built from it are unchanged. No dossier content is written
  here.
  """
  use ExUnit.Case, async: true

  alias DevilsDictionary.Curation.Agents.Persona
  alias DevilsDictionary.Curation.Digest
  alias DevilsDictionary.Curation.Runtime.Packet

  @moduletag :tmp_dir

  defp write!(root, slug, version, manifest) do
    path = Persona.path(slug, version, root: root)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, if(is_binary(manifest), do: manifest, else: Jason.encode!(manifest)))
    path
  end

  defp fixture(slug) do
    %{
      "slug" => slug,
      "template_version" => "#{slug}-whole-entry-v1",
      "dossier" => %{"disclosure" => "A fixture lens.", "selection" => "Prefer fixtures."},
      "source_refs" => [],
      "deceased_evidence_refs" => []
    }
  end

  test "every Voltaire version reads by slug, byte for byte the committed file" do
    for n <- 1..8 do
      {:ok, compiled} = Persona.manifest("voltaire", n)
      on_disk = Persona.path("voltaire", n) |> File.read!() |> Jason.decode!()
      assert compiled == on_disk
      assert compiled["slug"] == "voltaire"
    end

    assert Persona.manifest() == Persona.manifest!("voltaire", 1)
    assert Persona.versions("voltaire") == Enum.to_list(1..8)
  end

  test "the instructions built from Voltaire's lens keep their hashes" do
    assert Persona.selection_instruction("voltaire-whole-entry-v7") ==
             "voltaire" |> Persona.manifest!(5) |> Persona.lens()

    assert Digest.sha256(Packet.instruction!("voltaire-whole-entry-v7")) ==
             "a3219a5c496dbbfc6d731d87138191293a7f8243f4080f8b2067f27d5d8e853c"

    assert Digest.sha256(Packet.instruction!("voltaire-whole-entry-v6")) ==
             "e037baf1f599d321ea35ba740bb0d5deaf3bbfb880ec47ce6c33bdfb96e67212"

    assert Persona.body(Persona.manifest!("voltaire", 8))["template_version"] ==
             "voltaire-whole-entry-v7"
  end

  test "another persona reads by slug and version from its own directory", %{tmp_dir: root} do
    write!(root, "fixture-lens", 1, fixture("fixture-lens"))
    write!(root, "fixture-lens", 3, fixture("fixture-lens"))
    File.mkdir_p!(Path.join([root, "fixture-lens", "v2"]))

    assert {:ok, manifest} = Persona.manifest("fixture-lens", 1, root: root)
    assert Persona.lens(manifest) == "A fixture lens.\nPrefer fixtures."
    assert Persona.versions("fixture-lens", root: root) == [1, 3]

    assert Packet.grounded_with_lens(Persona.lens(manifest)) ==
             Packet.grounded_policy() <>
               "\nPersonality is a tie-breaker AFTER evidence, meaning and usefulness. Selection lens:\n" <>
               "A fixture lens.\nPrefer fixtures."
  end

  test "a missing, malformed or misnamed manifest is refused", %{tmp_dir: root} do
    assert {:error, :persona_missing} = Persona.manifest("absent", 1, root: root)
    write!(root, "broken", 1, "{not json")
    assert {:error, :persona_malformed} = Persona.manifest("broken", 1, root: root)
    write!(root, "misnamed", 1, fixture("someone-else"))
    assert {:error, :persona_malformed} = Persona.manifest("misnamed", 1, root: root)
    write!(root, "partial", 1, Map.delete(fixture("partial"), "source_refs"))
    assert {:error, :persona_malformed} = Persona.manifest("partial", 1, root: root)
    assert {:error, :invalid_persona} = Persona.manifest("../voltaire", 1, root: root)
    assert {:error, :invalid_persona} = Persona.manifest("voltaire", 0)
    assert Persona.versions("../x", root: root) == []
    assert_raise ArgumentError, fn -> Persona.manifest!("absent", 1, root: root) end
  end
end
