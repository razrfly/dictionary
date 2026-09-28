# The On reader's demonstration (#219 B7), on isolated copies only.
#
#   DD_STAGE2_REHEARSAL=1 DD_NO_OBAN=1 DD_DATABASE=devils_dictionary_stage2r_… DD_DATABASE_PORT=5433 \
#     mix run docs/routing/stage-2/rehearsal/on_demo.exs mars REVIEWER_EMAIL
#
# On a backfilled rehearsal copy, makes what the owner's example needs and the
# corpus does not hold:
#
#   * the planet — the corpus's one Mars entity, a classification review in
#     the population — confirmed as Nature by a **rehearsal review** and
#     allocated `/nature/mars`;
#   * a Mars deity, a **fixture** (the corpus has none), mapped to Subjects,
#     confirmed by a rehearsal review and allocated `/subjects/mars`;
#   * a Mars album, a **fixture**, mapped to Works, with a draft page and no
#     address.
#
# Every fixture carries `metadata["fixture"]`, which the Subjects card marks;
# every review and ledger row says it is a rehearsal. Nothing here is an
# approval, nothing is published, and the guard refuses anything but a
# `devils_dictionary_stage2*_*` copy off the usual server. Run it once per
# copy: it refuses a copy that already holds its fixtures.
Code.require_file("guard.exs", __DIR__)

import Ecto.Query

alias DevilsDictionary.{Registry, Repo}
alias DevilsDictionary.Accounts.User
alias DevilsDictionary.Registry.Entity
alias DevilsDictionary.Routing.{Classifications, Ledger, Pages, Policy}
alias DevilsDictionary.Sources.Actor

{_host, _port, database} = Stage2.Guard.check!()

# The guard accepts any rehearsal copy; these three are retained evidence
# (the frozen capture, the caught-up baseline, the verified restore) and are
# never written.
if database in ~w(devils_dictionary_stage2r_c1 devils_dictionary_stage2r_caughtup devils_dictionary_stage2r_bfa2),
  do: raise("#{database} is retained evidence: make the demonstration on a disposable copy")

marker = "#219 demo fixture: made on the disposable copy #{database} only; not a corpus record"
reason = "#219 On demonstration on an isolated copy: a rehearsal review, not an approval"

case System.argv() do
  ["mars", email] ->
    if Repo.exists?(from e in Entity, where: fragment("?->>'fixture' LIKE '#219 demo%'", e.metadata)),
      do: raise("#{database} already holds the #219 demo fixtures")

    user = Repo.get_by!(User, email: email, reviewer: true)

    reviewer =
      Repo.get_by(Actor, actor_kind: :user, user_id: user.id) ||
        Repo.insert!(%Actor{actor_kind: :user, user_id: user.id, label: "Rehearsal reviewer ##{user.id}"})

    # A fixture's evidence is as synthetic as the fixture: one type, the
    # family's policy anchor, on an identifier that names nothing real.
    evaluate = fn entity, anchor ->
      qid = "Q#{900_000_000 + entity.object_id}"

      Policy.classify(
        %{
          "object_id" => entity.object_id,
          "label" => entity.preferred_label,
          "entity_kind" => to_string(entity.entity_kind),
          "lifecycle" => "active",
          "qids" => [qid],
          "instance_of" => [anchor],
          "subclass_of" => [],
          "disambiguation" => false
        },
        %{
          qid => %{
            "qid" => qid,
            "revision_id" => 0,
            "checksum" => "#219-demo-fixture",
            "claims" => %{
              "P31" => [%{"rank" => "normal", "mainsnak" => %{"datavalue" => %{"value" => %{"id" => anchor}}}}],
              "P279" => []
            }
          }
        },
        Policy.load()
      )
    end

    # The rehearsal reviewer confirms the decision the copy holds, and the
    # address is allocated on that confirmation — the backfill's own order.
    confirm_and_allocate = fn entity, family, path ->
      current = Classifications.current(entity.object_id) || raise("no decision for #{entity.object_id}")

      {:ok, _override} =
        Classifications.override(
          entity.object_id,
          %{status: :mapped, family: family, reason: reason, evidence_fingerprint: current.evidence_fingerprint},
          reviewer.id
        )

      {:ok, page} = Pages.ensure(:subject, entity.object_id)
      {:ok, _path} = Ledger.allocate(page.id, path, actor_id: reviewer.id, reason: reason)
      IO.puts("#{path}  page #{page.id}  object #{entity.object_id}  (#{entity.preferred_label}: draft)")
    end

    # The planet: the corpus's own Mars.
    planet =
      case Repo.all(from e in Entity, where: e.preferred_label == "Mars") do
        [planet] -> planet
        other -> raise("expected the corpus's one Mars entity, found #{length(other)}")
      end

    confirm_and_allocate.(planet, :nature, "/nature/mars")

    # The deity: a fixture.
    {:ok, deity} =
      Registry.create_entity(%{
        entity_kind: :other,
        preferred_label: "Mars",
        description: "Roman god of war",
        metadata: %{"fixture" => marker}
      })

    {:ok, _, _} = deity |> evaluate.("Q178885") |> Classifications.record()
    confirm_and_allocate.(deity, :subjects, "/subjects/mars")

    # The album: a fixture with a page and no address.
    {:ok, album} =
      Registry.create_work(%{
        preferred_label: "Mars",
        description: "2012 album",
        work_kind: "album",
        metadata: %{"fixture" => marker}
      })

    {:ok, _, _} = album |> evaluate.("Q482994") |> Classifications.record()
    {:ok, page} = Pages.ensure(:subject, album.object_id)
    IO.puts("no address  page #{page.id}  object #{album.object_id}  (Mars album fixture: draft)")

  _other ->
    IO.puts("usage: on_demo.exs mars REVIEWER_EMAIL")
    System.halt(2)
end
