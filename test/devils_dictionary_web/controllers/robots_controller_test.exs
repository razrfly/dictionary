defmodule DevilsDictionaryWeb.RobotsControllerTest do
  @moduledoc """
  `robots.txt` (#237 C5): generated from the switch, the registry's reserved
  prefixes and the launch manifest. On, the families and the listed On pages
  are allowed and the sitemap is named; off (D5), the families are
  disallowed and no sitemap is named; always, the surfaces that are not for
  reading and every query variant are disallowed, and the assets a page
  renders with are allowed.
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

  test "on: the families and the listed On pages are allowed, the rest kept out, the sitemap named",
       ctx do
    voltaire =
      subject!("Voltaire", "people",
        kind: :person,
        path: "/people/voltaire",
        published: true,
        actor: human!()
      )

    chekhov = subject!("Чехов", "people", kind: :person, path: "/people/чехов", actor: human!())

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
        }
      ],
      fn ->
        lines = lines(ctx.conn)
        assert hd(lines) == "User-agent: *"

        for family <- Address.families(), do: assert("Allow: /#{family}/" in lines, family)
        assert "Allow: /on/voltaire$" in lines
        assert "Allow: /on/%D1%87%D0%B5%D1%85%D0%BE%D0%B2$" in lines
        for static <- ~w(assets fonts images), do: assert("Allow: /#{static}/" in lines)

        for prefix <- @kept_out, do: assert("Disallow: /#{prefix}" in lines, prefix)
        for prefix <- Indexing.kept_out(), do: assert("Disallow: /#{prefix}" in lines, prefix)
        assert "Disallow: /*?" in lines
        assert List.last(lines) == "Sitemap: #{PublicRouting.origin()}/sitemap.xml"

        refute Enum.any?(lines, &String.starts_with?(&1, "Disallow: /people"))

        # Noindex reader surfaces stay fetchable, so the instruction is read.
        refute Enum.any?(lines, &(&1 =~ ~r{\ADisallow: /(on|words|entities|sources|artworks)}))
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

      for prefix <- @kept_out, do: assert("Disallow: /#{prefix}" in lines, prefix)
      assert "Disallow: /*?" in lines
      for static <- ~w(assets fonts images), do: assert("Allow: /#{static}/" in lines)
    end)
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
