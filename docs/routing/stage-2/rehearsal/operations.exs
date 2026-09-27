# Stage 2 rehearsal: normal operations on a recovered working copy, after
# every equality check has passed. Writes only marked scratch pages and marked
# curation receipts.
#
#   DD_STAGE2_REHEARSAL=1 DD_NO_OBAN=1 \
#   DD_DATABASE=devils_dictionary_stage2r_working DD_DATABASE_PORT=5433 \
#     mix run docs/routing/stage-2/rehearsal/operations.exs FIXTURES.json OPERATIONS.json
#
# Checks, on the recovered fixture: a canonical path, a moved page's alias,
# a merged page's redirect, a split page's choice, a retired page's
# tombstone, a restored page, a rolled-back move, and an On page. Then, on new
# scratch pages: an allocation whose ids continue the restored sequences, a
# move (the old path becomes an alias) and its rollback.
#
# When the fixture holds curation (current main): the composition stands as it
# was approved, then `Stage2.Curation.operations!/2` replays, refuses,
# withdraws and republishes (see `curation.exs`).
Code.require_file("guard.exs", __DIR__)
Code.require_file("curation.exs", __DIR__)

import Ecto.Query

alias DevilsDictionary.{Registry, Repo}
alias DevilsDictionary.Routing.{Address, Classifications, Ledger, Page, Pages, Policy, PublicPath, Resolver}
alias DevilsDictionary.Sources.Actor

[fixtures_path, out] = System.argv()
{_host, _port, database} = Stage2.Guard.check!()
fixture = fixtures_path |> File.read!() |> Jason.decode!()
marker = fixture["marker"]
human = Repo.get!(Actor, fixture["actors"]["human"])
importer = Repo.get!(Actor, fixture["actors"]["importer"])
as = fn actor, reason -> [actor_id: actor.id, reason: marker <> reason] end
p = fn slug, family -> "/#{family}/stage2a-rehearsal-#{slug}" end

outcome = fn path ->
  r = path |> Address.encode() |> Resolver.resolve()

  %{
    "path" => path,
    "outcome" => to_string(r.outcome),
    "page_id" => r.page && r.page.id,
    "location" => r.location,
    "successors" => Enum.map(r.successors, & &1.page_id)
  }
end

expect = fn result, outcome, extra ->
  ok? = result["outcome"] == outcome and Enum.all?(extra, fn {k, v} -> result[k] == v end)
  Map.merge(result, %{"expected" => outcome, "pass" => ok?})
end

pages = fixture["pages"]

# The curation fixture stands as it was approved, before anything is written.
curation_before = fixture["curation"] && Stage2.Curation.check(fixture["curation"])

recovered = [
  expect.(outcome.(p.("cat", "nature")), "canonical", %{"page_id" => pages["cat"]}),
  expect.(outcome.(p.("dog", "nature")), "redirect", %{"location" => p.("domestic-dog", "nature")}),
  expect.(outcome.(p.("domestic-dog", "nature")), "canonical", %{"page_id" => pages["dog"]}),
  expect.(outcome.(p.("oyster", "nature")), "canonical", %{"page_id" => pages["oyster"]}),
  expect.(outcome.(p.("arouet", "people")), "redirect", %{"location" => p.("voltaire", "people")}),
  expect.(outcome.(p.("mercury", "nature")), "choice", %{"successors" => [pages["planet"], pages["element"]]}),
  expect.(outcome.(p.("candide", "people")), "gone", %{}),
  expect.(outcome.(p.("pangloss", "people")), "canonical", %{"page_id" => pages["pangloss"]}),
  expect.(outcome.(p.("zadig", "people")), "canonical", %{"page_id" => pages["zadig"]}),
  expect.(outcome.(p.("zadig-le-babylonien", "people")), "redirect", %{"location" => p.("zadig", "people")}),
  expect.(outcome.("/on/stage2a-rehearsal-mercury"), "canonical", %{"page_id" => pages["on"]})
]

max_page = Repo.aggregate(Page, :max, :id)
max_path = Repo.aggregate(PublicPath, :max, :id)

# New scratch pages on the recovered copy.
{:ok, entity} = Registry.create_person(%{preferred_label: marker <> "scratch Micromegas"})
qid = "Q#{9_000_000_000 + entity.object_id}"

graph = %{
  qid => %{
    "qid" => qid,
    "revision_id" => 1,
    "checksum" => "stage2a-rehearsal-evidence",
    "claims" => %{"P31" => [%{"rank" => "normal", "mainsnak" => %{"datavalue" => %{"value" => %{"id" => "Q5"}}}}], "P279" => []}
  }
}

{:ok, _, _} =
  %{
    "object_id" => entity.object_id,
    "label" => "labels never classify",
    "entity_kind" => "person",
    "lifecycle" => "active",
    "qids" => [qid],
    "instance_of" => ["Q5"],
    "subclass_of" => [],
    "disambiguation" => false
  }
  |> Policy.classify(graph, Policy.load())
  |> Classifications.record()

{:ok, page} = Pages.ensure(:subject, entity.object_id)
{:ok, allocated} = Ledger.allocate(page.id, p.("micromegas", "people"), as.(importer, "scratch allocation"))

# Published directly, as the fixture is: rehearsal state, not an approval.
{1, _} = Repo.update_all(from(pg in Page, where: pg.id == ^page.id), set: [publication_state: :published])
after_allocate = expect.(outcome.(p.("micromegas", "people")), "canonical", %{"page_id" => page.id})

{:ok, _} = Ledger.move(page.id, p.("micromegas-le-voyageur", "people"), as.(human, "scratch move"))

after_move = [
  expect.(outcome.(p.("micromegas", "people")), "redirect", %{"location" => p.("micromegas-le-voyageur", "people")}),
  expect.(outcome.(p.("micromegas-le-voyageur", "people")), "canonical", %{"page_id" => page.id})
]

old = Repo.get_by!(PublicPath, path: p.("micromegas", "people"))
%{operation_id: moved} = Ledger.history(page_id: page.id) |> List.last()
{:ok, _} = Ledger.rollback(moved, as.(human, "scratch rollback"))
restored = Repo.get!(Page, page.id)

after_rollback = [
  expect.(outcome.(p.("micromegas", "people")), "canonical", %{"page_id" => page.id}),
  expect.(outcome.(p.("micromegas-le-voyageur", "people")), "redirect", %{"location" => p.("micromegas", "people")})
]

# A tombstone the batch may not take back.
refused = Ledger.allocate(pages["candide"], p.("candide", "people"), as.(importer, "must be refused"))

curation_operations = fixture["curation"] && Stage2.Curation.operations!(fixture["curation"], marker)

report = %{
  "database" => database,
  "recovered_resolutions" => recovered,
  "scratch" => %{
    "page_id" => page.id,
    "page_id_follows_restored_sequence" => page.id > max_page,
    "path_id" => allocated.id,
    "path_id_follows_restored_sequence" => allocated.id > max_path,
    "after_allocate" => after_allocate,
    "after_move" => after_move,
    "after_rollback" => after_rollback,
    "old_path_kind_after_move" => to_string(old.kind),
    "canonical_restored_by_rollback" => restored.canonical_path_id == allocated.id
  },
  "tombstone_reallocation" => inspect(refused),
  "curation_before" => curation_before,
  "curation_operations" => curation_operations
}

pass? =
  Enum.all?(recovered, & &1["pass"]) and after_allocate["pass"] and Enum.all?(after_move, & &1["pass"]) and
    Enum.all?(after_rollback, & &1["pass"]) and
    page.id > max_page and allocated.id > max_path and old.kind == :alias and
    restored.canonical_path_id == allocated.id and match?({:error, {:tombstoned, _}}, refused) and
    (is_nil(fixture["curation"]) or (curation_before["pass"] and curation_operations["pass"]))

File.write!(out, Jason.encode_to_iodata!(Map.put(report, "pass", pass?), pretty: true))
IO.puts(if pass?, do: "PASS: #{length(recovered)} recovered resolutions and the scratch operations", else: "FAIL: see #{out}")
unless pass?, do: System.halt(1)
