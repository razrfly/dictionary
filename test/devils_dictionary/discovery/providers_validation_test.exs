defmodule DevilsDictionary.Discovery.ProvidersValidationTest do
  @moduledoc """
  The contract enforces what it documents (#144 Phase 0).

  `capabilities/0` is read with bare `Map.fetch!/2` deep inside `admit/5`, so
  before this a missing key was a `KeyError` raised out of the pipeline on the
  first page that happened to reach that provider. `Providers.validate!/0` runs
  at boot, for the same reason `DevilsDictionary.Discovery.ContentTypes` checks
  its rows at compile time: an invalid registry should refuse to start, not
  surprise a reader.

  Each declaration below is broken one way at a time. A module defined inside a
  test would be recompiled on every run, so the bad providers are named modules
  defined once at the bottom of this file and registered by the test that wants
  them.
  """

  use ExUnit.Case, async: false

  alias DevilsDictionary.Discovery.Providers

  setup do
    providers = Application.fetch_env!(:devils_dictionary, :discovery_providers)
    discovery = Application.fetch_env!(:devils_dictionary, :discovery)

    on_exit(fn ->
      Application.put_env(:devils_dictionary, :discovery_providers, providers)
      Application.put_env(:devils_dictionary, :discovery, discovery)
    end)

    %{providers: providers}
  end

  defp register(modules),
    do: Application.put_env(:devils_dictionary, :discovery_providers, modules)

  defp refused(modules) do
    register(modules)

    ArgumentError
    |> assert_raise(fn -> Providers.validate!() end)
    |> Exception.message()
  end

  test "the shipped registry boots", ctx do
    # The one that matters: whatever is registered on `main` has to pass the
    # check that now stands between it and a booting node.
    assert ctx.providers != []
    assert Providers.validate!() == :ok
  end

  test "a capability map missing one of the six documented keys refuses to boot" do
    message = refused([__MODULE__.MissingKeyProvider])

    assert message =~ "missing-key"
    assert message =~ "capabilities/0 is missing"
    assert message =~ ":persistence"
  end

  test "a content type the reader cannot present refuses to boot" do
    message = refused([__MODULE__.UnknownTypeProvider])

    assert message =~ "unknown-type"
    assert message =~ ":sculpture"
    assert message =~ "ContentTypes cannot present"
  end

  test "a pacing key that is not non-negative milliseconds refuses to boot" do
    # Absent is legal and means unpaced. Declared-and-unreadable is not: the
    # transport normalises it to unpaced, which is a rate the provider asked
    # for and would never notice losing.
    message = refused([__MODULE__.BadPacingProvider])

    assert message =~ "bad-pacing"
    assert message =~ "request_interval_ms"
    assert message =~ "not non-negative milliseconds"
  end

  test "a source_attrs row the catalog cannot seed refuses to boot" do
    message = refused([__MODULE__.BadAttrsProvider])

    assert message =~ "bad-attrs"
    assert message =~ "tier"
  end

  test "a module claiming the pipeline without exporting it refuses to boot" do
    message = refused([__MODULE__.UnexportedProvider])

    assert message =~ "unexported"
    assert message =~ "declares the background pipeline"
    assert message =~ "validate_mapping"
  end

  test "a source policy naming a slug no provider has refuses to boot", ctx do
    register(ctx.providers)

    config = Application.fetch_env!(:devils_dictionary, :discovery)

    Application.put_env(
      :devils_dictionary,
      :discovery,
      Keyword.put(config, :source_policies, %{
        "met" => [request_budget_limit: 10],
        "the-met" => [request_budget_limit: 10]
      })
    )

    message =
      ArgumentError
      |> assert_raise(fn -> Providers.validate!() end)
      |> Exception.message()

    # A renamed slug leaves an override that silently stops applying, which is
    # the worst shape a configuration mistake can take: the number is still
    # written down and no longer does anything.
    assert message =~ "the-met"
    refute message =~ ~s(source_policies names "met")
  end

  test "every complaint is collected, not just the first" do
    message = refused([__MODULE__.MissingKeyProvider, __MODULE__.UnknownTypeProvider])

    assert message =~ "missing-key"
    assert message =~ "unknown-type"
  end

  describe "the probes the pipeline makes of an optional callback" do
    @discovery_layer [
      "lib/devils_dictionary/discovery.ex",
      "lib/devils_dictionary/discovery/transport.ex",
      "lib/devils_dictionary/discovery/providers.ex"
    ]

    test "every one loads the module before asking whether it exports anything" do
      # `function_exported?/3` answers false for a module that is simply not
      # loaded yet, so a probe without `Code.ensure_loaded?/1` in front of it
      # reads "this provider has no identity contract" on a node where nothing
      # has happened to load it. Five of the six probes in this layer were
      # written that way and one was not (`identity_record/1`, #144 Phase 0),
      # and the difference was invisible: a durable identity silently degrading
      # to `insufficient_evidence` for the life of that node.
      #
      # Read from the source because the defect is a missing guard, which has
      # no runtime shape to assert against until the day it fires.
      for path <- @discovery_layer,
          chunk <- String.split(File.read!(path), ~r/\n  defp? /),
          String.contains?(chunk, "function_exported?(") do
        assert String.contains?(chunk, "Code.ensure_loaded?("),
               "#{path}: #{chunk |> String.split("\n") |> hd()} probes with " <>
                 "function_exported?/3 and never loads the module"
      end
    end
  end

  describe "Budget.claim/3's outcome is total" do
    test "the three rollbacks it writes, and anything else, are all refusals" do
      alias DevilsDictionary.Discovery.Budget

      assert Budget.outcome({:ok, {:ok, 0}}) == {:ok, 0}
      assert Budget.outcome({:error, {:budget_exhausted, 42}}) == {:deferred, 42}
      assert Budget.outcome({:error, {:provider_backoff, 7}}) == {:deferred, 7}
      assert Budget.outcome({:error, :attempts_exhausted}) == {:error, :attempts_exhausted}

      # The clause that was missing. A serialization failure under concurrency,
      # or the adapter's own rollback, used to raise `CaseClauseError` through
      # the transport and out of a run nothing could recover.
      assert Budget.outcome({:error, :rollback}) == {:error, :claim_failed}
      assert Budget.outcome({:error, %Postgrex.Error{}}) == {:error, :claim_failed}
    end
  end

  defmodule MissingKeyProvider do
    @moduledoc false
    def slug, do: "missing-key"
    def adapter_version, do: "v1"
    def enabled?, do: false

    def source_attrs,
      do: %{slug: "missing-key", name: "Missing Key", attribution: "None", tier: :plebs}

    def capabilities do
      %{
        background: false,
        transport: :server,
        pagination: :none,
        operations: ["search"],
        content_types: [:text]
      }
    end
  end

  defmodule UnknownTypeProvider do
    @moduledoc false
    def slug, do: "unknown-type"
    def adapter_version, do: "v1"
    def enabled?, do: false

    def source_attrs,
      do: %{slug: "unknown-type", name: "Unknown Type", attribution: "None", tier: :plebs}

    def capabilities do
      %{
        background: false,
        transport: :server,
        persistence: :persistent,
        pagination: :none,
        operations: ["search"],
        content_types: [:sculpture]
      }
    end
  end

  defmodule BadPacingProvider do
    @moduledoc false
    def slug, do: "bad-pacing"
    def adapter_version, do: "v1"
    def enabled?, do: false

    def source_attrs,
      do: %{slug: "bad-pacing", name: "Bad Pacing", attribution: "None", tier: :plebs}

    def capabilities do
      %{
        background: false,
        transport: :server,
        persistence: :persistent,
        pagination: :none,
        operations: ["search"],
        content_types: [:text],
        request_interval_ms: "3000"
      }
    end
  end

  defmodule BadAttrsProvider do
    @moduledoc false
    def slug, do: "bad-attrs"
    def adapter_version, do: "v1"
    def enabled?, do: false

    def source_attrs,
      do: %{slug: "bad-attrs", name: "Bad Attrs", attribution: "None", tier: :nobility}

    def capabilities do
      %{
        background: false,
        transport: :server,
        persistence: :persistent,
        pagination: :none,
        operations: ["search"],
        content_types: [:text]
      }
    end
  end

  defmodule UnexportedProvider do
    @moduledoc false
    def slug, do: "unexported"
    def adapter_version, do: "v1"
    def enabled?, do: true

    def source_attrs,
      do: %{slug: "unexported", name: "Unexported", attribution: "None", tier: :plebs}

    def capabilities do
      %{
        background: true,
        transport: :server,
        persistence: :persistent,
        pagination: :none,
        operations: ["search"],
        content_types: [:text]
      }
    end
  end
end
