defmodule Mix.Tasks.Dd.Routing.Rule do
  @shortdoc "Show the standing review rule and whether it is signed; sign it as its reviewer"

  @moduledoc """
  The owner's standing review rule (#237 Part A′, `Routing.ReviewRule`).

      DD_NO_OBAN=1 mix dd.routing.rule [PATH]
      DD_NO_OBAN=1 mix dd.routing.rule --sign [PATH] --reviewer EMAIL

  Without `--sign`: prints the rule's digest (its content without the
  signature), its file's SHA-256, each clause, and its signature, checked as
  every run checks it — it covers this content, and its signer holds the
  reviewer role on this installation. Exits non-zero if it is not signed or
  the signature does not hold. `PATH` defaults to
  `priv/routing/review-rule.json`.

  With `--sign`: the owner's one act. Asks for the reviewer account's
  password (read without echo on a terminal, or one line from a pipe),
  checks it and the reviewer role against this installation's database,
  and only then records the signing in `review_rule_signatures` and writes
  the same signature into the file: the signer's email and id, the digest
  signed, the time, the method and an attestation. Refuses a rule that is
  already signed, in the file or on this installation. That row is the only
  write to the database, and it is the owner's own act.

  Signing needs the account's password, which only its holder types; a
  signature written into the file by hand does not load, because no
  signing was recorded (`Routing.ReviewRule`). A signed file whose signing
  this installation does not hold (the row was never written, or the
  signer's email has changed since) neither loads nor can be signed again:
  change its content (its `name`, say) and sign that afresh. The task
  refuses to run without `DD_NO_OBAN=1` before it starts the application,
  so Oban never runs against the working database on its account.
  """

  use Mix.Task

  alias DevilsDictionary.Routing.ReviewRule

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

    {opts, rest, invalid} =
      OptionParser.parse(args, strict: [sign: :boolean, reviewer: :string])

    path =
      case {rest, invalid} do
        {[], []} -> ReviewRule.path()
        {[path], []} -> path
        _ -> Mix.raise("usage: mix dd.routing.rule [--sign --reviewer EMAIL] [PATH]")
      end

    if opts[:sign], do: sign(path, opts[:reviewer]), else: show(path)
  end

  defp sign(_path, nil), do: Mix.raise("--sign needs --reviewer EMAIL: the account that signs")

  defp sign(path, email) do
    case ReviewRule.read(path) do
      {:ok, rule} ->
        Mix.shell().info("signing #{path}: rule #{rule.sha256} as #{email}")

      {:error, message} ->
        Mix.raise(message)
    end

    case ReviewRule.sign(path, email, password!(email)) do
      {:ok, rule} ->
        Mix.shell().info("signed: #{rule.signature["signer"]} at #{rule.signature["signed_at"]}")
        show(path)

      {:error, message} ->
        Mix.raise(message)
    end
  end

  # The password, never echoed: on a terminal, read without echo and never
  # retried through an echoing read; from a pipe, one line, which nothing
  # echoes.
  defp password!(email) do
    Mix.shell().info("password for #{email}:")
    io = :io.getopts()
    terminal? = is_list(io) and Keyword.get(io, :terminal, false) == true

    line =
      if terminal? do
        case :io.get_password() do
          password when is_list(password) -> List.to_string(password)
          _other -> ""
        end
      else
        case IO.gets("") do
          line when is_binary(line) -> String.trim_trailing(line, "\n")
          _other -> ""
        end
      end

    if line == "", do: Mix.raise("no password given"), else: line
  end

  defp show(path) do
    case ReviewRule.read(path) do
      {:ok, rule} ->
        Mix.shell().info("rule        #{path}")
        Mix.shell().info("  digest    #{rule.sha256}")
        Mix.shell().info("  file      #{rule.file_sha256}")
        Mix.shell().info("  format    #{rule.doc["format"]}")

        for clause <- rule.doc["clauses"],
            do: Mix.shell().info("  #{String.pad_trailing(clause["action"], 8)} #{clause["id"]}")

        case ReviewRule.load(path) do
          {:ok, loaded} ->
            s = loaded.signature

            Mix.shell().info(
              "  signed    by #{s["signer"]} (user #{s["user_id"]}, a reviewer) at #{s["signed_at"]}"
            )

          {:error, message} ->
            Mix.shell().error("  not usable: #{message}")
            exit({:shutdown, 1})
        end

      {:error, message} ->
        Mix.raise(message)
    end
  end
end
