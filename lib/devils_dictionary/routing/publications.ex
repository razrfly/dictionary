defmodule DevilsDictionary.Routing.Publications do
  @moduledoc """
  Publication and withdrawal (#237, Stage 5 of #194; ADR 0004 §7).

  `publish/3` publishes the pages a launch manifest names
  (`Routing.LaunchManifest`), each only if it passes **all eight gates**,
  checked against the record at the moment of publishing:

  | gate | passes when |
  |---|---|
  | `identity` | the page is active, and its registry object is active: not merged, split or retired |
  | `decision` | the object's current classification decision is `mapped` to the family of the page's address (an edition's is `works`) — the evaluator's, or a standing override |
  | `canonical` | the page holds a canonical address, it is the one the manifest names, and the resolver serves the page there |
  | `content` | the page renders at least one section the entity actually has — a biography paragraph, a work, a definition, a quotation, an edition, an edition's contents — whose text may be shown; not a fixture, and not a label and an imported description alone |
  | `display` | every body the page renders passes `Claims.Visibility`: nothing whose rights restrict it is shown |
  | `approval` | the page is in the manifest with a reviewer's name: an account holding the reviewer role, who is the actor publishing; under a standing review rule, the manifest was made under that signed rule, the reviewer is its signer, and a confirming clause decided the record |
  | `metadata` | a title, the canonical address and a description are derivable (`Routing.PageMetadata`) |
  | `integrity` | the routing schema is present, the page and every address it serves resolve without corrupt state, and it has exactly one canonical |

  A page that fails a gate is refused, alone: each page is its own
  transaction, so a refusal never rolls back the batch, and is reported with
  every gate's finding; a refusal the database makes at the receipt or at
  commit is reported the same way, as `database`, in the database's words.
  A manifest made without a rule publishes only as a human's override
  (`override: true` with a `reason:`, D3 as amended), which every receipt
  carries; a rule's manifest takes none. A page that passes gets a receipt
  (`Routing.PagePublication`) — the manifest's digest, the rule's digest, the
  eight gates as found, the human actor and the reason — and its
  `publication_state` becomes `published` in the same transaction; the
  database refuses the change without the receipt. Publishing is
  idempotent: a published page is unchanged. A withdrawn page stays
  withdrawn: a withdrawal is a human's decision, and only a human's explicit
  `republish: true`, with a reason, publishes it again. `dry_run: true`
  checks every gate and writes nothing.

  `withdraw/3` is the human reverse: a reviewer takes a published page out
  of public view, with a reason. A withdrawn page's addresses answer 404
  publicly (`Routing.Resolver`); 410 is only for retirement.

  Publishing is not a route change: no address moves, and `route_changes` is
  untouched.
  """

  import Ecto.Query
  import DevilsDictionary.Routing.Input, only: [is_id: 1, text?: 1]

  alias DevilsDictionary.Accounts.User
  alias DevilsDictionary.Claims.Visibility
  alias DevilsDictionary.Encyclopedia.EntityPage
  alias DevilsDictionary.Registry.{Entity, Object}
  alias DevilsDictionary.Repo

  alias DevilsDictionary.Routing.{
    Address,
    Classifications,
    Page,
    PageMetadata,
    PagePublication,
    PublicPath,
    Recovery,
    Resolver
  }

  alias DevilsDictionary.Sources.Actor

  @gates ~w(identity decision canonical content display approval metadata integrity)
  @confirming ~w(standing_decision uncontested_mapping qualified_collision)

  @doc "The eight gates, in the order they are checked and recorded."
  def gates, do: @gates

  # ── publish ──────────────────────────────────────────────────────────────

  @doc """
  Publishes every page entry of `manifest` (from `LaunchManifest.read/1`)
  that passes the eight gates, as the human actor `actor_id`.

  Options: `rule:` the loaded, signed standing review rule the manifest was
  made under (`Routing.ReviewRule.load/1`); `dry_run: true`; `only:` page
  ids; `republish: true` with `reason:`, a human's explicit decision to
  publish a withdrawn page again.

  Returns `{:ok, report}` — `:published`, `:would_publish` (a dry run),
  `:unchanged` and `:refused`, each a list of `%{page_id:, path:, ...}`, a
  refusal with `:failed` (the gates it failed) and `:gates` — or `{:error,
  reason}` before anything is written: the actor is not a human.
  """
  def publish(manifest, actor_id, opts \\ []) do
    with {:ok, actor} <- human(actor_id),
         :ok <- republish_reason(opts),
         :ok <- override_reason(manifest, opts) do
      ctx = %{
        manifest: manifest,
        actor: actor,
        user: Repo.get(User, actor.user_id),
        rule: opts[:rule],
        dry_run: Keyword.get(opts, :dry_run) == true,
        republish: Keyword.get(opts, :republish) == true,
        override: Keyword.get(opts, :override) == true,
        reason: opts[:reason],
        schema: Recovery.routing_schema()
      }

      only = opts[:only] && MapSet.new(opts[:only])

      results =
        manifest.pages
        |> Enum.sort_by(&elem(&1, 0))
        |> Enum.filter(fn {id, _entry} -> is_nil(only) or MapSet.member?(only, id) end)
        |> Enum.map(fn {_id, entry} -> one(entry, ctx) end)

      report =
        Enum.reduce(
          results,
          %{published: [], would_publish: [], unchanged: [], refused: []},
          fn {outcome, result}, acc -> Map.update!(acc, outcome, &[result | &1]) end
        )
        |> Map.new(fn {key, list} -> {key, Enum.reverse(list)} end)
        |> Map.put(:empty, map_size(manifest.pages) == 0)

      {:ok, report}
    end
  end

  defp republish_reason(opts) do
    if Keyword.get(opts, :republish, false) and not reason?(opts[:reason]),
      do: {:error, :reason_required},
      else: :ok
  end

  # A human's override (D3 as amended): a manifest made without a rule
  # publishes only as one, with a reason every receipt carries; a rule's
  # manifest takes none.
  defp override_reason(manifest, opts) do
    cond do
      Keyword.get(opts, :override, false) and not reason?(opts[:reason]) ->
        {:error, :reason_required}

      Keyword.get(opts, :override, false) and manifest.rule_sha256 ->
        {:error, :override_under_rule}

      true ->
        :ok
    end
  end

  # One page, one transaction: a refusal is this page's alone. A refusal the
  # database makes at the receipt or at commit (a constraint, a trigger) is
  # this page's too: reported as refused with the database's words, and the
  # batch goes on.
  defp one(entry, ctx) do
    id = entry["page_id"]
    base = %{page_id: id, path: entry["path"], object_id: entry["object_id"]}

    try do
      {:ok, result} =
        Repo.transaction(
          fn ->
            case load(id, ctx.dry_run) do
              nil ->
                gates = Map.new(@gates, &{&1, fail("no page #{id}")})
                {:refused, Map.merge(base, %{failed: @gates, gates: ordered(gates)})}

              %Page{publication_state: :published} = page ->
                {:unchanged, Map.merge(base, %{state: page.publication_state})}

              %Page{publication_state: :withdrawn} when not ctx.republish ->
                {:unchanged,
                 Map.merge(base, %{
                   state: :withdrawn,
                   note: "withdrawn by a reviewer; only a reviewer's own decision republishes it"
                 })}

              %Page{} = page ->
                gates = evaluate(page, entry, ctx)
                failed = for g <- @gates, not gates[g]["passed"], do: g

                cond do
                  failed != [] ->
                    {:refused, Map.merge(base, %{failed: failed, gates: ordered(gates)})}

                  ctx.dry_run ->
                    {:would_publish, Map.merge(base, %{gates: ordered(gates)})}

                  true ->
                    receipt = write!(page, gates, entry, ctx)

                    {:published,
                     Map.merge(base, %{receipt_id: receipt.id, gates: ordered(gates)})}
                end
            end
          end,
          timeout: :infinity
        )

      result
    rescue
      e in [Postgrex.Error, Ecto.ConstraintError] ->
        {:refused,
         Map.merge(base, %{
           failed: ["database"],
           gates: %{"database" => fail("refused by the database: " <> Exception.message(e))}
         })}
    end
  end

  defp load(id, _dry_run) when not is_id(id), do: nil
  defp load(id, true), do: Repo.get(Page, id)

  defp load(id, false),
    do: Repo.one(from p in Page, where: p.id == ^id, lock: "FOR UPDATE")

  defp write!(page, gates, entry, ctx) do
    receipt =
      Repo.insert!(%PagePublication{
        page_id: page.id,
        action: :publish,
        before_state: page.publication_state,
        after_state: :published,
        manifest_sha256: ctx.manifest.sha256,
        rule_sha256: ctx.manifest.rule_sha256,
        gates: gates,
        actor_id: ctx.actor.id,
        reason: publish_reason(entry, ctx)
      })

    {1, _} =
      Repo.update_all(
        from(p in Page,
          where: p.id == ^page.id and p.publication_state == ^page.publication_state
        ),
        set: [publication_state: :published, updated_at: DateTime.utc_now()]
      )

    receipt
  end

  defp publish_reason(entry, ctx) do
    approval =
      if ctx.manifest.rule_sha256,
        do:
          "under standing review rule #{ctx.manifest.rule_sha256} (#{entry["clause"]}), signed by #{entry["reviewer"]}",
        else: "approved by #{entry["reviewer"]}"

    base = "launch manifest #{ctx.manifest.sha256}, #{approval}"

    cond do
      ctx.republish -> "#{base}; republished: #{ctx.reason}"
      ctx.override -> "#{base}; a human's override: #{ctx.reason}"
      true -> base
    end
  end

  # The gates, as found: each `%{"passed" => bool, "detail" => text}`.
  defp evaluate(page, entry, ctx) do
    canonical = page.canonical_path_id && Repo.get(PublicPath, page.canonical_path_id)

    entity_page =
      if page.role in [:subject, :edition] and page.target_object_id,
        do: EntityPage.build(page.target_object_id)

    %{
      "identity" => identity(page),
      "decision" => decision(page, canonical),
      "canonical" => canonical(page, canonical, entry),
      "content" => content(page, entity_page),
      "display" => check_display(entity_page),
      "approval" => approval(entry, ctx),
      "metadata" => metadata(entity_page, canonical),
      "integrity" => integrity(page, ctx)
    }
  end

  defp ordered(gates),
    do: Jason.OrderedObject.new(for g <- @gates, do: {g, Map.fetch!(gates, g)})

  defp pass(detail), do: %{"passed" => true, "detail" => detail}
  defp fail(detail), do: %{"passed" => false, "detail" => detail}

  # 1. Resolved identity.
  defp identity(%Page{role: role}) when role not in [:subject, :edition],
    do: fail("a #{role} page is not published from a launch manifest")

  defp identity(%Page{lifecycle_state: state}) when state != :active,
    do: fail("the page is #{state}")

  defp identity(%Page{target_object_id: target} = page) do
    case Repo.get(Object, target) do
      %Object{lifecycle_state: :active} ->
        if Repo.exists?(from e in Entity, where: e.object_id == ^target),
          do: pass("object #{target} is active; page #{page.id} is active"),
          else: fail("object #{target} is not an entity")

      %Object{lifecycle_state: state} ->
        fail("object #{target} is #{state}: identity review first")

      nil ->
        fail("no object #{target}")
    end
  end

  # 2. Approved classification.
  defp decision(%Page{target_object_id: target} = page, canonical) do
    family = family_of(page, canonical)

    case target && Classifications.current(target) do
      nil ->
        fail("no current classification decision")

      %{status: :mapped, family: mapped} = d ->
        cond do
          is_nil(family) ->
            fail("mapped to #{mapped}, and the page has no address to hold it to")

          Atom.to_string(mapped) == family ->
            pass("mapped to #{mapped} by #{decided_by(d)}")

          true ->
            fail("mapped to #{mapped}, but the address is in /#{family}")
        end

      %{status: status, reasons: reasons} ->
        fail("the current decision is #{status} (#{Enum.join(reasons, ", ")})")
    end
  end

  defp family_of(%Page{role: :edition}, _canonical), do: "works"
  defp family_of(_page, nil), do: nil

  defp family_of(_page, %PublicPath{path: path}) do
    case Address.parse(path) do
      {:ok, %{namespace: namespace}} -> namespace
      _ -> nil
    end
  end

  defp decided_by(d) do
    case {d.origin, Classifications.rule_sha256(d)} do
      {:override, nil} -> "a reviewer's override"
      {:override, sha256} -> "the standing review rule #{short(sha256)}"
      {:evaluator, _} -> "the evaluator, policy #{d.policy_version}"
    end
  end

  # 3. A unique allocated canonical, the manifest's, served at that address.
  defp canonical(_page, nil, _entry), do: fail("no canonical address is allocated")

  # The address is found to be this page's, and the page, once published,
  # answers there publicly: the resolver's own decision, asked of the page as
  # it would be (a draft and a withdrawn page are withheld until then).
  defp canonical(page, %PublicPath{} = canonical, entry) do
    named = entry["path"] && String.normalize(entry["path"], :nfc)
    found = Resolver.resolve(Address.encode(canonical.path), mode: :internal)

    published =
      Resolver.decide(
        canonical,
        %{page | publication_state: :published},
        canonical,
        true,
        :public
      )

    cond do
      canonical.kind != :canonical or canonical.destination_page_id != page.id ->
        fail("the page's canonical pointer names #{canonical.path}, which is not its canonical")

      named != canonical.path ->
        fail(
          "the manifest names #{inspect(entry["path"])}; the page's canonical is #{canonical.path}"
        )

      is_nil(found.page) or found.page.id != page.id ->
        fail("the resolver finds #{found.outcome} at #{canonical.path}, not this page")

      published.outcome != :canonical ->
        fail("published, the page would answer #{published.outcome} at #{canonical.path}")

      true ->
        pass(canonical.path)
    end
  end

  # 4. Useful, distinct content.
  defp content(_page, nil), do: fail("the page builds nothing: no entity")

  defp content(%Page{target_object_id: target}, %EntityPage{} = ep) do
    fixture =
      Repo.one(from e in Entity, where: e.object_id == ^target, select: e.metadata["fixture"])

    # A body counts only where it may be shown (`shown/1`); a work or an
    # edition is a label the entity actually has, as #237 step 1 allows
    # ("a work, a biography paragraph, a quotation"), and counts as such.
    counts =
      [
        biography: shown(ep.biography),
        works: length(ep.works),
        definitions: shown(ep.definitions),
        quotations: shown(ep.quotations),
        editions: length(ep.editions),
        contents: shown(ep.contents)
      ]
      |> Enum.reject(fn {_section, n} -> n == 0 end)

    cond do
      fixture ->
        fail("a fixture (#{inspect(fixture)}), never a public subject")

      counts == [] ->
        fail(
          "a label and an imported description alone: no biography, work, definition, quotation, edition or contents to show"
        )

      true ->
        pass(Enum.map_join(counts, ", ", fn {section, n} -> "#{section} #{n}" end))
    end
  end

  defp shown(views),
    do: Enum.count(views, &(is_binary(&1[:body]) and not &1[:display_restricted?]))

  @doc """
  Gate 5, permitted display, for a built page: every body it renders passes
  `Claims.Visibility`. The reader redacts a restricted body by construction,
  so this is the guard against a reader that stops doing so.
  """
  def check_display(nil), do: fail("the page builds nothing: no entity")

  def check_display(%EntityPage{} = ep) do
    bodies =
      for section <- [ep.biography, ep.definitions, ep.contents, ep.quotations, ep.misattributed],
          view <- section,
          is_map(view),
          do: view

    shown = Enum.filter(bodies, &is_binary(&1[:body]))
    forbidden = Enum.reject(shown, &displayable?/1)
    withheld = Enum.count(bodies, &(&1[:display_restricted?] == true))

    if forbidden == [] do
      pass(
        "#{length(shown)} bodies shown, every one permitted; #{withheld} withheld by rights metadata"
      )
    else
      ids = Enum.map_join(forbidden, ", ", &to_string(&1[:object_id]))
      fail("#{length(forbidden)} bodies shown that Visibility forbids: #{ids}")
    end
  end

  defp displayable?(view) do
    Visibility.body_displayable?(%{rights_metadata: view[:rights_metadata] || %{}}) and
      view[:display_restricted?] != true and
      view[:lifecycle_state] not in [:withdrawn, "withdrawn"]
  end

  # 6. Editorial approval.
  defp approval(entry, ctx) do
    email = entry["reviewer"]
    reviewer = is_binary(email) && Repo.get_by(User, email: email)
    rule = ctx.rule
    manifest = ctx.manifest

    cond do
      not match?(%User{reviewer: true}, reviewer) ->
        fail("#{inspect(email)} is not a reviewer account")

      is_nil(ctx.user) or ctx.user.id != reviewer.id ->
        fail(
          "approved by #{email}, but published by actor #{ctx.actor.id}, who is not that reviewer"
        )

      manifest.rule_sha256 && is_nil(rule) ->
        fail(
          "the manifest was made under rule #{short(manifest.rule_sha256)}, which was not given"
        )

      manifest.rule_sha256 && rule.sha256 != manifest.rule_sha256 ->
        fail(
          "the manifest was made under rule #{short(manifest.rule_sha256)}, not #{short(rule.sha256)}"
        )

      manifest.rule_sha256 && rule.signer.email != email ->
        fail("approved by #{email}, but the rule is signed by #{rule.signer.email}")

      manifest.rule_sha256 && entry["clause"] not in @confirming ->
        fail("the rule did not confirm it (#{inspect(entry["clause"])})")

      manifest.rule_sha256 ->
        pass(
          "in launch manifest #{short(manifest.sha256)}, under standing review rule #{short(rule.sha256)} (#{entry["clause"]}) signed by #{email}"
        )

      true ->
        pass("in launch manifest #{short(manifest.sha256)}, approved by #{email}")
    end
  end

  # 7. Complete metadata.
  defp metadata(nil, _canonical), do: fail("the page builds nothing: no entity")
  defp metadata(_ep, nil), do: fail("no canonical address to name")

  defp metadata(%EntityPage{} = ep, %PublicPath{path: path}) do
    meta = PageMetadata.subject(ep, path)
    missing = for key <- [:title, :description, :family_label], is_nil(meta[key]), do: key

    if missing == [],
      do: pass("#{meta.title} · #{meta.family_label}; #{path}; #{inspect(meta.description)}"),
      else: fail("no #{Enum.join(missing, ", ")} can be derived")
  end

  # 8. No blocking integrity issue.
  defp integrity(%Page{} = page, ctx) do
    paths = Repo.all(from p in PublicPath, where: p.destination_page_id == ^page.id)
    canonicals = Enum.count(paths, &(&1.kind == :canonical))

    corrupt =
      [Resolver.resolve_page(page.id, mode: :internal)] ++
        Enum.map(paths, &Resolver.resolve(Address.encode(&1.path), mode: :internal))

    corrupt = Enum.filter(corrupt, &(&1.outcome == :corrupt))

    cond do
      ctx.schema != :present ->
        fail("the routing schema is #{inspect(ctx.schema)}")

      corrupt != [] ->
        fail("corrupt resolver state at #{Enum.map_join(corrupt, ", ", &inspect(&1.request))}")

      canonicals != 1 ->
        fail("#{canonicals} canonical addresses serve the page")

      true ->
        pass(
          "routing schema present; #{length(paths)} addresses and the page resolve; one canonical"
        )
    end
  end

  defp short(sha256), do: String.slice(sha256, 0, 12) <> "…"

  # ── withdraw ─────────────────────────────────────────────────────────────

  @doc """
  Withdraws a published page, as the human actor `actor_id`, for `reason`:
  a receipt, and the page's `publication_state` becomes `withdrawn`, in one
  transaction. Returns `{:ok, receipt}` or `{:error, reason}` — the actor
  is not a human, no reason, no such page, or the page is not published —
  without rolling back a caller's transaction.
  """
  def withdraw(page_id, actor_id, reason) do
    with {:ok, actor} <- human(actor_id),
         true <- reason?(reason) || {:error, :reason_required},
         true <- is_id(page_id) || {:error, :not_found} do
      Repo.transaction(fn ->
        case Repo.one(from p in Page, where: p.id == ^page_id, lock: "FOR UPDATE") do
          nil ->
            {:refused, :not_found}

          %Page{publication_state: :published} = page ->
            receipt =
              Repo.insert!(%PagePublication{
                page_id: page.id,
                action: :withdraw,
                before_state: :published,
                after_state: :withdrawn,
                gates: %{},
                actor_id: actor.id,
                reason: String.trim(reason)
              })

            {1, _} =
              Repo.update_all(
                from(p in Page, where: p.id == ^page.id and p.publication_state == :published),
                set: [publication_state: :withdrawn, updated_at: DateTime.utc_now()]
              )

            {:withdrawn, receipt}

          %Page{publication_state: state} ->
            {:refused, {:not_published, state}}
        end
      end)
      |> case do
        {:ok, {:withdrawn, receipt}} -> {:ok, receipt}
        {:ok, {:refused, reason}} -> {:error, reason}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  defp human(actor_id) when is_id(actor_id) do
    case Repo.get(Actor, actor_id) do
      %Actor{actor_kind: :user, user_id: user_id} = actor when is_integer(user_id) -> {:ok, actor}
      _ -> {:error, :human_required}
    end
  end

  defp human(_actor_id), do: {:error, :human_required}

  defp reason?(reason), do: is_binary(reason) and text?(reason) and String.trim(reason) != ""

  # ── reading ──────────────────────────────────────────────────────────────

  @doc "A page's receipts, oldest first."
  def history(page_id) when is_id(page_id),
    do: Repo.all(from r in PagePublication, where: r.page_id == ^page_id, order_by: r.id)

  def history(_page_id), do: []

  @doc """
  The newest receipt's id, or 0: anything derived from what is published —
  the sitemaps — is current while this is unchanged.
  """
  def generation do
    Repo.one(from r in PagePublication, select: coalesce(max(r.id), 0))
  end
end
