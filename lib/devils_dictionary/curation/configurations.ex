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
    Transaction
  }

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
  """
  def create_version(scope, configuration_id, attrs) do
    Transaction.run(fn ->
      with {:ok, actor} <- Authority.actor(scope, :reviewer),
           {:ok, configuration} <- lock(configuration_id),
           {:ok, _reason} <- Transaction.required(Map.to_list(attrs), :reason),
           :ok <- admitted_members(Map.get(attrs, :members, [])) do
        {members, manifest} = manifest(attrs)

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

  @doc "Whether this build can compose under a configuration version: manual mode, a known lead policy."
  def ready?(%ConfigurationVersion{manifest: manifest, lead_policy: :bierce_first_v1}),
    do: manifest["mode"] == @mode

  def ready?(_version), do: false

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
        receipt(c, :activate, version.id, actor, reason, key, :enabled)
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
