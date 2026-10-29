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

  def manifest, do: @manifest
  def instruction_version, do: @instruction

  def selection_instruction do
    @manifest["dossier"]["disclosure"] <> "\n" <> @manifest["dossier"]["selection"]
  end

  def valid_version?(%Profile{slug: "voltaire", kind: :persona}, %ProfileVersion{} = version) do
    body = %{
      "dossier" => version.dossier,
      "source_refs" => version.source_refs,
      "deceased_evidence_refs" => version.deceased_evidence_refs,
      "template_version" => version.template_version
    }

    body == @body and version.manifest_hash == Digest.term(@body)
  end

  def valid_version?(_, _), do: false

  def compatible?(profile, version, config) do
    valid_version?(profile, version) and config.instruction_version == @instruction
  end

  def label(profile, config), do: profile.label <> " · " <> Configurations.editor_label(config)

  @doc "Prepare inactive source/bot and an unadmitted dossier, idempotently; never bind or activate."
  def prepare(scope, %ModelConfig{} = config, opts) do
    Transaction.run(fn ->
      with {:ok, _actor} <- Authority.actor(scope, :reviewer),
           {:ok, reason} <- Transaction.required(opts, :reason),
           :ok <-
             Transaction.check(
               config.instruction_version == @instruction,
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
              metadata: %{"operation" => "persona_selection", "accountability" => "proposes only"}
            })

        attrs = %{
          dossier: @body["dossier"],
          source_refs: @body["source_refs"],
          deceased_evidence_refs: @body["deceased_evidence_refs"],
          template_version: @instruction,
          reason: reason
        }

        profile = Repo.one!(from p in Profile, where: p.id == ^profile.id, lock: "FOR UPDATE")

        version =
          Repo.get_by(ProfileVersion, profile_id: profile.id, manifest_hash: Digest.term(@body))

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
