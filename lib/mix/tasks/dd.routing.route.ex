defmodule Mix.Tasks.Dd.Routing.Route do
  @shortdoc "One approved address operation under a named reviewer, with what the ledger wrote"

  @moduledoc """
  The reviewer's tool for the six address operations of `Routing.Ledger`
  (#237 Part B, C9): one operation per invocation, under a named human actor,
  with a reason. Everything it does, the ledger does; this task only names the
  actor, prints the resolver's answers before and after, and prints the rows
  the ledger wrote.

      DD_NO_OBAN=1 mix dd.routing.route move     --page ID --path PATH          --actor EMAIL --reason TEXT
      DD_NO_OBAN=1 mix dd.routing.route merge    --from ID --into ID            --actor EMAIL --reason TEXT
      DD_NO_OBAN=1 mix dd.routing.route split    --page ID --successors ID,ID   --actor EMAIL --reason TEXT
      DD_NO_OBAN=1 mix dd.routing.route retire   --page ID                      --actor EMAIL --reason TEXT
      DD_NO_OBAN=1 mix dd.routing.route restore  --page ID --path PATH          --actor EMAIL --reason TEXT
      DD_NO_OBAN=1 mix dd.routing.route rollback --operation UUID               --actor EMAIL --reason TEXT
      DD_NO_OBAN=1 mix dd.routing.route resolve  PATH [PATH ...]

  The options are the ledger's own arguments: `move/3` takes a page and a
  path, `merge/3` a page to merge from and one to merge into, `split/3` a
  page and its successors in the order the choice will list them, `retire/2`
  a page, `restore/3` a page and one of its tombstones, `rollback/2` an
  operation id from the ledger. A path is given in stored form
  (`/people/voltaire`), as the ledger stores it.

  `--actor` is an account that holds the reviewer role, resolved to its
  `user` actor the way `Routing.Backfill` resolves a reviewer. An account
  without that actor gets one, in the same transaction as the operation, so
  a refusal leaves nothing behind.

  Before writing, the task prints the resolver's answer, in public and in
  internal mode, for every path the operation touches. After writing, it
  prints the `route_changes` rows the operation wrote, the `public_paths` and
  `pages` rows they changed (and the `page_revisions` row a split writes),
  and the resolver's answers again. A refusal is the ledger's: the task prints
  the reason, writes nothing and exits non-zero. A registry merge or split
  must already exist for `merge` and `split`; the task reports what the
  registry holds and does not create one.

  `resolve` is read-only: it prints both answers for each path as a request
  would spell it, so the before and after of an operation can be recorded by
  hand as well.

  The public answers are the resolver's in this environment, under the launch
  switch as it stands here (`Routing.PublicRouting`, #237 D5), and the task
  says which first. A shell without `DD_PUBLISHED_HOST` has the switch off,
  so every family address answers 404 publicly there whatever the ledger
  holds; set the variable (and `DD_PUBLIC_ROUTING` as the published host has
  it) to read the published host's answers.

  The task starts the application, so it refuses to run without
  `DD_NO_OBAN=1`: Oban's queues and cron must not run beside a reviewer's
  operation.
  """

  use Mix.Task

  import Ecto.Query

  alias DevilsDictionary.Accounts.User
  alias DevilsDictionary.{Registry, Repo}
  import DevilsDictionary.Routing.Input, only: [is_id: 1]

  alias DevilsDictionary.Routing.{Address, Ledger, Page, PageRevision, PublicPath, Resolution}
  alias DevilsDictionary.Routing.{PublicRouting, Resolver, RouteChange}
  alias DevilsDictionary.Sources.Actor

  @requirements ["app.config"]

  @operations ~w(move merge split retire restore rollback)

  @switches [
    page: :integer,
    path: :string,
    from: :integer,
    into: :integer,
    successors: :string,
    operation: :string,
    actor: :string,
    reason: :string
  ]

  @usage """
  usage:
    mix dd.routing.route move     --page ID --path PATH        --actor EMAIL --reason TEXT
    mix dd.routing.route merge    --from ID --into ID          --actor EMAIL --reason TEXT
    mix dd.routing.route split    --page ID --successors ID,ID --actor EMAIL --reason TEXT
    mix dd.routing.route retire   --page ID                    --actor EMAIL --reason TEXT
    mix dd.routing.route restore  --page ID --path PATH        --actor EMAIL --reason TEXT
    mix dd.routing.route rollback --operation UUID             --actor EMAIL --reason TEXT
    mix dd.routing.route resolve  PATH [PATH ...]
  """

  @impl Mix.Task
  def run(args) do
    no_oban!()
    Mix.Task.run("app.start")

    case args do
      ["resolve" | paths] -> resolve(paths)
      [operation | rest] when operation in @operations -> perform(operation, rest)
      _other -> Mix.raise("unknown operation\n" <> @usage)
    end
  end

  # The application starts here; a reviewer's operation must not start the
  # queues and cron with it. The variable is the owner's deliberate choice,
  # and the configuration it produces is checked too.
  defp no_oban! do
    unless System.get_env("DD_NO_OBAN") in ["1", "true"],
      do:
        Mix.raise(
          "mix dd.routing.route starts the application; run it with DD_NO_OBAN=1 so that " <>
            "Oban's queues and cron do not run beside the operation"
        )

    oban = Application.get_env(:devils_dictionary, Oban, [])

    unless Keyword.get(oban, :testing) in [:manual, :inline] or
             (Keyword.get(oban, :queues) == false and Keyword.get(oban, :plugins) == false),
           do: Mix.raise("DD_NO_OBAN=1 is set but Oban is still configured to run queues")
  end

  # ── resolve ──────────────────────────────────────────────────────────────

  defp resolve([]), do: Mix.raise("resolve needs at least one path\n" <> @usage)

  defp resolve(paths) do
    print_switch()

    for raw <- paths do
      Mix.shell().info(resolution_line(raw, raw))
    end
  end

  # The launch switch the public answers are read under: off in a shell that
  # names no published host, where every family address is 404 publicly, so
  # a reviewer never takes that for the operation's doing.
  defp print_switch do
    Mix.shell().info(
      cond do
        PublicRouting.enabled?() and PublicRouting.published_host?() ->
          "switch     public routing on, as the published host #{PublicRouting.origin()} has it"

        PublicRouting.enabled?() ->
          "switch     public routing on"

        true ->
          "switch     public routing off here: every family address answers 404 publicly; " <>
            "set DD_PUBLISHED_HOST to read the published host's answers"
      end
    )
  end

  # ── the six operations ───────────────────────────────────────────────────

  defp perform(operation, args) do
    {opts, extra, invalid} = OptionParser.parse(args, strict: @switches)

    if extra != [] or invalid != [],
      do: Mix.raise("unexpected arguments #{inspect(extra ++ invalid)}\n" <> @usage)

    params = params!(operation, opts)
    reason = required!(opts, :reason)
    email = required!(opts, :actor)
    user = reviewer!(email)

    Mix.shell().info("operation  #{describe(operation, params)}")
    Mix.shell().info("actor      #{email} (user ##{user.id}, reviewer)")
    Mix.shell().info("reason     #{reason}")
    print_switch()

    before = touched(operation, params)
    report_registry(operation, params)
    print_state("before", before)

    newest = Repo.aggregate(RouteChange, :max, :id) || 0
    newest_revision = Repo.aggregate(PageRevision, :max, :id) || 0

    case with_actor(user, fn actor -> call(operation, params, actor, reason) end) do
      {:ok, result, created} ->
        print_written(operation, result, newest, newest_revision)
        print_created(created, user)
        print_state("after", merge_touched(before, touched(operation, params)))

      {:error, refusal} ->
        Mix.raise("refused: #{explain(refusal)}\nNothing written.")
    end
  end

  defp params!("move", opts), do: %{page: required!(opts, :page), path: required!(opts, :path)}
  defp params!("merge", opts), do: %{from: required!(opts, :from), into: required!(opts, :into)}

  defp params!("split", opts),
    do: %{page: required!(opts, :page), successors: successors!(required!(opts, :successors))}

  defp params!("retire", opts), do: %{page: required!(opts, :page)}

  defp params!("restore", opts),
    do: %{page: required!(opts, :page), path: required!(opts, :path)}

  defp params!("rollback", opts), do: %{operation: required!(opts, :operation)}

  defp required!(opts, key) do
    case opts[key] do
      nil -> Mix.raise("--#{key} is required\n" <> @usage)
      value when is_binary(value) and value == "" -> Mix.raise("--#{key} is required\n" <> @usage)
      value -> value
    end
  end

  # The successors as the choice will list them, in the given order. Anything
  # that is not a page id is left for the ledger to refuse as `:invalid_page`.
  defp successors!(given) do
    given
    |> String.split(",", trim: true)
    |> Enum.map(fn id ->
      case Integer.parse(String.trim(id)) do
        {n, ""} -> n
        _other -> id
      end
    end)
  end

  defp describe("move", p), do: "move page #{p.page} to #{p.path}"
  defp describe("merge", p), do: "merge page #{p.from} into page #{p.into}"

  defp describe("split", p),
    do: "split page #{p.page} into pages #{Enum.join(p.successors, ", ")}"

  defp describe("retire", p), do: "retire page #{p.page}"
  defp describe("restore", p), do: "restore page #{p.page} at #{p.path}"
  defp describe("rollback", p), do: "roll back operation #{p.operation}"

  defp call("move", p, actor, reason), do: Ledger.move(p.page, p.path, opts(actor, reason))
  defp call("merge", p, actor, reason), do: Ledger.merge(p.from, p.into, opts(actor, reason))

  defp call("split", p, actor, reason),
    do: Ledger.split(p.page, p.successors, opts(actor, reason))

  defp call("retire", p, actor, reason), do: Ledger.retire(p.page, opts(actor, reason))

  defp call("restore", p, actor, reason),
    do: Ledger.restore(p.page, p.path, opts(actor, reason))

  defp call("rollback", p, actor, reason), do: Ledger.rollback(p.operation, opts(actor, reason))

  defp opts(actor, reason), do: [actor_id: actor.id, reason: reason]

  # ── the actor ────────────────────────────────────────────────────────────

  # The account must hold the reviewer role, checked before anything else.
  defp reviewer!(email) do
    case Repo.get_by(User, email: email) do
      %User{reviewer: true} = user -> user
      %User{} -> Mix.raise("#{email} does not hold the reviewer role\nNothing written.")
      nil -> Mix.raise("no account #{email}\nNothing written.")
    end
  end

  # The account's `user` actor, as `Routing.Backfill` resolves a reviewer. An
  # account without one gets it in the operation's own transaction, so a
  # refusal leaves no actor row behind either. Inside that transaction the
  # ledger returns its refusal without rolling back, so the rollback is ours.
  # Returns `{:ok, result, created}`, where `created` is the actor row this
  # invocation wrote (nil when the account already had one), or the ledger's
  # `{:error, refusal}`. The actor row is the one write outside the ledger:
  # the ledger records a named human only through a `user` actor.
  defp with_actor(user, fun) do
    case Repo.get_by(Actor, actor_kind: :user, user_id: user.id) do
      %Actor{} = actor ->
        case fun.(actor) do
          {:ok, result} -> {:ok, result, nil}
          {:error, refusal} -> {:error, refusal}
        end

      nil ->
        result =
          Repo.transaction(fn ->
            actor =
              Repo.insert!(%Actor{
                actor_kind: :user,
                user_id: user.id,
                label: "Reviewer ##{user.id}"
              })

            case fun.(actor) do
              {:ok, result} -> {result, actor}
              {:error, refusal} -> Repo.rollback(refusal)
            end
          end)

        case result do
          {:ok, {result, actor}} -> {:ok, result, actor}
          {:error, refusal} -> {:error, refusal}
        end
    end
  end

  defp print_created(nil, _user), do: :ok

  defp print_created(%Actor{} = actor, user) do
    Mix.shell().info(
      "  actors\n    ##{actor.id}  user ##{user.id}  kind user  label #{inspect(actor.label)}  " <>
        "(created with this operation: the ledger records a named human only through a user actor)"
    )
  end

  # ── what the operation touches ───────────────────────────────────────────

  # The pages whose state is shown and the stored paths whose answers are
  # shown, before and after. A path the operation names is shown even when
  # nothing serves it yet.
  defp touched("move", p),
    do: %{pages: [p.page], paths: Enum.uniq(paths_of([p.page]) ++ [p.path])}

  defp touched("merge", p), do: %{pages: [p.from, p.into], paths: paths_of([p.from, p.into])}

  defp touched("split", p) do
    pages = [p.page | p.successors]
    %{pages: pages, paths: paths_of(pages)}
  end

  defp touched("retire", p), do: %{pages: [p.page], paths: paths_of([p.page])}

  defp touched("restore", p),
    do: %{pages: [p.page], paths: Enum.uniq(paths_of([p.page]) ++ [p.path])}

  defp touched("rollback", p) do
    rows = Ledger.operation(p.operation)

    pages =
      rows
      |> Enum.flat_map(&[&1.page_id, &1.before_destination_id, &1.after_destination_id])
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()

    path_ids = rows |> Enum.map(& &1.path_id) |> Enum.reject(&is_nil/1) |> Enum.uniq()

    named =
      if path_ids == [],
        do: [],
        else: Repo.all(from p in PublicPath, where: p.id in ^path_ids, select: p.path)

    %{pages: pages, paths: Enum.uniq(named ++ paths_of(pages))}
  end

  defp paths_of(page_ids) do
    page_ids
    |> Enum.filter(&(is_integer(&1) and &1 > 0))
    |> Enum.flat_map(&Resolver.paths/1)
    |> Enum.map(& &1.path)
    |> Enum.uniq()
  end

  defp merge_touched(before, now),
    do: %{
      pages: Enum.uniq(before.pages ++ now.pages),
      paths: Enum.uniq(before.paths ++ now.paths)
    }

  # ── the registry's part of a merge or split ──────────────────────────────

  # A registry merge or split must already exist. The ledger decides; this
  # says what the registry holds so a refusal is understood, and never
  # creates one.
  defp report_registry("merge", p) do
    with %Page{target_object_id: from} when is_integer(from) <- page(p.from),
         %Page{target_object_id: into} when is_integer(into) <- page(p.into) do
      survivor = Registry.canonical_id(into)

      line =
        case Registry.resolve(from) do
          {:merged, ^survivor} ->
            "object #{from} is merged into object #{survivor}, the survivor's identity"

          other ->
            "object #{from} is #{identity(other)}; no registry merge of #{from} into " <>
              "#{into} exists, and this tool creates none"
        end

      Mix.shell().info("registry   #{line}")
    else
      _editorial -> :ok
    end
  end

  defp report_registry("split", p) do
    case page(p.page) do
      %Page{target_object_id: target} when is_integer(target) ->
        outputs =
          case Registry.resolve(target) do
            {:split, ids} -> ids
            _other -> []
          end

        line =
          if outputs == [],
            do:
              "object #{target} is #{identity(Registry.resolve(target))}; no registry split " <>
                "of #{target} exists, and this tool creates none",
            else: "object #{target} is split into objects #{Enum.join(outputs, ", ")}"

        Mix.shell().info("registry   #{line}")

        for id <- p.successors, %Page{target_object_id: object} <- [page(id)] do
          status =
            cond do
              is_nil(object) -> "about no registry object"
              object in outputs -> "a split output"
              true -> "not a split output"
            end

          Mix.shell().info("           page #{id} is about object #{object || "none"}, #{status}")
        end

      _other ->
        :ok
    end
  end

  defp report_registry(_operation, _params), do: :ok

  defp identity(:itself), do: "its own live identity"
  defp identity({:merged, id}), do: "merged into object #{id}"
  defp identity({:split, ids}), do: "split into objects #{Enum.join(ids, ", ")}"
  defp identity({:cycle, ids}), do: "in a merge cycle (#{Enum.join(ids, ", ")})"
  defp identity(nil), do: "not a registry object"

  # ── printing state ───────────────────────────────────────────────────────

  defp print_state(label, %{pages: pages, paths: paths}) do
    Mix.shell().info(label)
    for id <- pages, do: Mix.shell().info("  " <> page_line(id))
    for path <- paths, do: Mix.shell().info("  " <> resolution_line(path, request(path)))
  end

  # A stored path is asked for as a request spells it; anything that is not
  # a stored path is asked for as given, and answered as a request would be.
  defp request(path) do
    case Address.parse(path) do
      {:ok, _parsed} -> Address.encode(path)
      {:error, _reason} -> path
    end
  end

  # An id outside `bigint` names no page; asking the database would raise
  # rather than let the ledger refuse it as `:invalid_page`.
  defp page(id) when is_id(id), do: Repo.get(Page, id)
  defp page(_id), do: nil

  defp page_line(id) do
    case page(id) do
      nil ->
        "page #{id}: no such page"

      %Page{} = page ->
        canonical = page.canonical_path_id && Repo.get!(PublicPath, page.canonical_path_id).path

        "page #{page.id}  #{page.role} #{page.locale}  #{page.lifecycle_state}  " <>
          "#{page.publication_state}  canonical #{canonical || "none"}  " <>
          "target #{page.target_object_id || "none"}  " <>
          "merged into #{page.merged_into_page_id || "none"}  " <>
          "revision #{page.current_revision_id || "none"}"
    end
  end

  defp resolution_line(shown, raw) do
    public = Resolver.resolve(raw, mode: :public)
    internal = Resolver.resolve(raw, mode: :internal)

    "#{String.pad_trailing(shown, 40)} public #{String.pad_trailing(answer(public), 34)} " <>
      "internal #{answer(internal)}"
  end

  defp answer(%Resolution{} = r) do
    status = Resolution.http_status(r)

    case r.outcome do
      :redirect -> "#{status} redirect -> #{r.location}"
      :choice -> "#{status} choice#{successors(r)}"
      :invalid -> "#{status} invalid (#{r.reason})"
      :corrupt -> "#{status} corrupt (#{r.reason})"
      outcome -> "#{status} #{outcome}"
    end
  end

  defp successors(%Resolution{successors: []}), do: ""

  defp successors(%Resolution{successors: successors}) do
    listed =
      Enum.map_join(successors, ", ", fn %{page_id: id, resolution: r} ->
        "page #{id} #{answer(r)}"
      end)

    " [#{listed}]"
  end

  # ── printing what was written ────────────────────────────────────────────

  defp print_written(operation, result, newest, newest_revision) do
    rows = rows_written(operation, result, newest)

    if rows == [] do
      Mix.shell().info("written    nothing: the ledger had nothing to change")
    else
      [first | _] = rows

      Mix.shell().info(
        "written    operation #{first.operation_id} (#{first.operation}), " <>
          "#{length(rows)} route_changes rows, actor #{first.actor_id}" <>
          if(first.reverts_operation_id, do: ", reverts #{first.reverts_operation_id}", else: "")
      )

      Mix.shell().info("  route_changes")
      for row <- rows, do: Mix.shell().info("    " <> change_line(row))

      path_ids = rows |> Enum.map(& &1.path_id) |> Enum.reject(&is_nil/1) |> Enum.uniq()
      page_ids = rows |> Enum.map(& &1.page_id) |> Enum.reject(&is_nil/1) |> Enum.uniq()

      if path_ids != [] do
        Mix.shell().info("  public_paths")

        for path <- Repo.all(from p in PublicPath, where: p.id in ^path_ids, order_by: p.id),
            do: Mix.shell().info("    " <> path_row(path))
      end

      if page_ids != [] do
        Mix.shell().info("  pages")

        for page <- Repo.all(from p in Page, where: p.id in ^page_ids, order_by: p.id),
            do: Mix.shell().info("    " <> page_row(page))
      end

      revisions =
        rows
        |> Enum.filter(&(&1.page_id && &1.before_revision_id != &1.after_revision_id))
        |> Enum.map(& &1.after_revision_id)
        |> Enum.reject(&is_nil/1)
        |> Enum.uniq()

      # A revision this operation inserted (a split's) is written; one a
      # rollback points the page back to already existed, and says so.
      {written, restored} =
        Repo.all(
          from r in PageRevision,
            where: r.id in ^revisions,
            order_by: r.id,
            preload: :memberships
        )
        |> Enum.split_with(&(&1.id > newest_revision))

      if written != [] do
        Mix.shell().info("  page_revisions")
        for revision <- written, do: Mix.shell().info("    " <> revision_row(revision))
      end

      if restored != [] do
        Mix.shell().info(
          "  page_revisions the page returns to (not written: they already existed)"
        )

        for revision <- restored, do: Mix.shell().info("    " <> revision_row(revision))
      end
    end
  end

  # The operation's rows, found from what the ledger returned and bounded to
  # what this invocation wrote: a no-op (a move to the current canonical)
  # returns an old row and is reported as nothing written.
  defp rows_written("rollback", operation_id, newest) do
    Repo.all(
      from c in RouteChange,
        where: c.reverts_operation_id == ^operation_id and c.id > ^newest,
        order_by: c.sequence
    )
  end

  defp rows_written(_operation, %{last_route_change_id: change_id}, newest) do
    case Repo.get(RouteChange, change_id) do
      nil -> []
      change -> change.operation_id |> Ledger.operation() |> Enum.filter(&(&1.id > newest))
    end
  end

  defp change_line(%RouteChange{path_id: path_id} = c) when is_integer(path_id) do
    path = Repo.get!(PublicPath, path_id)

    "##{c.id}  seq #{c.sequence}  path ##{path_id} #{path.path}  " <>
      "kind #{c.before_kind || "new"} -> #{c.after_kind}  " <>
      "destination #{c.before_destination_id || "none"} -> #{c.after_destination_id || "none"}" <>
      decision(c)
  end

  defp change_line(%RouteChange{} = c) do
    "##{c.id}  seq #{c.sequence}  page ##{c.page_id}  " <>
      "lifecycle #{c.before_lifecycle} -> #{c.after_lifecycle}  " <>
      "canonical #{c.before_canonical_path_id || "none"} -> #{c.after_canonical_path_id || "none"}  " <>
      "merged into #{c.before_merged_into_id || "none"} -> #{c.after_merged_into_id || "none"}  " <>
      "revision #{c.before_revision_id || "none"} -> #{c.after_revision_id || "none"}" <>
      decision(c)
  end

  defp decision(%RouteChange{classification_decision_id: nil}), do: ""

  defp decision(%RouteChange{} = c),
    do: "  decision #{c.classification_decision_id} (policy #{c.policy_version})"

  defp path_row(%PublicPath{} = p) do
    "##{p.id}  #{p.path}  #{p.kind}  original #{p.original_page_id}  " <>
      "destination #{p.destination_page_id}  last_route_change #{p.last_route_change_id}"
  end

  defp page_row(%Page{} = p) do
    "##{p.id}  #{p.role} #{p.locale}  #{p.lifecycle_state}  #{p.publication_state}  " <>
      "canonical #{p.canonical_path_id || "none"}  merged into #{p.merged_into_page_id || "none"}  " <>
      "revision #{p.current_revision_id || "none"}  last_route_change #{p.last_route_change_id}"
  end

  defp revision_row(%PageRevision{} = r) do
    members =
      Enum.map_join(r.memberships, ", ", fn m ->
        "#{m.position} #{m.relationship} -> " <>
          if(m.target_page_id,
            do: "page #{m.target_page_id}",
            else: "object #{m.target_object_id}"
          )
      end)

    "##{r.id}  page #{r.page_id}  revision #{r.revision_number}  memberships [#{members}]"
  end

  # ── the ledger's refusals, in words ──────────────────────────────────────

  defp explain(refusal), do: "#{inspect(refusal)} (#{why(refusal)})"

  defp why(:page_not_found), do: "no page with that id"
  defp why(:page_not_active), do: "the page is merged, split or retired, not active"
  defp why(:no_canonical), do: "the page has no canonical to move from"
  defp why({:path_taken, owner}), do: "the path is #{owner.kind} of page #{owner.page_id}"

  defp why({:tombstoned, owner}),
    do: "the path is a tombstone of page #{owner.page_id}; only restore brings it back"

  defp why(:identity_not_merged),
    do:
      "the registry has not merged the page's identity into the survivor's; " <>
        "a registry merge must already exist, and this tool does not create one"

  defp why(:identity_not_split),
    do:
      "the registry has not split the page's identity; " <>
        "a registry split must already exist, and this tool does not create one"

  defp why(:not_an_identity_page), do: "the page is about no registry object, so it cannot split"
  defp why(:pages_not_equivalent), do: "the pages differ in role or locale"
  defp why(:survivor_not_published), do: "a published page cannot merge into an unpublished one"
  defp why(:same_page), do: "a page cannot merge into itself"
  defp why(:successors_required), do: "a split names at least one successor"
  defp why(:duplicate_successor), do: "a successor is named twice"
  defp why(:page_cannot_succeed_itself), do: "a page cannot be its own successor"
  defp why(:successor_not_active), do: "a successor is not active"
  defp why(:successor_locale_differs), do: "a successor is in another locale"
  defp why(:successor_not_a_split_output), do: "a successor is not the page of a split output"
  defp why(:successor_not_published), do: "a published page's successors must be published"
  defp why(:page_not_restorable), do: "only an active or retired page can be restored"
  defp why(:no_such_reservation), do: "no reservation of that path exists"
  defp why({:not_a_tombstone, kind}), do: "the path is the page's #{kind}, not a tombstone"
  defp why(:unknown_operation), do: "no ledger operation has that id"
  defp why(:already_rolled_back), do: "the operation is already rolled back"

  defp why({:stale, _change}),
    do: "a later operation on the same path or page is still in force; roll that back first"

  defp why({:published_page_needs_canonical, id}),
    do: "page #{id} is published and would be left without a canonical"

  defp why(:allocation_conflict), do: "the operation lost a race three times; try again"
  defp why(:actor_required), do: "no actor"
  defp why(:human_approval_required), do: "the actor is not a human account"
  defp why(:reason_required), do: "a reason is required"
  defp why(:invalid_reason), do: "the reason is not valid text"
  defp why(:invalid_page), do: "a page id must be a positive integer"
  defp why(:invalid_operation), do: "an operation id is a UUID"
  defp why(:locale_mismatch), do: "the path's locale is not the page's"
  defp why({:namespace_not_allowed, role}), do: "a #{role} page may not use that namespace"
  defp why(:target_not_active), do: "the page's registry object is not active"
  defp why(:unclassified), do: "the page's object has no current classification"
  defp why({:family_mismatch, family}), do: "the object's current decision maps it to #{family}"

  defp why({:classification_not_mapped, status}),
    do: "the object's current decision is #{status}, not mapped"

  defp why(:not_ledger_addressed), do: "lexeme pages are not addressed by the ledger"
  defp why(:namespace_undefined), do: "the registry defines no namespace for that page role"
  defp why(:unknown_namespace), do: "the path's namespace is not in the registry"
  defp why(:invalid_shape), do: "a path is /<namespace>/<slug>"
  defp why(:not_absolute), do: "a path starts with /"
  defp why(:invalid_locale), do: "the path's locale prefix is not valid"
  defp why(:segment_too_long), do: "the slug is longer than the registry allows"
  defp why(:not_normalized), do: "the slug is not NFC lowercase"
  defp why(:invalid_segment), do: "the slug has characters a path may not hold"
  defp why(:invalid_encoding), do: "the path is not valid UTF-8"
  defp why(_other), do: "see Routing.Ledger"
end
