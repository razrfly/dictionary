defmodule Mix.Tasks.Dd.Routing.Publish do
  @shortdoc "Publish a launch manifest's pages through the eight gates, with receipts"

  @moduledoc """
  Publishes the pages a launch manifest names (#237, Stage 5 of #194), each
  only through all eight publication gates (`Routing.Publications`), and
  prints every refusal with the gate and the reason.

      DD_NO_OBAN=1 mix dd.routing.publish --manifest priv/routing/launch-manifest.json --dry-run
      DD_NO_OBAN=1 mix dd.routing.publish --manifest priv/routing/launch-manifest.json \\
        [--rule priv/routing/review-rule.json] [--receipts OUT.json]

  A manifest made under the owner's standing review rule is published under
  that rule: the rule is loaded and its signature checked
  (`Routing.ReviewRule.load/1`, `--rule` defaulting to
  `priv/routing/review-rule.json`), and the publishing actor is its signer's
  account. A manifest made without a rule names its reviewer with
  `--reviewer EMAIL`, whose account must already have its actor.

  `--dry-run` checks every gate and writes nothing. Without it, each page
  that passes gets a receipt and becomes `published`; a page that fails a
  gate stays as it is and is reported; a published page is unchanged, and a
  withdrawn one stays withdrawn. Running it again is idempotent. An empty
  manifest publishes nothing and says so. `--receipts` writes the report as
  JSON. Exits non-zero if the manifest or the rule cannot be loaded; a page
  refused by a gate is a reported outcome, not a failure of the task.
  """

  use Mix.Task

  alias DevilsDictionary.Accounts.User
  alias DevilsDictionary.Repo
  alias DevilsDictionary.Routing.{LaunchManifest, Publications, ReviewRule}
  alias DevilsDictionary.Sources.Actor

  @requirements ["app.start"]

  @impl Mix.Task
  def run(args) do
    {opts, extra, invalid} =
      OptionParser.parse(args,
        strict: [
          manifest: :string,
          rule: :string,
          reviewer: :string,
          dry_run: :boolean,
          receipts: :string
        ]
      )

    unless extra == [] and invalid == [] and opts[:manifest] do
      Mix.raise(
        "usage: mix dd.routing.publish --manifest MANIFEST [--rule RULE | --reviewer EMAIL] " <>
          "[--dry-run] [--receipts OUT]"
      )
    end

    manifest = ok!(LaunchManifest.read(opts[:manifest]))
    rule = if manifest.rule_sha256, do: ok!(ReviewRule.load(opts[:rule] || ReviewRule.path()))
    actor = actor!(rule, opts[:reviewer])

    Mix.shell().info("manifest #{opts[:manifest]} (#{manifest.sha256})")
    Mix.shell().info("  pages #{map_size(manifest.pages)}, lexical #{length(manifest.lexical)}")

    if rule,
      do:
        Mix.shell().info(
          "  rule #{rule.sha256}, signed by #{rule.signer.email} at #{rule.signature["signed_at"]}"
        )

    case LaunchManifest.validate(manifest, rule: rule) do
      :ok -> Mix.shell().info("  every entry holds against the ledger")
      {:error, problems} -> Enum.each(problems, &Mix.shell().info("  entry: #{&1}"))
    end

    {:ok, report} =
      Publications.publish(manifest, actor.id, rule: rule, dry_run: opts[:dry_run] == true)

    print(report, opts[:dry_run])

    if path = opts[:receipts] do
      File.write!(path, Jason.encode_to_iodata!(json(report, manifest, rule, opts), pretty: true))
      Mix.shell().info("report #{path}")
    end
  end

  defp ok!({:ok, value}), do: value
  defp ok!({:error, message}), do: Mix.raise(message)

  # The rule's signer, or the named reviewer: an account holding the
  # reviewer role, with its actor. Nothing is created here.
  defp actor!(nil, nil),
    do: Mix.raise("a manifest made without a rule names its reviewer: --reviewer EMAIL")

  defp actor!(nil, email), do: user_actor!(Repo.get_by(User, email: email), email)
  defp actor!(rule, _email), do: user_actor!(Repo.get(User, rule.signer.id), rule.signer.email)

  defp user_actor!(%User{reviewer: true} = user, _email) do
    Repo.get_by(Actor, actor_kind: :user, user_id: user.id) ||
      Mix.raise("#{user.email} has no actor on this installation")
  end

  defp user_actor!(_user, email), do: Mix.raise("#{email} is not a reviewer account")

  defp print(report, dry_run) do
    if report.empty, do: Mix.shell().info("the manifest names no page: nothing to publish")

    for %{page_id: id, path: path} <- report.published,
        do: Mix.shell().info("  published  #{id} #{path}")

    for %{page_id: id, path: path} <- report.would_publish,
        do: Mix.shell().info("  would publish #{id} #{path}")

    for %{page_id: id, path: path} = r <- report.unchanged,
        do:
          Mix.shell().info("  unchanged  #{id} #{path} (#{r.state}#{r[:note] && ": " <> r.note})")

    for %{page_id: id, path: path, failed: failed, gates: gates} <- report.refused do
      Mix.shell().info("  refused    #{id} #{path}")

      for gate <- failed,
          do: Mix.shell().info("    #{String.pad_trailing(gate, 10)} #{gates[gate]["detail"]}")
    end

    Mix.shell().info(
      "#{if dry_run, do: "dry run: ", else: ""}" <>
        "#{length(report.published)} published, #{length(report.would_publish)} would publish, " <>
        "#{length(report.unchanged)} unchanged, #{length(report.refused)} refused"
    )
  end

  defp json(report, manifest, rule, opts) do
    %{
      "manifest" => opts[:manifest],
      "manifest_sha256" => manifest.sha256,
      "rule_sha256" => rule && rule.sha256,
      "dry_run" => opts[:dry_run] || false,
      "empty" => report.empty,
      "published" => report.published,
      "would_publish" => report.would_publish,
      "unchanged" => report.unchanged,
      "refused" => report.refused
    }
  end
end
