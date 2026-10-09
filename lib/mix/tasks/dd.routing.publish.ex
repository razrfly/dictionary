defmodule Mix.Tasks.Dd.Routing.Publish do
  @shortdoc "Publish a launch manifest's pages through the eight gates, with receipts"

  @moduledoc """
  Publishes the pages a launch manifest names (#237, Stage 5 of #194), each
  only through all eight publication gates (`Routing.Publications`), and
  prints every refusal with the gate and the reason.

      DD_NO_OBAN=1 mix dd.routing.publish --rule priv/routing/review-rule.json \\
        --from MANIFEST.json [--population candidates.json] --write-manifest priv/routing/launch-manifest.json
      DD_NO_OBAN=1 mix dd.routing.publish --manifest priv/routing/launch-manifest.json --dry-run
      DD_NO_OBAN=1 mix dd.routing.publish --manifest priv/routing/launch-manifest.json \\
        [--rule priv/routing/review-rule.json] [--receipts OUT.json]

  **Making the launch manifest** (`--from` with `--write-manifest`): the
  standing review rule generates it from a backfill run's candidate manifest
  and the population that run was bound to (`--population`, default
  `docs/routing/stage-2/candidates.json`), reading only
  (`Routing.LaunchManifest.generate/3`): the pages the rule confirms at the
  addresses they hold, the lexical entries of D1, and what it defers. It is
  never written by hand. Nothing is published by this step.

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

  @impl Mix.Task
  def run(args) do
    # Checked before the application starts: with the variable unset, the
    # development configuration would start Oban's queues against the
    # working database.
    unless System.get_env("DD_NO_OBAN") == "1",
      do:
        Mix.raise(
          "run with DD_NO_OBAN=1: this task starts the application, and Oban must not run " <>
            "against the working database"
        )

    Mix.Task.run("app.start")

    {opts, extra, invalid} =
      OptionParser.parse(args,
        strict: [
          manifest: :string,
          from: :string,
          population: :string,
          write_manifest: :string,
          rule: :string,
          reviewer: :string,
          override: :string,
          dry_run: :boolean,
          receipts: :string
        ]
      )

    cond do
      (extra == [] and invalid == [] and opts[:from]) && opts[:write_manifest] && !opts[:manifest] ->
        write_manifest(opts)

      (extra == [] and invalid == [] and opts[:manifest]) && !opts[:from] ->
        publish(opts)

      true ->
        Mix.raise(
          "usage: mix dd.routing.publish --manifest MANIFEST " <>
            "[--rule RULE | --reviewer EMAIL --override REASON] [--dry-run] [--receipts OUT]\n" <>
            "       mix dd.routing.publish --rule RULE --from BACKFILL_MANIFEST " <>
            "[--population CANDIDATES] --write-manifest OUT"
        )
    end
  end

  # The rule makes the launch manifest; nothing is published.
  defp write_manifest(opts) do
    rule = ok!(ReviewRule.load(opts[:rule] || ReviewRule.path()))
    population = opts[:population] || "docs/routing/stage-2/candidates.json"
    doc = ok!(LaunchManifest.generate(opts[:from], population, rule))
    File.write!(opts[:write_manifest], [Jason.encode!(doc, pretty: true), "\n"])
    {:ok, manifest} = LaunchManifest.read(opts[:write_manifest])
    counts = Jason.decode!(Jason.encode!(doc))["counts"]

    Mix.shell().info("launch manifest #{opts[:write_manifest]} (#{manifest.sha256})")
    Mix.shell().info("  from  #{opts[:from]}, population #{population}")
    Mix.shell().info("  rule  #{rule.sha256}, signed by #{rule.signer.email}")

    Mix.shell().info(
      "  pages #{counts["pages"]}, lexical #{counts["lexical"]}, pending #{counts["pending"]}, deferred #{counts["deferred"]}"
    )

    for {clause, n} <- counts["by_clause"], do: Mix.shell().info("    #{clause}: #{n}")
  end

  defp publish(opts) do
    manifest = ok!(LaunchManifest.read(opts[:manifest]))
    rule = if manifest.rule_sha256, do: ok!(ReviewRule.load(opts[:rule] || ReviewRule.path()))
    actor = actor!(rule, opts[:reviewer])
    override = override!(rule, opts[:override])

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
      Publications.publish(manifest, actor.id,
        rule: rule,
        dry_run: opts[:dry_run] == true,
        override: override != nil,
        reason: override
      )

    print(report, opts[:dry_run])

    if path = opts[:receipts] do
      File.write!(path, Jason.encode_to_iodata!(json(report, manifest, rule, opts), pretty: true))
      Mix.shell().info("report #{path}")
    end
  end

  defp ok!({:ok, value}), do: value
  defp ok!({:error, message}), do: Mix.raise(message)

  # D3 as amended (#237): the signed rule is the publication authority, and
  # a human publishes only as an override, recorded as such. A manifest made
  # without a rule therefore publishes only with `--override REASON`, which
  # every receipt carries; a rule's manifest takes no override.
  defp override!(nil, nil),
    do:
      Mix.raise(
        "a manifest made without a rule publishes only as a human's override, recorded as " <>
          "such (D3): give --override REASON"
      )

  defp override!(nil, reason) do
    if String.trim(reason) == "",
      do: Mix.raise("--override needs a reason"),
      else: String.trim(reason)
  end

  defp override!(_rule, nil), do: nil

  defp override!(_rule, _reason),
    do: Mix.raise("a manifest made under the standing review rule takes no --override")

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
