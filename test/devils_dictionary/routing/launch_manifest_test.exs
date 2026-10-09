defmodule DevilsDictionary.Routing.LaunchManifestTest do
  @moduledoc """
  The launch manifest (#237): what `LaunchManifest.read/1` refuses in a
  file's shape, what `validate/2` refuses against the ledger and the
  accounts — an entry whose page has no canonical, whose path is not the
  page's canonical, or whose reviewer is not a reviewer account (the rule's
  signer, under a rule) — and `mix dd.routing.publish` over a manifest file:
  a dry run writes nothing, and a second run is idempotent.
  """
  use DevilsDictionary.DataCase, async: false

  import DevilsDictionary.RoutingFixtures
  import Ecto.Query

  alias DevilsDictionary.AccountsFixtures
  alias DevilsDictionary.Routing.{LaunchManifest, Page, PagePublication, Pages, PublicPath}
  alias DevilsDictionary.Sources.Actor

  setup do
    dir = Path.join(System.tmp_dir!(), "launch-manifest-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)

    reviewer =
      AccountsFixtures.user_fixture() |> Ecto.Changeset.change(reviewer: true) |> Repo.update!()

    Repo.insert!(%Actor{actor_kind: :user, user_id: reviewer.id, label: "Reviewer"})

    page =
      subject_page!("people", "Voltaire", :person) |> allocated!("/people/voltaire", importer!())

    %{dir: dir, reviewer: reviewer, page: page}
  end

  defp entry(ctx, fields \\ %{}) do
    Map.merge(
      %{
        "kind" => "subject",
        "page_id" => ctx.page.id,
        "locale" => "en",
        "path" => "/people/voltaire",
        "reviewer" => ctx.reviewer.email
      },
      fields
    )
  end

  defp write!(ctx, doc) do
    path = Path.join(ctx.dir, "manifest-#{System.unique_integer([:positive])}.json")
    File.write!(path, Jason.encode!(Map.merge(%{"format" => LaunchManifest.format()}, doc)))
    path
  end

  test "a manifest reads, with its digest, its pages and its lexical entries", ctx do
    lexical = %{
      "kind" => "lexical",
      "locale" => "en",
      "path" => "/on/voltaire",
      "reviewer" => ctx.reviewer.email
    }

    path = write!(ctx, %{"entries" => [entry(ctx), lexical]})
    assert {:ok, manifest} = LaunchManifest.read(path)

    assert manifest.sha256 ==
             :crypto.hash(:sha256, File.read!(path)) |> Base.encode16(case: :lower)

    assert Map.keys(manifest.pages) == [ctx.page.id]
    assert [%{"path" => "/on/voltaire"}] = manifest.lexical
    assert :ok = LaunchManifest.validate(manifest)

    assert {:ok, empty} = LaunchManifest.read(write!(ctx, %{"entries" => []}))
    assert empty.pages == %{}
  end

  test "a manifest whose shape is wrong is refused", ctx do
    for {doc, expected} <- [
          {%{"format" => "something else", "entries" => []}, "format"},
          {%{"entries" => "all"}, "entries is a list"},
          {%{"entries" => [entry(ctx, %{"locale" => "fr"})]}, "launch locale is en"},
          {%{"entries" => [entry(ctx, %{"reviewer" => ""})]}, "names the reviewer"},
          {%{"entries" => [entry(ctx, %{"path" => "/users/settings"})]}, "is not an address"},
          {%{"entries" => [entry(ctx, %{"kind" => "lexical"})]}, "a lexical entry is an On page"},
          {%{"entries" => [entry(ctx, %{"page_id" => nil})]}, "names its page id"},
          {%{"entries" => [entry(ctx, %{"kind" => "edition"})]},
           "an edition's address is in /works"},
          {%{"entries" => [entry(ctx), entry(ctx, %{"path" => "/people/arouet"})]},
           "listed twice"},
          {%{"entries" => [entry(ctx), entry(ctx, %{"page_id" => ctx.page.id + 1})]},
           "listed twice"},
          {%{"rule" => %{"sha256" => "abc"}, "entries" => []}, "a rule names its sha256"}
        ] do
      assert {:error, message} = LaunchManifest.read(write!(ctx, doc))
      assert message =~ expected, "#{inspect(doc)}: #{message}"
    end
  end

  test "an entry with no canonical, another path, or no reviewer is refused against the ledger",
       ctx do
    {:ok, unrouted} =
      Pages.ensure(:subject, subject_page!("people", "Arouet", :person).target_object_id)

    plain = AccountsFixtures.user_fixture()

    entries = [
      entry(ctx, %{"path" => "/people/arouet"}),
      entry(ctx, %{"page_id" => unrouted.id, "path" => "/people/françois"}),
      entry(ctx, %{"page_id" => 999_999_999, "path" => "/people/nobody"}),
      %{
        entry(ctx, %{"reviewer" => plain.email})
        | "path" => "/people/x",
          "page_id" => ctx.page.id + 100
      }
    ]

    {:ok, manifest} = LaunchManifest.read(write!(ctx, %{"entries" => entries}))
    assert {:error, problems} = LaunchManifest.validate(manifest)

    assert Enum.any?(problems, &(&1 =~ "page #{ctx.page.id}'s canonical is /people/voltaire"))
    assert Enum.any?(problems, &(&1 =~ "page #{unrouted.id} has no canonical"))
    assert Enum.any?(problems, &(&1 =~ "no page 999999999"))
    assert Enum.any?(problems, &(&1 =~ "#{plain.email} is not a reviewer account"))
  end

  test "mix dd.routing.publish: a dry run writes nothing, and a second run is idempotent", ctx do
    {:ok, _} =
      DevilsDictionary.Registry.create_content(%{
        content_kind: :article,
        source_id: DevilsDictionary.Fixtures.seed_catalog!().sources["wikipedia"].id,
        body: "Voltaire was a writer.",
        body_format: :markdown,
        canonical_url: "https://example.test/voltaire",
        position: 0
      })
      |> then(fn {:ok, content} ->
        DevilsDictionary.Claims.assert(content.object_id, "about", ctx.page.target_object_id, %{})
      end)

    Repo.update_all(
      from(e in DevilsDictionary.Registry.Entity,
        where: e.object_id == ^ctx.page.target_object_id
      ),
      set: [description: "French writer"]
    )

    path = write!(ctx, %{"entries" => [entry(ctx)]})
    Mix.shell(Mix.Shell.Process)
    on_exit(fn -> Mix.shell(Mix.Shell.IO) end)

    run = fn args ->
      Mix.Task.rerun(
        "dd.routing.publish",
        ["--manifest", path, "--reviewer", ctx.reviewer.email] ++ args
      )
    end

    run.(["--dry-run"])

    assert_received {:mix_shell, :info,
                     ["dry run: 0 published, 1 would publish, 0 unchanged, 0 refused"]}

    assert Repo.aggregate(PagePublication, :count) == 0
    assert Repo.get!(Page, ctx.page.id).publication_state == :draft

    run.([])
    assert_received {:mix_shell, :info, ["1 published, 0 would publish, 0 unchanged, 0 refused"]}

    run.([])
    assert_received {:mix_shell, :info, ["0 published, 0 would publish, 1 unchanged, 0 refused"]}
    assert Repo.aggregate(PagePublication, :count) == 1
    assert Repo.get!(Page, ctx.page.id).publication_state == :published
    assert Repo.get!(PublicPath, ctx.page.canonical_path_id).path == "/people/voltaire"
  end
end
