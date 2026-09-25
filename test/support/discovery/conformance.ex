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

  import ExUnit.Assertions

  alias DevilsDictionary.Discovery.{MatchReason, PageEvidence, Providers}

  @doc false
  def uncovered_target(fixture, context), do: fixture.uncovered_target(context)

  @doc """
  C4 of #172: a result retrieved for a word-level recipe is labelled, or the
  suite is red — the way an unlabelled `:query` fails the evidence checks.

  Labelled means all of it: `match_details["level"]` says `"word"`, the
  declared class is `:word_identity` (so the content-type row's `evidence`
  is what admits it, and only three rows do), and every identity reason on
  it is word-level and ends with `MatchReason.word_level_note/1`. A result
  retrieved for a sense-level recipe says `"sense"` and none of that.

  Public, so the suite's own test can hand it an unlabelled result and watch
  it fail.
  """
  def assert_labelled!(details, term, entities) do
    reasons = MatchReason.from_result(details, term)

    case PageEvidence.level(entities) do
      "word" ->
        assert details["level"] == "word",
               "a result from a word-level recipe carries match_details[\"level\"] " <>
                 inspect(details["level"])

        assert MatchReason.declared_evidence(details) == :word_identity,
               "a result from a word-level recipe declares " <>
                 inspect(details["evidence"]) <> ", not \"word_identity\""

        for reason <- reasons, reason.kind not in [:attestation, :query] do
          assert MatchReason.evidence(reason) == :word_identity

          assert String.ends_with?(
                   MatchReason.describe(reason),
                   MatchReason.word_level_note(term)
                 ),
                 "a word-level reason reads #{inspect(MatchReason.describe(reason))}"
        end

      "sense" ->
        assert details["level"] in [nil, "sense"]
        refute Enum.any?(reasons, &(MatchReason.evidence(&1) == :word_identity))
    end
  end

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

  @doc """
  The tier a provider's source row is seeded with.

  Through an opaque module for the same reason as `declares_pipeline?/1`: a
  provider's `source_attrs/0` is a literal, and the type checker would fold
  `attrs.tier in [...]` into a constant and warn that the comparison is
  always true.
  """
  def tier(provider), do: provider.source_attrs()[:tier]

  @doc """
  The operation this provider's own recipe names, for a throwaway target.

  Through an opaque module for the same reason as `declares_pipeline?/1`, and
  for one more: a registry-only provider does not export `automatic_mapping/1`
  at all, and the compiler cannot see that the suite only asks a pipeline
  provider for it.
  """
  def automatic_operation(provider) do
    {operation, _parameters} =
      provider.automatic_mapping(%{
        object_id: 1,
        lexeme_ids: [1],
        term: "war",
        language: "en",
        relevance: "term"
      })

    operation
  end

  @doc """
  A Wikidata that answers every entity request with a human whose label is
  the QID, and every `haswbstatement` search with nothing.

  The default for the conformance suite, installed before a fixture's own
  stubs so any of them can replace it.
  """
  def stub_wikidata_humans do
    Req.Test.stub(DevilsDictionary.Absorb.Clients, fn conn ->
      conn = Plug.Conn.fetch_query_params(conn)

      case conn.params["action"] do
        "query" ->
          Req.Test.json(conn, %{"query" => %{"search" => []}})

        _ ->
          entities =
            (conn.params["ids"] || "")
            |> String.split("|", trim: true)
            |> Map.new(&{&1, human(&1, &1)})

          Req.Test.json(conn, %{"entities" => entities})
      end
    end)
  end

  @doc "A Wikidata entity for a human, in the shape `wbgetentities` returns."
  def human(qid, label, opts \\ []) do
    claims =
      %{
        "P31" => [
          %{
            "mainsnak" => %{"datavalue" => %{"value" => %{"id" => "Q5"}}},
            "rank" => "normal",
            "type" => "statement"
          }
        ]
      }
      |> put_time("P569", opts[:born])
      |> put_time("P570", opts[:died])

    %{
      "id" => qid,
      "labels" => %{"en" => %{"language" => "en", "value" => label}},
      "descriptions" =>
        if(opts[:description],
          do: %{"en" => %{"language" => "en", "value" => opts[:description]}},
          else: %{}
        ),
      "claims" => claims
    }
  end

  defp put_time(claims, _property, nil), do: claims

  defp put_time(claims, property, %Date{} = date) do
    time = "+" <> Date.to_iso8601(date) <> "T00:00:00Z"

    Map.put(claims, property, [
      %{
        "mainsnak" => %{"datavalue" => %{"value" => %{"time" => time, "precision" => 11}}},
        "rank" => "normal",
        "type" => "statement"
      }
    ])
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

        # Creator identity (#164) fetches any QID a result credits that the
        # registry lacks. Every fixture gets a Wikidata that answers "a human"
        # for whatever it is asked, so a provider whose results credit
        # somebody is not an unstubbed request; a fixture that cares what the
        # answer is (`creator_case/1`, the Met's own stub) installs its own.
        DevilsDictionary.Discovery.Conformance.stub_wikidata_humans()

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

          # The tier is where this source sorts among the others on a shelf
          # (#116 M2), so it has to be one the shelf can rank.
          tier = DevilsDictionary.Discovery.Conformance.tier(@provider)

          assert tier in [:aristocracy, :middle, :plebs],
                 "#{@slug} declares tier #{inspect(tier)}"
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

        test "the operation it builds is one it declared" do
          # `operations` was decoration: documented as a required capability
          # key and read by no shared code (#144 Phase 0). It is the operation
          # `automatic_mapping/1` names, which goes into the mapping row and
          # comes back to `validate_mapping/2` and `retrieve/4` — so a provider
          # whose recipe names an operation its capability map does not is
          # describing itself wrongly, and now says so here.
          if DevilsDictionary.Discovery.Conformance.pipeline?(@provider) do
            operation = DevilsDictionary.Discovery.Conformance.automatic_operation(@provider)

            assert operation in @provider.capabilities().operations,
                   "#{@slug} builds the operation #{inspect(operation)} and declares " <>
                     inspect(@provider.capabilities().operations)
          end
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

        describe "#{@slug} — throttling" do
          test "a 429 with Retry-After defers once, backs the provider off, then succeeds",
               context do
            target = @fixture.covered_target(context)

            %{pages: [ids | _]} =
              DevilsDictionary.Discovery.Conformance.Fixture.stub(@fixture, :throttled, context)

            assert {:queued, run} = Discovery.request(target, @slug)

            # One deferral. A throttle is backpressure and never a failure: the
            # run snoozes for the header's seconds and stays pending, so the
            # page keeps whatever it was showing and the work is not lost.
            assert {:snooze, seconds} = Discovery.execute_run(run.id)
            assert is_integer(seconds) and seconds > 0

            deferred = Repo.get!(Run, run.id)
            assert deferred.status == :pending
            assert deferred.error_code == "provider_retry_after"

            # One provider-wide backoff, written where every node and every
            # visit reads it before spending anything — not held in the process
            # that happened to be refused.
            source = Repo.get_by!(DevilsDictionary.Sources.Source, slug: @slug)
            assert %DateTime{} = source.discovery_retry_after
            assert DateTime.compare(source.discovery_retry_after, DateTime.utc_now()) == :gt
            assert source.discovery_retry_reason == "retry_after"

            # The ledger records what was spent, and a refused request was
            # spent: it left the node and counted against the source's budget.
            throttled_attempts = Repo.aggregate(RequestAttempt, :count)
            assert throttled_attempts >= 1

            # Nothing was published, so a second visit cannot read a result
            # that does not exist.
            assert Repo.aggregate(Result, :count) == 0
            assert Discovery.state(target.object_id, @slug).status in [:loading, :deferred]

            # Waiting out `Retry-After`, in the only form a test can: the
            # backoff the transport wrote is the thing that expires.
            source
            |> Ecto.Changeset.change(discovery_retry_after: nil, discovery_retry_reason: nil)
            |> Repo.update!()

            Repo.update_all(from(r in Run, where: r.id == ^run.id), set: [retry_at: nil])

            # One success, on the same run, from the same admission.
            assert :ok = Discovery.execute_run(run.id)
            assert Repo.get!(Run, run.id).status == :succeeded

            state = Discovery.state(target.object_id, @slug)
            assert state.status == :ready
            assert Enum.map(state.items, & &1.external_id) == ids

            assert Repo.aggregate(RequestAttempt, :count) > throttled_attempts
            assert Repo.aggregate(Run, :count) == 1
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

            # Since #164 a result may credit its creator (`authored_by`); what
            # it must never do is claim to illustrate the word it was found for.
            if object_ids != [] do
              assert Repo.aggregate(
                       from(revision in DevilsDictionary.Claims.AssertionRevision,
                         join: predicate in assoc(revision, :predicate),
                         where:
                           revision.subject_object_id in ^object_ids and
                             predicate.key == "illustrates"
                       ),
                       :count
                     ) == 0
            end
          end
        end

        if function_exported?(@fixture, :creator_case, 1) do
          describe "#{@slug} — creator identity (#164)" do
            test "a creator it identifies is credited and linked; one it cannot stays text",
                 context do
              target = @fixture.covered_target(context)

              %{credited: credited_id, qid: qid, text_only: text_id} =
                creator_case = @fixture.creator_case(context)

              # A fixture says how sure its provider is: the Met's constituent
              # is the museum's own statement (`:verified`); a Wikiquote theme
              # page's citation link is a candidate (#158 build 4).
              expected_confidence =
                DevilsDictionary.SourceIdentity.Creators.confidence(
                  Map.get(creator_case, :certainty, :verified)
                )

              assert {:queued, run} = Discovery.request(target, @slug)
              assert :ok = Discovery.execute_run(run.id)

              results =
                Repo.all(from r in Result, where: r.run_id == ^run.id)
                |> Map.new(&{&1.external_id, &1})

              credited = Map.fetch!(results, credited_id)
              text_only = Map.fetch!(results, text_id)

              person_id = DevilsDictionary.Registry.by_external_id("wikidata", qid)
              assert is_integer(person_id), "#{qid} was neither matched nor minted"

              assert [%{object_object_id: ^person_id} = revision] =
                       DevilsDictionary.Claims.outgoing(credited.object_id,
                         predicate: "authored_by"
                       )

              assert revision.method == "provider_relationship"
              assert revision.confidence == expected_confidence
              assert revision.metadata["provider"] == @slug

              assert [%{"qid" => ^qid, "state" => state, "object_id" => ^person_id}] =
                       credited.preview_metadata["creators"]

              assert state in ["matched", "minted"]

              # No identifier, no credit: the text line is all there is.
              assert DevilsDictionary.Claims.outgoing(text_only.object_id,
                       predicate: "authored_by"
                     ) == []

              refute Enum.any?(
                       text_only.preview_metadata["creators"] || [],
                       &(&1["state"] in ["matched", "minted"])
                     )

              state = Discovery.state(target.object_id, @slug)
              html = render_component(&Culture.section/1, states: %{@slug => state})
              doc = LazyHTML.from_fragment(html)

              link =
                LazyHTML.query(
                  doc,
                  "#culture-creator-#{credited.external_namespace}-#{credited_id} a"
                )

              assert LazyHTML.attribute(link, "href") |> hd() =~ "/entities/#{person_id}/"

              assert LazyHTML.query(
                       doc,
                       "#culture-creator-#{text_only.external_namespace}-#{text_id}"
                     )
                     |> Enum.count() == 0
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

            # The card's column width and title clamp come from the
            # content-type table rather than from the shelf markup. A text card
            # has no poster frame to set its width, and the shared 96 px poster
            # column clipped a poem's title to two lines of the seven it wanted
            # at 375 px (#109 Phase 3b).
            assert html =~ ContentTypes.column(type)
            assert html =~ ContentTypes.title_clamp(type)

            # A provider ships zero components: the byline is the source row's
            # name plus whatever `shelf_detail/0` returned, rendered by shared
            # code that names no provider.
            assert html =~ state.provider_name

            # The state carries the tier the shelf orders sources by (#116 M2).
            assert state.tier in [:aristocracy, :middle, :plebs]

            # M4 of #116: on a shelf whose row requires attribution, every item
            # renders its credit beneath the thumbnail, always visible. The
            # line is `preview_metadata["attribution"]` or `"credit_line"`; a
            # provider delivering an item with neither onto such a shelf is
            # the defect this catches.
            if ContentTypes.attribution(type) == :required do
              for item <- state.items do
                assert html =~
                         ~s(id="culture-attribution-#{item.external_namespace}-#{item.external_id}"),
                       "#{@slug} delivered #{item.external_id} onto the #{type} shelf " <>
                         "without an attribution line, and that shelf requires one"

                # D2 of #126: that line is **one sentence**, not a paragraph.
                # M4's *verbatim* was always about the fields; Openverse read
                # it as licence boilerplate and rendered seven rows under a
                # 112 px thumbnail. The licence link `Culture.credit_parts/2`
                # puts on the licence name is where "view a copy of this
                # license" lives, so a URL in the prose is a URL twice.
                line =
                  item.preview_metadata["attribution"] ||
                    item.preview_metadata["credit_line"]

                assert is_binary(line)

                refute String.contains?(String.downcase(line), "http"),
                       "#{@slug} put a URL in the credit for #{item.external_id}; the " <>
                         "licence link is on the licence name (D2 of #126): #{inspect(line)}"

                assert String.length(line) < 160,
                       "#{@slug}'s credit for #{item.external_id} is " <>
                         "#{String.length(line)} characters; a required credit is at most " <>
                         "one sentence, under 160 (D2 of #126): #{inspect(line)}"
              end
            end
          end

          test "every result carries a reason that renders as one sentence", context do
            target = @fixture.covered_target(context)
            @fixture.stub(:results, context)

            assert {:queued, run} = Discovery.request(target, @slug)
            assert :ok = Discovery.execute_run(run.id)

            state = Discovery.state(target.object_id, @slug)

            type =
              Enum.find(@provider.capabilities().content_types, &(&1 in ContentTypes.known()))

            for item <- state.items do
              reasons = MatchReason.from_result(item.match_details, state.term)
              assert reasons != []

              sentence = MatchReason.describe_all(reasons)
              assert is_binary(sentence) and sentence != ""
              assert String.ends_with?(sentence, ".")

              # M6 of #116, as data: the content-type row says which classes
              # of reason it admits, and every reason this provider delivers
              # onto it has to be one of them. A text provider whose result
              # named no attestation, or an artwork provider whose result is
              # a bare search, is caught here rather than by a reviewer.
              for reason <- reasons do
                assert ContentTypes.admits?(type, reason),
                       "#{@slug} delivered a #{inspect(MatchReason.evidence(reason))} reason " <>
                         "onto the #{type} shelf, whose row admits " <>
                         inspect(ContentTypes.evidence(type))
              end
            end
          end

          test "every result declares its evidence, and delivers what it declared", context do
            # #144 Phase 0. Before the declaration, `MatchReason.from_result/2`
            # dispatched on the presence of one of four keys, so a provider
            # with a reason shape none of them matched became a `:query` with
            # nothing to say — silently, on any shelf, with no check to notice.
            # A result now says what it is and is held to it.
            target = @fixture.covered_target(context)
            @fixture.stub(:results, context)

            assert {:queued, run} = Discovery.request(target, @slug)
            assert :ok = Discovery.execute_run(run.id)

            state = Discovery.state(target.object_id, @slug)

            type =
              Enum.find(@provider.capabilities().content_types, &(&1 in ContentTypes.known()))

            for item <- state.items do
              details = item.match_details

              assert MatchReason.known_kind?(details["kind"]),
                     "#{@slug} declares match_details[\"kind\"] as " <>
                       "#{inspect(details["kind"])}; MatchReason builds " <>
                       inspect(MatchReason.kinds())

              declared = MatchReason.declared_evidence(details)

              assert declared in [:identity, :word_identity, :attestation, :query],
                     "#{@slug} wrote no match_details[\"evidence\"] on #{item.external_id}"

              # The declaration is not decoration: it has to be the class of
              # the reason the builder actually produced from the same map.
              for reason <- MatchReason.from_result(details, state.term) do
                assert MatchReason.evidence(reason) == declared,
                       "#{@slug} declared #{inspect(declared)} on #{item.external_id} and " <>
                         "delivered a #{inspect(MatchReason.evidence(reason))} reason"
              end

              assert ContentTypes.admits?(type, declared),
                     "#{@slug} declared #{inspect(declared)} onto the #{type} shelf, " <>
                       "whose row admits #{inspect(ContentTypes.evidence(type))}"

              # And the level matches the recipe it was retrieved for (#172 C4).
              mapping = Repo.get!(DevilsDictionary.Discovery.Mapping, run.mapping_id)

              DevilsDictionary.Discovery.Conformance.assert_labelled!(
                details,
                state.term,
                mapping.parameters["entities"]
              )
            end
          end
        end

        if function_exported?(@fixture, :word_level_target, 1) do
          describe "#{@slug} — the word-level tier (#172 build B)" do
            setup context do
              target = @fixture.word_level_target(context)
              @fixture.stub(:results, context)

              assert {:queued, run} = Discovery.request(target, @slug)
              assert :ok = Discovery.execute_run(run.id)

              mapping = Repo.get!(DevilsDictionary.Discovery.Mapping, run.mapping_id)
              state = Discovery.state(target.object_id, @slug)

              type =
                Enum.find(@provider.capabilities().content_types, &(&1 in ContentTypes.known()))

              %{word_target: target, mapping: mapping, state: state, type: type}
            end

            test "a page whose senses refer to nothing reads the word's candidate, and says so",
                 %{mapping: mapping, state: state, type: type} do
              # The recipe is word-level, all of it (C2), and carries the level.
              entities = mapping.parameters["entities"]
              assert entities != []
              assert Enum.all?(entities, &(&1["level"] == "word"))

              assert state.items != [],
                     "#{@slug} delivered nothing for a word-level recipe its :results stub answers"

              assert ContentTypes.admits?(type, :word_identity)

              for item <- state.items do
                DevilsDictionary.Discovery.Conformance.assert_labelled!(
                  item.match_details,
                  state.term,
                  entities
                )
              end

              # And the shelf says it once, above the rail.
              html = render_component(&Culture.section/1, states: %{@slug => state})
              note = MatchReason.word_level_note(state.term)
              document = LazyHTML.from_fragment(html)
              line = LazyHTML.query(document, "#culture-word-level-#{type}")

              assert Enum.count(line) == 1
              assert line |> LazyHTML.text() |> String.trim() == note
              refute html =~ "Search result for"
            end

            test "an unlabelled word-level result fails the check",
                 %{mapping: mapping, state: state} do
              [item | _] = state.items
              entities = mapping.parameters["entities"]

              # The label taken off, as a provider that forgot it would leave it:
              # the declared class back to `identity`, and the level gone.
              for stripped <- [
                    Map.put(item.match_details, "evidence", "identity"),
                    Map.drop(item.match_details, ["level", "evidence"])
                    |> Map.put("evidence", "identity")
                  ] do
                assert_raise ExUnit.AssertionError, fn ->
                  DevilsDictionary.Discovery.Conformance.assert_labelled!(
                    stripped,
                    state.term,
                    entities
                  )
                end
              end
            end

            test "a candidate below the corroborated floor covers nothing", context do
              word = DevilsDictionary.WordFixtures.word!(context, "thither", ~w(wordnet))
              DevilsDictionary.WordFixtures.sense!(context, word, "wordnet")

              DevilsDictionary.WordFixtures.link!(
                word,
                DevilsDictionary.WordFixtures.concept!("Q900999", "Thither"),
                method: :title_match,
                confidence: 0.7
              )

              refute @provider.covers?(%{
                       object_id: word.object_id,
                       term: word.lemma,
                       language: word.language_tag,
                       relevance: "term"
                     })
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
