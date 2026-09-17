defmodule DevilsDictionary.Discovery.Conformance do
  @moduledoc """
  One suite every discovery provider passes, or the suite is red (K6 of #109).

  Before this, "does discovery work for X" was an audit: someone opened a page,
  looked at a shelf and wrote a comment. Three providers produced three audits
  and no assertion that the fourth would behave like the first three. This is
  that assertion, and it is deliberately written against
  `DevilsDictionary.Discovery` and nothing else — it never calls a provider's
  own functions except through the pipeline, because a provider that only works
  when called directly is exactly the defect worth catching.

  ## Using it

      defmodule DevilsDictionary.Discovery.Conformance.MetTest do
        use DevilsDictionary.Discovery.Conformance,
          fixture: DevilsDictionary.Discovery.Conformance.MetFixture
      end

  The fixture supplies the two things the shared code cannot invent — a target
  this provider covers, and this provider's own `Req.Test` stub. See
  `DevilsDictionary.Discovery.Conformance.Fixture`.

  ## Two profiles

  A provider that declares `background: true, transport: :server` **and**
  exports the pipeline callbacks is driven end to end: admission, budget,
  positive and negative cache, pagination, cleanup, render and identity.

  A provider that declares neither — Artsy (`background: false`) and GIPHY
  (`transport: :browser`) — is *registry-only*. There is no run to drive, so the
  suite checks the contract half and then asserts the registry agrees it cannot
  be scheduled. That is the honest reading: #109's K6 says every registered
  module must pass, and two of the four registered modules have no `retrieve/4`
  to pass with. The profile is chosen from the provider's own capabilities, so a
  provider that grows a transport is promoted into the full suite without
  anyone remembering to move it.
  """

  alias DevilsDictionary.Discovery.Providers

  @doc false
  def uncovered_target(fixture, context), do: fixture.uncovered_target(context)

  @doc """
  True when the provider *claims* the background pipeline.

  A claim, not the proof: `retrievable?/1` is the proof, and the two are
  compared rather than conflated. Written as a function of an opaque module so
  the type checker cannot fold one provider's literal capability map into a
  constant and call the comparison dead code.
  """
  def declares_pipeline?(provider) do
    capabilities = provider.capabilities()
    capabilities.background and capabilities.transport == :server
  end

  @doc "The provider's optional shelf qualifier, without warning when it has none."
  def shelf_detail(provider) do
    if function_exported?(provider, :shelf_detail, 0), do: provider.shelf_detail()
  end

  @doc "True when this provider can actually be driven through the pipeline."
  def pipeline?(provider) do
    declares_pipeline?(provider) and Providers.retrievable?(provider)
  end

  defmacro __using__(opts) do
    fixture = Macro.expand(Keyword.fetch!(opts, :fixture), __CALLER__)
    Code.ensure_compiled!(fixture)
    provider = fixture.provider()
    Code.ensure_compiled!(provider)

    quote do
      use DevilsDictionary.DataCase, async: false
      use Oban.Testing, repo: DevilsDictionary.Repo

      import Ecto.Query
      import Phoenix.LiveViewTest

      alias DevilsDictionary.Repo
      alias DevilsDictionary.Discovery
      alias DevilsDictionary.Discovery.{ContentTypes, MatchReason, RequestAttempt, Result, Run}
      alias DevilsDictionary.Discovery.Providers
      alias DevilsDictionaryWeb.Culture

      @fixture unquote(fixture)
      @provider unquote(provider)
      @slug unquote(provider).slug()
      @capabilities unquote(provider).capabilities()
      @pipeline? DevilsDictionary.Discovery.Conformance.pipeline?(unquote(provider))

      @moduletag :conformance

      setup do
        catalog = DevilsDictionary.Fixtures.seed_catalog!()

        providers = Application.fetch_env!(:devils_dictionary, :discovery_providers)
        req_options = Application.fetch_env!(:devils_dictionary, :discovery_req_options)
        discovery = Application.fetch_env!(:devils_dictionary, :discovery)

        # One provider at a time. `request_all/2` and the reader iterate the
        # registry, and a second provider's stub answering this one's request
        # is not a conformance result.
        Application.put_env(:devils_dictionary, :discovery_providers, [@provider])

        Application.put_env(:devils_dictionary, :discovery_req_options,
          plug: {Req.Test, @provider}
        )

        on_exit(fn ->
          Application.put_env(:devils_dictionary, :discovery_providers, providers)
          Application.put_env(:devils_dictionary, :discovery_req_options, req_options)
          Application.put_env(:devils_dictionary, :discovery, discovery)
        end)

        context = %{
          sources: catalog.sources,
          scopes: catalog.scopes,
          slug: @slug,
          provider: @provider
        }

        Map.merge(context, @fixture.setup(context))
      end

      describe "#{@slug} — the contract" do
        test "names one identity the registry and the source catalog share" do
          assert is_binary(@slug) and @slug != ""
          attrs = @provider.source_attrs()
          assert attrs.slug == @slug
          assert is_binary(attrs.name) and attrs.name != ""
          assert is_binary(attrs.attribution) and attrs.attribution != ""
          assert is_binary(@provider.adapter_version()) and @provider.adapter_version() != ""
        end

        test "declares capabilities the shared pipeline can branch on" do
          capabilities = @provider.capabilities()

          for key <- ~w(background transport persistence pagination operations content_types)a do
            assert Map.has_key?(capabilities, key),
                   "#{@slug} capabilities/0 is missing #{inspect(key)}"
          end

          assert is_boolean(capabilities.background)
          assert capabilities.transport in [:server, :browser]
          assert capabilities.persistence in [:persistent, :transient]
          assert capabilities.pagination in [:none, :offset, :cursor]
          assert Enum.count(capabilities.operations) > 0
          assert Enum.all?(capabilities.operations, &is_binary/1)
          assert Enum.count(capabilities.content_types) > 0
        end

        test "declares only content types the reader can present" do
          # A provider ships zero components (K2), so a type nobody can render
          # is a shelf that never appears rather than a compile error.
          for type <- @provider.capabilities().content_types do
            assert type in ContentTypes.known(),
                   "#{@slug} declares #{inspect(type)}, which DevilsDictionary.Discovery.ContentTypes cannot present"
          end
        end

        test "pacing declarations, where present, are non-negative milliseconds" do
          capabilities = @provider.capabilities()

          # `Map.fetch/2` and not `Map.get/2` in a `for` qualifier: a qualifier
          # drops a falsy value, so a provider declaring `request_interval_ms:
          # nil` would skip the assertion entirely. Absent is the only thing
          # that may be skipped — the transport reads a declared key and
          # normalises anything non-integer to unpaced, which is a rate this
          # provider did not ask for.
          for key <- [:min_retry_interval_ms, :request_interval_ms] do
            case Map.fetch(capabilities, key) do
              :error ->
                :ok

              {:ok, value} ->
                assert is_integer(value) and value >= 0,
                       "#{@slug} declares #{inspect(key)} as #{inspect(value)}"
            end
          end
        end

        test "shelf_detail is one short qualifier or nothing at all" do
          # It is rendered beside the provider name on a shelf and never
          # persisted: `source_attrs/0` is upserted column by column.
          detail = DevilsDictionary.Discovery.Conformance.shelf_detail(@provider)
          assert is_nil(detail) or (is_binary(detail) and String.length(detail) <= 40)
        end

        test "a module the pipeline is told it can drive exports everything it drives" do
          # `retrieve/4` alone is not the gate: `Discovery` builds the automatic
          # mapping and `Transport` builds the request, both before a run runs.
          if DevilsDictionary.Discovery.Conformance.declares_pipeline?(@provider) do
            assert Providers.retrievable?(@provider),
                   "#{@slug} declares the background pipeline but does not export " <>
                     inspect(Providers.pipeline_callbacks())
          end

          assert @pipeline? == DevilsDictionary.Discovery.Conformance.pipeline?(@provider)
        end
      end

      if @pipeline? do
        describe "#{@slug} — admission" do
          test "admits one run for a covered target and joins the one in flight", context do
            target = @fixture.covered_target(context)
            @fixture.stub(:results, context)

            assert {:queued, run} = Discovery.request(target, @slug)

            # A second visit while the first is still running is the same run.
            # Two runs for one request key is the duplicate-work defect the
            # advisory lock and the request key exist to prevent.
            assert {:queued, same} = Discovery.request(target, @slug)
            assert same.id == run.id
            assert Repo.aggregate(Run, :count) == 1

            assert Discovery.state(target.object_id, @slug).status in [:loading, :deferred]
            assert :ok = Discovery.execute_run(run.id)
            assert Repo.get!(Run, run.id).status == :succeeded
          end

          test "an unregistered provider slug is not admitted", context do
            target = @fixture.covered_target(context)
            assert {:error, :unsupported_provider} = Discovery.request(target, "not-a-provider")
          end

          test "a target the provider declines never becomes a run", context do
            case DevilsDictionary.Discovery.Conformance.uncovered_target(@fixture, context) do
              nil ->
                # The provider covers everything; the positive half is still
                # worth asserting, because `covers?/1` is what the first,
                # disconnected render asks before any run exists.
                assert Discovery.covers?(@provider, @fixture.covered_target(context))

              target ->
                refute Discovery.covers?(@provider, target)
                assert {:error, :target_not_covered} = Discovery.request(target, @slug)
                assert Repo.aggregate(Run, :count) == 0
                assert Discovery.state(target.object_id, @slug).status == :idle
            end
          end
        end

        describe "#{@slug} — budget" do
          test "an exhausted rolling budget defers the run and retains what is shown",
               context do
            target = @fixture.covered_target(context)
            %{pages: [ids | _]} = @fixture.stub(:results, context)

            assert {:queued, first} = Discovery.request(target, @slug)
            assert :ok = Discovery.execute_run(first.id)
            assert Repo.get!(Run, first.id).status == :succeeded

            spent = Repo.aggregate(RequestAttempt, :count)
            assert spent >= 1, "#{@slug} completed a run without recording one outbound request"

            # One request already spent inside the window, a limit of one, and
            # the provider's own override removed so the limit is the limit.
            configure_discovery(
              request_budget_limit: 1,
              source_policies: %{},
              positive_refresh_seconds: 0,
              empty_refresh_seconds: 0,
              refresh_cooldown_seconds: 0
            )

            assert {:queued, deferred} = Discovery.request(target, @slug, refresh: true)
            assert {:snooze, seconds} = Discovery.execute_run(deferred.id)
            assert is_integer(seconds) and seconds > 0

            pending = Repo.get!(Run, deferred.id)
            assert pending.status == :pending
            assert pending.error_code == "request_budget"

            # Nothing left the node, and the shelf still shows the last answer.
            assert Repo.aggregate(RequestAttempt, :count) == spent
            state = Discovery.state(target.object_id, @slug)
            assert Enum.map(state.items, & &1.external_id) == ids
          end
        end

        describe "#{@slug} — cache" do
          test "a positive answer is cached and not asked for twice", context do
            target = @fixture.covered_target(context)
            %{pages: [ids | _]} = @fixture.stub(:results, context)

            assert {:queued, run} = Discovery.request(target, @slug)
            assert :ok = Discovery.execute_run(run.id)

            state = Discovery.state(target.object_id, @slug)
            assert state.status == :ready
            assert Enum.map(state.items, & &1.external_id) == ids
            assert state.provider == @slug

            spent = Repo.aggregate(RequestAttempt, :count)

            assert {:cached, cached} = Discovery.request(target, @slug)
            assert cached.id == run.id
            assert Repo.aggregate(Run, :count) == 1
            assert Repo.aggregate(RequestAttempt, :count) == spent
          end

          test "an empty answer is a negative cache, not a failure", context do
            target = @fixture.covered_target(context)
            assert %{pages: [[]]} = @fixture.stub(:empty, context)

            assert {:queued, run} = Discovery.request(target, @slug)
            assert :ok = Discovery.execute_run(run.id)

            completed = Repo.get!(Run, run.id)
            assert completed.status == :succeeded
            assert completed.result_count == 0

            assert %{status: :empty, items: []} = Discovery.state(target.object_id, @slug)

            spent = Repo.aggregate(RequestAttempt, :count)
            assert {:cached, cached} = Discovery.request(target, @slug)
            assert cached.id == run.id
            assert Repo.aggregate(RequestAttempt, :count) == spent
          end
        end

        if @capabilities.pagination != :none do
          describe "#{@slug} — pagination" do
            test "hands back a cursor and the next page appends to the first", context do
              target = @fixture.covered_target(context)
              assert %{pages: [first_ids, second_ids]} = @fixture.stub(:paged, context)

              assert {:queued, first} = Discovery.request(target, @slug)
              assert :ok = Discovery.execute_run(first.id)

              state = Discovery.state(target.object_id, @slug)
              assert state.pagination == @provider.capabilities().pagination
              assert Enum.map(state.items, & &1.external_id) == first_ids
              assert is_binary(state.next_cursor), "#{@slug} ended pagination on a full page"
              assert state.page == 0

              assert {:queued, second} =
                       Discovery.request_next(
                         target.object_id,
                         @slug,
                         state.page_context,
                         state.page,
                         state.next_cursor
                       )

              assert :ok = Discovery.execute_run(second.id)

              paged = Discovery.state(target.object_id, @slug)
              assert paged.page == 1
              assert Enum.map(paged.items, & &1.external_id) == first_ids ++ second_ids

              # The cursor the provider handed back is the cursor the second
              # request carried, opaque to everything between them.
              assert Repo.get!(Run, second.id).request_parameters["after"] == state.next_cursor
            end

            test "a stale cursor is refused rather than paged from", context do
              target = @fixture.covered_target(context)
              @fixture.stub(:paged, context)

              assert {:queued, first} = Discovery.request(target, @slug)
              assert :ok = Discovery.execute_run(first.id)
              state = Discovery.state(target.object_id, @slug)

              assert {:error, :stale_pagination} =
                       Discovery.request_next(
                         target.object_id,
                         @slug,
                         state.page_context,
                         state.page,
                         "a-cursor-this-provider-never-issued"
                       )
            end
          end
        end

        describe "#{@slug} — cleanup" do
          test "an abandoned run is recovered and completes on the next attempt", context do
            target = @fixture.covered_target(context)
            %{pages: [ids | _]} = @fixture.stub(:results, context)

            assert {:queued, run} = Discovery.request(target, @slug)

            run
            |> Run.lifecycle_changeset(%{
              status: :running,
              started_at: DateTime.utc_now(),
              execution_lease_expires_at: DateTime.add(DateTime.utc_now(), -1, :second)
            })
            |> Repo.update!()

            assert %{recovered: 1} = Discovery.cleanup()
            assert Repo.get!(Run, run.id).status == :pending

            assert :ok = Discovery.execute_run(run.id)
            state = Discovery.state(target.object_id, @slug)
            assert state.status == :ready
            assert Enum.map(state.items, & &1.external_id) == ids
          end
        end

        describe "#{@slug} — identity" do
          test "every persisted result says what identity it resolved to, or why not",
               context do
            target = @fixture.covered_target(context)
            @fixture.stub(:results, context)

            assert {:queued, run} = Discovery.request(target, @slug)
            assert :ok = Discovery.execute_run(run.id)

            results = Repo.all(from r in Result, where: r.run_id == ^run.id)
            assert results != []

            for result <- results do
              # The disposable cache row exists either way: a result is search
              # cache first and a durable identity only if the provider has an
              # identity contract at all.
              assert result.source_record_id

              if function_exported?(@provider, :identity_record, 1) do
                assert result.resolution_state in [
                         :matched,
                         :newly_created,
                         :insufficient_evidence,
                         :conflicting_identifiers
                       ]

                if result.resolution_state in [:matched, :newly_created] do
                  assert is_integer(result.object_id)
                end
              else
                assert result.resolution_state == :insufficient_evidence
                refute result.object_id
              end
            end
          end

          test "a discovery appearance never writes an illustrates claim", context do
            target = @fixture.covered_target(context)
            @fixture.stub(:results, context)

            assert {:queued, run} = Discovery.request(target, @slug)
            assert :ok = Discovery.execute_run(run.id)

            object_ids =
              Repo.all(from r in Result, where: r.run_id == ^run.id, select: r.object_id)
              |> Enum.reject(&is_nil/1)

            if object_ids != [] do
              assert Repo.aggregate(
                       from(revision in DevilsDictionary.Claims.AssertionRevision,
                         where: revision.subject_object_id in ^object_ids
                       ),
                       :count
                     ) == 0
            end
          end
        end

        describe "#{@slug} — the reader" do
          test "renders through Culture.section on its content type's shelf", context do
            target = @fixture.covered_target(context)
            %{pages: [ids | _]} = @fixture.stub(:results, context)

            assert {:queued, run} = Discovery.request(target, @slug)
            assert :ok = Discovery.execute_run(run.id)

            state = Discovery.state(target.object_id, @slug)
            html = render_component(&Culture.section/1, states: %{@slug => state})

            type =
              Enum.find(@provider.capabilities().content_types, &(&1 in ContentTypes.known()))

            assert html =~ ~s(id="culture-shelf-#{type}")
            assert html =~ ContentTypes.fetch!(type).heading

            for item <- state.items do
              assert html =~
                       ~s(id="culture-result-#{item.external_namespace}-#{item.external_id}")
            end

            assert Enum.map(state.items, & &1.external_id) == ids

            # A provider ships zero components: the byline is the source row's
            # name plus whatever `shelf_detail/0` returned, rendered by shared
            # code that names no provider.
            assert html =~ state.provider_name
          end

          test "every result carries a reason that renders as one sentence", context do
            target = @fixture.covered_target(context)
            @fixture.stub(:results, context)

            assert {:queued, run} = Discovery.request(target, @slug)
            assert :ok = Discovery.execute_run(run.id)

            state = Discovery.state(target.object_id, @slug)

            for item <- state.items do
              reasons = MatchReason.from_result(item.match_details, state.term)
              assert reasons != []

              sentence = MatchReason.describe_all(reasons)
              assert is_binary(sentence) and sentence != ""
              assert String.ends_with?(sentence, ".")
            end
          end
        end
      else
        describe "#{@slug} — registry only" do
          test "is registered, and the pipeline gate refuses to schedule it" do
            refute @provider in Providers.server_providers(),
                   "#{@slug} cannot be driven but `server_providers/0` offers it to the worker"

            refute DevilsDictionary.Discovery.Conformance.pipeline?(@provider)
          end

          test "still answers the reader, which asks every registered provider", context do
            target = @fixture.covered_target(context)
            state = Discovery.state(target.object_id, @slug)

            assert state.provider == @slug
            assert state.status == :idle
            assert state.items == []
            assert is_binary(state.provider_name)
          end

          test "a visit cannot admit a run for it either", context do
            target = @fixture.covered_target(context)

            assert {:error, reason} = Discovery.request(target, @slug)

            assert reason in [
                     :provider_disabled,
                     :provider_not_background,
                     :provider_not_server,
                     :provider_not_retrievable
                   ]

            assert Repo.aggregate(Run, :count) == 0
          end
        end
      end

      defp configure_discovery(overrides) do
        config = Application.fetch_env!(:devils_dictionary, :discovery)
        Application.put_env(:devils_dictionary, :discovery, Keyword.merge(config, overrides))
      end
    end
  end
end
