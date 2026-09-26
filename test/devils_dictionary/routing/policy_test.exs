defmodule DevilsDictionary.Routing.PolicyTest do
  use ExUnit.Case, async: true

  alias DevilsDictionary.Routing.Policy

  setup do
    %{policy: Policy.load()}
  end

  test "approved charter examples select distinct families without reading labels", %{
    policy: policy
  } do
    examples = [
      {"Q5", "people"},
      {"Q215380", "organizations"},
      {"Q4022", "places"},
      {"Q8502", "places"},
      {"Q6256", "places"},
      {"Q482994", "works"},
      {"Q11424", "works"},
      {"Q5398426", "works"},
      {"Q7397", "works"},
      {"Q3504248", "nature"},
      {"Q16521", "nature"},
      {"Q15304943", "nature"},
      {"Q11173", "nature"},
      {"Q33742", "concepts"},
      {"Q9143", "concepts"},
      {"Q16748888", "concepts"},
      {"Q752783", "events"},
      {"Q7944", "events"},
      {"Q95074", "subjects"},
      {"Q178885", "subjects"}
    ]

    for {qid, family} <- examples do
      subject = entity([qid])
      result = Policy.classify(subject, graph([qid]), policy)
      assert result.family == family, "wrong family for #{qid}"
      assert result.status == "mapped"
      refute result.publishable
      refute result.allocated

      assert Policy.classify(%{subject | "label" => "Unrelated new name"}, graph([qid]), policy).family ==
               family
    end
  end

  test "general earthquake class and an earthquake occurrence have different families", %{
    policy: policy
  } do
    class = %{entity([]) | "qids" => ["Q7944"]}

    assert Policy.classify(class, %{"Q7944" => evidence("Q7944", [], [])}, policy).family ==
             "nature"

    assert Policy.classify(entity(["Q7944"]), graph(["Q7944"]), policy).family == "events"
  end

  test "all storage kinds are accounted for without trusting them as classifications", %{
    policy: policy
  } do
    for kind <- ~w(person organization concept event work edition place artifact taxon other) do
      result = Policy.classify(%{entity([]) | "entity_kind" => kind}, %{}, policy)
      assert result.status == "needs_review"
      assert result.family == nil
    end
  end

  test "P31 once then P279 supports indirect types, with pinned evidence", %{policy: policy} do
    graph = graph(["Q900001"]) |> Map.put("Q900001", evidence("Q900001", ["Q5"], ["Q482994"]))
    result = Policy.classify(entity(["Q900001"]), graph, policy)
    assert result.family == "works"
    assert result.status == "mapped"
    assert [%{path: ["Q900001", "Q482994"]}] = result.matches
    assert Enum.any?(result.evidence, &(&1["qid"] == "Q900001"))
  end

  test "P31 is not transitive and unrelated claims do not classify", %{policy: policy} do
    node = evidence("Q900001", ["Q5"], [])
    graph = graph(["Q900001"]) |> Map.put("Q900001", node)
    result = Policy.classify(entity(["Q900001"]), graph, policy)
    assert result.family == nil
    assert result.status == "needs_review"
  end

  test "preferred ranks supersede normal and deprecated statements are ignored" do
    record = %{
      "claims" => %{
        "P31" => [
          claim("Q5", "normal"),
          claim("Q482994", "preferred"),
          claim("Q8502", "deprecated")
        ]
      }
    }

    assert Policy.values(record, "P31") == ["Q482994"]
  end

  test "qualified assertions are not treated as unconditional classification" do
    record = %{"claims" => %{"P31" => [Map.put(claim("Q5"), "qualifiers", %{"P580" => [%{}]})]}}
    assert Policy.values(record, "P31") == []
  end

  test "missing, cyclic and bounded class walks defer instead of guessing", %{policy: policy} do
    for graph <- [
          graph(["Q900001"]),
          graph(["Q900001"]) |> Map.put("Q900001", evidence("Q900001", [], ["Q900001"]))
        ] do
      result = Policy.classify(entity(["Q900001"]), graph, policy)
      assert result.status == "needs_review"
      assert result.warnings != []
    end

    shallow = put_in(policy.rules["max_depth"], 0)
    result = Policy.classify(entity(["Q900001"]), graph(["Q900001"]), shallow)
    assert "graph_depth_limit:Q900001" in result.warnings
  end

  test "incompatible matches and incomplete alternative branches need review", %{policy: policy} do
    conflict = Policy.classify(entity(["Q5", "Q482994"]), graph(["Q5", "Q482994"]), policy)
    assert conflict.status == "needs_review"
    assert conflict.family == nil
    assert conflict.candidate_families == ["people", "works"]
    incomplete = Policy.classify(entity(["Q5", "Q900001"]), graph(["Q5", "Q900001"]), policy)
    assert incomplete.family == "people"
    assert incomplete.status == "needs_review"
  end

  test "explicit precedence handles human, fictional and celestial overlaps", %{policy: policy} do
    for {types, family} <- [
          {["Q5", "Q16521"], "people"},
          {["Q5", "Q95074"], "subjects"},
          {["Q3504248", "Q2221906"], "nature"}
        ] do
      assert Policy.classify(entity(types), graph(types), policy).family == family
    end
  end

  test "source pages are excluded and stale flags remain reviewable", %{policy: policy} do
    assert Policy.classify(
             entity(["Q4167410", "Q486972"]),
             graph(["Q4167410", "Q486972"]),
             policy
           ).status == "excluded_source_page"

    novel = Map.put(entity(["Q47461344"]), "disambiguation", true)
    result = Policy.classify(novel, graph(["Q47461344"]), policy)
    assert result.family == "works"
    assert result.status == "needs_review"
  end

  test "unversioned projection and projection drift cannot become mapped", %{policy: policy} do
    assert Policy.classify(entity(["Q5"]), %{}, policy).status == "needs_review"
    result = Policy.classify(entity(["Q5"]), graph(["Q482994"]), policy)
    assert result.family == "works"
    assert "projection_differs_from_source" in result.warnings
    assert result.status == "needs_review"
  end

  test "local work and edition identities do not require an external identifier", %{
    policy: policy
  } do
    work =
      entity([]) |> Map.merge(%{"qids" => [], "entity_kind" => "work", "work_kind" => "poem"})

    edition =
      entity([])
      |> Map.merge(%{"qids" => [], "entity_kind" => "edition", "edition_work_id" => 42})

    assert Policy.classify(work, %{}, policy).family == "works"
    assert Policy.classify(edition, %{}, policy).page_role == "edition"
    refute Policy.classify(work, %{}, policy).publishable
  end

  test "subclass-only projections need revision evidence and drift is reviewable", %{
    policy: policy
  } do
    subject = Map.put(entity([]), "subclass_of", ["Q16521"])
    result = Policy.classify(subject, %{}, policy)
    assert result.status == "needs_review"
    assert "unversioned_type_projection" in result.warnings

    result = Policy.classify(subject, graph([]), policy)
    assert "projection_differs_from_source" in result.warnings
  end

  test "a mapped ancestry branch cannot hide qualified or unpinned alternative evidence", %{
    policy: policy
  } do
    qualified = Map.put(claim("Q5"), "qualifiers", %{"P580" => [%{}]})
    ancestor = evidence("Q900001", [], ["Q482994"])
    ancestor = update_in(ancestor["claims"]["P279"], &[qualified | &1])
    evidence_graph = graph(["Q900001"]) |> Map.put("Q900001", ancestor)
    result = Policy.classify(entity(["Q900001"]), evidence_graph, policy)
    assert result.family == "works"
    assert result.status == "needs_review"
    assert "qualified_ancestry:Q900001" in result.warnings

    unpinned = evidence("Q900001", [], ["Q482994"]) |> Map.delete("revision_id")
    evidence_graph = Map.put(evidence_graph, "Q900001", unpinned)
    result = Policy.classify(entity(["Q900001"]), evidence_graph, policy)
    assert result.status == "needs_review"
    assert "missing_ancestry_revision_pin:Q900001" in result.warnings
  end

  test "retired, merged and split objects never get automatic assignments", %{policy: policy} do
    for state <- ~w(retired merged split) do
      result = Policy.classify(%{entity(["Q5"]) | "lifecycle" => state}, graph(["Q5"]), policy)
      assert result.status == "identity_review"
      refute result.publishable
    end
  end

  test "punctuation, Unicode and length have deliberate non-identity semantics" do
    assert Policy.slug("C++") == "c-plus-plus"
    assert Policy.slug("C+") == "c-plus"
    assert Policy.slug("c") == "c"
    assert Policy.slug("C#") == "c-sharp"
    assert Policy.slug(".NET") == "dot-net"
    assert Policy.slug("cafe\u0301") == Policy.slug("café")
    assert Policy.slug("中文") == "中文"
    assert Policy.slug("Polish") == Policy.slug("polish")
    assert Policy.slug("!!!") == nil
    assert Policy.slug("") == nil
    assert Policy.slug(String.duplicate("é", 61)) == nil
  end

  test "input order does not select a winning class", %{policy: policy} do
    a = Policy.classify(entity(["Q5", "Q482994"]), graph(["Q5", "Q482994"]), policy)
    b = Policy.classify(entity(["Q482994", "Q5"]), graph(["Q482994", "Q5"]), policy)
    assert a == b
  end

  defp entity(types) do
    %{
      "object_id" => 42,
      "label" => "Same name",
      "entity_kind" => "concept",
      "lifecycle" => "active",
      "qids" => ["Q900000"],
      "instance_of" => types,
      "subclass_of" => [],
      "disambiguation" => false
    }
  end

  defp graph(types), do: %{"Q900000" => evidence("Q900000", types, [])}

  defp evidence(qid, p31, p279),
    do: %{
      "qid" => qid,
      "revision_id" => 10,
      "checksum" => "fixture",
      "claims" => %{"P31" => Enum.map(p31, &claim/1), "P279" => Enum.map(p279, &claim/1)}
    }

  defp claim(qid, rank \\ "normal"),
    do: %{"rank" => rank, "mainsnak" => %{"datavalue" => %{"value" => %{"id" => qid}}}}
end
