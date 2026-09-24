defmodule DevilsDictionary.Examples.ExemplarsTest do
  @moduledoc """
  #181 build 2: the exemplar layer, from a manifest row to a card.

  Every box build 2 carries on the issue has a test here: a living person
  with a QID and one evidence URL seeds a `needs_review` claim and mints the
  person under `community`; a second row for the same subject and meaning is
  held; a `sense.match` that hits zero or several senses is refused with the
  glosses; no QID and no entity is refused; the person page groups accepted
  claims by word. Plus the visibility rule (#105 rule 1) both ways, and the
  evidence rule (#105 rule 2) at `Contributions.propose/6` itself.
  """

  use DevilsDictionary.DataCase, async: true

  import DevilsDictionary.AccountsFixtures
  import DevilsDictionary.WordFixtures

  alias DevilsDictionary.Accounts.Scope
  alias DevilsDictionary.Claims
  alias DevilsDictionary.Claims.{Assertion, AssertionRevision, Contributions}
  alias DevilsDictionary.Discovery.Conformance
  alias DevilsDictionary.Examples
  alias DevilsDictionary.Examples.{Community, Manifest, Seeder}
  alias DevilsDictionary.Fixtures
  alias DevilsDictionary.Registry
  alias DevilsDictionary.Registry.{Entity, ExternalIdentifier}
  alias DevilsDictionary.Sources.SourceRecord

  @bezos "Q312556"
  @cnn "https://www.cnn.com/2024/10/25/media/washington-post-wont-endorse-presidential-candidate"

  setup ctx do
    %{sources: sources} = Fixtures.seed_catalog!()
    ctx = Map.put(ctx, :sources, sources)

    contributor =
      user_fixture() |> Ecto.Changeset.change(internal_contributor: true) |> Repo.update!()

    reviewer = user_fixture() |> Ecto.Changeset.change(reviewer: true) |> Repo.update!()

    coward = word!(ctx, "coward", ~w(wordnet wiktionary))
    coward_sense = sense!(ctx, coward, "wordnet", gloss: "a person who shows fear or timidity")
    sense!(ctx, coward, "wiktionary", gloss: "A person who lacks courage.")
    sense!(ctx, coward, "wiktionary", gloss: "Cowardly.")

    {:ok, requests} = Agent.start_link(fn -> 0 end)

    Req.Test.stub(DevilsDictionary.Absorb.Clients, fn conn ->
      conn = Plug.Conn.fetch_query_params(conn)
      Agent.update(requests, &(&1 + 1))

      entities =
        (conn.params["ids"] || "")
        |> String.split("|", trim: true)
        |> Map.new(fn
          "Q43229" = qid -> {qid, organization(qid, "Some Organisation")}
          @bezos -> {@bezos, Conformance.human(@bezos, "Jeff Bezos", born: ~D[1964-01-12])}
          qid -> {qid, Conformance.human(qid, "Person #{qid}")}
        end)

      Req.Test.json(conn, %{"entities" => entities})
    end)

    Map.merge(ctx, %{
      contributor: Scope.for_user(contributor),
      reviewer: Scope.for_user(reviewer),
      coward: coward,
      coward_sense: coward_sense,
      requests: requests
    })
  end

  defp organization(qid, label) do
    Conformance.human(qid, label)
    |> put_in(["claims", "P31"], [
      %{
        "mainsnak" => %{"datavalue" => %{"value" => %{"id" => "Q43229"}}},
        "rank" => "normal",
        "type" => "statement"
      }
    ])
  end

  defp row(overrides \\ %{}) do
    Map.merge(
      %{
        "word" => "coward",
        "sense" => %{"source" => "wordnet", "match" => "shows fear or timidity"},
        "subject" => %{"wikidata" => @bezos, "label" => "Jeff Bezos", "kind" => "person"},
        "rationale" =>
          "Blocked his newspaper's drafted presidential endorsement eleven days before the election.",
        "evidence" => [
          %{"url" => @cnn, "attribution" => "CNN, 25 October 2024", "role" => "supports"}
        ],
        "curator" => "holden"
      },
      overrides
    )
  end

  defp manifest(rows, slug \\ "test-v1") do
    manifest = %{
      "schema_version" => 1,
      "kind" => "exemplars",
      "manifest" => slug,
      "rows" => rows,
      "row_count" => length(rows)
    }

    Map.put(manifest, "checksum", Manifest.checksum(manifest))
  end

  defp seed(ctx, rows, opts \\ []) do
    {:ok, summary} =
      Seeder.run(
        manifest(rows, opts[:slug] || "test-v1"),
        ctx.contributor,
        Keyword.merge([claim: fn _stage -> {:ok, 0} end], opts)
      )

    summary
  end

  defp accept!(ctx, assertion_id, decision \\ "accepted") do
    revision = Claims.current_revision(assertion_id)
    shown = Contributions.context_items(revision)

    {:ok, _} =
      Contributions.review(ctx.reviewer, assertion_id, revision.id, decision, "Checked.", shown)
  end

  defp illustrates_count do
    Repo.aggregate(
      from(r in AssertionRevision,
        join: p in assoc(r, :predicate),
        where: p.key == "illustrates"
      ),
      :count
    )
  end

  describe "a manifest row for a living person with a QID and one evidence URL" do
    test "seeds a needs_review claim and mints the person under community", ctx do
      assert nil == Registry.by_external_id("wikidata", @bezos)

      summary = seed(ctx, [row()])
      assert %{created: 1, minted: 1, refused: 0, held: 0} = summary
      assert [%{outcome: :created, minted: true, assertion_id: id}] = summary.results

      # The person: one entity, a person, identified by the verified QID and
      # minted by `community` (entities have no origin_source_id column; the
      # creator path records who minted it in `metadata["minted_by"]`).
      bezos_id = Registry.by_external_id("wikidata", @bezos)

      assert %Entity{entity_kind: :person, preferred_label: "Jeff Bezos"} =
               entity = Repo.get!(Entity, bezos_id)

      assert entity.metadata["minted_by"] == Community.slug()

      assert %ExternalIdentifier{status: :verified} =
               Repo.get_by!(ExternalIdentifier, namespace: "wikidata", external_id: @bezos)

      # The claim: curated, the rationale, the sense the match resolved, the
      # file and row, submitted by the contributor.
      revision = Claims.current_revision(id)
      assert revision.subject_object_id == bezos_id
      assert revision.object_object_id == ctx.coward_sense.object_id
      assert revision.method == "curated"
      assert revision.metadata["manifest"] == "test-v1"
      assert revision.metadata["row"] == 1
      assert revision.metadata["curator"] == "holden"
      assert revision.metadata["sense"]["source"] == "wordnet"
      assert Claims.review_state(revision.id) == :needs_review

      # The evidence: a URL stored as a record under `community`, URL and
      # citation only.
      assert [evidence] = Claims.evidence(revision.id)
      assert evidence.locator == @cnn
      assert evidence.attribution_text == "CNN, 25 October 2024"
      record = Repo.get_by!(SourceRecord, external_id: Community.digest(@cnn))
      assert record.url == @cnn
      assert record.source_id == ctx.sources["community"].id

      # Every claim has a source: a nomination's is `community`.
      assert Repo.get!(Assertion, id).source_id == ctx.sources["community"].id
    end

    test "is invisible to the public and marked for an internal viewer", ctx do
      %{results: [%{assertion_id: id}]} = seed(ctx, [row()])

      assert Examples.exemplars([ctx.coward.object_id], :public) == []

      assert [%{layer: :exemplar, claim: claim, subject: subject}] =
               Examples.exemplars([ctx.coward.object_id], :internal)

      assert claim.assertion_id == id
      assert claim.review_state == :needs_review
      assert claim.method == "curated"
      assert claim.evidence_count == 1
      assert claim.nominated_by.label == "holden"
      assert [%{url: @cnn, attribution: "CNN, 25 October 2024", role: :supports}] = claim.evidence
      assert subject.label == "Jeff Bezos"
      assert subject.qid == @bezos

      refute Claims.publicly_visible_revision?(Claims.current_revision(id))
    end

    test "a reviewer's accept makes it public; a reject removes it for everyone", ctx do
      %{results: [%{assertion_id: id}]} = seed(ctx, [row()])

      accept!(ctx, id)

      assert [%{claim: %{review_state: :accepted}, signals: signals}] =
               Examples.exemplars([ctx.coward.object_id], :public)

      # No votes exist yet, and nothing is featured: both counts are shown as
      # zero rather than hidden.
      assert %{human_up: 0, human_down: 0, featured_at: nil, evidence_count: 1} = signals

      accept!(ctx, id, "rejected")
      assert Examples.exemplars([ctx.coward.object_id], :public) == []
      assert Examples.exemplars([ctx.coward.object_id], :internal) == []
    end

    test "a disputed nomination of a person stays out of public view", ctx do
      %{results: [%{assertion_id: id}]} = seed(ctx, [row()])
      accept!(ctx, id, "disputed")

      assert Examples.exemplars([ctx.coward.object_id], :public) == []

      assert [%{claim: %{review_state: :disputed}}] =
               Examples.exemplars([ctx.coward.object_id], :internal)
    end
  end

  describe "held" do
    test "a second row for the same subject and meaning is held and writes nothing", ctx do
      summary =
        seed(ctx, [
          row(),
          row(%{"rationale" => "Another reason, from another hand.", "curator" => "someone else"})
        ])

      assert [%{outcome: :created, assertion_id: id}, %{outcome: :held, assertion_id: id}] =
               summary.results

      assert illustrates_count() == 1
    end

    test "a replayed manifest reports every row held and adds no row anywhere", ctx do
      seed(ctx, [row()])
      requests = Agent.get(ctx.requests, & &1)
      records = Repo.aggregate(SourceRecord, :count)
      entities = Repo.aggregate(Entity, :count)

      assert %{held: 1, created: 0, minted: 0} = seed(ctx, [row()])

      assert illustrates_count() == 1
      assert Repo.aggregate(SourceRecord, :count) == records
      assert Repo.aggregate(Entity, :count) == entities
      # The person is held now, so nothing is asked of Wikidata again.
      assert Agent.get(ctx.requests, & &1) == requests
    end

    test "the form path holds a duplicate too", ctx do
      %{results: [%{assertion_id: id}]} = seed(ctx, [row()])
      bezos = Registry.by_external_id("wikidata", @bezos)

      evidence = [
        Map.merge(Community.cite!(@cnn, "CNN"), %{locator: @cnn, evidence_role: :supports})
      ]

      assert {:error, {:held, ^id}} =
               Contributions.propose(
                 ctx.contributor,
                 bezos,
                 "illustrates",
                 ctx.coward_sense.object_id,
                 %{rationale: "Again."},
                 evidence
               )
    end
  end

  describe "refused" do
    test "a sense.match hitting no sense is refused with the word's glosses", ctx do
      # The issue's own example row: "person who lacks courage" is
      # Wiktionary's gloss, not WordNet's.
      summary =
        seed(ctx, [
          row(%{"sense" => %{"source" => "wordnet", "match" => "person who lacks courage"}})
        ])

      assert [%{outcome: :refused, reason: :sense_not_found, glosses: glosses}] = summary.results
      assert glosses == ["a person who shows fear or timidity"]
      assert illustrates_count() == 0
      assert Registry.by_external_id("wikidata", @bezos) == nil
    end

    test "a sense.match hitting several senses is refused with the glosses", ctx do
      summary = seed(ctx, [row(%{"sense" => %{"source" => "wiktionary", "match" => "."}})])

      assert [%{outcome: :refused, reason: :sense_ambiguous, glosses: glosses, matched: matched}] =
               summary.results

      assert Enum.sort(glosses) == ["A person who lacks courage.", "Cowardly."]
      assert Enum.sort(matched) == Enum.sort(glosses)
      assert illustrates_count() == 0
    end

    test "a row with no QID and no entity is refused", ctx do
      summary =
        seed(ctx, [row(%{"subject" => %{"label" => "Some Name", "kind" => "person"}})])

      assert [%{outcome: :refused, reason: :subject_without_identity}] = summary.results
      assert illustrates_count() == 0
      assert Agent.get(ctx.requests, & &1) == 0
    end

    test "a person with no evidence is refused, at the manifest and at propose/6", ctx do
      summary = seed(ctx, [row(%{"evidence" => []})])
      assert [%{outcome: :refused, reason: :evidence_required_for_person}] = summary.results

      {:ok, person} = Registry.create_person(%{preferred_label: "Held Person"})

      assert {:error, :evidence_required_for_person} =
               Contributions.propose(
                 ctx.contributor,
                 person.object_id,
                 "illustrates",
                 ctx.coward_sense.object_id,
                 %{rationale: "No evidence."},
                 []
               )
    end

    test "a QID held as an untyped concept stub is refused, not nominated (#165)", ctx do
      concept!("Q317521", "Elon Musk")

      summary =
        seed(ctx, [
          row(%{
            "subject" => %{"wikidata" => "Q317521", "label" => "Elon Musk", "kind" => "person"}
          })
        ])

      assert [%{outcome: :refused, reason: :subject_held_as_concept}] = summary.results
    end

    test "a QID Wikidata says is an organisation is refused as a person", ctx do
      summary =
        seed(ctx, [
          row(%{"subject" => %{"wikidata" => "Q43229", "label" => "Org", "kind" => "person"}})
        ])

      assert [%{outcome: :refused, reason: :subject_kind_mismatch}] = summary.results
      assert Registry.by_external_id("wikidata", "Q43229") == nil
    end

    test "a meaning that moved since the claim was written is refused, not retargeted", ctx do
      %{results: [%{outcome: :created}]} = seed(ctx, [row()])
      sense!(ctx, ctx.coward, "wordnet", gloss: "someone who shows fear or timidity in a crisis")

      # The old match now hits two senses; a narrower one hits only the new one.
      moved = row(%{"sense" => %{"source" => "wordnet", "match" => "in a crisis"}})
      assert %{results: [%{outcome: :refused, reason: :sense_moved}]} = seed(ctx, [moved])
      assert illustrates_count() == 1
    end

    test "a row inserted above another does not make the other look moved", ctx do
      hypocrite = word!(ctx, "hypocrite", ~w(wordnet))
      sense!(ctx, hypocrite, "wordnet", gloss: "a person who professes beliefs")
      %{results: [%{outcome: :created}]} = seed(ctx, [row()])

      above =
        row(%{"word" => "hypocrite", "sense" => %{"source" => "wordnet", "match" => "professes"}})

      assert %{results: [%{outcome: :created}, %{outcome: :held}]} = seed(ctx, [above, row()])
    end

    test "a manifest whose checksum does not match is refused on load" do
      path =
        Path.join(System.tmp_dir!(), "exemplars-drift-#{System.unique_integer([:positive])}.json")

      manifest = manifest([row()]) |> Map.put("rows", [row(%{"rationale" => "edited"})])
      File.write!(path, Jason.encode!(manifest))

      assert_raise ArgumentError, ~r/checksum mismatch/, fn -> Manifest.load!(path) end

      Manifest.stamp!(path)
      assert %{"row_count" => 1} = Manifest.load!(path)
      File.rm!(path)
    end
  end

  test "a dry run resolves every row, writes nothing and asks nothing", ctx do
    summary = seed(ctx, [row()], dry_run: true)

    assert [%{outcome: :would_seed, mint: true}] = summary.results
    assert illustrates_count() == 0
    assert Agent.get(ctx.requests, & &1) == 0
  end

  test "--limit seeds only the first rows", ctx do
    summary = seed(ctx, [row(), row(%{"word" => "nosuchword"})], limit: 1)
    assert summary.rows == 1
  end

  test "without a Wikidata claim a nominee to mint is deferred, not refused", ctx do
    {:ok, summary} = Seeder.run(manifest([row()]), ctx.contributor, [])
    assert [%{outcome: :deferred}] = summary.results
    assert illustrates_count() == 0
  end

  describe "the visibility rule is about nominations, not about people" do
    test "an imported claim with a person subject stays public (#181 R3)", ctx do
      {:ok, person} = Registry.create_person(%{preferred_label: "Imported Person"})
      human = concept!("Q5", "human")

      {:ok, assertion} =
        Claims.assert(person.object_id, "instance_of", human.object_id, %{
          method: "source",
          source_id: ctx.sources["wikidata"].id
        })

      assert Claims.publicly_visible_revision?(Claims.current_revision(assertion.id))
    end

    test "a nomination whose subject is not a person is public while pending", ctx do
      {:ok, work} = Registry.create_work(%{preferred_label: "An Allegory", work_kind: "artwork"})

      {:ok, claim} =
        Contributions.propose(
          ctx.contributor,
          work.object_id,
          "illustrates",
          ctx.coward_sense.object_id,
          %{rationale: "It shows a figure fleeing."},
          []
        )

      assert [%{claim: %{review_state: :needs_review}}] =
               Examples.exemplars([ctx.coward.object_id], :public)

      assert Claims.publicly_visible_revision?(Claims.current_revision(claim.id))
    end
  end

  describe "the read model" do
    test "exemplars come before instances, and instances are unchanged by them", ctx do
      hitler = word!(ctx, "Adolf Hitler", ~w(wordnet))
      hitler_sense = sense!(ctx, hitler, "wordnet", group_key: "oewn-hitler-n")

      relation!(ctx, hitler, :instance_of, nil,
        source: "wordnet",
        from_sense: hitler_sense,
        to_sense: ctx.coward_sense
      )

      before = Examples.for_page([ctx.coward.object_id], :public)
      %{results: [%{assertion_id: id}]} = seed(ctx, [row()])
      accept!(ctx, id)
      now = Examples.for_page([ctx.coward.object_id], :public)

      assert [%{layer: :exemplar, id: "ex:" <> _} | instances] = now.items
      assert instances == before.items
      assert now.totals == %{instance: 1, exemplar: 1}
      assert Enum.all?(now.items, &(Examples.check(&1) == :ok))
    end

    test "Rank orders accepted exemplars by net votes, then evidence, then age", ctx do
      %{results: [%{assertion_id: first}, %{assertion_id: second}]} =
        seed(ctx, [
          row(),
          row(%{
            "subject" => %{
              "wikidata" => "Q36215",
              "label" => "Mark Zuckerberg",
              "kind" => "person"
            },
            "evidence" => [
              %{"url" => "https://example.test/a", "attribution" => "A"},
              %{"url" => "https://example.test/b", "attribution" => "B"}
            ]
          })
        ])

      accept!(ctx, first)
      accept!(ctx, second)

      assert ["ex:#{second}", "ex:#{first}"] ==
               Examples.exemplars([ctx.coward.object_id], :public)
               |> Examples.Rank.order()
               |> Enum.map(& &1.id)

      # One person's vote outranks one more piece of evidence.
      voter = user_fixture()

      actor =
        Repo.insert!(%DevilsDictionary.Sources.Actor{
          actor_kind: :user,
          user_id: voter.id,
          label: "v"
        })

      {:ok, _} = Claims.vote(Claims.current_revision(first).id, actor.id, 1)

      assert ["ex:#{first}", "ex:#{second}"] ==
               Examples.exemplars([ctx.coward.object_id], :public)
               |> Examples.Rank.order()
               |> Enum.map(& &1.id)
    end
  end

  describe "the person page (the reverse view)" do
    test "accepted claims grouped by word, and what the record files them under", ctx do
      hypocrite = word!(ctx, "hypocrite", ~w(wordnet))

      sense!(ctx, hypocrite, "wordnet",
        gloss: "a person who professes beliefs and opinions that he or she does not hold"
      )

      summary =
        seed(ctx, [
          row(),
          row(%{
            "word" => "hypocrite",
            "sense" => %{"source" => "wordnet", "match" => "professes beliefs"}
          })
        ])

      [%{assertion_id: coward_claim}, %{assertion_id: hypocrite_claim}] = summary.results
      bezos = Registry.by_external_id("wikidata", @bezos)

      # Nothing accepted: nothing on the page.
      assert Examples.cited_as(bezos) == []

      accept!(ctx, coward_claim)
      accept!(ctx, hypocrite_claim)

      assert [%{lexeme: %{lemma: first}}, %{lexeme: %{lemma: second}}] = Examples.cited_as(bezos)
      assert Enum.sort([first, second]) == ["coward", "hypocrite"]

      # The record's side: a word for the person, filed by WordNet under
      # another word's sense.
      businessman = word!(ctx, "businessman", ~w(wordnet))
      businessman_sense = sense!(ctx, businessman, "wordnet")
      bezos_word = word!(ctx, "Jeff Bezos", ~w(wordnet))
      bezos_sense = sense!(ctx, bezos_word, "wordnet")
      link!(bezos_word, Repo.get!(Entity, bezos), sense: bezos_sense)

      relation!(ctx, bezos_word, :instance_of, nil,
        source: "wordnet",
        from_sense: bezos_sense,
        to_sense: businessman_sense
      )

      assert [%{kind: :lexeme, label: "businessman", source: %{slug: "wordnet"}}] =
               Examples.named_under(bezos)
    end
  end
end
