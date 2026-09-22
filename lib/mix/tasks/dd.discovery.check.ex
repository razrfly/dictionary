defmodule Mix.Tasks.Dd.Discovery.Check do
  use Mix.Task
  @shortdoc "Preflight every registered discovery provider's configuration"

  @moduledoc """
  Run `mix dd.discovery.check` in the same environment as the server before a
  discovery demo or deployment. It checks configuration only; live verification
  of a credential remains a separate gate.

      mix dd.discovery.check

  Every registered provider, one row each, from
  `DevilsDictionary.Discovery.Providers.all()`: whether the pipeline can drive
  it or the reader's browser can, whether its own `enabled?/0` says it is
  ready, what its `:enabled` switch is set to, which of the environment names
  `allowed_provider_env` admits under its prefix arrived, whether its endpoints
  are endpoints, and whether its policy keys are keys `Policy` knows.

  Until #144 Phase 4 this task checked **CineGraph**, by name, and had done
  since the second provider was added: eleven of the twelve providers could be
  misconfigured in every way this task exists to catch and it would still print
  *configuration ready*. Nothing here names a provider, so the thirteenth is
  checked the day it is registered and this file is not edited.

  ## What it never prints

  A credential value, in any form. The presence map this reads is built in
  `config/runtime.exs`, which is the only scope holding both the exported
  environment and the development `.env`; what it publishes is one boolean per
  admitted name. Endpoints *are* printed — they are in `config/config.exs` in
  the open — after the check that they carry no userinfo, query or fragment,
  which is where a credential hides in a URL.

  ## What fails the preflight

  A misconfiguration: an endpoint that is not an `http(s)` endpoint, a policy
  override `Policy` cannot read, a registry `Providers.validate!/0` refuses, or
  a provider that can neither be run nor rendered.

  A **missing credential does not**. A keyless checkout is a legitimate
  deployment of this application — the provider registers, `enabled?/0` is
  false, and the shelf is simply not there — and a preflight that exited
  non-zero on it would be a gate against a state the system is designed to
  have. The summary line says how many providers are ready, and that is the
  number a demo cares about.
  """

  @requirements ["app.config"]

  alias DevilsDictionary.Discovery.{Providers, Status}

  @impl Mix.Task
  def run([]) do
    # First, and on its own: a registry `validate!/0` refuses is one whose
    # modules cannot be asked anything. Asking a module that does not export
    # `enabled?/0` whether it is enabled raises `UndefinedFunctionError` from
    # inside the preflight, which is a worse report of the same fault than the
    # sentence the boot check already writes.
    case validate_registry() do
      [] -> :ok
      problems -> raise_on(problems)
    end

    rows = Status.preflight()

    providers(rows)
    credentials(rows)
    summary(rows)

    case Enum.flat_map(rows, & &1.problems) do
      [] ->
        say(
          "\n  Configuration only. A present credential has not been used against the provider yet."
        )

      problems ->
        raise_on(problems)
    end
  end

  def run(_), do: Mix.raise("usage: mix dd.discovery.check")

  defp raise_on(problems) do
    Mix.raise("discovery configuration is not ready:\n  " <> Enum.join(problems, "\n  ") <> "\n")
  end

  # The boot-time check, run here rather than repeated here. It is what refuses
  # a node whose registry holds a module that cannot be read as a provider at
  # all (#144 Phase 0), and a preflight that re-asked its questions would be a
  # second answer to drift from the first.
  defp validate_registry do
    Providers.validate!()
    []
  rescue
    error in ArgumentError -> [Exception.message(error)]
  end

  defp providers(rows) do
    say("\nPROVIDERS (#{length(rows)} registered)")
    width = width(rows)

    say(
      "  " <>
        pad("provider", width) <>
        pad("kind", 9) <> pad("ready", 8) <> pad("switch", 8) <> pad("policy", 8) <> "endpoints"
    )

    for row <- rows do
      say(
        "  " <>
          pad(row.slug, width) <>
          pad(to_string(row.kind), 9) <>
          pad(if(row.enabled, do: "yes", else: "no"), 8) <>
          pad(to_string(row.switch), 8) <>
          pad(policy(row.policy), 8) <> endpoints(row.endpoints)
      )
    end
  end

  defp policy({:ok, _policy}), do: "ok"
  defp policy({:error, _message}), do: "INVALID"

  defp endpoints([]), do: "—"

  defp endpoints(endpoints) do
    Enum.map_join(endpoints, "  ", fn
      {_key, url, :ok} -> url
      {key, url, :invalid} -> "#{key}=#{url} REFUSED"
    end)
  end

  # Names and whether they arrived. The provider a name belongs to is its
  # environment prefix, so this is a report about `allowed_provider_env` and
  # the registry, and not a list anybody maintains twice.
  defp credentials(rows) do
    say("\nCREDENTIALS (names only — no value is read to print this)")

    say(
      "  missing is a name this environment does not set. Whether that matters is the" <>
        " provider's answer above, not this line's: a switch left unset is its default."
    )

    width = width(rows)
    keyed = Enum.reject(rows, &(&1.credentials == []))

    if keyed == [] do
      say("  no registered provider claims an admitted environment name")
    else
      for row <- keyed, do: say("  " <> pad(row.slug, width) <> names(row.credentials))
    end

    case Status.unclaimed_credentials() do
      [] ->
        :ok

      unclaimed ->
        say("  " <> pad("(unclaimed)", width) <> names(unclaimed))

        say(
          "  Admitted by allowed_provider_env and read by no registered provider — Artsy's are\n" <>
            "  kept deliberately (#144 §4). Not a fault; a credential nothing asks for."
        )
    end
  end

  defp names(credentials) do
    Enum.map_join(credentials, " · ", fn {name, status} -> "#{name} #{status}" end)
  end

  defp summary(rows) do
    ready = Enum.count(rows, & &1.enabled)
    off = Enum.count(rows, &(&1.switch == :off))
    waiting = Enum.count(rows, &(not &1.enabled and &1.switch != :off))

    say(
      "\n  #{ready}/#{length(rows)} ready · #{off} switched off · " <>
        "#{waiting} waiting for a credential"
    )
  end

  # As wide as the widest slug, because the registry is the one column width
  # this file cannot know in advance.
  defp width(rows) do
    rows |> Enum.map(&String.length(&1.slug)) |> Enum.max(fn -> 0 end) |> max(12) |> Kernel.+(2)
  end

  defp pad(value, width), do: String.pad_trailing(value, width)
  defp say(line), do: Mix.shell().info(line)
end
