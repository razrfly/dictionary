defmodule DevilsDictionaryWeb.IndexingTest do
  @moduledoc """
  The one module that says what may be indexed (#237 C4): every route the
  router serves is on a surface it names; a subject page is indexable only
  published, active, at its canonical, publicly, with the switch on and no
  query string; an On page only as a lexical entry of the launch manifest
  whose subject is published; and `robots.txt`'s kept-out prefixes come
  from the registry and never name a reader's route.
  """
  use DevilsDictionary.DataCase, async: false

  import DevilsDictionary.OnFixtures
  import DevilsDictionary.RoutingFixtures, only: [human!: 0]

  alias DevilsDictionary.Routing.{Address, LaunchManifest, Page}
  alias DevilsDictionaryWeb.Indexing

  defp with_env(key, value, fun) do
    previous = Application.get_env(:devils_dictionary, key)

    if is_nil(value),
      do: Application.delete_env(:devils_dictionary, key),
      else: Application.put_env(:devils_dictionary, key, value)

    try do
      fun.()
    after
      if is_nil(previous),
        do: Application.delete_env(:devils_dictionary, key),
        else: Application.put_env(:devils_dictionary, key, previous)
    end
  end

  defp switch(on?, fun), do: with_env(:public_routing, on?, fun)

  defp lexical(path, page_ids) do
    %{
      "kind" => "lexical",
      "locale" => "en",
      "path" => path,
      "lexeme_ids" => [],
      "subject_page_ids" => page_ids,
      "reviewer" => "reviewer@example.test",
      "clause" => "index_lexical"
    }
  end

  defp with_manifest(entries, fun) do
    file =
      Path.join(System.tmp_dir!(), "launch-manifest-#{System.unique_integer([:positive])}.json")

    File.write!(
      file,
      Jason.encode!(%{"format" => LaunchManifest.format(), "entries" => entries})
    )

    try do
      with_env(:launch_manifest, file, fun)
    after
      File.rm(file)
    end
  end

  test "every route the router serves is on a surface the module names" do
    for route <- Phoenix.Router.routes(DevilsDictionaryWeb.Router) do
      assert Indexing.surface(route.path), "#{route.path} is on no noindex surface"
    end

    # The surfaces #237 names, and the two that are indexable by exception.
    for path <- [
          "/",
          "/entities/:id/:slug",
          "/words/:id/:slug",
          "/evidence/content/:id",
          "/connections/:id",
          "/connect",
          "/sources/:slug",
          "/ops/health",
          "/kit",
          "/dev/dashboard",
          "/users/log-in",
          "/reconciliation",
          "/artworks",
          "/people/:slug",
          "/on/:slug"
        ] do
      assert {surface, why} = Indexing.surface(path), path
      assert is_binary(surface) and is_binary(why)
    end

    assert Indexing.surface("/nowhere/x") == nil

    assert Enum.any?(Indexing.surfaces(), fn {surface, _why} ->
             surface =~ "?demo" and surface =~ "any query string"
           end)
  end

  test "subject?: published, active, at its canonical, publicly, with the switch on, no query" do
    page = %Page{publication_state: :published, lifecycle_state: :active, role: :subject}

    assert Indexing.subject?(page, :canonical, :public, nil)
    assert Indexing.subject?(page, :canonical, :public, "")
    assert Indexing.subject?(%{page | role: :edition}, :canonical, :public, nil)

    refute Indexing.subject?(%{page | publication_state: :draft}, :canonical, :public, nil)
    refute Indexing.subject?(%{page | publication_state: :withdrawn}, :canonical, :public, nil)

    for lifecycle <- [:merged, :split, :retired] do
      refute Indexing.subject?(%{page | lifecycle_state: lifecycle}, :canonical, :public, nil)
    end

    refute Indexing.subject?(%{page | role: :overview}, :canonical, :public, nil)
    refute Indexing.subject?(page, :redirect, :public, nil)
    refute Indexing.subject?(page, :choice, :public, nil)
    refute Indexing.subject?(page, :canonical, :internal, nil)
    refute Indexing.subject?(page, :canonical, :public, "works_after=1")
    refute Indexing.subject?(page, :canonical, :public, "demo=1")
    refute Indexing.subject?(nil, :canonical, :public, nil)

    switch(false, fn -> refute Indexing.subject?(page, :canonical, :public, nil) end)
  end

  test "lexical?: a listed On page whose subject is published, publicly, with the switch on, no query" do
    human = human!()

    voltaire =
      subject!("Voltaire", "people",
        kind: :person,
        path: "/people/voltaire",
        published: true,
        actor: human
      )

    draft = subject!("Arouet", "people", kind: :person, path: "/people/arouet")

    with_manifest(
      [
        lexical("/on/voltaire", [voltaire.page.id]),
        lexical("/on/arouet", [draft.page.id]),
        lexical("/on/nobody", [])
      ],
      fn ->
        assert Indexing.lexical_entries() == %{
                 "/on/voltaire" => [voltaire.page.id],
                 "/on/arouet" => [draft.page.id],
                 "/on/nobody" => []
               }

        assert Indexing.lexical?("voltaire", :public, nil)
        assert Indexing.lexical?("voltaire", :public, "")
        refute Indexing.lexical?("arouet", :public, nil)
        refute Indexing.lexical?("nobody", :public, nil)
        refute Indexing.lexical?("oyster", :public, nil)
        refute Indexing.lexical?("Voltaire", :public, nil)
        refute Indexing.lexical?("voltaire", :internal, nil)
        refute Indexing.lexical?("voltaire", :public, "trail=oyster")
        refute Indexing.lexical?(nil, :public, nil)
        switch(false, fn -> refute Indexing.lexical?("voltaire", :public, nil) end)

        withdrawn!(voltaire.page)
        refute Indexing.lexical?("voltaire", :public, nil)
      end
    )

    # No manifest, or one that does not read: nothing is listed.
    with_env(:launch_manifest, "/nonexistent/launch-manifest.json", fn ->
      assert Indexing.lexical_entries() == %{}
      refute Indexing.lexical?("voltaire", :public, nil)
    end)

    file = Path.join(System.tmp_dir!(), "bad-manifest-#{System.unique_integer([:positive])}.json")
    File.write!(file, "{not json")

    try do
      with_env(:launch_manifest, file, fn -> assert Indexing.lexical_entries() == %{} end)
    after
      File.rm(file)
    end
  end

  test "robots.txt keeps crawlers out of what is not for reading, never out of a reader's route" do
    for prefix <- ~w(ops evidence connections connect users dev kit search reconciliation admin) do
      assert prefix in Indexing.kept_out(), prefix
    end

    for prefix <-
          ~w(on words entities sources artworks assets images fonts l) ++ Address.families() do
      refute prefix in Indexing.kept_out(), prefix
    end

    assert Indexing.robots(true) == nil
    assert Indexing.robots(false) == "noindex"
    assert Indexing.no_query?(nil) and Indexing.no_query?("")
    refute Indexing.no_query?("q=1")
  end
end
