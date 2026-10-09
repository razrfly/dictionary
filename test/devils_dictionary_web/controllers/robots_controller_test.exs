defmodule DevilsDictionaryWeb.RobotsControllerTest do
  @moduledoc """
  `robots.txt` (#237 C5): generated from the switch, the registry's reserved
  prefixes and the launch manifest. On, the families and the listed On pages
  are allowed and the sitemap is named; off (D5), the families are
  disallowed and no sitemap is named; always, the surfaces that are not for
  reading and every query variant are disallowed, and the assets a page
  renders with are allowed.

  The file is read as a crawler reads it (RFC 9309: the longest matching
  rule wins, an Allow wins a tie, `*` is any run, `$` ends the path), not
  line by line: a bare `Disallow: /s` once kept crawlers from the sitemap
  it named and from every source page.
  """
  use DevilsDictionaryWeb.ConnCase, async: false

  import DevilsDictionary.OnFixtures
  import DevilsDictionary.RoutingFixtures, only: [human!: 0]

  alias DevilsDictionary.Routing.{Address, LaunchManifest, PublicRouting}
  alias DevilsDictionaryWeb.Indexing

  defp with_env(key, value, fun) do
    previous = Application.get_env(:devils_dictionary, key)
    Application.put_env(:devils_dictionary, key, value)

    try do
      fun.()
    after
      if is_nil(previous),
        do: Application.delete_env(:devils_dictionary, key),
        else: Application.put_env(:devils_dictionary, key, previous)
    end
  end

  defp switch(on?, fun), do: with_env(:public_routing, on?, fun)

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

  defp lines(conn) do
    response = get(conn, "/robots.txt")
    assert response.status == 200
    assert hd(get_resp_header(response, "content-type")) =~ "text/plain"
    assert String.ends_with?(response.resp_body, "\n")
    String.split(response.resp_body, "\n", trim: true)
  end

  @kept_out ~w(ops evidence connections connect users dev kit search)

  # RFC 9309 §2.2.2: the longest matching rule wins; an Allow wins a tie.
  defp allowed?(body, url) do
    body
    |> String.split("\n", trim: true)
    |> Enum.flat_map(fn line ->
      case String.split(line, ":", parts: 2) do
        [kind, pattern] when kind in ["Allow", "Disallow"] ->
          pattern = String.trim(pattern)

          if pattern != "" and matches?(pattern, url),
            do: [{byte_size(pattern), kind == "Allow"}],
            else: []

        _ ->
          []
      end
    end)
    |> Enum.max(fn -> {0, true} end)
    |> elem(1)
  end

  defp matches?(pattern, url) do
    {pattern, anchor} =
      if String.ends_with?(pattern, "$"),
        do: {String.trim_trailing(pattern, "$"), "\\z"},
        else: {pattern, ""}

    body = pattern |> String.split("*") |> Enum.map_join(".*", &Regex.escape/1)
    Regex.match?(Regex.compile!("\\A" <> body <> anchor, "s"), url)
  end

  defp crawl(conn), do: get(conn, "/robots.txt").resp_body

  @always_fetchable ~w(/ /on/unlisted /words/1/voltaire /entities/1/voltaire /sources/wiktionary
                       /sources/johnson-1755 /artworks /sitemap.xml /sitemaps/subjects-1.xml
                       /robots.txt /assets/js/app.js /assets/css/app.css?vsn=d /fonts/x.woff2
                       /images/logo.svg)

  @always_kept_out ~w(/?q=voltaire /search /search?q=x /ops /ops/health /ops/imports /s/anything
                      /dev/mailbox /dev/mailbox/json /dev/dashboard /users/log-in /users/settings
                      /evidence/content/1 /connections/1 /connect /kit /health /admin/imports
                      /reconciliation /live/websocket /phoenix/live_reload/socket /api/x
                      /on/voltaire?trail=oyster /on/unlisted?demo=1)

  test "on: the families and the listed On pages are allowed, the rest kept out, the sitemap named",
       ctx do
    voltaire =
      subject!("Voltaire", "people",
        kind: :person,
        path: "/people/voltaire",
        published: true,
        actor: human!()
      )

    chekhov =
      subject!("Чехов", "people",
        kind: :person,
        path: "/people/чехов",
        published: true,
        actor: human!()
      )

    # Listed, but its only subject page is a draft: not allowed by name.
    candide = subject!("Candide", "people", kind: :person, path: "/people/candide")

    with_manifest(
      [
        %{
          "kind" => "lexical",
          "locale" => "en",
          "path" => "/on/voltaire",
          "subject_page_ids" => [voltaire.page.id],
          "reviewer" => "reviewer@example.test"
        },
        %{
          "kind" => "lexical",
          "locale" => "en",
          "path" => "/on/чехов",
          "subject_page_ids" => [chekhov.page.id],
          "reviewer" => "reviewer@example.test"
        },
        %{
          "kind" => "lexical",
          "locale" => "en",
          "path" => "/on/candide",
          "subject_page_ids" => [candide.page.id],
          "reviewer" => "reviewer@example.test"
        }
      ],
      fn ->
        lines = lines(ctx.conn)
        assert hd(lines) == "User-agent: *"

        for family <- Address.families(), do: assert("Allow: /#{family}/" in lines, family)
        assert "Allow: /on/voltaire$" in lines
        assert "Allow: /on/%D1%87%D0%B5%D1%85%D0%BE%D0%B2$" in lines
        refute "Allow: /on/candide$" in lines
        for static <- ~w(assets fonts images), do: assert("Allow: /#{static}/" in lines)

        for prefix <- @kept_out ++ Indexing.kept_out() do
          assert "Disallow: /#{prefix}/" in lines, prefix
          assert "Disallow: /#{prefix}$" in lines, prefix
        end

        # Never a bare prefix: `/s` would keep crawlers from `/sources/` and
        # `/sitemap.xml`.
        for line <- lines, String.starts_with?(line, "Disallow: /"), line != "Disallow: /*?" do
          assert line =~ ~r{(/|\$|/\*\?)\z}, line
        end

        assert "Disallow: /*?" in lines
        assert List.last(lines) == "Sitemap: #{PublicRouting.origin()}/sitemap.xml"

        refute "Disallow: /people/" in lines
        for family <- Address.families(), do: assert("Disallow: /#{family}/*?" in lines, family)

        # Noindex reader surfaces stay fetchable, so the instruction is read.
        refute Enum.any?(lines, &(&1 =~ ~r{\ADisallow: /(on|words|entities|sources|artworks)}))

        # As a crawler reads it.
        body = crawl(ctx.conn)

        for url <-
              @always_fetchable ++
                ~w(/people/voltaire /concepts/love /nature/human /on/voltaire /on/candide) do
          assert allowed?(body, url), "#{url} is disallowed when on"
        end

        for url <-
              @always_kept_out ++
                ~w(/people/voltaire?trail=oyster /people/voltaire?works_after=1
                   /works/candide?from=x /on/voltaire?x=1) do
          refute allowed?(body, url), "#{url} is allowed when on"
        end
      end
    )
  end

  test "off: the families are disallowed and no sitemap is named; the rest is as it was", ctx do
    switch(false, fn ->
      lines = lines(ctx.conn)
      assert hd(lines) == "User-agent: *"

      for family <- Address.families(), do: assert("Disallow: /#{family}/" in lines, family)
      refute Enum.any?(lines, &String.starts_with?(&1, "Allow: /people"))
      refute Enum.any?(lines, &String.starts_with?(&1, "Allow: /on/"))
      refute Enum.any?(lines, &String.starts_with?(&1, "Sitemap:"))

      for prefix <- @kept_out, do: assert("Disallow: /#{prefix}/" in lines, prefix)
      assert "Disallow: /*?" in lines
      for static <- ~w(assets fonts images), do: assert("Allow: /#{static}/" in lines)

      body = crawl(ctx.conn)

      for url <- @always_fetchable,
          do: assert(allowed?(body, url), "#{url} is disallowed when off")

      for url <-
            @always_kept_out ++ ~w(/people/voltaire /concepts/love /subjects/x /works/candide) do
        refute allowed?(body, url), "#{url} is allowed when off"
      end
    end)
  end

  test "the matcher itself reads RFC 9309's examples" do
    body = "Allow: /p\nDisallow: /\nAllow: /folder\nDisallow: /folder\nDisallow: /*.gif$\n"
    assert allowed?(body, "/page")
    assert allowed?(body, "/folder/page")
    refute allowed?(body, "/other")
    refute allowed?(body, "/a/b.gif")
    assert allowed?("Disallow: /s\n", "/x")
    refute allowed?("Disallow: /s\n", "/sitemap.xml")
  end

  test "the published host is the origin the sitemap is named at", ctx do
    with_env(:published_host, "wordhoard.test", fn ->
      assert "Sitemap: https://wordhoard.test/sitemap.xml" in lines(ctx.conn)
    end)
  end

  test "generated, not a static file" do
    refute File.exists?(Application.app_dir(:devils_dictionary, "priv/static/robots.txt"))
    refute "robots.txt" in DevilsDictionaryWeb.static_paths()
  end
end
