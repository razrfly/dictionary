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

  @no_echo_refusal "cannot turn off this terminal's echo, and a password is never read echoed: " <>
                     "pipe it instead (for example `read -rs PW` in zsh, then " <>
                     "`printf '%s\\n' \"$PW\" | DD_NO_OBAN=1 mix dd.routing.rule --sign ...`)"

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

  # The password, never echoed. From a pipe, one line, which nothing echoes.
  # On a terminal, the terminal's echo is turned off by its device's name and
  # one line is read, echo turned back on whatever happens. By name, because
  # neither simpler way works under mix: `:io.get_password/0` answers
  # `{:error, :enotsup}` in mix's -noshell mode even on a terminal, and a
  # program the BEAM starts runs in its own session, with no controlling
  # terminal, so `stty < /dev/tty` reaches nothing. Where echo cannot be
  # turned off, the task refuses rather than read an echoed password.
  defp password!(email) do
    Mix.shell().info("password for #{email}:")

    line =
      case terminal() do
        :none -> read_line()
        {:ok, device} -> without_echo(device, &read_line/0)
        :unknown -> Mix.raise(@no_echo_refusal)
      end

    if line == "", do: Mix.raise("no password given"), else: line
  end

  defp read_line do
    case IO.gets("") do
      line when is_binary(line) ->
        line |> String.trim_trailing("\n") |> String.trim_trailing("\r")

      _eof_or_error ->
        ""
    end
  end

  # `:none` when standard input is not a terminal (a pipe); `{:ok, device}`,
  # the terminal's device path, when it is and the device can be named;
  # `:unknown` when it is a terminal the task cannot name.
  defp terminal do
    io = :io.getopts()

    if is_list(io) and Keyword.get(io, :terminal, false) == true do
      case System.cmd("ps", ["-o", "tty=", "-p", System.pid()], stderr_to_stdout: true) do
        {tty, 0} ->
          case String.trim(tty) do
            name when name in ["", "?", "??"] -> :unknown
            name -> {:ok, "/dev/" <> name}
          end

        _failed ->
          :unknown
      end
    else
      :none
    end
  end

  # Runs `read` with the terminal's echo off, and turns it back on after,
  # whatever happens. Refuses before reading if echo cannot be turned off.
  defp without_echo(device, read) do
    unless stty(device, "-echo"), do: Mix.raise(@no_echo_refusal)

    try do
      read.()
    after
      stty(device, "echo")
      IO.write("\n")
    end
  end

  # BSD stty names a device with -f, GNU stty with -F.
  defp stty(device, setting) do
    flag = if match?({:unix, :darwin}, :os.type()), do: "-f", else: "-F"
    match?({_, 0}, System.cmd("stty", [flag, device, setting], stderr_to_stdout: true))
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
