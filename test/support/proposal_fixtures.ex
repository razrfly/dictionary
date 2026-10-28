defmodule DevilsDictionary.ProposalFixtures do
  @moduledoc """
  The proposal path's test world (#264 §8): *love* as `RefreshFixtures`
  builds it, a pinned `generic-editor-v2` model config served by the
  controlled fake (`RuntimeFixtures`), the generic editor seeded and
  admitted, a configuration version binding it activated and the editor
  enabled, and *love* provisioned and published under it.

  The runtime is stubbed with `Req.Test` as the runtime tests stub it: no
  model is reached. Every text is a placeholder, as in `CurationFixtures`.
  `curation_fixtures.ex` is not edited (#264 §7).
  """

  import DevilsDictionary.CurationFixtures
  import DevilsDictionary.RefreshFixtures
  import DevilsDictionary.RuntimeFixtures

  alias DevilsDictionary.Curation.{
    Configurations,
    Profiles,
    Refresh
  }

  alias DevilsDictionary.Curation.Runtime.Packet
  alias DevilsDictionary.Repo

  @instruction "generic-editor-v2"

  @doc """
  The world, editor on. Options: `:enable` (default `true`), `:publish`
  (default `true`, love published under the editor's configuration
  version).
  """
  def editor_world!(ctx \\ %{}, opts \\ []) do
    world = love_world!(ctx)
    editor = editor!(world)

    world =
      Map.merge(world, editor)
      |> Map.put(:configuration, Repo.reload!(world.configuration))

    composition = provision!(world)
    world = Map.put(world, :composition, composition)

    world =
      if Keyword.get(opts, :publish, true),
        do: Map.put(world, :published, publish!(world, composition)),
        else: world

    if Keyword.get(opts, :enable, true), do: enable!(world)
    world
  end

  @doc """
  Seeds and admits the generic editor for a fresh `generic-editor-v2` model
  config, binds it in a new configuration version and activates that
  version. Returns `%{model_config, bot, profile, profile_version,
  editor_version, runtime}`; `runtime` is the runtime's options for a bound
  fake service.
  """
  def editor!(world) do
    slug = "qwen3.5-9b-v2-#{System.unique_integer([:positive])}"

    config =
      model_config!(%{instruction_version: @instruction, slug: slug, tag: "9b"}) |> ready!()

    {:ok, seed} = Profiles.seed_generic_editor(world.reviewer, config, reason: "#264 test seed")

    {:ok, profile} =
      Profiles.admit(world.reviewer, seed.profile.id, seed.version.id,
        reason: "#264 test admission",
        bot_actor_id: seed.bot_actor.id
      )

    {:ok, version} =
      Configurations.create_version(world.reviewer, world.configuration.id, %{
        reason: "#264 test binding",
        editor: %{
          profile_id: profile.id,
          profile_version_id: seed.version.id,
          model_config_id: config.id
        }
      })

    {:ok, _receipt} =
      Configurations.activate(world.reviewer, world.configuration.id, version.id,
        reason: "#264 test activation",
        idempotency_key: key("activate"),
        expected: Repo.reload!(world.configuration).current_version_id
      )

    key = "proposals-#{System.unique_integer([:positive])}"

    %{
      model_config: config,
      bot: seed.bot_actor,
      profile: profile,
      profile_version: seed.version,
      editor_version: version,
      configuration_version: version,
      runtime: bind!(service_key: key, actor_id: seed.bot_actor.id)
    }
  end

  @doc "Switches the editor on for the configuration's current version."
  def enable!(world) do
    configuration = Repo.reload!(world.configuration)

    {:ok, configuration} =
      Configurations.enable_editor(world.reviewer, configuration.id,
        reason: "#264 test window",
        expected: configuration.current_version_id
      )

    configuration
  end

  @doc "The packet the editor is sent for a page, frozen."
  def frozen!(slug \\ "love") do
    {:ok, packet} = Packet.for_page(page(slug), instruction_version: @instruction)
    {:ok, frozen} = Packet.freeze(packet)
    frozen
  end

  @doc """
  The stubbed model's answer: a lead and highlights by the object id of the
  packet candidate (`{object_id, kind}` where two kinds share an object),
  each under the meaning the packet holds it to.
  """
  def answer_for(frozen, lead, highlights) do
    pick = fn ref ->
      c = pick(frozen, ref)
      {c["candidate_id"], c["required_meaning"]}
    end

    selection(
      lead && pick.(lead),
      Enum.map(highlights, fn ref ->
        {id, meaning} = pick.(ref)
        {id, meaning, nil}
      end)
    )
  end

  @doc "The packet candidate for an object id, or `{object_id, locator}` for a quotation."
  def pick(frozen, {object_id, locator}) when is_binary(locator) do
    Enum.find(
      frozen.packet["candidates"],
      &(&1["object_id"] == object_id and &1["locator"] == locator)
    ) ||
      raise "no candidate #{object_id} #{locator}"
  end

  def pick(frozen, object_id) do
    candidate(frozen, object_id) || raise "no candidate for #{object_id}"
  end

  @doc "Stubs the fake model to answer `content` (a map) to every chat, counting calls."
  def stub_answer!(world, content) do
    test = self()

    stub_ollama!(world.model_config,
      chat: fn _request ->
        send(test, :chat_called)
        {:json, answer(content)}
      end
    )
  end

  @doc """
  The owner's request (`Refresh.request/5`), then the worker's claim and
  check, with the editor's runtime options. Answers what the check answers.
  """
  def run!(world, slug \\ "love", opts \\ []) do
    {:ok, :admitted} = Refresh.request(world.reviewer, world.composition.id, slug, "#264 test")
    work!(world, slug, opts)
  end

  @doc "The worker's claim and check of the queued run, with the editor's runtime options."
  def work!(world, slug \\ "love", opts \\ []) do
    row = row!(world.composition)
    {:ok, claim} = Refresh.claim(row.id, row.refresh_generation)
    Refresh.check(claim, slug, Keyword.merge([runtime: world.runtime], opts))
  end

  @doc "The claim of the queued run, for a test that drives the step itself."
  def claim!(world) do
    row = row!(world.composition)
    {:ok, claim} = Refresh.claim(row.id, row.refresh_generation)
    claim
  end

  @doc "The quality form, answered `yes` for every question of every item."
  def all_yes(items) do
    for item <- items, into: %{} do
      {DevilsDictionary.Curation.Proposals.QualityForm.slot(item),
       Map.new(DevilsDictionary.Curation.Proposals.QualityForm.questions(), &{&1, "yes"})}
    end
  end
end
