defmodule DevilsDictionary.Curation.Configurations do
  @moduledoc """
  System-owned curation configurations (#201): identities, immutable
  versions, activation, and resolution of the global default.

  Each rule below is enforced here and checked again by the database:

    * **Only `system` ownership exists**, and at most one global default is
      enabled at a time (C1).
    * **A pointer moves only with a receipt.** `activate/4` and `disable/3`
      are a reviewer's audited act, each writing an activation receipt in the
      pointer's transaction. The database checks at commit that the
      configuration matches its latest receipt (C3). Neither publishes
      anything (C8).
    * **Resolution is server-side and default-only** (C7).
      `resolve_default/1` takes no configuration argument. It answers the
      enabled global default and its version, or an explicit `{:unavailable,
      reason}` (`:missing`, `:no_active_version`, `:disabled`, `:unready`,
      `:panel_not_available`). It never answers another configuration in the
      default's place.
    * **Seeding activates nothing.** `seed!/0` creates `global-default` as a
      draft, with version 1 and no current version. That version is
      manual-only: the Bierce-first lead policy, three highlights, and an
      empty roster. Until a reviewer activates it, the default resolves as
      `{:unavailable, :no_active_version}`.

  **The editor (#264 R1)** is three acts, never one:

    * *binding*: a new immutable version whose manifest names the admitted
      generic editor, its bot actor and its model config
      (`create_version/3` with `:editor`). `"mode"` stays `"manual"`:
      publication stays the owner's (#253 D4);
    * *activation*: the existing `activate/4`, which also makes every
      pending proposal of another configuration version obsolete;
    * *enablement*: a separate switch on the configuration
      (`enable_editor/3`, `disable_editor/3`), off by default and off again
      after any activation, so the editor runs only when someone says so for
      the version now current (`editor_enabled?/1`).
  """

  import Ecto.Query

  alias DevilsDictionary.Curation.{
    Authority,
    Configuration,
    ConfigurationActivation,
    ConfigurationMember,
    ConfigurationVersion,
    Digest,
    Profile,
    Profiles,
    ProfileVersion,
    Transaction
  }

  alias DevilsDictionary.Curation.Runtime.{ModelConfig, Packet}
  alias DevilsDictionary.Repo
  alias DevilsDictionary.Sources.Actor

  @default_slug "global-default"
  @seed_actor "Curation seed"
  @mode "manual"

  def default_slug, do: @default_slug

  # ── seeding ───────────────────────────────────────────────────────────────

  @doc """
  Seeds the `global-default` identity with its first version, and the five
  proposed profiles. Idempotent, and never changes an existing row's state:
  a configuration someone has activated stays activated.
  """
  def seed! do
    {:ok, result} =
      Repo.transaction(fn ->
        actor = seed_actor!()
        profiles = Profiles.seed_proposed!()

        configuration =
          Repo.get_by(Configuration, slug: @default_slug) ||
            Repo.insert!(%Configuration{
              slug: @default_slug,
              name: "Global default",
              role: :global_default,
              state: :draft,
              created_by_actor_id: actor.id
            })

        version =
          Repo.get_by(ConfigurationVersion, configuration_id: configuration.id, version: 1) ||
            insert_version!(configuration, actor.id, %{
              reason: "Initial manual-only default: Bierce-first lead, up to three highlights."
            })

        %{configuration: configuration, version: version, profiles: profiles}
      end)

    result
  end

  defp seed_actor! do
    Repo.get_by(Actor, actor_kind: :import, label: @seed_actor) ||
      Repo.insert!(
        Actor.changeset(%Actor{}, %{
          actor_kind: :import,
          label: @seed_actor,
          metadata: %{"operation" => "curation_seed", "accountability" => "creates drafts only"}
        })
      )
  end

  # ── identities and versions ───────────────────────────────────────────────

  @doc """
  Creates an internal test configuration, as a draft. The global default is
  created only by `seed!/0`.
  """
  def create_test_configuration(scope, slug, name) do
    Transaction.run(fn ->
      with {:ok, actor} <- Authority.actor(scope, :reviewer) do
        %Configuration{
          slug: slug,
          name: name,
          role: :internal_test,
          state: :draft,
          created_by_actor_id: actor.id
        }
        |> Ecto.Changeset.change()
        |> Ecto.Changeset.unique_constraint(:slug)
        |> Repo.insert()
      end
    end)
  end

  @doc """
  Adds an immutable, manual-only version to a configuration, as a reviewer.

  `attrs`: `:reason`, and optionally `:max_highlights` (0–3, default 3) and
  `:members`, a list of `%{profile_id, profile_version_id}`. Each member must
  be an admitted profile's admitted version. Slots follow list order. The
  version is not activated.

  `:editor`, `%{profile_id, profile_version_id, model_config_id}`, binds the
  generic editor (#264 R1.1). The server resolves it and writes the
  manifest's `"editor"`: the profile and the version it is admitted at, its
  bot actor, the model config and its hash, and the instruction. Refused
  unless the profile is the admitted generic editor at that version
  (`:editor_not_admitted`), the model config exists
  (`:model_config_unknown`), its instruction is a pinned one
  (`:unsupported_instruction_version`) and the bot actor is labelled
  `"<instruction> · <model config slug>"` (`:editor_label_mismatch`).
  """
  def create_version(scope, configuration_id, attrs) do
    Transaction.run(fn ->
      with {:ok, actor} <- Authority.actor(scope, :reviewer),
           {:ok, configuration} <- lock(configuration_id),
           {:ok, _reason} <- Transaction.required(Map.to_list(attrs), :reason),
           :ok <- admitted_members(Map.get(attrs, :members, [])),
           {:ok, editor} <- editor_binding(Map.get(attrs, :editor)) do
        {members, manifest} = attrs |> Map.put(:editor, editor) |> manifest()

        case Repo.get_by(ConfigurationVersion,
               configuration_id: configuration.id,
               manifest_hash: Digest.term(manifest)
             ) do
          nil -> {:ok, insert_version!(configuration, actor.id, attrs, members, manifest)}
          %ConfigurationVersion{id: id} -> {:error, {:duplicate_version, id}}
        end
      end
    end)
  end

  defp admitted_members(members) do
    admitted =
      Enum.all?(members, fn %{profile_id: pid, profile_version_id: vid} ->
        Repo.exists?(
          from p in Profile,
            where: p.id == ^pid and p.state == :admitted and p.current_version_id == ^vid
        )
      end)

    Transaction.check(admitted, :profile_not_admitted)
  end

  # The editor a version binds, resolved by the server: never the caller's
  # word for a bot, a hash or an instruction.
  defp editor_binding(nil), do: {:ok, nil}

  defp editor_binding(%{profile_id: pid, profile_version_id: vid, model_config_id: mid}) do
    with {:ok, profile} <-
           Transaction.need(
             Repo.one(
               from p in Profile,
                 where:
                   p.id == ^pid and p.kind == :generic_editor and p.state == :admitted and
                     p.current_version_id == ^vid
             ),
             :editor_not_admitted
           ),
         {:ok, config} <- Transaction.need(Repo.get(ModelConfig, mid), :model_config_unknown),
         :ok <-
           Transaction.check(
             config.instruction_version in Packet.instruction_versions(),
             :unsupported_instruction_version
           ),
         {:ok, bot} <- Transaction.need(Repo.get(Actor, profile.bot_actor_id), :bot_actor_missing),
         :ok <- Transaction.check(bot.label == editor_label(config), :editor_label_mismatch) do
      {:ok,
       %{
         "profile_id" => profile.id,
         "profile_version_id" => vid,
         "bot_actor_id" => bot.id,
         "model_config_id" => config.id,
         "model_config_hash" => config.config_hash,
         "instruction_version" => config.instruction_version
       }}
    end
  end

  defp editor_binding(_editor), do: {:error, :editor_invalid}

  @doc """
  The label the generic editor's bot actor carries for a model config:
  `"<instruction version> · <model config slug>"`, e.g.
  `"generic-editor-v2 · qwen3.5-9b-v2"` (#264 R1.1, R2.3).
  """
  def editor_label(%ModelConfig{instruction_version: instruction, slug: slug}),
    do: "#{instruction} · #{slug}"

  # What a version is: its roster seats and the manifest they are hashed into.
  defp manifest(attrs) do
    members =
      attrs
      |> Map.get(:members, [])
      |> Enum.with_index(1)
      |> Enum.map(fn {m, slot} ->
        %{
          profile_id: m.profile_id,
          profile_version_id: m.profile_version_id,
          slot: slot,
          voting_weight: 1
        }
      end)

    manifest = %{
      "mode" => @mode,
      "lead_policy" => "bierce_first_v1",
      "max_highlights" => Map.get(attrs, :max_highlights, 3),
      "roster" => Enum.map(members, &Map.new(&1, fn {k, v} -> {to_string(k), v} end))
    }

    manifest =
      case Map.get(attrs, :editor) do
        %{} = editor -> Map.put(manifest, "editor", editor)
        nil -> manifest
      end

    {members, manifest}
  end

  defp insert_version!(configuration, actor_id, attrs) do
    {members, manifest} = manifest(attrs)
    insert_version!(configuration, actor_id, attrs, members, manifest)
  end

  defp insert_version!(configuration, actor_id, attrs, members, manifest) do
    max = manifest["max_highlights"]

    version =
      Repo.insert!(%ConfigurationVersion{
        configuration_id: configuration.id,
        version: next_version(configuration.id),
        manifest_hash: Digest.term(manifest),
        manifest: manifest,
        lead_policy: :bierce_first_v1,
        max_highlights: max,
        roster_hash: Digest.roster_hash(members),
        created_by_actor_id: actor_id,
        change_reason: attrs.reason
      })

    for m <- members do
      Repo.insert!(struct(ConfigurationMember, Map.put(m, :configuration_version_id, version.id)))
    end

    version
  end

  defp next_version(configuration_id) do
    (Repo.one(
       from v in ConfigurationVersion,
         where: v.configuration_id == ^configuration_id,
         select: max(v.version)
     ) || 0) + 1
  end

  # ── resolution ────────────────────────────────────────────────────────────

  @doc """
  The global default and its current version, as `{:ok, %{configuration,
  version}}`, or `{:unavailable, reason}`.

  `purpose: :manual` (the default) is what this slice supports.
  `purpose: :panel` is always unavailable: no model configuration exists
  (#195), and none is invented to make it answer.
  """
  def resolve_default(opts \\ []) do
    case Keyword.get(opts, :purpose, :manual) do
      :panel -> {:unavailable, :panel_not_available}
      :manual -> resolve_manual()
    end
  end

  defp resolve_manual do
    defaults = Repo.all(from c in Configuration, where: c.role == :global_default)

    case Enum.find(defaults, &(&1.state == :enabled)) do
      %Configuration{} = configuration ->
        version = Repo.get!(ConfigurationVersion, configuration.current_version_id)

        if ready?(version),
          do: {:ok, %{configuration: configuration, version: version}},
          else: {:unavailable, :unready}

      nil ->
        cond do
          defaults == [] -> {:unavailable, :missing}
          Enum.any?(defaults, &(&1.state == :disabled)) -> {:unavailable, :disabled}
          true -> {:unavailable, :no_active_version}
        end
    end
  end

  @doc """
  Whether this build can compose under a configuration version: manual
  mode, a known lead policy, and no editor or an editor binding of exactly
  its six keys (#264 R1.2). Pure: it runs on every page read, so it asks
  the database nothing. Whether the bound editor still stands is
  `editor/1`'s question, and only the editor step asks it.
  """
  def ready?(%ConfigurationVersion{manifest: %{} = manifest, lead_policy: :bierce_first_v1}),
    do: manifest["mode"] == @mode and editor_shape?(Map.get(manifest, "editor", :none))

  def ready?(_version), do: false

  @editor_ids ~w(profile_id profile_version_id bot_actor_id model_config_id)
  @editor_keys Enum.sort(@editor_ids ++ ~w(model_config_hash instruction_version))

  defp editor_shape?(:none), do: true

  defp editor_shape?(%{} = editor) do
    Enum.sort(Map.keys(editor)) == @editor_keys and
      Enum.all?(@editor_ids, &(is_integer(editor[&1]) and editor[&1] > 0)) and
      is_binary(editor["model_config_hash"]) and is_binary(editor["instruction_version"])
  end

  defp editor_shape?(_editor), do: false

  @doc """
  The editor a configuration version binds, read again from the record
  (#264 R1.3): `:none`, `{:ok, %{profile, profile_version, bot_actor,
  model_config, instruction_version}}`, or `{:error, reason}` when the
  binding no longer stands: the profile is not admitted at the bound version
  (`:editor_not_admitted`), its bot or model config is not the one bound
  (`:editor_binding_changed`), or the model config's hash moved
  (`:model_config_changed`).
  """
  def editor(%ConfigurationVersion{manifest: %{"editor" => %{} = editor}}) do
    profile = Repo.get(Profile, editor["profile_id"])
    config = Repo.get(ModelConfig, editor["model_config_id"])

    cond do
      is_nil(profile) or profile.kind != :generic_editor or profile.state != :admitted or
          profile.current_version_id != editor["profile_version_id"] ->
        {:error, :editor_not_admitted}

      profile.bot_actor_id != editor["bot_actor_id"] or is_nil(config) ->
        {:error, :editor_binding_changed}

      config.config_hash != editor["model_config_hash"] or
          config.instruction_version != editor["instruction_version"] ->
        {:error, :model_config_changed}

      true ->
        {:ok,
         %{
           profile: profile,
           profile_version: Repo.get!(ProfileVersion, profile.current_version_id),
           bot_actor: Repo.get!(Actor, profile.bot_actor_id),
           model_config: config,
           instruction_version: config.instruction_version
         }}
    end
  end

  def editor(%ConfigurationVersion{}), do: :none

  def editor(version_id) when is_integer(version_id) do
    case Repo.get(ConfigurationVersion, version_id) do
      nil -> {:error, :version_not_found}
      version -> editor(version)
    end
  end

  @doc """
  Whether the editor may run for a configuration version now (#264 R1.5):
  its configuration is enabled, this is its current version, the switch is
  on for exactly it, and the version binds an editor that still stands.
  Answers `{:ok, editor}` (as `editor/1` gives it) or `:off`.
  """
  def editor_enabled(configuration_version_id) when is_integer(configuration_version_id) do
    with %ConfigurationVersion{} = version <-
           Repo.get(ConfigurationVersion, configuration_version_id),
         %Configuration{state: :enabled} = c <- Repo.get(Configuration, version.configuration_id),
         true <- c.current_version_id == version.id,
         true <- c.editor_enabled_version_id == version.id,
         {:ok, editor} <- editor(version) do
      {:ok, editor}
    else
      _off -> :off
    end
  end

  def editor_enabled(_id), do: :off

  @doc """
  Switches the editor on for a configuration's current version, as a
  reviewer (#264 R1.5). `opts`: `:reason` and `:expected`, the current
  version id the caller saw. Refused when the version binds no editor
  (`:no_editor_binding`), when the binding no longer stands, when it is
  already on (`:already_enabled`), or when the current version moved
  (`{:stale, current}`). Marks nothing dirty.
  """
  def enable_editor(scope, configuration_id, opts) do
    Transaction.run(fn ->
      with {:ok, actor} <- Authority.actor(scope, :reviewer),
           {:ok, reason} <- Transaction.required(opts, :reason),
           {:ok, c} <- lock(configuration_id),
           :ok <- Transaction.check(c.state == :enabled, :not_enabled),
           :ok <- expected(c, Keyword.fetch!(opts, :expected)),
           version = Repo.get!(ConfigurationVersion, c.current_version_id),
           {:ok, _editor} <- bound(editor(version)),
           :ok <-
             Transaction.check(c.editor_enabled_version_id != version.id, :already_enabled) do
        switch(c, version.id, actor, reason)
      end
    end)
  end

  @doc """
  Switches the editor off, as a reviewer. `opts`: `:reason`. Refused when it
  is off already (`:editor_not_enabled`).
  """
  def disable_editor(scope, configuration_id, opts) do
    Transaction.run(fn ->
      with {:ok, actor} <- Authority.actor(scope, :reviewer),
           {:ok, reason} <- Transaction.required(opts, :reason),
           {:ok, c} <- lock(configuration_id),
           :ok <- Transaction.check(not is_nil(c.editor_enabled_version_id), :editor_not_enabled) do
        switch(c, nil, actor, reason)
      end
    end)
  end

  defp bound({:ok, editor}), do: {:ok, editor}
  defp bound(:none), do: {:error, :no_editor_binding}
  defp bound({:error, reason}), do: {:error, reason}

  defp switch(c, version_id, actor, reason) do
    c
    |> Ecto.Changeset.change(
      editor_enabled_version_id: version_id,
      editor_switched_by_actor_id: actor.id,
      editor_switched_at: DateTime.utc_now(),
      editor_switch_reason: reason
    )
    |> Repo.update()
  end

  @doc """
  The configuration and its current version, if it is enabled and ready, as
  `{:ok, configuration, version}`. Otherwise `{:error,
  :configuration_unavailable}`.
  """
  def current(configuration_id) do
    with %Configuration{state: :enabled} = c <- Repo.get(Configuration, configuration_id),
         %ConfigurationVersion{} = v <- Repo.get(ConfigurationVersion, c.current_version_id),
         true <- ready?(v) do
      {:ok, c, v}
    else
      _ -> {:error, :configuration_unavailable}
    end
  end

  # ── activation ────────────────────────────────────────────────────────────

  @doc """
  Makes `version_id` a configuration's current version and enables it, as a
  reviewer.

  `opts`:

    * `:reason`;
    * `:idempotency_key`;
    * `:expected`: the current version id the caller saw, or `nil`.
      Required, so a stale screen cannot move a pointer it did not see.

  A replay of the same key answers the same receipt. Publishes nothing.
  """
  def activate(scope, configuration_id, version_id, opts) do
    Transaction.run(fn ->
      with {:ok, actor} <- Authority.actor(scope, :reviewer),
           {:ok, reason} <- Transaction.required(opts, :reason),
           {:ok, key} <- Transaction.required(opts, :idempotency_key),
           {:ok, c} <- lock(configuration_id),
           :fresh <-
             Transaction.replay(ConfigurationActivation, key, fn r ->
               r.configuration_id == c.id and r.action == :activate and
                 r.configuration_version_id == version_id
             end),
           {:ok, version} <-
             Transaction.need(
               Repo.get_by(ConfigurationVersion, id: version_id, configuration_id: c.id),
               :version_not_found
             ),
           :ok <- Transaction.check(ready?(version), :unready),
           :ok <- expected(c, Keyword.fetch!(opts, :expected)),
           :ok <-
             Transaction.check(
               not (c.state == :enabled and c.current_version_id == version.id),
               :already_active
             ),
           :ok <- sole_default(c) do
        result = receipt(c, :activate, version.id, actor, reason, key, :enabled)
        # A proposal made under another configuration version no longer
        # stands: it is not this configuration's any more (#264 R1.4).
        DevilsDictionary.Curation.Proposals.obsolete_other_versions(c.id, version.id)
        result
      else
        {:replay, row} -> {:ok, row}
        error -> error
      end
    end)
  end

  @doc """
  Disables an enabled configuration, as a reviewer, with a receipt. `opts` as
  for `activate/4`. The pointer stays where it was, and resolution then
  answers `{:unavailable, :disabled}`.
  """
  def disable(scope, configuration_id, opts) do
    Transaction.run(fn ->
      with {:ok, actor} <- Authority.actor(scope, :reviewer),
           {:ok, reason} <- Transaction.required(opts, :reason),
           {:ok, key} <- Transaction.required(opts, :idempotency_key),
           {:ok, c} <- lock(configuration_id),
           :fresh <-
             Transaction.replay(ConfigurationActivation, key, fn r ->
               r.configuration_id == c.id and r.action == :disable
             end),
           :ok <- Transaction.check(c.state == :enabled, :not_enabled),
           :ok <- expected(c, Keyword.fetch!(opts, :expected)) do
        receipt(c, :disable, c.current_version_id, actor, reason, key, :disabled)
      else
        {:replay, row} -> {:ok, row}
        error -> error
      end
    end)
  end

  defp receipt(c, action, version_id, actor, reason, key, state) do
    activation =
      Repo.insert!(%ConfigurationActivation{
        configuration_id: c.id,
        action: action,
        configuration_version_id: version_id,
        previous_version_id: c.current_version_id,
        actor_id: actor.id,
        reason: reason,
        idempotency_key: key
      })

    c |> Ecto.Changeset.change(state: state, current_version_id: version_id) |> Repo.update!()

    {:ok, activation}
  end

  defp expected(%Configuration{current_version_id: current}, current), do: :ok

  defp expected(%Configuration{current_version_id: current}, _seen),
    do: {:error, {:stale, current}}

  defp sole_default(%Configuration{role: :global_default, id: id}) do
    Transaction.check(
      not Repo.exists?(
        from c in Configuration,
          where: c.role == :global_default and c.state == :enabled and c.id != ^id
      ),
      :another_default_enabled
    )
  end

  defp sole_default(_configuration), do: :ok

  defp lock(id) do
    Transaction.need(
      Repo.one(from c in Configuration, where: c.id == ^id, lock: "FOR UPDATE"),
      :not_found
    )
  end
end
