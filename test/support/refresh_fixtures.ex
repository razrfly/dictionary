defmodule DevilsDictionary.RefreshFixtures do
  @moduledoc """
  The curation refresh clock's test world (#259 §6): *love* as the opening
  fixtures build it, a noun and a verb, the global default seeded and
  active, and helpers that run a visit, a worker step, or the queue.

  Every text is a placeholder, as in `CurationFixtures`.
  """

  import Ecto.Query
  import DevilsDictionary.CurationFixtures
  import DevilsDictionary.OpeningFixtures
  import DevilsDictionary.WordFixtures

  alias DevilsDictionary.Curation.{
    Compositions,
    Opening,
    Publications,
    PublishedReader,
    Refresh,
    RefreshState,
    Reviews
  }

  alias DevilsDictionary.{Fixtures, Lexicon, Repo}
  alias DevilsDictionary.Lexicon.WordPage

  @doc "The world: `love!/1`, a verb *love*, a reviewer, a contributor and the active default."
  def love_world!(ctx \\ %{}) do
    %{sources: sources} = Fixtures.seed_catalog!()
    ctx = Map.put(ctx, :sources, sources)
    ctx = Map.merge(ctx, love!(ctx))
    verb = word!(ctx, "love", ~w(wiktionary), pos: "verb", scope: nil)
    reviewer = account([:reviewer])
    {configuration, version} = enabled_default!(reviewer)

    Map.merge(ctx, %{
      verb: verb,
      author: account([:contributor]),
      reviewer: reviewer,
      configuration: configuration,
      configuration_version: version
    })
  end

  @doc "The On *love* page's composition, provisioned over its noun and verb."
  def provision!(ctx, lexemes \\ nil) do
    {:ok, composition} =
      Compositions.provision(ctx.author, ctx.configuration.id, %{
        scope_kind: :lexical_page,
        lexeme_ids: Enum.map(lexemes || [ctx.love, ctx.verb], & &1.object_id),
        language_tag: "en",
        reason: "#259 test"
      })

    composition
  end

  @doc """
  A version of `composition` (Bierce leads, Johnson and a Milton quotation
  as highlights), accepted and published from `expected_pointer`. Returns
  `%{version, receipt}`.
  """
  def publish!(ctx, composition, expected_pointer \\ nil, opts \\ []) do
    highlights =
      Keyword.get(opts, :highlights, [
        ctx.johnson |> content_spec(ctx.love) |> Map.put(:note, %{text: "Johnson's senses."}),
        ctx.profound |> quotation_spec(1) |> Map.put(:note, %{text: "A literary use."})
      ])

    parent = Compositions.latest_version(composition.id)

    {:ok, version} =
      Compositions.create_version(ctx.author, composition.id, %{
        lead: content_spec(ctx.bierce, ctx.love),
        highlights: highlights,
        reason: "#259 test",
        expected_parent: parent && parent.id
      })

    {:ok, _review} =
      Reviews.decide(ctx.reviewer, version.id, :accepted,
        reason: "#259 test",
        idempotency_key: key("review")
      )

    {:ok, receipt} =
      Publications.publish(ctx.reviewer, version.id,
        reason: "#259 test",
        idempotency_key: key("publish"),
        expected_pointer: expected_pointer
      )

    %{version: version, receipt: receipt}
  end

  @doc "Withdraws a composition's publication."
  def withdraw!(ctx, composition) do
    composition = Repo.reload!(composition)

    {:ok, receipt} =
      Publications.withdraw(ctx.reviewer, composition.id,
        reason: "#259 test withdrawal",
        idempotency_key: key("withdraw"),
        expected_pointer: composition.current_published_version_id
      )

    receipt
  end

  @doc "The public On page for `slug`, as the worker builds it."
  def page(slug \\ "love"), do: slug |> Lexicon.lookup() |> WordPage.build(viewer: :public)

  @doc "A visit to the public On page `slug`, as `WordLive` makes it."
  def visit!(slug \\ "love", opts \\ []) do
    page = page(slug)
    Refresh.visit(page, Opening.for_page(page, PublishedReader), Keyword.put(opts, :slug, slug))
  end

  @doc "The composition's refresh row under the active configuration version."
  def row!(composition) do
    Repo.one!(
      from r in RefreshState,
        where: r.composition_id == ^composition.id,
        order_by: [desc: r.configuration_version_id],
        limit: 1
    )
  end

  @doc "Runs every queued curation job, raising if one crashes."
  def drain!, do: Oban.drain_queue(queue: :curation, with_safety: false)

  @doc "The curation jobs ever inserted."
  def curation_jobs,
    do: Repo.all(from j in Oban.Job, where: j.queue == "curation", order_by: j.id)

  @doc "Sets a refresh row's columns directly, to stand for elapsed time."
  def set!(%RefreshState{} = row, changes) do
    row |> Ecto.Changeset.change(changes) |> Repo.update!()
  end

  @doc "`seconds` ago."
  def ago(seconds), do: DateTime.add(DateTime.utc_now(), -seconds, :second)
end
