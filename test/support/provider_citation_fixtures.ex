defmodule DevilsDictionary.ProviderCitationFixtures do
  @moduledoc "Adapter-produced observations from committed Req.Test conformance responses; never network."
  import ExUnit.Assertions
  import ExUnit.Callbacks
  alias DevilsDictionary.{Discovery, Repo, Sources}
  alias DevilsDictionary.Discovery.Run

  @fixtures %{
    "guardian" => DevilsDictionary.Discovery.Conformance.GuardianFixture,
    "bing-news" => DevilsDictionary.Discovery.Conformance.BingNewsFixture,
    "spotify" => DevilsDictionary.Discovery.Conformance.SpotifyFixture,
    "pexels" => DevilsDictionary.Discovery.Conformance.PexelsFixture,
    "unsplash" => DevilsDictionary.Discovery.Conformance.UnsplashFixture,
    "openverse" => DevilsDictionary.Discovery.Conformance.OpenverseFixture,
    "commons" => DevilsDictionary.Discovery.Conformance.CommonsFixture,
    "met" => DevilsDictionary.Discovery.Conformance.MetFixture,
    "cinegraph" => DevilsDictionary.Discovery.Conformance.CineGraphFixture,
    "open-library" => DevilsDictionary.Discovery.Conformance.OpenLibraryFixture,
    "poetrydb" => DevilsDictionary.Discovery.Conformance.PoetrydbFixture,
    "wikiquote" => DevilsDictionary.Discovery.Conformance.WikiquoteFixture
  }
  def provider_observation!(world, slug) do
    fixture = Map.fetch!(@fixtures, slug)
    provider = fixture.provider()

    saved =
      for key <- [:discovery_providers, :discovery_req_options, :discovery],
          do: {key, Application.fetch_env!(:devils_dictionary, key)}

    on_exit(fn ->
      for {key, value} <- saved, do: Application.put_env(:devils_dictionary, key, value)
    end)

    Application.put_env(:devils_dictionary, :discovery_providers, [provider])
    Application.put_env(:devils_dictionary, :discovery_req_options, plug: {Req.Test, provider})
    DevilsDictionary.Discovery.Conformance.stub_wikidata_humans()
    catalog = DevilsDictionary.Fixtures.seed_catalog!()
    context = %{sources: catalog.sources, scopes: catalog.scopes, slug: slug, provider: provider}
    context = Map.merge(context, fixture.setup(context))
    target = fixture.covered_target(context)
    %{pages: [expected | _]} = fixture.stub(:results, context)
    assert {:queued, run} = Discovery.request(target, slug)
    assert :ok = Discovery.execute_run(run.id)
    assert Repo.get!(Run, run.id).status == :succeeded
    state = Discovery.state(target.object_id, slug)
    assert Enum.map(state.items, & &1.external_id) == expected
    [row | _] = state.items
    record = Repo.get!(DevilsDictionary.Sources.SourceRecord, row.source_record_id)
    raw = Sources.raw(record)
    # Reuse the adapter's complete raw shape and declared match/metadata, with a
    # valid manual mapping on the fixture curation page. No content is authored.
    o =
      DevilsDictionary.CitationFixtures.observation!(world, slug,
        external_id: row.external_id,
        namespace: row.external_namespace,
        metadata: row.preview_metadata,
        matches: row.match_details,
        raw: raw
      )

    assert o.raw == raw
    assert provider.validate_mapping(o.mapping.operation, o.mapping.parameters) == :ok

    assert Enum.any?(
             Discovery.citable(world.love.object_id),
             &(&1.result.id == o.result.id and &1.status == :ok)
           )

    Map.put(o, :adapter_run_id, run.id)
  end
end
