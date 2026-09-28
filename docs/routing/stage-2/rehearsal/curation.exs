# Shared by the Stage 2 rehearsal scripts: the curation (#206) part of the
# fixture, and what "curation state and approvals preserved" means when it is
# checked. Loaded with Code.require_file/2.
#
# The fixture is a real word's composition: "abasement" (noun), whose Bierce
# entry leads and whose Johnson definition is a highlight — both corpus
# content, nothing invented. A marked reviewer accepts and publishes the
# first version; a second version is rejected. These are rehearsal approvals
# on an isolated copy, made through the curation services with their own
# checks, never a publication decision: no reader is enabled on a copy.
#
# Published.current/1 evaluates the arrangement live — current revisions,
# displayable source records, active sources, scope and review standing — so
# the standing recorded here is also a check that recovery and re-projection
# kept everything an approval stands on.
defmodule Stage2.Curation do
  import Ecto.Query

  alias DevilsDictionary.{Accounts, Registry, Repo}
  alias DevilsDictionary.Accounts.Scope
  alias DevilsDictionary.Curation.{Compositions, Configurations, Eligibility, Published, Publications, Reviews}

  # The migration that completes #206's schema on main.
  @curation_migration 20_260_927_094_256

  @tables ~w(
    curator_profiles curator_profile_versions
    curation_configurations curation_configuration_versions curation_configuration_members
    curation_configuration_activations
    editorial_compositions editorial_composition_versions editorial_composition_items
    editorial_composition_memberships editorial_composition_scope_changes
    editorial_composition_reviews editorial_composition_publications
  )

  @lemma "abasement"
  @part_of_speech "noun"

  def tables, do: @tables

  @doc "Whether the copy is at current main's curation schema."
  def present? do
    %{rows: rows} = Repo.query!("SELECT 1 FROM schema_migrations WHERE version = $1", [@curation_migration])
    rows != []
  end

  def counts, do: Map.new(@tables, &{&1, Repo.aggregate(&1, :count)})

  @doc "Writes the curation fixture once, returning its inventory."
  def write!(marker) do
    if Enum.any?(counts(), fn {_table, n} -> n > 0 end),
      do: raise("the copy already holds curation state; the fixture is written once, onto an empty copy")

    reviewer = account!("reviewer", :reviewer)
    contributor = account!("contributor", :internal_contributor)
    %{lexeme_id: lexeme_id, bierce: bierce, johnson: johnson} = word!()

    if not Eligibility.leadable?(bierce), do: raise("the Bierce entry #{bierce} is not leadable")

    spec = fn content_id ->
      %{
        kind: :content,
        object_id: content_id,
        content_revision_id: Registry.current_content_revision(content_id).id,
        meaning: {:lexeme, lexeme_id}
      }
    end

    {:ok, configuration} =
      Configurations.create_test_configuration(reviewer, "stage2-rehearsal", marker <> "configuration")

    {:ok, config_version} =
      Configurations.create_version(reviewer, configuration.id, %{reason: marker <> "rehearsal configuration"})

    {:ok, _} =
      Configurations.activate(reviewer, configuration.id, config_version.id,
        reason: marker <> "activation",
        idempotency_key: "stage2-rehearsal-activate",
        expected: nil
      )

    {:ok, composition} =
      Compositions.provision(contributor, configuration.id, %{
        scope_kind: :lexeme,
        lexeme_ids: [lexeme_id],
        language_tag: "en",
        reason: marker <> "curate #{@lemma}"
      })

    {:ok, accepted} =
      Compositions.create_version(contributor, composition.id, %{
        lead: spec.(bierce),
        highlights: [spec.(johnson)],
        reason: marker <> "first arrangement",
        expected_parent: nil
      })

    {:ok, _} =
      Reviews.decide(reviewer, accepted.id, :accepted,
        reason: marker <> "reads well",
        idempotency_key: "stage2-rehearsal-review-accepted"
      )

    {:ok, receipt} =
      Publications.publish(reviewer, accepted.id,
        reason: marker <> "rehearsal publication",
        idempotency_key: "stage2-rehearsal-publish",
        expected_pointer: nil
      )

    {:ok, rejected} =
      Compositions.create_version(contributor, composition.id, %{
        lead: spec.(bierce),
        highlights: [],
        reason: marker <> "a bare lead",
        expected_parent: accepted.id
      })

    {:ok, _} =
      Reviews.decide(reviewer, rejected.id, :rejected,
        reason: marker <> "the definition belongs",
        idempotency_key: "stage2-rehearsal-review-rejected"
      )

    %{
      "users" => %{"reviewer" => reviewer.user.id, "contributor" => contributor.user.id},
      "lexeme_id" => lexeme_id,
      "lead_content_id" => bierce,
      "highlight_content_id" => johnson,
      "configuration_id" => configuration.id,
      "configuration_version_id" => config_version.id,
      "composition_id" => composition.id,
      "accepted_version_id" => accepted.id,
      "rejected_version_id" => rejected.id,
      "receipt_id" => receipt.id,
      "standing" => standing(composition.id),
      "row_counts" => counts()
    }
  end

  @doc """
  What a reader would be answered for the composition, as plain data: the
  published version, its receipt, the lead and highlights it would show, and
  anything withheld, with its reason.
  """
  def standing(composition_id) do
    case Published.current(composition_id) do
      {:ok, p} ->
        %{
          "status" => "published",
          "version_id" => p.version.id,
          "receipt_id" => p.receipt.id,
          "lead" => p.lead && [p.lead.item_object_id, p.lead.content_revision_id],
          "highlights" => Enum.map(p.highlights, &[&1.position, &1.item_object_id, &1.content_revision_id]),
          "withheld" => Enum.map(p.withheld, &Map.new(&1, fn {k, v} -> {to_string(k), to_string(v)} end))
        }

      {:withheld, reasons} ->
        %{"status" => "withheld", "reasons" => Enum.map(reasons, &to_string/1)}

      other ->
        %{"status" => inspect(other)}
    end
  end

  @doc "Whether the curation fixture stands as it was written: rows and standing."
  def check(inventory) do
    now = %{"row_counts" => counts(), "standing" => standing(inventory["composition_id"])}

    %{
      "row_counts_match" => now["row_counts"] == inventory["row_counts"],
      "standing_matches" => now["standing"] == inventory["standing"],
      "standing" => now["standing"],
      "pass" => now["row_counts"] == inventory["row_counts"] and now["standing"] == inventory["standing"] and
        now["standing"]["status"] == "published" and now["standing"]["withheld"] == []
    }
  end

  @doc """
  Normal curation operations on a recovered copy, after `check/1` passed:
  the original publication's idempotency key replays its own receipt; a
  rejected version cannot be published; the publication is withdrawn and the
  accepted version republished, with a receipt id that continues the restored
  sequence; and the arrangement a reader would get is the one approved.
  """
  def operations!(inventory, marker) do
    reviewer = Scope.for_user(Repo.get!(Accounts.User, inventory["users"]["reviewer"]))
    composition_id = inventory["composition_id"]
    receipt_id = inventory["receipt_id"]
    accepted = inventory["accepted_version_id"]
    max_receipt = Repo.aggregate("editorial_composition_publications", :max, :id)

    publish = fn version_id, key, expected ->
      Publications.publish(reviewer, version_id,
        reason: marker <> "operations",
        idempotency_key: key,
        expected_pointer: expected
      )
    end

    replayed = publish.(accepted, "stage2-rehearsal-publish", nil)
    refused = publish.(inventory["rejected_version_id"], "stage2-rehearsal-publish-rejected", accepted)

    {:ok, withdrawn} =
      Publications.withdraw(reviewer, composition_id,
        reason: marker <> "operations",
        idempotency_key: "stage2-rehearsal-withdraw",
        expected_pointer: accepted
      )

    after_withdraw = standing(composition_id)
    {:ok, republished} = publish.(accepted, "stage2-rehearsal-republish", nil)
    after_republish = standing(composition_id)

    report = %{
      "replayed_receipt" => match?({:ok, %{id: ^receipt_id}}, replayed),
      "rejected_version_refused" => inspect(refused),
      "withdraw_receipt_follows_restored_sequence" => withdrawn.id > max_receipt,
      "after_withdraw" => after_withdraw,
      "republish_receipt_follows_restored_sequence" => republished.id > withdrawn.id,
      "after_republish" => after_republish
    }

    pass? =
      report["replayed_receipt"] and match?({:error, _}, refused) and
        report["withdraw_receipt_follows_restored_sequence"] and after_withdraw["status"] == ":unpublished" and
        report["republish_receipt_follows_restored_sequence"] and
        Map.delete(after_republish, "receipt_id") == Map.delete(inventory["standing"], "receipt_id") and
        after_republish["receipt_id"] == republished.id

    Map.put(report, "pass", pass?)
  end

  @doc "An account with one role, marked by its address, and its scope."
  def account!(role, flag) do
    email = "stage2-rehearsal-#{role}-#{System.unique_integer([:positive])}@example.invalid"
    {:ok, user} = Accounts.register_user(%{email: email})
    user |> Ecto.Changeset.change([{flag, true}]) |> Repo.update!() |> Scope.for_user()
  end

  # The word, and exactly one current Bierce and one current Johnson
  # definition of it.
  defp word! do
    lexeme_id =
      Repo.one!(
        from l in "lexemes",
          where: l.lemma == @lemma and l.part_of_speech == @part_of_speech and l.language_tag == "en",
          select: l.object_id
      )

    defining = fn slug ->
      Repo.all(
        from ar in "assertion_revisions",
          join: pr in "predicates",
          on: pr.id == ar.predicate_id and pr.key == "defines",
          join: ci in "content_items",
          on: ci.object_id == ar.subject_object_id,
          join: s in "sources",
          on: s.id == ci.source_id and s.slug == ^slug,
          where: ar.object_object_id == ^lexeme_id and ar.is_current and ar.lifecycle_state == "active",
          distinct: true,
          select: ci.object_id
      )
    end

    case {defining.("bierce"), defining.("johnson")} do
      {[bierce], [johnson]} -> %{lexeme_id: lexeme_id, bierce: bierce, johnson: johnson}
      other -> raise "expected one Bierce and one Johnson definition of #{@lemma}, found #{inspect(other)}"
    end
  end
end
