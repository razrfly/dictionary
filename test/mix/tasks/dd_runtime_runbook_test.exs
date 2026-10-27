defmodule Mix.Tasks.Dd.RuntimeRunbookTest do
  @moduledoc """
  The runbook's commands exist and their flags parse (#267 §8 test 5). Every
  `mix dd.runtime` command in a code block of
  `docs/curation/runtime-operations.md` (the operating window, the first
  window on v2 and the rehearsal among them) is a command the task answers,
  with only switches it knows, and `mix help dd.runtime` documents each one.
  Nothing is started: the commands are parsed, not run.
  """
  use ExUnit.Case, async: true

  import ExUnit.CaptureIO

  @runbook "docs/curation/runtime-operations.md"

  # Every `mix dd.runtime …` line in a fenced block, continuations joined,
  # with its shell prompt, environment, trailing comment and the brackets
  # around optional switches taken off.
  defp runbook_commands do
    @runbook
    |> File.read!()
    |> String.split("```")
    # What lies between the fences: the odd pieces.
    |> Enum.drop_every(2)
    |> Enum.flat_map(fn block ->
      block
      |> String.replace(~r/\\\n\s*/, " ")
      |> String.split("\n")
    end)
    |> Enum.filter(&String.contains?(&1, "mix dd.runtime "))
    |> Enum.map(fn line ->
      [_before, args] = String.split(line, "mix dd.runtime ", parts: 2)

      args
      |> String.split(" #", parts: 2)
      |> hd()
      |> String.replace(["[", "]"], "")
      |> OptionParser.split()
    end)
  end

  test "every runbook command is a command of the task, and its flags parse" do
    commands = runbook_commands()

    # The operating window's and the rehearsal's are among them.
    for expected <- [
          ~w(service start --rebind),
          ~w(rehearse --model-config qwen3.5-9b-v2 --scope love --dry-run),
          ~w(rehearse --model-config qwen3.5-9b-v2 --scope love),
          ~w(ready --model-config qwen3.5-9b-v2 --smoke),
          ~w(service stop)
        ] do
      assert expected in commands,
             "the runbook has no `mix dd.runtime #{Enum.join(expected, " ")}`"
    end

    assert length(commands) > 20

    for args <- commands do
      {_opts, rest} = Mix.Tasks.Dd.Runtime.parse!(args)

      assert rest in Mix.Tasks.Dd.Runtime.commands(),
             "`mix dd.runtime #{Enum.join(args, " ")}` is not a command"
    end
  end

  test "an unknown switch does not parse" do
    assert_raise Mix.Error, ~r/unknown options/, fn ->
      Mix.Tasks.Dd.Runtime.parse!(~w(rehearse --scope love --dry-rn))
    end
  end

  test "`mix help dd.runtime` documents every command and switch the runbook uses" do
    help = capture_io(fn -> Mix.Tasks.Help.run(["dd.runtime"]) end)

    assert help =~ "mix dd.runtime rehearse --model-config SLUG --scope SLUG --dry-run"

    for args <- runbook_commands() do
      {opts, [command | words] = rest} = Mix.Tasks.Dd.Runtime.parse!(args)

      # `service start|stop|restart|status` is one line of the help.
      assert help =~ "mix dd.runtime #{command}", inspect(rest)
      for word <- words, do: assert(help =~ word, inspect(rest))

      for {switch, _value} <- opts do
        flag = "--" <> String.replace(to_string(switch), "_", "-")
        assert help =~ flag, "#{flag} is not in mix help dd.runtime"
      end
    end
  end
end
