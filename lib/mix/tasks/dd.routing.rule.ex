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
  and only then writes the signature into the file: the signer's email and
  id, the digest signed, the time and an attestation. Refuses a rule that is
  already signed. Nothing is written to the database.

  Nobody may sign for the owner: the task needs the account's password,
  which only its holder types.
  """

  use Mix.Task

  alias DevilsDictionary.Routing.ReviewRule

  @requirements ["app.start"]

  @impl Mix.Task
  def run(args) do
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

  # The password, never echoed: from the terminal without echo, or one line
  # from a pipe.
  defp password!(email) do
    Mix.shell().info("password for #{email}:")

    case :io.get_password() do
      password when is_list(password) and password != [] ->
        List.to_string(password)

      _ ->
        case IO.gets("") do
          line when is_binary(line) and line != "" -> String.trim_trailing(line, "\n")
          _ -> Mix.raise("no password given")
        end
    end
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
