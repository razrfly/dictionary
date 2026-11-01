defmodule Mix.Tasks.Dd.Curation.Editor do
  @shortdoc "The generic editor's live steps (#264 §10): seed, admit, bind, activate, enable, disable, provision, request, forms"

  @moduledoc """
  The seams #264's Delivery B (#268 Stages 3c–3d) runs, one command per
  step, each a reviewer's act through the record's own services:

      DD_NO_OBAN=1 mix dd.curation.editor seed      --as EMAIL --model-config SLUG --reason TEXT
      DD_NO_OBAN=1 mix dd.curation.editor admit     --as EMAIL --reason TEXT
      DD_NO_OBAN=1 mix dd.curation.editor bind      --as EMAIL --model-config SLUG --reason TEXT
      DD_NO_OBAN=1 mix dd.curation.editor activate  --as EMAIL --version N --reason TEXT
      DD_NO_OBAN=1 mix dd.curation.editor enable    --as EMAIL --reason TEXT
      DD_NO_OBAN=1 mix dd.curation.editor disable   --as EMAIL --reason TEXT
      DD_NO_OBAN=1 mix dd.curation.editor provision --as EMAIL --slug SLUG --reason TEXT
      DD_NO_OBAN=1 mix dd.curation.editor request   --as EMAIL --slug SLUG --reason TEXT
      DD_NO_OBAN=1 mix dd.curation.editor forms     [--counted-only]

  Phase A (#275): `seed`, `admit` and `bind` accept `--profile voltaire`.
  To admit a newly prepared persona version, pass --version N explicitly; omission preserves the current version.
  Use a separately registered model config pinned to `voltaire-selector-v1`.
  Seed prepares an inactive source, model-specific bot and sourced dossier;
  admission and binding are still distinct reviewer acts. Generic defaults are unchanged.

  Every command takes `--dry-run`, which resolves and prints what it would
  do and writes nothing. `--as` names the reviewer account by email: the
  acts are that reviewer's, as on the screen.

    * `seed` writes the `generic-editor` source (a bot, inactive), its bot
      actor labelled `"<instruction> · <model config slug>"`, the
      `generic-editor` profile and its first, empty version. Admits nothing.
    * `admit` admits the generic editor from that version, through its bot
      actor, under the narrow rule (no dossier, no sources, no evidence).
    * `bind` writes a new configuration version of `global-default` binding
      the admitted editor and the model config. Activates nothing.
    * `activate` makes version N current (`expected` is read now and
      printed). Every version made under the previous one stops standing:
      re-publish the pages it showed in the same sitting (#264 OD-3).
    * `enable` and `disable` switch the editor for the current version
      (OD-8: enable at the start of a window, disable at its end).
    * `provision` creates a page's composition over its live words.
    * `request` asks for a proposal for a page (R18): one run is admitted,
      which the server's own queue then runs.
    * `forms` prints the resolved proposals' quality forms as Markdown, for
      #253.

  It starts the application, so it must run with `DD_NO_OBAN=1`: Oban then
  runs no queue here, and a requested run is the server's to execute. It
  starts no model and calls no runtime: `mix dd.runtime` does that. Without
  `MIX_ENV=test` it acts on the working database; each write is a live step
  of #264 §10 and waits for the owner's yes.
  """

  use Mix.Task

  alias DevilsDictionary.Accounts.{Scope, User}

  alias DevilsDictionary.Curation.{
    Candidates,
    Compositions,
    Configuration,
    ConfigurationVersion,
    Configurations,
    Profile,
    ProfileVersion,
    Profiles,
    Proposals,
    Refresh
  }

  alias DevilsDictionary.Curation.Runtime.ModelConfig
  alias DevilsDictionary.Lexicon
  alias DevilsDictionary.Lexicon.WordPage
  alias DevilsDictionary.Repo
  alias DevilsDictionary.Sources.Actor

  @switches [
    as: :string,
    reason: :string,
    dry_run: :boolean,
    model_config: :string,
    version: :integer,
    slug: :string,
    counted_only: :boolean,
    refresh_window: :string,
    shelf: :string,
    profile: :string,
    publication: :string
  ]

  @impl Mix.Task
  def run(args) do
    unless System.get_env("DD_NO_OBAN") == "1",
      do:
        Mix.raise(
          "run with DD_NO_OBAN=1: this task starts the application, and Oban must not run " <>
            "queues here"
        )

    {opts, rest, invalid} = OptionParser.parse(args, strict: @switches)
    if invalid != [], do: Mix.raise("unknown options: #{inspect(invalid)}")

    if opts[:profile] &&
         (opts[:profile] != "voltaire" || rest not in [["seed"], ["admit"], ["bind"]]),
       do: Mix.raise("--profile voltaire is supported only by seed, admit and bind")

    Mix.Task.run("app.start")
    command(rest, opts)
  end

  defp command(["seed"], opts) do
    scope = scope!(opts)
    config = model_config!(opts)
    reason = reason!(opts)

    if opts[:profile] &&
         config.instruction_version not in [
           "voltaire-selector-v1",
           "voltaire-whole-entry-v1",
           "voltaire-whole-entry-v2",
           "voltaire-whole-entry-v3",
           "voltaire-whole-entry-v4",
           "voltaire-whole-entry-v5",
           "voltaire-whole-entry-v6",
           "voltaire-whole-entry-v7"
         ],
       do: Mix.raise("the persona requires a config pinned to voltaire-selector-v1")

    label =
      if opts[:profile],
        do: "Inspired by Voltaire · " <> Configurations.editor_label(config),
        else: Configurations.editor_label(config)

    if opts[:dry_run] do
      info(
        "would prepare #{opts[:profile] || "generic-editor"} (admission/activation unchanged) for #{config.slug} (config ##{config.id}), bot label #{inspect(label)}"
      )
    else
      case opts[:profile] do
        nil ->
          print(Profiles.seed_generic_editor(scope, config, reason: reason))

        "voltaire" ->
          print(DevilsDictionary.Curation.Agents.Persona.prepare(scope, config, reason: reason))

        _ ->
          Mix.raise("--profile supports only voltaire")
      end
    end
  end

  defp command(["admit"], opts) do
    scope = scope!(opts)
    reason = reason!(opts)
    profile = selected_profile!(opts)

    version =
      if opts[:version],
        do:
          Repo.get_by(ProfileVersion, profile_id: profile.id, version: opts[:version]) ||
            Mix.raise("no such profile version"),
        else: Repo.get(ProfileVersion, profile.current_version_id) || Mix.raise("no version")

    bot =
      if opts[:profile] do
        config = model_config!(opts)

        unless DevilsDictionary.Curation.Agents.Persona.compatible?(profile, version, config),
          do: Mix.raise("persona dossier/model instruction mismatch")

        source =
          Repo.get_by!(DevilsDictionary.Sources.Source, slug: "curator-voltaire-" <> config.slug)

        Repo.get_by!(Actor, actor_kind: :bot, bot_source_id: source.id)
      else
        editor_bot!()
      end

    if opts[:dry_run] do
      info(
        "would admit profile ##{profile.id} at version ##{version.id} (#{version.template_version}) through bot ##{bot.id} #{inspect(bot.label)}"
      )
    else
      print(Profiles.admit(scope, profile.id, version.id, reason: reason, bot_actor_id: bot.id))
    end
  end

  defp command(["bind"], opts) do
    scope = scope!(opts)
    reason = reason!(opts)
    config = model_config!(opts)
    c = default!()
    profile = if opts[:profile], do: selected_profile!(opts), else: admitted_editor!()

    editor = %{
      profile_id: profile.id,
      profile_version_id: profile.current_version_id,
      model_config_id: config.id
    }

    policy = Keyword.get(opts, :publication, "manual")

    unless policy in ["manual", "single_editor_v1"],
      do: Mix.raise("--publication must be manual or single_editor_v1")

    window =
      case Keyword.get(opts, :refresh_window, "48h") do
        "24h" -> 86_400
        "48h" -> 172_800
        "7d" -> 604_800
        _ -> Mix.raise("--refresh-window must be 24h, 48h or 7d")
      end

    if opts[:dry_run] do
      info("publication policy: #{policy}; refresh window: #{window} seconds; no activation")

      info(
        "would bind #{inspect(editor)} in a new version of #{c.slug} (current ##{c.current_version_id})"
      )
    else
      print(
        Configurations.create_version(scope, c.id, %{
          reason: reason,
          editor: editor,
          refresh_window: window,
          editor_publication: policy,
          selection_scope:
            if(config.instruction_version in DevilsDictionary.Curation.WholeEntry.instructions(),
              do: "whole_entry_v1",
              else: nil
            )
        })
      )
    end
  end

  defp command(["activate"], opts) do
    scope = scope!(opts)
    reason = reason!(opts)
    c = default!()
    n = opts[:version] || Mix.raise("--version N: the configuration version to activate")

    version =
      Repo.get_by(ConfigurationVersion, configuration_id: c.id, version: n) ||
        Mix.raise("#{c.slug} has no version #{n}")

    info("#{c.slug}: current version ##{c.current_version_id}; activating ##{version.id} (v#{n})")

    if opts[:dry_run] do
      info("would activate; every version made under the current one stops standing (OD-3)")
    else
      print(
        Configurations.activate(scope, c.id, version.id,
          reason: reason,
          idempotency_key: key("activate"),
          expected: c.current_version_id
        )
      )
    end
  end

  defp command([switch], opts) when switch in ["enable", "disable"] do
    scope = scope!(opts)
    reason = reason!(opts)
    c = default!()

    cond do
      opts[:dry_run] ->
        info(
          "would #{switch} the editor of #{c.slug} at version ##{c.current_version_id} (now: #{inspect(c.editor_enabled_version_id)})"
        )

      switch == "enable" ->
        print(
          Configurations.enable_editor(scope, c.id,
            reason: reason,
            expected: c.current_version_id
          )
        )

      true ->
        print(Configurations.disable_editor(scope, c.id, reason: reason))
    end
  end

  defp command(["provision"], opts) do
    scope = scope!(opts)
    reason = reason!(opts)
    {slug, ids, language} = page!(opts)
    c = default!()

    if opts[:dry_run] do
      info("would provision #{slug} over #{inspect(ids)} (#{language}) under #{c.slug}")
    else
      print(
        Compositions.provision(scope, c.id, %{
          scope_kind: :lexical_page,
          lexeme_ids: ids,
          language_tag: language,
          reason: reason
        })
      )
    end
  end

  defp command(["request"], opts) do
    scope = scope!(opts)
    reason = reason!(opts)
    {slug, ids, language} = page!(opts)
    c = default!()

    composition =
      Compositions.active(c.id, :lexical_page, language, Compositions.signature(ids)) ||
        Mix.raise("#{slug} has no composition: provision it first")

    editor = Configurations.editor_enabled(c.current_version_id)

    if opts[:dry_run] do
      info(
        "would request a run for #{slug} (composition ##{composition.id}); the editor is #{if match?({:ok, _}, editor), do: "on", else: "off"}"
      )
    else
      print(Refresh.request(scope, composition.id, slug, reason, shelf: opts[:shelf]))
    end
  end

  defp command(["forms"], opts) do
    Mix.shell().info(Proposals.export_forms(counted_only: opts[:counted_only] || false))
  end

  defp command(_other, _opts),
    do: Mix.raise("usage: see `mix help dd.curation.editor`")

  # ── helpers ──────────────────────────────────────────────────────────────

  defp scope!(opts) do
    email = opts[:as] || Mix.raise("--as EMAIL: the reviewer account acting")
    user = Repo.get_by(User, email: email) || Mix.raise("no account #{email}")
    unless user.reviewer, do: Mix.raise("#{email} is not a reviewer")
    Scope.for_user(user)
  end

  defp reason!(opts) do
    case opts[:reason] do
      text when is_binary(text) and text != "" -> text
      _none -> Mix.raise("--reason TEXT: every act records why")
    end
  end

  defp model_config!(opts) do
    slug = opts[:model_config] || Mix.raise("--model-config SLUG")
    Repo.get_by(ModelConfig, slug: slug) || Mix.raise("no model config #{slug}")
  end

  defp default! do
    Repo.get_by(Configuration, slug: Configurations.default_slug()) ||
      Mix.raise("no #{Configurations.default_slug()} configuration")
  end

  defp admitted_editor! do
    case Profiles.generic_editor() do
      %Profile{state: :admitted} = p -> p
      _other -> Mix.raise("the generic editor is not admitted: run admit first")
    end
  end

  defp editor_bot! do
    source =
      Repo.get_by(DevilsDictionary.Sources.Source, slug: "generic-editor") ||
        Mix.raise("no generic-editor source: run seed first")

    Repo.get_by(Actor, actor_kind: :bot, bot_source_id: source.id) ||
      Mix.raise("no bot actor for the generic-editor source")
  end

  # The page's scope as the screen and the reader take it: its words, in one
  # language (`Candidates.for_page/1`).
  defp page!(opts) do
    slug = opts[:slug] || Mix.raise("--slug SLUG: the On page")
    page = slug |> Lexicon.lookup() |> WordPage.build(viewer: :public)

    case Candidates.for_page(page).scope do
      %{ids: [_ | _] = ids, language: language} when is_binary(language) -> {slug, ids, language}
      _none -> Mix.raise("#{slug} has no words in a single language to curate")
    end
  end

  defp key(action), do: "dd.curation.editor:#{action}:#{Ecto.UUID.generate()}"

  defp info(text), do: Mix.shell().info(text)

  defp print({:ok, value}), do: info("ok: " <> describe(value))
  defp print({:error, reason}), do: Mix.raise("refused: #{inspect(reason)}")

  defp describe(%{__struct__: module, id: id}), do: "#{inspect(module)} ##{id}"

  defp describe(%{} = map) when not is_struct(map),
    do: Enum.map_join(map, ", ", fn {k, v} -> "#{k}: #{describe(v)}" end)

  defp describe(value), do: inspect(value)

  defp selected_profile!(opts) do
    case opts[:profile] do
      nil ->
        Profiles.generic_editor() || Mix.raise("no generic editor: run seed first")

      "voltaire" ->
        Repo.get_by(Profile, slug: "voltaire") || Mix.raise("run seed --profile voltaire first")

      _ ->
        Mix.raise("--profile supports only voltaire")
    end
  end
end
