defmodule DevilsDictionary.Tasks.DdProviderNewTest do
  @moduledoc """
  The generator, proved by generating (K7 of #109).

  The strongest thing this file can assert without a nested `mix test` is that
  the scaffold **compiles and runs through the real pipeline with its own
  generated stub** — admission, cache, pagination and the reader, driven by
  `DevilsDictionary.Discovery` exactly as conformance drives them. Everything is
  written into a temporary directory and compiled from there, so the repository
  is never touched; the full 19-case conformance suite on a generated provider
  is the verification step in the PR, run against a real `mix dd.provider.new
  demo` and then deleted.
  """

  use DevilsDictionary.DataCase, async: false

  alias DevilsDictionary.Discovery
  alias DevilsDictionary.Discovery.Conformance
  alias DevilsDictionary.Discovery.Providers
  alias DevilsDictionary.Discovery.Run
  alias Mix.Tasks.Dd.Provider.New

  setup do
    Mix.shell(Mix.Shell.Process)
    on_exit(fn -> Mix.shell(Mix.Shell.IO) end)
    :ok
  end

  describe "refusals" do
    test "an unknown content type is refused with the list of valid ones", %{} do
      assert_raise Mix.Error, ~r/film, artwork, text, gif/, fn ->
        run(~w(thing --archetype discovery --content-type sculpture --transport get
               --pagination offset))
      end
    end

    test "a missing flag is refused with its own valid values" do
      assert_raise Mix.Error, ~r/--archetype is required.*discovery, corpus, both/s, fn ->
        run(~w(thing --content-type text --transport get --pagination offset))
      end

      assert_raise Mix.Error, ~r/--content-type is required/, fn ->
        run(~w(thing --archetype discovery --transport get --pagination offset))
      end

      assert_raise Mix.Error, ~r/--transport is required.*get, graphql/s, fn ->
        run(~w(thing --archetype discovery --content-type text --pagination offset))
      end

      assert_raise Mix.Error, ~r/--pagination is required.*offset, cursor/s, fn ->
        run(~w(thing --archetype discovery --content-type text --transport get))
      end
    end

    test "an out-of-range flag value is refused with the same list" do
      assert_raise Mix.Error, ~r/--transport "ftp" is not valid.*get, graphql/s, fn ->
        run(~w(thing --archetype discovery --content-type text --transport ftp
               --pagination offset))
      end
    end

    test "a slug that cannot name a source row, a config key and a file is refused" do
      assert_raise Mix.Error, ~r/is not a usable provider slug/, fn ->
        run(~w(Open_Library --archetype corpus))
      end
    end

    test "an existing file is never overwritten", %{} do
      root = tmp!()
      slug = slug()

      run(~w(#{slug} --archetype corpus --root #{root}))

      assert_raise Mix.Error, ~r/refusing to overwrite/, fn ->
        run(~w(#{slug} --archetype corpus --root #{root}))
      end
    end

    test "a collision on a later output leaves nothing behind", %{} do
      root = tmp!()
      slug = slug()
      flags = ~w(--archetype discovery --content-type text --transport get --pagination offset)

      # The ledger is the last of the four files the discovery scaffold writes.
      # Only it exists, so the first three paths are free and a task that
      # checked as it went would write them and then raise.
      ledger = Path.join(root, "docs/integrations/#{slug}.md")
      File.mkdir_p!(Path.dirname(ledger))
      File.write!(ledger, "a ledger somebody already started\n")

      assert_raise Mix.Error, ~r/docs\/integrations\/#{slug}\.md/, fn ->
        run([slug, "--root", root] ++ flags)
      end

      for relative <- [
            "lib/devils_dictionary/discovery/providers/#{underscore(slug)}.ex",
            "test/support/discovery/conformance/#{underscore(slug)}_fixture.ex",
            "test/devils_dictionary/discovery/conformance/#{underscore(slug)}_conformance_test.exs"
          ] do
        refute File.exists?(Path.join(root, relative)),
               "#{relative} was written despite a collision on a later output"
      end

      assert File.read!(ledger) == "a ledger somebody already started\n"
    end
  end

  describe "the discovery scaffold" do
    test "writes the four files and compiles into a provider the pipeline accepts" do
      %{root: root, module: module, fixture: fixture, slug: slug} =
        generate(~w(--archetype discovery --content-type text --transport get
                    --pagination offset))

      for relative <- [
            "lib/devils_dictionary/discovery/providers/#{underscore(slug)}.ex",
            "test/support/discovery/conformance/#{underscore(slug)}_fixture.ex",
            "test/devils_dictionary/discovery/conformance/#{underscore(slug)}_conformance_test.exs",
            "docs/integrations/#{slug}.md"
          ] do
        assert File.exists?(Path.join(root, relative)), "#{relative} was not written"
      end

      assert module.slug() == slug
      assert module.source_attrs().slug == slug
      assert module.capabilities().pagination == :offset
      assert module.capabilities().content_types == [:text]

      # The two gates a provider has to pass before the worker will touch it.
      assert Providers.retrievable?(module)
      assert Conformance.pipeline?(module)

      assert fixture.provider() == module

      assert Conformance.Fixture in List.wrap(fixture.__info__(:attributes)[:behaviour])

      suite =
        File.read!(
          Path.join(
            root,
            "test/devils_dictionary/discovery/conformance/#{underscore(slug)}_conformance_test.exs"
          )
        )

      assert suite =~ "use DevilsDictionary.Discovery.Conformance"
      assert suite =~ inspect(fixture)
    end

    for transport <- ~w(get graphql), pagination <- ~w(offset cursor) do
      test "#{transport} over #{pagination} paging compiles and pages" do
        %{module: module, fixture: fixture} =
          generate(~w(--archetype discovery --content-type text
                      --transport #{unquote(transport)} --pagination #{unquote(pagination)}))

        assert module.capabilities().pagination == String.to_existing_atom(unquote(pagination))

        context = pipeline_context(module)
        target = fixture.covered_target(context)
        %{pages: [first, second]} = fixture.stub(:paged, context)

        assert {:queued, run} = Discovery.request(target, module.slug())
        assert :ok = Discovery.execute_run(run.id)

        state = Discovery.state(target.object_id, module.slug())
        assert Enum.map(state.items, & &1.external_id) == first
        assert is_binary(state.next_cursor)

        assert {:queued, next} =
                 Discovery.request_next(
                   target.object_id,
                   module.slug(),
                   state.page_context,
                   state.page,
                   state.next_cursor
                 )

        assert :ok = Discovery.execute_run(next.id)

        paged = Discovery.state(target.object_id, module.slug())
        assert Enum.map(paged.items, & &1.external_id) == first ++ second
      end
    end

    test "the scaffold answers a page, caches the answer and caches an empty one" do
      %{module: module, fixture: fixture} =
        generate(~w(--archetype discovery --content-type text --transport get
                    --pagination offset))

      context = pipeline_context(module)
      target = fixture.covered_target(context)
      %{pages: [ids]} = fixture.stub(:results, context)

      assert {:queued, run} = Discovery.request(target, module.slug())
      assert :ok = Discovery.execute_run(run.id)

      state = Discovery.state(target.object_id, module.slug())
      assert state.status == :ready
      assert Enum.map(state.items, & &1.external_id) == ids
      assert {:cached, _run} = Discovery.request(target, module.slug())
      assert Repo.aggregate(Run, :count) == 1
    end

    test "an empty answer from the scaffold is a negative cache, not a failure" do
      %{module: module, fixture: fixture} =
        generate(~w(--archetype discovery --content-type text --transport get
                    --pagination offset))

      context = pipeline_context(module)
      target = fixture.covered_target(context)
      %{pages: [[]]} = fixture.stub(:empty, context)

      assert {:queued, run} = Discovery.request(target, module.slug())
      assert :ok = Discovery.execute_run(run.id)
      assert %{status: :empty, items: []} = Discovery.state(target.object_id, module.slug())
      assert {:cached, _cached} = Discovery.request(target, module.slug())
    end
  end

  describe "the corpus scaffold" do
    test "writes the builder and names the two edits it cannot make" do
      %{root: root, slug: slug, output: output} = generate(~w(--archetype corpus))

      builder = Path.join(root, "lib/devils_dictionary/artworks/corpus/#{underscore(slug)}.ex")
      assert File.exists?(builder)

      source = File.read!(builder)
      assert source =~ "@kind \"#{slug}\""
      assert source =~ "Manifest.new"
      assert source =~ ~S(priv/artworks/manifests/#{@kind}-v1.json)

      # The claim the moduledoc makes: without the two edits, building this
      # manifest raises rather than writing a file nothing can seed.
      assert_raise KeyError, fn -> DevilsDictionary.Artworks.Corpus.Manifest.new(slug, []) end

      # A corpus registers in two pattern matches rather than in config, and the
      # task says which rather than guessing at the second one.
      assert output =~ "@kinds in"
      assert output =~ "corpus/manifest.ex"
      assert output =~ "corpus/seeder.ex"

      # No discovery module, no config change: `--archetype corpus` is one half.
      refute File.exists?(
               Path.join(root, "lib/devils_dictionary/discovery/providers/#{underscore(slug)}.ex")
             )
    end
  end

  describe "the config entries" do
    test "register the module and write both environments' stanzas" do
      root = tmp!()
      File.mkdir_p!(Path.join(root, "config"))
      File.cp!("config/config.exs", Path.join(root, "config/config.exs"))
      File.cp!("config/test.exs", Path.join(root, "config/test.exs"))

      slug = slug()

      run(~w(#{slug} --archetype discovery --content-type text --transport get
             --pagination offset --root #{root}))

      config = File.read!(Path.join(root, "config/config.exs"))
      test_config = File.read!(Path.join(root, "config/test.exs"))
      module = "DevilsDictionary.Discovery.Providers.#{camelize(slug)}"

      assert config =~ "  #{module},\n" or config =~ "  #{module}\n"
      assert config =~ "config :devils_dictionary, :#{underscore(slug)},"
      assert test_config =~ "config :devils_dictionary, :#{underscore(slug)},"

      # The registry stays sorted and keeps everyone it already had.
      [_whole, body] =
        Regex.run(~r/config :devils_dictionary, :discovery_providers, \[\n(.*?)\n\]/s, config)

      entries = body |> String.split(",\n") |> Enum.map(&String.trim/1)
      assert entries == Enum.sort(entries)
      assert "DevilsDictionary.Discovery.Providers.Met" in entries
      assert module in entries
    end
  end

  # ------------------------------------------------------------------ helpers

  defp generate(flags) do
    root = tmp!()
    slug = slug()

    assert run(flags ++ ~w(#{slug} --root #{root}))
    output = shell_output()

    module = compile(root, "lib/devils_dictionary/discovery/providers/#{underscore(slug)}.ex")

    fixture =
      compile(root, "test/support/discovery/conformance/#{underscore(slug)}_fixture.ex")

    %{root: root, slug: slug, module: module, fixture: fixture, output: output}
  end

  defp compile(root, relative) do
    path = Path.join(root, relative)

    if File.exists?(path) do
      [{module, _binary} | _] = Code.compile_file(path)
      module
    end
  end

  # Everything the conformance suite's own setup does, for a module that exists
  # only in this test's memory.
  defp pipeline_context(module) do
    catalog = DevilsDictionary.Fixtures.seed_catalog!()
    key = String.to_atom(underscore(module.slug()))

    providers = Application.fetch_env!(:devils_dictionary, :discovery_providers)
    req_options = Application.fetch_env!(:devils_dictionary, :discovery_req_options)

    Application.put_env(:devils_dictionary, :discovery_providers, [module])
    Application.put_env(:devils_dictionary, :discovery_req_options, plug: {Req.Test, module})

    Application.put_env(:devils_dictionary, key,
      endpoint: "https://#{module.slug()}.test/api",
      enabled: true
    )

    on_exit(fn ->
      Application.put_env(:devils_dictionary, :discovery_providers, providers)
      Application.put_env(:devils_dictionary, :discovery_req_options, req_options)
      Application.delete_env(:devils_dictionary, key)
    end)

    %{sources: catalog.sources, scopes: catalog.scopes}
  end

  defp run(args), do: New.run(args)

  # `Mix.Shell.Process` sends what the task printed here rather than to the
  # terminal, which is the only way to assert on the two edits the corpus
  # scaffold says it could not make — that message goes to stderr.
  defp shell_output(acc \\ []) do
    receive do
      {:mix_shell, _kind, [message]} -> shell_output([message | acc])
    after
      0 -> acc |> Enum.reverse() |> Enum.join("\n")
    end
  end

  defp tmp! do
    path =
      Path.join(
        System.tmp_dir!(),
        "dd-provider-new-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(path)
    on_exit(fn -> File.rm_rf(path) end)
    path
  end

  # A fresh slug per test: the generated modules are compiled into this VM and
  # two tests sharing a name would redefine one another's.
  defp slug, do: "gen#{System.unique_integer([:positive])}"

  defp underscore(slug), do: String.replace(slug, "-", "_")
  defp camelize(slug), do: slug |> underscore() |> Macro.camelize()
end
