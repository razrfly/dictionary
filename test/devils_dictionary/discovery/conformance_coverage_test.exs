defmodule DevilsDictionary.Discovery.ConformanceCoverageTest do
  @moduledoc """
  The architecture test: nothing registered escapes conformance.

  A suite that every provider passes is only worth having if every provider is
  in it. This is the assertion that adding the fifth provider to
  `:discovery_providers`, or the third manifest to `priv/artworks/manifests/`,
  turns the suite red until it is covered — which is what makes
  `docs/discovery/adding-a-provider.md` a checklist rather than a hope.

  Coverage is read from the files on disk, not from a list kept here, so there
  is no second place to forget.
  """

  use ExUnit.Case, async: true

  alias DevilsDictionary.Artworks.Corpus
  alias DevilsDictionary.Discovery.Conformance
  alias DevilsDictionary.Discovery.Providers

  @provider_suites "test/devils_dictionary/discovery/conformance"
  @corpus_suites "test/devils_dictionary/artworks/corpus/conformance"

  describe "discovery providers" do
    test "every registered provider has a conformance fixture" do
      covered = Map.new(fixtures(), &{&1.provider(), &1})

      for provider <- Providers.all() do
        assert Map.has_key?(covered, provider),
               """
               #{inspect(provider)} is in :discovery_providers with no conformance fixture.

               Write one in test/support/discovery/conformance/, `use
               DevilsDictionary.Discovery.Conformance.Fixture`, and add the
               one-line suite that uses it. See docs/discovery/adding-a-provider.md.
               """
      end
    end

    test "every fixture is actually run by a suite" do
      sources = suite_sources(@provider_suites)

      for fixture <- fixtures() do
        assert Enum.any?(sources, &String.contains?(&1, inspect(fixture))),
               "#{inspect(fixture)} exists but no suite in #{@provider_suites} uses it"
      end
    end

    test "each suite drives the profile the provider's own capabilities choose" do
      for fixture <- fixtures(), provider = fixture.provider() do
        # A claim without the callbacks is the shape that raises inside a queued
        # run, where nothing can recover it; the conformance profile and the
        # pipeline gate must agree about which providers those are.
        assert Conformance.pipeline?(provider) ==
                 (Conformance.declares_pipeline?(provider) and Providers.retrievable?(provider))

        # `server_providers/0` reads the registry, so this half only has an
        # answer for registered modules — the offset fixture is deliberately
        # outside it, which is how conformance proves the pipeline does not
        # depend on a provider being configured.
        if provider in Providers.all() do
          if Conformance.pipeline?(provider) do
            assert provider in Providers.server_providers() or not provider.enabled?()
          else
            refute provider in Providers.server_providers()
          end
        end
      end
    end
  end

  describe "artwork corpora" do
    test "every committed corpus manifest has a conformance suite" do
      sources = suite_sources(@corpus_suites)

      for path <- Corpus.Conformance.paths() do
        assert Enum.any?(sources, &String.contains?(&1, path)),
               """
               #{path} is a committed corpus manifest with no conformance suite.

               Add one in #{@corpus_suites}: `use
               DevilsDictionary.Artworks.Corpus.Conformance, manifest: "#{path}"`.
               """
      end
    end

    test "every JSON file in the manifests directory is one of the two known formats" do
      # #109's K6 asks for "every manifest with schema_version >= 1", and every
      # file here has one — but they are not all corpora. Four of the six are
      # the Artsy pilot's resumable *import* manifests
      # (`DevilsDictionary.Artworks.Manifest`, schema_version 2, `candidates`
      # keyed on qid + artsy_artwork_slug); two are committed corpus
      # *selections* (schema_version 1, `rows`). Conformance covers the corpora;
      # this asserts the rest are the format they claim to be rather than
      # something nobody is checking.
      corpora = Corpus.Conformance.paths()

      for path <- Path.wildcard(Path.join(Corpus.Conformance.dir(), "*.json")) do
        manifest = path |> File.read!() |> Jason.decode!()
        assert manifest["schema_version"] >= 1, "#{path} has no schema_version"

        if path in corpora do
          assert manifest["rows"], "#{path} is a corpus manifest with no rows"
          assert Corpus.Manifest.load!(path)
        else
          assert manifest["candidates"],
                 "#{path} is neither a corpus manifest nor an Artsy import manifest"

          assert DevilsDictionary.Artworks.Manifest.load!(path)
        end
      end
    end
  end

  defp fixtures do
    {:ok, modules} = :application.get_key(:devils_dictionary, :modules)

    Enum.filter(modules, fn module ->
      Code.ensure_loaded?(module) and
        Conformance.Fixture in List.wrap(module.__info__(:attributes)[:behaviour])
    end)
  end

  defp suite_sources(directory) do
    directory
    |> Path.join("*.exs")
    |> Path.wildcard()
    |> Enum.map(&File.read!/1)
  end
end
