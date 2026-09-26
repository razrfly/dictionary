defmodule DevilsDictionary.RoutingFixtures do
  @moduledoc """
  Identities, decisions, pages and addresses for the routing tests (#194).

  Classifications go through the real evaluator, `Routing.Policy.classify/3`,
  over a one-node evidence graph whose P31 is the family's policy anchor — so
  a fixture is mapped for the same reason a corpus record would be.
  Voltaire, Putin, Mercury and C++ here are deliberate CI fixtures, not
  records of the development corpus.
  """

  import DevilsDictionary.AccountsFixtures, only: [unconfirmed_user_fixture: 0]
  import Ecto.Query

  alias DevilsDictionary.{Registry, Repo}
  alias DevilsDictionary.Routing.{Classifications, Ledger, Page, Pages, Policy}
  alias DevilsDictionary.Sources.Actor

  # One policy anchor per family, from the policy's approved examples.
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

  @doc "A human actor: the only kind that may approve a move, merge or override."
  def human! do
    user = unconfirmed_user_fixture()
    Repo.insert!(%Actor{actor_kind: :user, user_id: user.id, label: "Reviewer ##{user.id}"})
  end

  @doc "An import actor, as a batch backfill would be."
  def importer! do
    Repo.insert!(%Actor{
      actor_kind: :import,
      label: "routing backfill #{System.unique_integer([:positive])}"
    })
  end

  @doc "An entity of `kind`, created through the registry."
  def entity!(kind, label) do
    {:ok, entity} =
      case kind do
        :person -> Registry.create_person(%{preferred_label: label})
        :work -> Registry.create_work(%{preferred_label: label, work_kind: "album"})
        kind -> Registry.create_entity(%{entity_kind: kind, preferred_label: label})
      end

    entity
  end

  @doc "A lexeme, for lexical membership."
  def lexeme!(lemma, part_of_speech \\ "noun") do
    {:ok, lexeme} = Registry.create_lexeme(%{lemma: lemma, part_of_speech: part_of_speech})
    lexeme
  end

  @doc """
  Records the evaluator's result for an entity whose one Wikidata type is the
  family's policy anchor. `:revision` changes the pinned source revision, and
  so the evidence fingerprint, without changing the type.
  """
  def classify!(object_id, family, opts \\ []) do
    {:ok, _outcome, decision} =
      object_id |> evaluate(@anchors[family], opts) |> Classifications.record()

    decision
  end

  @doc "Records an evaluator result with an unknown type: `needs_review`."
  def leave_unmapped!(object_id, opts \\ []) do
    {:ok, _outcome, decision} = object_id |> evaluate("Q1", opts) |> Classifications.record()
    decision
  end

  @doc """
  The evaluator's raw result for an entity typed `types` (one QID or several).
  `:revision` moves the source pin; `:lifecycle` is the registry state.
  """
  def evaluate(object_id, types, opts \\ []) do
    qid = "Q#{9_000_000 + object_id}"
    revision = opts[:revision] || 1
    types = List.wrap(types)

    entity = %{
      "object_id" => object_id,
      "label" => "labels never classify",
      "entity_kind" => "concept",
      "lifecycle" => opts[:lifecycle] || "active",
      "qids" => [qid],
      "instance_of" => types,
      "subclass_of" => [],
      "disambiguation" => false
    }

    graph = %{
      qid => %{
        "qid" => qid,
        "revision_id" => revision,
        "checksum" => "fixture-#{revision}",
        "claims" => %{"P31" => Enum.map(types, &claim/1), "P279" => []}
      }
    }

    Policy.classify(entity, graph, Policy.load())
  end

  defp claim(qid),
    do: %{"rank" => "normal", "mainsnak" => %{"datavalue" => %{"value" => %{"id" => qid}}}}

  @doc "An entity classified into `family`, with its draft subject page."
  def subject_page!(family, label, kind \\ :concept) do
    entity = entity!(kind, label)
    classify!(entity.object_id, family)
    {:ok, page} = Pages.ensure(:subject, entity.object_id)
    page
  end

  @doc "An On overview page."
  def overview_page! do
    {:ok, page} = Pages.create(%{role: :overview})
    page
  end

  @doc "Allocates `path` for a page and returns the reloaded page."
  def allocated!(%Page{} = page, path, actor) do
    {:ok, _path} =
      Ledger.allocate(page.id, path, actor_id: actor.id, reason: "fixture allocation")

    Repo.get!(Page, page.id)
  end

  @doc """
  Marks a page published **directly**. Stage 1 has no publication path — that
  is Stage 5's gated workflow — so tests stand in for it here. Nothing in the
  application calls this.
  """
  def published!(%Page{id: id}) do
    {1, _} =
      Repo.update_all(from(p in Page, where: p.id == ^id), set: [publication_state: :published])

    Repo.get!(Page, id)
  end

  @doc "An allocated, published subject page at `path`."
  def live_page!(family, path, actor, kind \\ :concept) do
    family |> subject_page!(path, kind) |> allocated!(path, actor) |> published!()
  end

  @doc """
  Fires every deferred constraint now, then defers again. The sandbox never
  commits, so without this a sandboxed test would never see the commit-time
  checks that a real transaction always runs.
  """
  def consistent! do
    Repo.query!("SET CONSTRAINTS ALL IMMEDIATE")
    Repo.query!("SET CONSTRAINTS ALL DEFERRED")
    :ok
  end
end
