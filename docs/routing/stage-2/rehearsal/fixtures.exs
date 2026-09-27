# Stage 2 rehearsal: a small, clearly marked routing history — and, at
# current main, a curation composition — on the migrated rehearsal baseline
# copy, written through the supported APIs.
#
#   DD_STAGE2_REHEARSAL=1 DD_NO_OBAN=1 \
#   DD_DATABASE=devils_dictionary_stage2r_baseline DD_DATABASE_PORT=5433 \
#     mix run docs/routing/stage-2/rehearsal/fixtures.exs FIXTURES.json
#
# Every registry row it creates is labelled "Stage 2A rehearsal: …", every
# path contains "stage2a-rehearsal", and every routing row references only
# those rows, so the fixture is counted apart from the captured corpus. It
# covers decisions and an override, subject and On pages, revisions with
# typed membership, allocation, a move (alias), a merge, a split, retirement,
# restoration and a rollback — every routing table and every operation.
#
# Classifications go through the real evaluator (`Routing.Policy.classify/3`)
# over a synthetic, one-node evidence graph whose P31 is the family's policy
# anchor, exactly as the Stage 1 tests do. Publication has no workflow before
# Stage 5, so publishing is a direct update here, as in the tests: rehearsal
# state on an isolated copy, not an editorial approval.
#
# At current main it also writes the curation fixture in `curation.exs`: a real
# word's composition accepted and published by a marked reviewer, and a second
# version rejected. At the pinned routing-only boundary (Stage 2A's), there is
# no curation schema; the script says so and writes the routing part alone.
Code.require_file("guard.exs", __DIR__)
Code.require_file("curation.exs", __DIR__)

import Ecto.Query

alias DevilsDictionary.{Accounts, Registry, Repo}
alias DevilsDictionary.Routing.{Classifications, Ledger, Page, Pages, Policy, PublicPath, Recovery, RouteChange}
alias DevilsDictionary.Sources.Actor

[out] = System.argv()
{_host, _port, database} = Stage2.Guard.check!()

if Recovery.routing_schema() != :present, do: raise("the routing migration is not applied to #{database}")

if Repo.aggregate(Page, :count) != 0 or Repo.aggregate(RouteChange, :count) != 0,
  do: raise("#{database} already holds routing state; the fixture is written once, onto an empty copy")

marker = "Stage 2A rehearsal: "

anchors = %{"people" => "Q5", "nature" => "Q16521", "concepts" => "Q9143"}

classify = fn object_id, types ->
  qid = "Q#{9_000_000_000 + object_id}"

  entity = %{
    "object_id" => object_id,
    "label" => "labels never classify",
    "entity_kind" => "concept",
    "lifecycle" => "active",
    "qids" => [qid],
    "instance_of" => List.wrap(types),
    "subclass_of" => [],
    "disambiguation" => false
  }

  graph = %{
    qid => %{
      "qid" => qid,
      "revision_id" => 1,
      "checksum" => "stage2a-rehearsal-evidence",
      "claims" => %{
        "P31" =>
          Enum.map(List.wrap(types), fn t ->
            %{"rank" => "normal", "mainsnak" => %{"datavalue" => %{"value" => %{"id" => t}}}}
          end),
        "P279" => []
      }
    }
  }

  {:ok, _outcome, decision} = entity |> Policy.classify(graph, Policy.load()) |> Classifications.record()
  decision
end

{:ok, user} =
  Accounts.register_user(%{email: "stage2a-rehearsal-reviewer-#{System.unique_integer([:positive])}@example.invalid"})

human = Repo.insert!(%Actor{actor_kind: :user, user_id: user.id, label: marker <> "reviewer"})
importer = Repo.insert!(%Actor{actor_kind: :import, label: marker <> "backfill"})
as = fn actor, reason -> [actor_id: actor.id, reason: marker <> reason] end

entity! = fn kind, label ->
  {:ok, entity} =
    case kind do
      :person -> Registry.create_person(%{preferred_label: marker <> label})
      kind -> Registry.create_entity(%{entity_kind: kind, preferred_label: marker <> label})
    end

  entity
end

publish! = fn %Page{id: id} ->
  {1, _} = Repo.update_all(from(p in Page, where: p.id == ^id), set: [publication_state: :published])
  Repo.get!(Page, id)
end

allocate! = fn page, path, actor ->
  {:ok, _} = Ledger.allocate(page.id, path, as.(actor, "allocation"))
  Repo.get!(Page, page.id)
end

live! = fn kind, family, label, path ->
  entity = entity!.(kind, label)
  classify.(entity.object_id, anchors[family])
  {:ok, page} = Pages.ensure(:subject, entity.object_id)
  page |> allocate!.(path, importer) |> publish!.()
end

p = fn slug, family -> "/#{family}/stage2a-rehearsal-#{slug}" end

# Allocation, and a move leaving an alias.
cat = live!.(:concept, "nature", "cat", p.("cat", "nature"))
dog = live!.(:concept, "nature", "dog", p.("dog", "nature"))
{:ok, _} = Ledger.move(dog.id, p.("domestic-dog", "nature"), as.(human, "more precise"))

# An evaluator decision that needs review, overridden by a human.
oyster_entity = entity!.(:taxon, "oyster")
reviewed = classify.(oyster_entity.object_id, "Q1")

{:ok, override} =
  Classifications.override(
    oyster_entity.object_id,
    %{status: :mapped, family: :nature, reason: marker <> "a mollusc", evidence_fingerprint: reviewed.evidence_fingerprint},
    human.id
  )

{:ok, oyster} = Pages.ensure(:subject, oyster_entity.object_id)
oyster = oyster |> allocate!.(p.("oyster", "nature"), importer) |> publish!.()

# A merge that the registry made first.
arouet = live!.(:person, "people", "Arouet", p.("arouet", "people"))
voltaire = live!.(:person, "people", "Voltaire", p.("voltaire", "people"))
{:ok, _} = Registry.merge([arouet.target_object_id], voltaire.target_object_id, reason: marker <> "one man")
{:ok, _} = Ledger.merge(arouet.id, voltaire.id, as.(human, "one man"))

# A split that the registry made first: a choice among ordered successors.
mercury = live!.(:concept, "nature", "Mercury", p.("mercury", "nature"))
planet = live!.(:concept, "nature", "Mercury the planet", p.("mercury-planet", "nature"))
element = live!.(:concept, "nature", "Mercury the element", p.("mercury-element", "nature"))

{:ok, _} =
  Registry.split(mercury.target_object_id, [planet.target_object_id, element.target_object_id],
    reason: marker <> "planet and element"
  )

{:ok, _} = Ledger.split(mercury.id, [planet.id, element.id], as.(human, "planet and element"))

# Retirement, and a retirement undone by a human restoration.
candide = live!.(:person, "people", "Candide", p.("candide", "people"))
{:ok, _} = Ledger.retire(candide.id, as.(human, "fiction"))
pangloss = live!.(:person, "people", "Pangloss", p.("pangloss", "people"))
{:ok, _} = Ledger.retire(pangloss.id, as.(human, "withdrawn"))
{:ok, _} = Ledger.restore(pangloss.id, p.("pangloss", "people"), as.(human, "reinstated"))

# A move rolled back.
zadig = live!.(:person, "people", "Zadig", p.("zadig", "people"))
{:ok, _} = Ledger.move(zadig.id, p.("zadig-le-babylonien", "people"), as.(human, "longer title"))
%{operation_id: moved} = Ledger.history(page_id: zadig.id) |> List.last()
{:ok, _} = Ledger.rollback(moved, as.(human, "wrong title"))

# An On page: two immutable revisions, the first with typed membership.
{:ok, on} = Pages.create(%{role: :overview})
on = on |> allocate!.("/on/stage2a-rehearsal-mercury", human) |> publish!.()
{:ok, lexeme} = Registry.create_lexeme(%{lemma: "stage2a rehearsal poutine", part_of_speech: "noun"})

{:ok, _} =
  Pages.add_revision(
    on.id,
    %{title: marker <> "On Mercury", body: "Planet, element, god."},
    [
      %{relationship: :discusses_subject, target_page_id: planet.id},
      %{relationship: :supplies_lexical_material, target_object_id: lexeme.object_id},
      %{relationship: :editorial_association, target_object_id: cat.target_object_id, rationale: marker <> "none"}
    ],
    human.id
  )

{:ok, _} = Pages.add_revision(on.id, %{title: marker <> "On Mercury", body: "Revised."}, [], human.id)

# Curation (#206), on a copy at current main.
curation =
  if Stage2.Curation.present?() do
    Stage2.Curation.write!(marker)
  else
    IO.puts("curation schema absent (the routing-only boundary): no curation fixture")
    nil
  end

pages = [cat, dog, oyster, arouet, voltaire, mercury, planet, element, candide, pangloss, zadig, on]
page_ids = Enum.map(pages, & &1.id)

objects =
  Repo.all(
    from o in "objects",
      join: e in "entities",
      on: e.object_id == o.id,
      where: like(e.preferred_label, ^(marker <> "%")),
      select: o.id
  ) ++ [lexeme.object_id]

counts =
  Map.new(Recovery.routing_tables(), fn table ->
    {table, Repo.one(from(r in table, select: count(r.id)))}
  end)

operations =
  Repo.all(from c in RouteChange, group_by: c.operation, select: {c.operation, count(fragment("DISTINCT ?", c.operation_id))})
  |> Map.new(fn {op, n} -> {to_string(op), n} end)

inventory = %{
  "database" => database,
  "marker" => marker,
  "actors" => %{"human" => human.id, "importer" => importer.id, "user" => user.id},
  "object_ids" => Enum.sort(objects),
  "page_ids" => page_ids,
  "pages" =>
    Map.new(
      [cat: cat, dog: dog, oyster: oyster, arouet: arouet, voltaire: voltaire, mercury: mercury, planet: planet,
       element: element, candide: candide, pangloss: pangloss, zadig: zadig, on: on],
      fn {name, page} -> {name, page.id} end
    ),
  "paths" => Repo.all(from pp in PublicPath, order_by: pp.id, select: [pp.id, pp.path, pp.kind]) |> Enum.map(fn [id, path, kind] -> [id, path, to_string(kind)] end),
  "override_decision_id" => override.id,
  "routing_row_counts" => counts,
  "operations" => operations,
  "curation" => curation
}

# Every routing row references only fixture pages and objects.
foreign_pages = Repo.all(from pg in Page, where: pg.id not in ^page_ids, select: pg.id)
foreign_targets = Repo.all(from pg in Page, where: not is_nil(pg.target_object_id) and pg.target_object_id not in ^objects, select: pg.id)

if foreign_pages != [] or foreign_targets != [],
  do: raise("routing rows outside the fixture: pages #{inspect(foreign_pages)}, targets #{inspect(foreign_targets)}")

File.write!(out, Jason.encode_to_iodata!(inventory, pretty: true))
IO.puts("fixture written: #{length(page_ids)} pages, #{length(objects)} marked objects, rows #{inspect(counts)}, operations #{inspect(operations)}")
