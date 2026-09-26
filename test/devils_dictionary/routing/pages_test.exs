defmodule DevilsDictionary.Routing.PagesTest do
  @moduledoc """
  Page identity and revisioned On storage (ADR 0004 §4): immutable revisions,
  typed ordered membership, and membership that never asserts identity.
  """
  use DevilsDictionary.DataCase, async: true

  import DevilsDictionary.RoutingFixtures

  alias DevilsDictionary.Registry.{ExternalIdentifier, ObjectName}
  alias DevilsDictionary.Routing.Pages

  setup do
    %{human: human!()}
  end

  defp members(revision),
    do:
      Enum.map(
        revision.memberships,
        &{&1.position, &1.relationship, &1.target_object_id || &1.target_page_id}
      )

  test "an On page keeps every revision whole, with its ordered, typed membership", ctx do
    on = overview_page!()
    putin = subject_page!("people", "Vladimir Putin", :person)
    poutine = lexeme!("poutine")

    identity_rows =
      {Repo.aggregate(ObjectName, :count), Repo.aggregate(ExternalIdentifier, :count)}

    first = [
      %{relationship: :discusses_subject, target_page_id: putin.id},
      %{relationship: :supplies_lexical_material, target_object_id: poutine.object_id},
      %{
        relationship: :editorial_association,
        target_object_id: putin.target_object_id,
        rationale: "wordplay, not identity"
      }
    ]

    {:ok, one} =
      Pages.add_revision(
        on.id,
        %{title: "On Putin and poutine", body: "Draft."},
        first,
        ctx.human.id
      )

    {:ok, two} =
      Pages.add_revision(
        on.id,
        %{title: "On Putin and poutine", body: "Revised."},
        Enum.take(first, 2),
        ctx.human.id
      )

    assert {one.revision_number, two.revision_number} == {1, 2}
    assert Pages.current_revision(Pages.get(on.id)).id == two.id

    assert [{1, "Draft.", first_members}, {2, "Revised.", second_members}] =
             Enum.map(Pages.revisions(on.id), &{&1.revision_number, &1.body, members(&1)})

    assert first_members == [
             {1, :discusses_subject, putin.id},
             {2, :supplies_lexical_material, poutine.object_id},
             {3, :editorial_association, putin.target_object_id}
           ]

    assert second_members == Enum.take(first_members, 2)

    # An association is only an association: no name, alias or identifier moved.
    assert {Repo.aggregate(ObjectName, :count), Repo.aggregate(ExternalIdentifier, :count)} ==
             identity_rows

    consistent!()
  end

  test "membership is typed by what it points at", ctx do
    on = overview_page!()
    person = entity!(:person, "Voltaire")
    before = Pages.revisions(on.id)

    for {member, error} <- [
          {%{relationship: :supplies_lexical_material, target_object_id: person.object_id},
           :lexical_material_must_be_a_lexeme_or_sense},
          {%{relationship: :split_successor, target_page_id: overview_page!().id},
           :split_successors_are_written_by_the_ledger},
          {%{relationship: :choice_option, target_page_id: overview_page!().id},
           :choice_options_belong_to_choice_pages},
          {%{relationship: :discusses_subject, target_object_id: -1},
           :membership_target_not_found}
        ] do
      assert Pages.add_revision(on.id, %{}, [member], ctx.human.id) == {:error, error}
    end

    assert Pages.revisions(on.id) == before
  end

  test "ensure finds or creates the one page for a target and locale" do
    entity = entity!(:person, "Voltaire")
    assert {:ok, page} = Pages.ensure(:subject, entity.object_id)
    assert {:ok, ^page} = Pages.ensure(:subject, entity.object_id)
    assert {:ok, french} = Pages.ensure(:subject, entity.object_id, "fr")
    assert french.id != page.id and french.locale == "fr"
  end
end
