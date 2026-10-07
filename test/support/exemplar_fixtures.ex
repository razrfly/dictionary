defmodule DevilsDictionary.ExemplarFixtures do
  @moduledoc """
  Exemplars for #212's tests: nominations through `Contributions.propose/6`,
  reviews through `Contributions.review/6`, a passage a shelf left behind,
  and a way to take every provider off the network.

  Every subject is a fixture. The people are fictional, and one of them is
  the *adverse person* the leakage tests need: someone nominated under an
  unflattering meaning who must leave no trace for the public until a
  reviewer accepts it. No words are attributed to anyone real.
  """

  import Ecto.Query

  alias DevilsDictionary.{Claims, Registry, Repo, WordFixtures}
  alias DevilsDictionary.Claims.Contributions
  alias DevilsDictionary.Discovery.{Mapping, Result, Run}
  alias DevilsDictionary.Discovery.Providers.Wikiquote
  alias DevilsDictionary.Examples.Community
  alias DevilsDictionary.Sources.{Actor, Source}

  @evidence "https://example.test/fixture-evidence"

  @doc "A fictional person."
  def person!(label \\ "Fixture Person") do
    {:ok, person} = Registry.create_person(%{preferred_label: label})
    person
  end

  @doc "Cited evidence for a nomination: one `community` URL."
  def cited(url \\ @evidence),
    do: [Map.merge(Community.cite!(url, "Fixture"), %{locator: url, evidence_role: :supports})]

  @doc """
  A contributor's nomination of `subject` as an example of `object`, through
  the one path every nomination takes. A person needs evidence (#105 rule 2);
  pass `[]` for a work or a passage. Returns the current revision.
  """
  def nominate!(contributor, subject, object, evidence \\ nil, attrs \\ %{}) do
    {:ok, assertion} =
      Contributions.propose(
        contributor,
        subject.object_id,
        "illustrates",
        object.object_id,
        Map.merge(%{rationale: "fixture rationale"}, attrs),
        evidence || cited()
      )

    Claims.current_revision(assertion.id)
  end

  @doc """
  A reviewer's decision on exactly what is displayed, which opens the review
  context an exemplar's eligibility compares against.
  """
  def decide!(reviewer, revision, decision \\ "accepted") do
    {:ok, review} =
      Contributions.review(
        reviewer,
        revision.assertion_id,
        revision.id,
        decision,
        "Checked.",
        Contributions.context_items(revision)
      )

    review
  end

  @doc """
  A quotation as a provider with a durable identity leaves it behind: a
  `content/quotation` object whose first revision cites the provider's record
  (Wikiquote's `identity_record/1`), and a shelf result naming it. Returns
  `%{quotation, record_revision, run, result, source}`.
  """
  def shelved_quotation!(ctx, target, body) do
    {:ok, _} =
      %Source{}
      |> Source.changeset(Wikiquote.source_attrs())
      |> Repo.insert(on_conflict: :nothing, conflict_target: [:slug])

    source = Repo.get_by!(Source, slug: Wikiquote.slug())
    record = WordFixtures.record!(put_in(ctx.sources["wikiquote"], source), "wikiquote")

    record_revision =
      Repo.one!(
        from r in "source_record_revisions", where: r.source_record_id == ^record.id, select: r.id
      )

    {:ok, quotation} =
      Registry.create_content(%{
        content_kind: :quotation,
        source_id: source.id,
        headword: "Fixture quotation",
        body: body,
        source_record_revision_id: record_revision
      })

    run = shelf_run!(target, source)

    result =
      Repo.insert!(
        Result.changeset(%Result{}, %{
          run_id: run.id,
          external_namespace: "wikiquote_item",
          external_id: "fixture-#{quotation.object_id}",
          object_id: quotation.object_id,
          source_record_id: record.id,
          position: 0,
          match_details: %{},
          preview_metadata: %{},
          display_allowed: true,
          resolution_state: :newly_created
        })
      )

    %{
      quotation: quotation,
      record_revision: record_revision,
      run: run,
      result: result,
      source: source
    }
  end

  defp shelf_run!(target, source) do
    actor =
      Repo.insert!(Actor.changeset(%Actor{}, %{actor_kind: :import, label: "fixture shelf"}))

    mapping =
      Repo.insert!(
        Mapping.create_changeset(%Mapping{}, %{
          mapping_key: "wikiquote:#{target.object_id}:#{System.unique_integer([:positive])}",
          version: 1,
          target_object_id: target.object_id,
          source_id: source.id,
          operation: "term_quote_discovery",
          parameters: %{},
          configured_by_actor_id: actor.id,
          enabled: true
        })
      )

    now = DateTime.utc_now()

    run =
      Repo.insert!(
        Run.create_changeset(%Run{}, %{
          mapping_id: mapping.id,
          adapter_version: "wikiquote.fixture",
          request_parameters: %{},
          request_key: "fixture-request",
          position_key: "fixture-position",
          page_context: Ecto.UUID.generate(),
          page: 0,
          status: :pending
        })
      )

    Repo.update!(
      Run.lifecycle_changeset(run, %{
        status: :succeeded,
        started_at: now,
        completed_at: now,
        refresh_after: DateTime.add(now, 3_600),
        expires_at: DateTime.add(now, 86_400),
        completion_reason: :results,
        result_count: 1,
        request_count: 1
      })
    )
  end

  @doc """
  C7: no provider and no model is reachable. Every HTTP plug the test
  configuration routes through raises, and the provider registry is empty
  until the test ends. Call it from the test process, in an `async: false`
  module: the registry is application-wide.
  """
  def offline! do
    for plug <- [
          DevilsDictionary.Absorb.Clients,
          DevilsDictionary.Discovery.Providers.CineGraph,
          DevilsDictionary.Quotations.Verifier
        ] do
      Req.Test.stub(plug, fn _conn -> raise "an example read made an HTTP request" end)
    end

    providers = Application.fetch_env!(:devils_dictionary, :discovery_providers)
    Application.put_env(:devils_dictionary, :discovery_providers, [])

    ExUnit.Callbacks.on_exit(fn ->
      Application.put_env(:devils_dictionary, :discovery_providers, providers)
    end)
  end
end
