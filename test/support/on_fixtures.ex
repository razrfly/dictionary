defmodule DevilsDictionary.OnFixtures do
  @moduledoc """
  Subjects, addresses and authored overviews for the On reader's tests
  (#219).

  Everything here is a deliberate CI fixture made in the test's own sandbox —
  the Mars deity and album, the Butterfly works, On C++ — and never minted
  into the corpus. The corpus holds exactly one Mars entity, the planet; the
  others exist only here, and a fixture meant to be seen as one carries
  `metadata["fixture"]`, which the Subjects card marks.

  Classifications go through `RoutingFixtures` and so through the real
  evaluator; addresses through `Routing.Ledger`; overviews through
  `Routing.Pages`. Publication has no path in the application (Stage 5), so
  tests stand in for it with `RoutingFixtures.published!/1` and `withdrawn!/1`
  here.
  """

  import DevilsDictionary.RoutingFixtures

  alias DevilsDictionary.{Registry, Repo}
  alias DevilsDictionary.Routing.{Classifications, Page, Pages}

  @doc """
  An entity with a subject page (an edition page for `kind: :edition`),
  classified into `family` by the evaluator, and optionally allocated
  (`path:`) and published (`published: true`). `status: :needs_review` with
  `candidates:` leaves it for review instead; `status: :none` records no
  decision; `page: false` makes no page.
  """
  def subject!(label, family, opts \\ []) do
    entity = entity(label, opts)

    case Keyword.get(opts, :status, :mapped) do
      :mapped ->
        classify!(entity.object_id, family)

      :needs_review ->
        anchors = Enum.map(Keyword.get(opts, :candidates, [family]), &anchor/1)
        {:ok, _, _} = entity.object_id |> evaluate(anchors) |> Classifications.record()

      :none ->
        :ok
    end

    role = if Keyword.get(opts, :kind) == :edition, do: :edition, else: :subject

    page =
      if Keyword.get(opts, :page, true) do
        {:ok, page} = Pages.ensure(role, entity.object_id)

        page
        |> then(
          &if(path = opts[:path], do: allocated!(&1, path, opts[:actor] || importer!()), else: &1)
        )
        |> then(&if(opts[:published], do: published!(&1), else: &1))
      end

    %{entity: entity, page: page}
  end

  @anchors %{
    "people" => "Q5",
    "organizations" => "Q215380",
    "places" => "Q6256",
    "events" => "Q7944",
    "works" => "Q482994",
    "concepts" => "Q9143",
    "nature" => "Q16521",
    "subjects" => "Q95074"
  }

  defp anchor(family), do: Map.fetch!(@anchors, family)

  defp entity(label, opts) do
    attrs =
      %{preferred_label: label, description: opts[:description], metadata: metadata(opts)}

    {:ok, entity} =
      case Keyword.get(opts, :kind, :concept) do
        :work ->
          Registry.create_work(Map.put(attrs, :work_kind, Keyword.get(opts, :work_kind, "album")))

        :edition ->
          {:ok, work} =
            Registry.create_work(%{preferred_label: label <> " (work)", work_kind: "book"})

          Registry.create_edition(
            Map.merge(attrs, %{work_id: work.object_id, edition_label: "1911"})
          )

        :person ->
          Registry.create_person(attrs)

        kind ->
          Registry.create_entity(Map.put(attrs, :entity_kind, kind))
      end

    entity
  end

  defp metadata(opts) do
    case opts[:fixture] do
      nil -> %{}
      note -> %{"fixture" => note}
    end
  end

  @doc """
  An authored overview with one revision: `members` are `{relationship,
  target}` pairs, a target being an object id or `{:page, page_id}`,
  allocated at `path` (nil for none) and optionally published.
  """
  def overview!(title, path, members, opts \\ []) do
    author = opts[:author] || human!()
    page = overview_page!()

    memberships =
      Enum.map(members, fn
        {relationship, {:page, page_id}} ->
          %{relationship: relationship, target_page_id: page_id, rationale: "fixture"}

        {relationship, object_id} ->
          %{relationship: relationship, target_object_id: object_id, rationale: "fixture"}
      end)

    {:ok, _revision} =
      Pages.add_revision(
        page.id,
        %{title: title, body: Keyword.get(opts, :body, "An authored page (#219 fixture).")},
        memberships,
        author.id
      )

    page = Repo.get!(Page, page.id)
    page = if path, do: allocated!(page, path, author), else: page
    if opts[:published], do: published!(page), else: page
  end

  @doc "Withdraws a page with a fixture's receipt (`RoutingFixtures.withdrawn!/1`)."
  def withdrawn!(%Page{} = page), do: DevilsDictionary.RoutingFixtures.withdrawn!(page)

  @doc "Runs `fun` with internal reading configured `on` (or off), restoring it after."
  def reading(on?, fun) do
    previous = Application.get_env(:devils_dictionary, :internal_reading)
    Application.put_env(:devils_dictionary, :internal_reading, on?)

    try do
      fun.()
    after
      Application.put_env(:devils_dictionary, :internal_reading, previous)
    end
  end
end
