defmodule DevilsDictionary.Routing.JsonLdTest do
  @moduledoc """
  The structured data of #237 D4 (ADR 0004 §7): a `WebPage` node separate
  from the subject node; the subject typed only by its evidenced family
  mapping, `Thing` with an `additionalType` for Concepts, Nature and
  Subjects only where the record names the class; `sameAs` only from
  verified identifiers; never `schema:Nature`, never `DefinedTerm`; encoded
  so nothing in it can close the script element.
  """
  use DevilsDictionary.DataCase, async: false

  import DevilsDictionary.OnFixtures
  import DevilsDictionary.RoutingFixtures, only: [evaluate: 2, leave_unmapped!: 1]
  import Ecto.Query

  alias DevilsDictionary.Registry
  alias DevilsDictionary.Registry.Entity
  alias DevilsDictionary.Routing.{Classifications, JsonLd}

  test "the subject is typed by its family alone; Thing for Concepts, Nature and Subjects" do
    for {family, type} <- [
          {"people", "Person"},
          {"organizations", "Organization"},
          {"places", "Place"},
          {"events", "Event"},
          {"works", "CreativeWork"},
          {"concepts", "Thing"},
          {"nature", "Thing"},
          {"subjects", "Thing"}
        ] do
      assert JsonLd.type(family) == type, family
    end

    assert JsonLd.type("on") == nil
  end

  test "sameAs names verified identifiers only; additionalType only a class the record names" do
    mars = subject!("Mars", "nature", description: "fourth planet", page: false)
    id = mars.entity.object_id

    {:ok, _} = Registry.add_external_id(id, "wikidata", "Q111")
    {:ok, _} = Registry.add_external_id(id, "wikidata", "Q222", %{status: :candidate})
    {:ok, _} = Registry.add_external_id(id, "wikipedia", "12345")

    assert JsonLd.same_as(id) == ["https://www.wikidata.org/wiki/Q111"]
    assert JsonLd.same_as(nil) == []

    # The fixture's rule (biological groups) anchors on three classes, and the
    # record names none: nothing is claimed.
    assert %{rule_ids: ["biological_groups"]} = Classifications.current(id)
    assert JsonLd.additional_type(id, "nature") == []

    # The entity's own recorded class that the rule anchors on is claimed;
    # one it does not anchor on is not.
    Repo.update_all(from(e in Entity, where: e.object_id == ^id),
      set: [metadata: %{"wikidata_instance_of" => ["Q16521", "Q999"]}]
    )

    assert JsonLd.additional_type(id, "nature") == ["https://www.wikidata.org/wiki/Q16521"]

    # A typed family claims no additional type.
    assert JsonLd.additional_type(id, "people") == []

    # A page in another untyped family than the decision names (a
    # reclassification not yet moved, ADR 0004 §8.4) claims none either: the
    # class is the decision's family's, not the page's.
    assert %{family: :nature} = Classifications.current(id)
    assert JsonLd.additional_type(id, "concepts") == []
    assert JsonLd.additional_type(id, "subjects") == []

    # A rule with one anchor is certain without a recorded class.
    jupiter = subject!("Jupiter", "nature", status: :none, page: false)
    {:ok, _, _} = jupiter.entity.object_id |> evaluate("Q3504248") |> Classifications.record()

    assert JsonLd.additional_type(jupiter.entity.object_id, "nature") ==
             ["https://www.wikidata.org/wiki/Q3504248"]

    # A record under review claims none.
    unknown = subject!("Unknown", "subjects", status: :none, page: false)
    leave_unmapped!(unknown.entity.object_id)
    assert JsonLd.additional_type(unknown.entity.object_id, "subjects") == []
    assert JsonLd.additional_type(999_999_999, "subjects") == []
  end

  test "a WebPage about a separate subject node; nothing is Nature or DefinedTerm; HTML-safe" do
    mars = subject!("Mars", "nature", page: false)
    id = mars.entity.object_id
    {:ok, _} = Registry.add_external_id(id, "wikidata", "Q111")

    Repo.update_all(from(e in Entity, where: e.object_id == ^id),
      set: [metadata: %{"wikidata_instance_of" => ["Q16521"]}]
    )

    canonical = "https://wordhoard.test/nature/mars"

    graph =
      JsonLd.subject_graph(
        canonical,
        %{title: "Mars · Nature", description: "The planet.", modified: "2026-10-09T10:00:00Z"},
        %{
          object_id: id,
          label: "Mars",
          description: "fourth <planet> & </script>",
          family: "nature"
        }
      )

    assert %{"@context" => "https://schema.org", "@graph" => [page, subject]} = graph

    assert page == %{
             "@type" => "WebPage",
             "@id" => canonical <> "#page",
             "url" => canonical,
             "inLanguage" => "en",
             "name" => "Mars · Nature",
             "description" => "The planet.",
             "dateModified" => "2026-10-09T10:00:00Z",
             "about" => %{"@id" => canonical <> "#subject"}
           }

    assert subject == %{
             "@type" => "Thing",
             "@id" => canonical <> "#subject",
             "name" => "Mars",
             "url" => canonical,
             "description" => "fourth <planet> & </script>",
             "sameAs" => "https://www.wikidata.org/wiki/Q111",
             "additionalType" => "https://www.wikidata.org/wiki/Q16521"
           }

    # Nothing in it can open a tag or close the script element.
    json = JsonLd.encode(graph)
    refute json =~ "<"
    refute json =~ "</"
    refute json =~ ~s("@type":"Nature")
    refute json =~ "DefinedTerm"
    assert Jason.decode!(json) == graph

    # Without a description, a date or an identifier, the keys are absent.
    bare =
      JsonLd.subject_graph(canonical, %{title: "Mars"}, %{
        object_id: 0,
        label: "Mars",
        family: "people"
      })

    assert %{"@graph" => [page, subject]} = bare
    refute Map.has_key?(page, "description")
    refute Map.has_key?(page, "dateModified")
    refute Map.has_key?(subject, "sameAs")
    refute Map.has_key?(subject, "additionalType")
    assert subject["@type"] == "Person"

    # A page about no subject is the WebPage node alone.
    assert %{
             "@graph" => [%{"@type" => "WebPage", "@id" => "https://wordhoard.test/#page"} = home]
           } =
             JsonLd.page_graph("https://wordhoard.test/", %{title: "Every word"})

    refute Map.has_key?(home, "about")
  end
end
