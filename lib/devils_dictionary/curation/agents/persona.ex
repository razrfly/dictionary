defmodule DevilsDictionary.Curation.Agents.Persona do
  @moduledoc """
  The single reviewed Phase A selection lens (#275). No model calls or activation.
  The bundled dossier is compiled and versioned with its instruction. Imports
  use existing profile services; admitting it remains a separate reviewer act.
  A changed dossier must use a new template version, never overwrite v1.
  """
  import Ecto.Query

  alias DevilsDictionary.Curation.{
    Authority,
    Configurations,
    Digest,
    Profile,
    ProfileVersion,
    Profiles,
    Transaction
  }

  alias DevilsDictionary.Curation.Runtime.ModelConfig
  alias DevilsDictionary.Repo
  alias DevilsDictionary.Sources.{Actor, Source}

  @path Path.expand("../../../../priv/curation/agents/personas/voltaire/v1/profile.json", __DIR__)
  @external_resource @path
  @manifest @path |> File.read!() |> Jason.decode!()
  @body Map.take(@manifest, ~w(dossier source_refs deceased_evidence_refs template_version))
  @instruction @manifest["template_version"]
  @whole_path Path.expand(
                "../../../../priv/curation/agents/personas/voltaire/v2/profile.json",
                __DIR__
              )
  @external_resource @whole_path
  @whole_manifest @whole_path |> File.read!() |> Jason.decode!()
  @whole_body Map.take(
                @whole_manifest,
                ~w(dossier source_refs deceased_evidence_refs template_version)
              )

  @revised_path Path.expand(
                  "../../../../priv/curation/agents/personas/voltaire/v3/profile.json",
                  __DIR__
                )
  @external_resource @revised_path
  @revised_manifest @revised_path |> File.read!() |> Jason.decode!()
  @revised_body Map.take(
                  @revised_manifest,
                  ~w(dossier source_refs deceased_evidence_refs template_version)
                )
  @sections_path Path.expand(
                   "../../../../priv/curation/agents/personas/voltaire/v4/profile.json",
                   __DIR__
                 )
  @external_resource @sections_path
  @sections_manifest @sections_path |> File.read!() |> Jason.decode!()
  @sections_body Map.take(
                   @sections_manifest,
                   ~w(dossier source_refs deceased_evidence_refs template_version)
                 )
  @relevance_path Path.expand(
                    "../../../../priv/curation/agents/personas/voltaire/v5/profile.json",
                    __DIR__
                  )
  @external_resource @relevance_path
  @relevance_manifest @relevance_path |> File.read!() |> Jason.decode!()
  @relevance_body Map.take(
                    @relevance_manifest,
                    ~w(dossier source_refs deceased_evidence_refs template_version)
                  )
  @selection_path Path.expand(
                    "../../../../priv/curation/agents/personas/voltaire/v6/profile.json",
                    __DIR__
                  )
  @external_resource @selection_path
  @selection_manifest @selection_path |> File.read!() |> Jason.decode!()
  @selection_body Map.take(
                    @selection_manifest,
                    ~w(dossier source_refs deceased_evidence_refs template_version)
                  )
  @whole_bodies %{
    "voltaire-whole-entry-v1" => @whole_body,
    "voltaire-whole-entry-v2" => @revised_body,
    "voltaire-whole-entry-v3" => @sections_body,
    "voltaire-whole-entry-v4" => @relevance_body,
    "voltaire-whole-entry-v5" => @selection_body
  }

  def manifest, do: @manifest
  def instruction_version, do: @instruction

  def selection_instruction do
    @manifest["dossier"]["disclosure"] <> "\n" <> @manifest["dossier"]["selection"]
  end

  def selection_instruction("voltaire-whole-entry-v1"),
    do:
      @whole_manifest["dossier"]["disclosure"] <> "\n" <> @whole_manifest["dossier"]["selection"]

  def selection_instruction("voltaire-whole-entry-v2"),
    do:
      @revised_manifest["dossier"]["disclosure"] <>
        "\n" <> @revised_manifest["dossier"]["selection"]

  def selection_instruction("voltaire-whole-entry-v3"),
    do:
      @sections_manifest["dossier"]["disclosure"] <>
        "\n" <> @sections_manifest["dossier"]["selection"]

  def selection_instruction("voltaire-whole-entry-v5"),
    do: selection_instruction("voltaire-whole-entry-v4")

  def selection_instruction("voltaire-whole-entry-v4"),
    do:
      @relevance_manifest["dossier"]["disclosure"] <>
        "\n" <> @relevance_manifest["dossier"]["selection"]

  def valid_version?(%Profile{slug: "voltaire", kind: :persona}, %ProfileVersion{} = version) do
    body = %{
      "dossier" => version.dossier,
      "source_refs" => version.source_refs,
      "deceased_evidence_refs" => version.deceased_evidence_refs,
      "template_version" => version.template_version
    }

    expected = Map.get(@whole_bodies, version.template_version, @body)

    body == expected and version.manifest_hash == Digest.term(expected)
  end

  def valid_version?(_, _), do: false

  def compatible?(profile, version, config) do
    valid_version?(profile, version) and config.instruction_version == version.template_version
  end

  def label(profile, config), do: profile.label <> " · " <> Configurations.editor_label(config)

  @doc "Prepare inactive source/bot and an unadmitted dossier, idempotently; never bind or activate."
  def prepare(scope, %ModelConfig{} = config, opts) do
    Transaction.run(fn ->
      body = Map.get(@whole_bodies, config.instruction_version, @body)

      with {:ok, _actor} <- Authority.actor(scope, :reviewer),
           {:ok, reason} <- Transaction.required(opts, :reason),
           :ok <-
             Transaction.check(
               config.instruction_version in [
                 @instruction,
                 "voltaire-whole-entry-v1",
                 "voltaire-whole-entry-v2",
                 "voltaire-whole-entry-v3",
                 "voltaire-whole-entry-v4",
                 "voltaire-whole-entry-v5"
               ],
               :persona_instruction_mismatch
             ) do
        profile = Enum.find(Profiles.seed_proposed!(), &(&1.slug == "voltaire"))
        source_slug = "curator-voltaire-" <> config.slug

        source =
          Repo.get_by(Source, slug: source_slug) ||
            Repo.insert!(%Source{
              slug: source_slug,
              name: label(profile, config),
              kind: :bot,
              tier: :middle,
              access: :static,
              active: false,
              config: %{}
            })

        bot =
          Repo.get_by(Actor, actor_kind: :bot, bot_source_id: source.id) ||
            Repo.insert!(%Actor{
              actor_kind: :bot,
              bot_source_id: source.id,
              label: label(profile, config),
              metadata: %{
                "operation" => "persona_selection",
                "accountability" =>
                  if(
                    config.instruction_version in [
                      "voltaire-whole-entry-v1",
                      "voltaire-whole-entry-v2",
                      "voltaire-whole-entry-v3",
                      "voltaire-whole-entry-v4",
                      "voltaire-whole-entry-v5"
                    ],
                    do: "single_editor_v1",
                    else: "proposes only"
                  )
              }
            })

        attrs = %{
          dossier: body["dossier"],
          source_refs: body["source_refs"],
          deceased_evidence_refs: body["deceased_evidence_refs"],
          template_version: config.instruction_version,
          reason: reason
        }

        profile = Repo.one!(from p in Profile, where: p.id == ^profile.id, lock: "FOR UPDATE")

        version =
          Repo.get_by(ProfileVersion, profile_id: profile.id, manifest_hash: Digest.term(body))

        version =
          version ||
            case Profiles.add_version(scope, profile.id, attrs) do
              {:ok, v} -> v
            end

        {:ok, %{profile: Repo.reload!(profile), version: version, bot_actor: bot, source: source}}
      end
    end)
  end
end
