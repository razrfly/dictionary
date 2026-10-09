defmodule Mix.Tasks.Dd.Routing.RouteTest do
  @moduledoc """
  The reviewer's tool for the six address operations (#237 Part B, C9): each
  operation performed under a named reviewer, with the resolver's answer
  before and after and the rows the ledger wrote; a refusal that is the
  ledger's, printed, with nothing written; an actor that is not a reviewer
  refused; a merge or split without its registry merge or split reported;
  and the read-only `resolve`.
  """

  # Not async: the sandbox holds each test's transaction, these tests reuse
  # addresses, and the Mix shell and DD_NO_OBAN are process-wide.
  use DevilsDictionary.DataCase, async: false

  import DevilsDictionary.RoutingFixtures

  alias DevilsDictionary.{AccountsFixtures, Registry}
  alias DevilsDictionary.Routing.{Ledger, Page, Pages, PublicPath, RouteChange}
  alias DevilsDictionary.Sources.Actor
  alias Mix.Tasks.Dd.Routing.Route

  setup do
    Mix.shell(Mix.Shell.Process)
    no_oban = System.get_env("DD_NO_OBAN")
    System.put_env("DD_NO_OBAN", "1")

    on_exit(fn ->
      Mix.shell(Mix.Shell.IO)
      if no_oban, do: System.put_env("DD_NO_OBAN", no_oban), else: System.delete_env("DD_NO_OBAN")
    end)

    user = reviewer!()
    actor = Repo.insert!(%Actor{actor_kind: :user, user_id: user.id, label: "Reviewer"})
    %{user: user, actor: actor, importer: importer!()}
  end

  defp reviewer!(roles \\ [reviewer: true]) do
    AccountsFixtures.unconfirmed_user_fixture()
    |> Ecto.Changeset.change(roles)
    |> Repo.update!()
  end

  defp run(args), do: Route.run(args)

  defp signed(args, user, reason \\ "reviewed"),
    do: args ++ ["--actor", user.email, "--reason", reason]

  # Everything the task printed since the last call, as one string.
  defp output do
    receive do
      {:mix_shell, :info, [line]} -> line <> "\n" <> output()
    after
      0 -> ""
    end
  end

  defp ledger_size, do: Repo.aggregate(RouteChange, :count)

  defp operation_of(page_id, operation) do
    %{operation_id: id} =
      Enum.find(Ledger.history(page_id: page_id), &(&1.operation == operation))

    id
  end

  describe "move" do
    test "prints 200 before, the rows written, and 301 from the old address after", ctx do
      page = live_page!("people", "/people/voltaire", ctx.importer, :person)

      run(signed(["move", "--page", "#{page.id}", "--path", "/people/arouet"], ctx.user))
      out = output()

      assert out =~ "operation  move page #{page.id} to /people/arouet"
      assert out =~ "actor      #{ctx.user.email} (user ##{ctx.user.id}, reviewer)"

      assert out =~
               ~r{before\n  page #{page.id}  subject en  active  published  canonical /people/voltaire}

      assert out =~ ~r{/people/voltaire\s+public 200 canonical\s+internal 200 canonical}
      assert out =~ ~r{/people/arouet\s+public 404 missing\s+internal 404 missing}

      # The rows, each named.
      assert out =~
               ~r/written    operation [0-9a-f-]{36} \(move\), 3 route_changes rows, actor #{ctx.actor.id}/

      assert out =~
               ~r{seq 1  path #\d+ /people/voltaire  kind canonical -> alias  destination #{page.id} -> #{page.id}}

      assert out =~
               ~r{seq 2  path #\d+ /people/arouet  kind new -> canonical  destination none -> #{page.id}}

      assert out =~ ~r{seq 3  page ##{page.id}  lifecycle active -> active  canonical \d+ -> \d+}

      assert out =~
               ~r{public_paths\n    #\d+  /people/voltaire  alias  original #{page.id}  destination #{page.id}}

      assert out =~
               ~r{#\d+  /people/arouet  canonical  original #{page.id}  destination #{page.id}}

      assert out =~ ~r{pages\n    ##{page.id}  subject en  active  published  canonical \d+}

      assert out =~
               ~r{after\n  page #{page.id}  subject en  active  published  canonical /people/arouet}

      assert out =~
               ~r{/people/voltaire\s+public 301 redirect -> /people/arouet\s+internal 301 redirect -> /people/arouet}

      assert out =~ ~r{/people/arouet\s+public 200 canonical\s+internal 200 canonical}
      assert %Page{canonical_path_id: id} = Repo.get!(Page, page.id)
      assert Repo.get!(PublicPath, id).path == "/people/arouet"
    end

    test "a move to the current canonical reports nothing written", ctx do
      page = live_page!("people", "/people/voltaire", ctx.importer, :person)
      before = ledger_size()

      run(signed(["move", "--page", "#{page.id}", "--path", "/people/voltaire"], ctx.user))

      assert output() =~ "written    nothing in the ledger: it had nothing to change"
      assert ledger_size() == before
    end
  end

  describe "merge" do
    test "without a registry merge, reports it and writes nothing", ctx do
      a = live_page!("people", "/people/arouet", ctx.importer, :person)
      b = live_page!("people", "/people/voltaire", ctx.importer, :person)
      before = ledger_size()

      error =
        assert_raise Mix.Error, fn ->
          run(signed(["merge", "--from", "#{a.id}", "--into", "#{b.id}"], ctx.user))
        end

      assert error.message =~ "refused: :identity_not_merged"
      assert error.message =~ "this tool does not create one"
      assert error.message =~ "Nothing written."

      out = output()

      assert out =~
               "registry   object #{a.target_object_id} is its own live identity; no registry merge of " <>
                 "#{a.target_object_id} into #{b.target_object_id} exists, and this tool creates none"

      assert ledger_size() == before
      assert %Page{lifecycle_state: :active} = Repo.get!(Page, a.id)
    end

    test "with one, every old address answers 301 to the survivor", ctx do
      a = live_page!("people", "/people/arouet", ctx.importer, :person)
      b = live_page!("people", "/people/voltaire", ctx.importer, :person)
      {:ok, _} = Registry.merge([a.target_object_id], b.target_object_id, reason: "same person")

      run(signed(["merge", "--from", "#{a.id}", "--into", "#{b.id}"], ctx.user))
      out = output()

      assert out =~
               "registry   object #{a.target_object_id} is merged into object #{b.target_object_id}, the survivor's identity"

      assert out =~
               ~r{before\n  page #{a.id}  subject en  active  published  canonical /people/arouet}

      assert out =~ ~r{/people/arouet\s+public 200 canonical\s+internal 200 canonical}
      assert out =~ ~r/\(merge\), 2 route_changes rows/

      assert out =~
               ~r{seq 1  path #\d+ /people/arouet  kind canonical -> alias  destination #{a.id} -> #{b.id}}

      assert out =~
               ~r{seq 2  page ##{a.id}  lifecycle active -> merged  canonical \d+ -> none  merged into none -> #{b.id}}

      assert out =~
               ~r{after\n  page #{a.id}  subject en  merged  published  canonical none  target \d+  merged into #{b.id}}

      assert out =~
               ~r{/people/arouet\s+public 301 redirect -> /people/voltaire\s+internal 301 redirect -> /people/voltaire}

      assert out =~ ~r{/people/voltaire\s+public 200 canonical\s+internal 200 canonical}
    end
  end

  describe "split" do
    test "without a registry split, reports it and writes nothing", ctx do
      mercury = live_page!("nature", "/nature/mercury", ctx.importer)
      planet = live_page!("nature", "/nature/mercury-planet", ctx.importer)
      before = ledger_size()

      error =
        assert_raise Mix.Error, fn ->
          run(
            signed(["split", "--page", "#{mercury.id}", "--successors", "#{planet.id}"], ctx.user)
          )
        end

      assert error.message =~ "refused: :identity_not_split"
      assert error.message =~ "Nothing written."

      out = output()

      assert out =~
               "registry   object #{mercury.target_object_id} is its own live identity; no registry split of " <>
                 "#{mercury.target_object_id} exists, and this tool creates none"

      assert out =~
               "page #{planet.id} is about object #{planet.target_object_id}, not a split output"

      assert ledger_size() == before
      assert %Page{lifecycle_state: :active} = Repo.get!(Page, mercury.id)
    end

    test "with one, the page becomes a choice among the successors in the given order", ctx do
      mercury = live_page!("nature", "/nature/mercury", ctx.importer)
      planet = live_page!("nature", "/nature/mercury-planet", ctx.importer)
      element = live_page!("nature", "/nature/mercury-element", ctx.importer)

      {:ok, _} =
        Registry.split(
          mercury.target_object_id,
          [planet.target_object_id, element.target_object_id],
          reason: "planet and element"
        )

      run(
        signed(
          ["split", "--page", "#{mercury.id}", "--successors", "#{element.id},#{planet.id}"],
          ctx.user
        )
      )

      out = output()

      assert out =~
               "page #{element.id} is about object #{element.target_object_id}, a split output"

      assert out =~ ~r{/nature/mercury\s+public 200 canonical\s+internal 200 canonical}
      assert out =~ ~r/\(split\), 1 route_changes rows/

      assert out =~
               ~r{seq 1  page ##{mercury.id}  lifecycle active -> split  canonical (\d+) -> \1  merged into none -> none  revision none -> \d+}

      assert out =~
               ~r{page_revisions\n    #\d+  page #{mercury.id}  revision 1  memberships \[1 split_successor -> page #{element.id}, 2 split_successor -> page #{planet.id}\]}

      assert out =~
               ~r{/nature/mercury\s+public 200 choice \[page #{element.id} 200 canonical, page #{planet.id} 200 canonical\]\s+internal 200 choice}

      assert %Page{lifecycle_state: :split} = Repo.get!(Page, mercury.id)
    end
  end

  describe "retire, restore and rollback" do
    test "retiring a published page answers 410 at every address, and restore brings one back",
         ctx do
      page = live_page!("people", "/people/voltaire", ctx.importer, :person)

      run(signed(["retire", "--page", "#{page.id}"], ctx.user, "removed"))
      out = output()

      assert out =~
               ~r{before\n  page #{page.id}  subject en  active  published  canonical /people/voltaire}

      assert out =~ ~r{/people/voltaire\s+public 200 canonical\s+internal 200 canonical}
      assert out =~ ~r/\(retire\), 2 route_changes rows/

      assert out =~
               ~r{seq 1  path #\d+ /people/voltaire  kind canonical -> tombstone  destination #{page.id} -> #{page.id}}

      assert out =~
               ~r{seq 2  page ##{page.id}  lifecycle active -> retired  canonical \d+ -> none}

      assert out =~
               ~r{#\d+  /people/voltaire  tombstone  original #{page.id}  destination #{page.id}}

      assert out =~ ~r{after\n  page #{page.id}  subject en  retired  published  canonical none}
      assert out =~ ~r{/people/voltaire\s+public 410 gone\s+internal 410 gone}

      run(
        signed(
          ["restore", "--page", "#{page.id}", "--path", "/people/voltaire"],
          ctx.user,
          "lifted"
        )
      )

      out = output()

      assert out =~ ~r{before\n  page #{page.id}  subject en  retired  published  canonical none}
      assert out =~ ~r{/people/voltaire\s+public 410 gone\s+internal 410 gone}
      assert out =~ ~r/\(restore\), 2 route_changes rows/

      assert out =~
               ~r{seq 1  path #\d+ /people/voltaire  kind tombstone -> canonical  destination #{page.id} -> #{page.id}  decision \d+ \(policy 1\.0\.0\)}

      assert out =~
               ~r{seq 2  page ##{page.id}  lifecycle retired -> active  canonical none -> \d+}

      assert out =~
               ~r{after\n  page #{page.id}  subject en  active  published  canonical /people/voltaire}

      assert out =~ ~r{/people/voltaire\s+public 200 canonical\s+internal 200 canonical}
      assert %Page{lifecycle_state: :active} = Repo.get!(Page, page.id)
    end

    test "a retired draft answers 404, not 410", ctx do
      page =
        "people"
        |> subject_page!("Candide", :person)
        |> allocated!("/people/candide", ctx.importer)

      run(signed(["retire", "--page", "#{page.id}"], ctx.user))
      out = output()

      assert out =~
               ~r{before\n  page #{page.id}  subject en  active  draft  canonical /people/candide}

      assert out =~ ~r{/people/candide\s+public 404 unavailable\s+internal 200 canonical}
      assert out =~ ~r{after\n  page #{page.id}  subject en  retired  draft  canonical none}
      assert out =~ ~r{/people/candide\s+public 404 unavailable\s+internal 404 unavailable}
    end

    test "rolling back a move restores the old canonical and keeps the new address as a 301",
         ctx do
      page = live_page!("people", "/people/voltaire", ctx.importer, :person)

      {:ok, _} =
        Ledger.move(page.id, "/people/arouet", actor_id: ctx.actor.id, reason: "pen name")

      move = operation_of(page.id, :move)

      run(signed(["rollback", "--operation", move], ctx.user, "wrong name"))
      out = output()

      assert out =~ "operation  roll back operation #{move}"

      assert out =~
               ~r{before\n  page #{page.id}  subject en  active  published  canonical /people/arouet}

      assert out =~
               ~r{/people/voltaire\s+public 301 redirect -> /people/arouet\s+internal 301 redirect -> /people/arouet}

      assert out =~ ~r{/people/arouet\s+public 200 canonical\s+internal 200 canonical}
      assert out =~ ~r/\(rollback\), 3 route_changes rows, actor #{ctx.actor.id}, reverts #{move}/
      assert out =~ ~r{page ##{page.id}  lifecycle active -> active  canonical (\d+) -> (\d+)}

      assert out =~
               ~r{/people/arouet  kind canonical -> alias  destination #{page.id} -> #{page.id}}

      assert out =~
               ~r{/people/voltaire  kind alias -> canonical  destination #{page.id} -> #{page.id}}

      assert out =~
               ~r{after\n  page #{page.id}  subject en  active  published  canonical /people/voltaire}

      assert out =~ ~r{/people/voltaire\s+public 200 canonical\s+internal 200 canonical}

      assert out =~
               ~r{/people/arouet\s+public 301 redirect -> /people/voltaire\s+internal 301 redirect -> /people/voltaire}

      before = ledger_size()

      error =
        assert_raise Mix.Error, fn ->
          run(signed(["rollback", "--operation", move], ctx.user))
        end

      assert error.message =~
               "refused: :already_rolled_back (the operation is already rolled back)"

      assert ledger_size() == before
    end
  end

  describe "rolling back a split" do
    test "lists the revision the page returns to as one it did not write", ctx do
      mercury = live_page!("nature", "/nature/mercury", ctx.importer)
      planet = live_page!("nature", "/nature/mercury-planet", ctx.importer)
      element = live_page!("nature", "/nature/mercury-element", ctx.importer)
      {:ok, earlier} = Pages.add_revision(mercury.id, %{title: "Mercury"}, [], ctx.actor.id)

      {:ok, _} =
        Registry.split(
          mercury.target_object_id,
          [planet.target_object_id, element.target_object_id],
          reason: "planet and element"
        )

      run(
        signed(
          ["split", "--page", "#{mercury.id}", "--successors", "#{planet.id},#{element.id}"],
          ctx.user
        )
      )

      split = output()
      assert split =~ "  page_revisions\n"
      refute split =~ "they already existed"

      run(signed(["rollback", "--operation", operation_of(mercury.id, :split)], ctx.user))
      out = output()

      # The page returns to its earlier revision, which the rollback did not
      # write: it is listed apart, and no revision is listed as written.
      assert out =~ "page_revisions the page returns to (not written: they already existed)"
      assert out =~ ~r/#{earlier.id}  page #{mercury.id}  revision 1/
      refute out =~ "  page_revisions\n"
    end
  end

  describe "refusals" do
    test "a refused operation prints the ledger's reason and leaves the ledger unchanged", ctx do
      page = live_page!("people", "/people/voltaire", ctx.importer, :person)
      other = live_page!("people", "/people/arouet", ctx.importer, :person)
      before = ledger_size()
      paths = Repo.all(from p in PublicPath, order_by: p.id)

      error =
        assert_raise Mix.Error, fn ->
          run(signed(["move", "--page", "#{page.id}", "--path", "/people/arouet"], ctx.user))
        end

      assert error.message ==
               "refused: {:path_taken, %{path: \"/people/arouet\", kind: :canonical, page_id: #{other.id}}} " <>
                 "(the path is canonical of page #{other.id})\nNothing written."

      # The before answers were printed; no after, no rows.
      out = output()
      assert out =~ ~r{before\n  page #{page.id}}
      refute out =~ "written"
      refute out =~ "after"
      assert ledger_size() == before
      assert Repo.all(from p in PublicPath, order_by: p.id) == paths
      assert Repo.get!(Page, page.id).canonical_path_id == page.canonical_path_id
    end

    test "an account without the reviewer role, or no account, is refused before anything", ctx do
      page = live_page!("people", "/people/voltaire", ctx.importer, :person)
      contributor = reviewer!(reviewer: false, internal_contributor: true)
      before = ledger_size()

      error =
        assert_raise Mix.Error, fn ->
          run(signed(["move", "--page", "#{page.id}", "--path", "/people/arouet"], contributor))
        end

      assert error.message ==
               "#{contributor.email} does not hold the reviewer role\nNothing written."

      error =
        assert_raise Mix.Error, fn ->
          run(
            ["move", "--page", "#{page.id}", "--path", "/people/arouet"] ++
              ["--actor", "nobody@example.com", "--reason", "x"]
          )
        end

      assert error.message == "no account nobody@example.com\nNothing written."
      assert output() == ""
      assert ledger_size() == before
      assert Repo.get_by(Actor, user_id: contributor.id) == nil
    end

    test "a reviewer without a user actor gets one with the operation, and none on a refusal",
         ctx do
      page = live_page!("people", "/people/voltaire", ctx.importer, :person)
      other = live_page!("people", "/people/arouet", ctx.importer, :person)
      reviewer = reviewer!()
      before = ledger_size()

      assert_raise Mix.Error, ~r/refused: {:path_taken/, fn ->
        run(signed(["move", "--page", "#{page.id}", "--path", "/people/arouet"], reviewer))
      end

      assert Repo.get_by(Actor, user_id: reviewer.id) == nil
      assert ledger_size() == before
      _ = output()

      run(
        signed(["move", "--page", "#{other.id}", "--path", "/people/arouet-le-jeune"], reviewer)
      )

      assert %Actor{actor_kind: :user, id: actor_id} = Repo.get_by(Actor, user_id: reviewer.id)
      out = output()
      assert out =~ ~r/\(move\), 3 route_changes rows, actor #{actor_id}/
      assert ledger_size() == before + 3

      # The one write outside the ledger is printed with what was written.
      assert out =~ ~r/  actors\n    ##{actor_id}  user ##{reviewer.id}  kind user/
      assert out =~ "created with this operation"

      # A reviewer who already has the actor gets no such line.
      run(signed(["retire", "--page", "#{page.id}"], reviewer))
      refute output() =~ "  actors"
    end

    test "the task refuses to run without DD_NO_OBAN=1", ctx do
      page = live_page!("people", "/people/voltaire", ctx.importer, :person)
      before = ledger_size()
      System.delete_env("DD_NO_OBAN")

      error =
        assert_raise Mix.Error, fn ->
          run(signed(["move", "--page", "#{page.id}", "--path", "/people/arouet"], ctx.user))
        end

      assert error.message =~ "run it with DD_NO_OBAN=1"
      assert output() == ""
      assert ledger_size() == before
    end

    test "the arguments are the ledger's, and each is required", ctx do
      page = live_page!("people", "/people/voltaire", ctx.importer, :person)

      for {args, message} <- [
            {["publish", "--page", "1"], ~r/unknown operation/},
            {["move", "--page", "#{page.id}", "--actor", ctx.user.email, "--reason", "x"],
             ~r/--path is required/},
            {["move", "--page", "#{page.id}", "--path", "/people/arouet", "--reason", "x"],
             ~r/--actor is required/},
            {[
               "move",
               "--page",
               "#{page.id}",
               "--path",
               "/people/arouet",
               "--actor",
               ctx.user.email
             ], ~r/--reason is required/},
            {["merge", "--from", "#{page.id}", "--actor", ctx.user.email, "--reason", "x"],
             ~r/--into is required/},
            {["split", "--page", "#{page.id}", "--actor", ctx.user.email, "--reason", "x"],
             ~r/--successors is required/},
            {["rollback", "--actor", ctx.user.email, "--reason", "x"],
             ~r/--operation is required/},
            {["retire", "--page", "x", "--actor", ctx.user.email, "--reason", "x"],
             ~r/unexpected arguments/},
            {[
               "retire",
               "--page",
               "#{page.id}",
               "stray",
               "--actor",
               ctx.user.email,
               "--reason",
               "x"
             ], ~r/unexpected arguments/},
            {["resolve"], ~r/resolve needs at least one path/}
          ] do
        assert_raise Mix.Error, message, fn -> run(args) end
      end

      # A malformed path or id is the ledger's refusal, not a crash.
      error =
        assert_raise Mix.Error, fn ->
          run(signed(["move", "--page", "#{page.id}", "--path", "/users/settings"], ctx.user))
        end

      assert error.message =~ "refused: :unknown_namespace"

      error =
        assert_raise Mix.Error, fn ->
          run(signed(["rollback", "--operation", "not-a-uuid"], ctx.user))
        end

      assert error.message =~ "refused: :invalid_operation"

      # An id past bigint names no page: the ledger refuses it, nothing
      # crashes on the way, for every option that takes a page id.
      too_big = "9223372036854775808"

      for args <- [
            ["retire", "--page", too_big],
            ["move", "--page", too_big, "--path", "/people/somebody"],
            ["merge", "--from", too_big, "--into", "#{page.id}"],
            ["split", "--page", "#{page.id}", "--successors", "#{too_big},#{page.id}"]
          ] do
        error = assert_raise Mix.Error, fn -> run(signed(args, ctx.user)) end
        assert error.message =~ "refused: :invalid_page", inspect(args)
      end
    end
  end

  describe "resolve" do
    test "prints both modes for each path as a request spells it, and writes nothing", ctx do
      live_page!("people", "/people/voltaire", ctx.importer, :person)
      "people" |> subject_page!("Candide", :person) |> allocated!("/people/candide", ctx.importer)
      live_page!("people", "/people/чехов", ctx.importer, :person)
      before = ledger_size()

      run([
        "resolve",
        "/people/voltaire",
        "/people/Voltaire/",
        "/people/candide",
        "/people/nobody",
        "/people/%D1%87%D0%B5%D1%85%D0%BE%D0%B2",
        "/people/c%2B%2B",
        "/people/a%2Fb",
        "/people/%zz"
      ])

      out = output()
      assert out =~ ~r{^/people/voltaire\s+public 200 canonical\s+internal 200 canonical$}m

      assert out =~
               ~r{^/people/Voltaire/\s+public 301 redirect -> /people/voltaire\s+internal 301 redirect -> /people/voltaire$}m

      assert out =~ ~r{^/people/candide\s+public 404 unavailable\s+internal 200 canonical$}m
      assert out =~ ~r{^/people/nobody\s+public 404 missing\s+internal 404 missing$}m

      assert out =~
               ~r{^/people/%D1%87%D0%B5%D1%85%D0%BE%D0%B2\s+public 200 canonical\s+internal 200 canonical$}m

      # c%2B%2B is C++, which no stored path can be: missing, never re-slugified.
      assert out =~ ~r{^/people/c%2B%2B\s+public 404 missing\s+internal 404 missing$}m

      assert out =~
               ~r{^/people/a%2Fb\s+public 400 invalid \(encoded_separator\)\s+internal 400 invalid \(encoded_separator\)$}m

      assert out =~
               ~r{^/people/%zz\s+public 400 invalid \(malformed_encoding\)\s+internal 400 invalid \(malformed_encoding\)$}m

      assert ledger_size() == before
    end

    test "says the launch switch the public answers are read under", ctx do
      live_page!("people", "/people/voltaire", ctx.importer, :person)
      previous = Application.get_env(:devils_dictionary, :public_routing)

      try do
        Application.put_env(:devils_dictionary, :public_routing, true)
        run(["resolve", "/people/voltaire"])
        out = output()
        assert out =~ ~r{^switch     public routing on$}m
        assert out =~ ~r{^/people/voltaire\s+public 200 canonical}m

        # Off, as in a shell that names no published host: the line says so,
        # so a 404 is not read as the ledger's answer.
        Application.put_env(:devils_dictionary, :public_routing, false)
        run(["resolve", "/people/voltaire"])
        out = output()
        assert out =~ ~r{^switch     public routing off here: every family address answers 404}m
        assert out =~ ~r{^/people/voltaire\s+public 404 unavailable\s+internal 200 canonical$}m

        # The published host itself, on and rolled back (D5): the line names
        # it, and the rollback is not mistaken for a shell without the host.
        Application.put_env(:devils_dictionary, :published_host, "wordhoard.test")
        run(["resolve", "/people/voltaire"])
        out = output()

        assert out =~
                 ~r{^switch     public routing off, as the published host https://wordhoard.test has it \(DD_PUBLIC_ROUTING=off\)}m

        refute out =~ "set DD_PUBLISHED_HOST"

        Application.put_env(:devils_dictionary, :public_routing, true)
        run(["resolve", "/people/voltaire"])

        assert output() =~
                 ~r{^switch     public routing on, as the published host https://wordhoard.test has it$}m
      after
        Application.put_env(:devils_dictionary, :public_routing, previous)
        Application.delete_env(:devils_dictionary, :published_host)
      end
    end
  end
end
