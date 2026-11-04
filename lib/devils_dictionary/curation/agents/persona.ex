defmodule DevilsDictionary.Curation.Agents.Persona do
  @moduledoc """
  The single reviewed Phase A selection lens (#275). No model calls or activation.
  The bundled dossier is compiled and versioned with its instruction. Imports
  use existing profile services; admitting it remains a separate reviewer act.
  A changed dossier must use a new template version, never overwrite v1.

  Manifests are read by slug and version (#298 C4): `manifest/3` reads
  `priv/curation/agents/personas/<slug>/v<n>/profile.json`, Voltaire's from
  the compiled copies. Only Voltaire can be prepared or admitted here; a new
  persona's lens reaches a comparison instruction through `lens/1` and
  `Runtime.Packet.grounded_with_lens/1`, and admission into the publication
  guards is a later, separately specified change (#298 OD-B).
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

  # Every persona manifest lives at `<root>/<slug>/v<n>/profile.json`
  # (#298 C4). The reviewed Voltaire versions are compiled in, so their
  # bytes, hashes and instructions cannot drift with the files; any other
  # persona is read by slug and version at run time (`manifest/3`).
  @root Path.expand("../../../../priv/curation/agents/personas", __DIR__)
  @slug_format ~r/^[a-z][a-z0-9-]{0,31}$/
  @body_keys ~w(dossier source_refs deceased_evidence_refs template_version)

  @voltaire (for n <- 1..8, into: %{} do
               path = Path.join([@root, "voltaire", "v#{n}", "profile.json"])
               Module.put_attribute(__MODULE__, :external_resource, path)
               {n, path |> File.read!() |> Jason.decode!()}
             end)

  @manifest @voltaire[1]
  @body Map.take(@manifest, @body_keys)
  @instruction @manifest["template_version"]
  @whole_manifest @voltaire[2]
  @whole_body Map.take(@whole_manifest, @body_keys)
  @revised_manifest @voltaire[3]
  @revised_body Map.take(@revised_manifest, @body_keys)
  @sections_manifest @voltaire[4]
  @sections_body Map.take(@sections_manifest, @body_keys)
  @relevance_manifest @voltaire[5]
  @relevance_body Map.take(@relevance_manifest, @body_keys)
  @selection_body Map.take(@voltaire[6], @body_keys)
  @sense_lead_body Map.take(@voltaire[7], @body_keys)
  @grounded_body Map.take(@voltaire[8], @body_keys)

  @whole_bodies %{
    "voltaire-whole-entry-v1" => @whole_body,
    "voltaire-whole-entry-v2" => @revised_body,
    "voltaire-whole-entry-v3" => @sections_body,
    "voltaire-whole-entry-v4" => @relevance_body,
    "voltaire-whole-entry-v5" => @selection_body,
    "voltaire-whole-entry-v6" => @sense_lead_body,
    "voltaire-whole-entry-v7" => @grounded_body
  }

  def manifest, do: @manifest
  def instruction_version, do: @instruction

  # ── manifests by slug and version (#298 C4) ──────────────────────────────

  @doc """
  Where persona `slug`'s manifest of version `version` lives:
  `priv/curation/agents/personas/<slug>/v<version>/profile.json`, under
  `opts[:root]` when given.
  """
  def path(slug, version, opts \\ []) when is_integer(version) and version > 0,
    do: Path.join([root(opts), slug, "v#{version}", "profile.json"])

  @doc """
  Persona `slug`'s manifest of version `version`: `{:ok, manifest}` or
  `{:error, reason}`, one of `:invalid_persona`, `:persona_missing`,
  `:persona_unreadable` or `:persona_malformed`.

  A reviewed Voltaire version is the compiled one, byte for byte; any other
  is read from disk and must name its own slug, a template version, a
  dossier with a disclosure and a selection, and its source and
  deceased-evidence references as lists. Reading admits nothing and writes
  nothing: admission stays the profile services' reviewed act.
  `opts`: `:root`, another personas directory (tests).
  """
  def manifest(slug, version, opts \\ [])

  def manifest("voltaire", version, opts) when is_map_key(@voltaire, version) do
    if Keyword.has_key?(opts, :root),
      do: read(path("voltaire", version, opts), "voltaire"),
      else: {:ok, Map.fetch!(@voltaire, version)}
  end

  def manifest(slug, version, opts)
      when is_binary(slug) and is_integer(version) and version > 0 do
    if Regex.match?(@slug_format, slug),
      do: read(path(slug, version, opts), slug),
      else: {:error, :invalid_persona}
  end

  def manifest(_slug, _version, _opts), do: {:error, :invalid_persona}

  @doc "As `manifest/3`, raising on any refusal."
  def manifest!(slug, version, opts \\ []) do
    case manifest(slug, version, opts) do
      {:ok, manifest} -> manifest
      {:error, reason} -> raise ArgumentError, "persona #{slug} v#{version}: #{reason}"
    end
  end

  @doc "The versions of persona `slug` on disk, oldest first."
  def versions(slug, opts \\ []) do
    if is_binary(slug) and Regex.match?(@slug_format, slug) do
      case File.ls(Path.join(root(opts), slug)) do
        {:ok, names} ->
          names
          |> Enum.flat_map(fn
            "v" <> n ->
              case Integer.parse(n) do
                {v, ""} when v > 0 -> [v]
                _ -> []
              end

            _ ->
              []
          end)
          |> Enum.filter(&File.regular?(path(slug, &1, opts)))
          |> Enum.sort()

        {:error, _} ->
          []
      end
    else
      []
    end
  end

  @doc """
  The lens a manifest gives an instruction: its dossier's disclosure, a
  newline and its selection guidance, the same two fields Voltaire's
  pinned instructions are compiled from.
  """
  def lens(%{"dossier" => %{"disclosure" => disclosure, "selection" => selection}}),
    do: disclosure <> "\n" <> selection

  @doc "What a profile version of a manifest stores and is hashed by."
  def body(manifest), do: Map.take(manifest, @body_keys)

  defp root(opts), do: Keyword.get_lazy(opts, :root, &runtime_root/0)

  # The application's own priv directory once compiled; the source tree's
  # before (a compile-time read).
  defp runtime_root do
    case :code.priv_dir(:devils_dictionary) do
      {:error, _} -> @root
      priv -> Path.join(to_string(priv), "curation/agents/personas")
    end
  end

  defp read(path, slug) do
    with {:ok, body} <- file(path),
         {:ok, manifest} <- decode(body),
         :ok <- well_formed(manifest, slug) do
      {:ok, manifest}
    end
  end

  defp file(path) do
    case File.read(path) do
      {:ok, body} -> {:ok, body}
      {:error, :enoent} -> {:error, :persona_missing}
      {:error, _} -> {:error, :persona_unreadable}
    end
  end

  defp decode(body) do
    case Jason.decode(body) do
      {:ok, %{} = manifest} -> {:ok, manifest}
      _ -> {:error, :persona_malformed}
    end
  end

  defp well_formed(m, slug) do
    ok =
      m["slug"] == slug and is_binary(m["template_version"]) and m["template_version"] != "" and
        is_map(m["dossier"]) and is_binary(m["dossier"]["disclosure"]) and
        is_binary(m["dossier"]["selection"]) and is_list(m["source_refs"]) and
        is_list(m["deceased_evidence_refs"])

    if ok, do: :ok, else: {:error, :persona_malformed}
  end

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

  def selection_instruction("voltaire-whole-entry-v7"),
    do: selection_instruction("voltaire-whole-entry-v6")

  def selection_instruction("voltaire-whole-entry-v6"),
    do: selection_instruction("voltaire-whole-entry-v5")

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
                 "voltaire-whole-entry-v5",
                 "voltaire-whole-entry-v6",
                 "voltaire-whole-entry-v7"
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
                      "voltaire-whole-entry-v5",
                      "voltaire-whole-entry-v6",
                      "voltaire-whole-entry-v7"
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
