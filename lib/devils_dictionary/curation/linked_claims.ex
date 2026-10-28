defmodule DevilsDictionary.Curation.LinkedClaims do
  @moduledoc "Citation-only projection of the four existing public linked-claim paths."
  import Ecto.Query
  alias DevilsDictionary.{Repo, Claims}
  alias DevilsDictionary.Claims.AssertionRevision
  alias DevilsDictionary.Registry.{Sense, SenseRevision, Entity, Lexeme, Object}
  alias DevilsDictionary.Curation.{Digest, ItemBasis}

  def for_scope(ids, sense_order \\ %{}) do
    senses =
      Repo.all(
        from r in SenseRevision,
          join: s in Sense,
          on: s.object_id == r.sense_id,
          where:
            s.lexeme_id in ^ids and s.identity_state == :active and r.is_current and
              r.lifecycle_state == :active,
          order_by: [r.position, r.id]
      )

    senses =
      Enum.sort_by(
        senses,
        &{Map.get(sense_order, &1.sense_id, map_size(sense_order)), &1.position, &1.id}
      )

    ranked =
      DevilsDictionary.Examples.for_page(ids, :public,
        senses: Enum.map(senses, &%{id: &1.sense_id, gloss: &1.gloss})
      ).items

    instance_rank =
      ranked
      |> Enum.with_index()
      |> Enum.reduce(%{}, fn {item, index}, acc ->
        Enum.reduce(item.sources, acc, fn source, acc ->
          Enum.reduce(Map.get(source, :assertion_ids, []), acc, fn id, acc ->
            Map.put_new(acc, id, index)
          end)
        end)
      end)

    shown_by_assertion =
      Enum.reduce(ranked, %{}, fn item, acc ->
        if item.layer == :instance and item.subject.kind == :entity do
          Enum.reduce(item.sources, acc, fn source, acc ->
            Enum.reduce(Map.get(source, :assertion_ids, []), acc, fn id, acc ->
              Map.put(acc, id, item.subject.object_id)
            end)
          end)
        else
          acc
        end
      end)

    sense_ids = Enum.map(senses, & &1.sense_id)

    visible =
      from(r in AssertionRevision, where: r.is_current and r.lifecycle_state == :active)
      |> Claims.visible(:public)

    links =
      Repo.all(
        from r in visible,
          join: p in assoc(r, :predicate),
          where:
            (p.key == "refers_to" and r.subject_object_id in ^sense_ids) or
              (p.key == "lexeme_entity_candidate" and r.subject_object_id in ^ids),
          order_by: [desc_nulls_last: r.confidence, asc: r.id],
          preload: [:predicate, assertion: :source]
      )

    direct =
      for r <- links,
          Repo.exists?(from e in Entity, where: e.object_id == ^r.object_object_id),
          do:
            (
              sense = Enum.find(senses, &(&1.sense_id == r.subject_object_id))

              choice(
                r,
                if(sense, do: {:sense_revision, sense.id}, else: {:lexeme, r.subject_object_id}),
                nil,
                if(sense, do: "c", else: "d"),
                r.object_object_id
              )
            )

    instances =
      Repo.all(
        from r in visible,
          join: p in assoc(r, :predicate),
          where:
            p.key == "instance_of" and
              r.object_object_id in ^(sense_ids ++ Enum.map(links, & &1.object_object_id)),
          order_by: [desc_nulls_last: r.confidence, asc: r.id],
          preload: [:predicate, assertion: :source]
      )

    a =
      for r <- instances,
          sense <- senses,
          r.object_object_id == sense.sense_id,
          Repo.exists?(from s in Sense, where: s.object_id == ^r.subject_object_id),
          do:
            choice(
              r,
              {:sense_revision, sense.id},
              nil,
              "a",
              Map.get(shown_by_assertion, r.assertion_id, r.subject_object_id)
            )

    b =
      for r <- instances,
          link <- links,
          link.predicate.key == "refers_to" and r.object_object_id == link.object_object_id,
          Repo.exists?(from e in Entity, where: e.object_id == ^r.subject_object_id),
          sense <- senses,
          sense.sense_id == link.subject_object_id,
          do: choice(r, {:sense_revision, sense.id}, link.id, "b", r.subject_object_id)

    (a ++ b ++ direct)
    |> Enum.uniq_by(& &1.key)
    |> Enum.map(fn choice ->
      meaning_order =
        case choice.meaning do
          {:sense_revision, id} -> Enum.find_index(senses, &(&1.id == id)) || length(senses)
          {:lexeme, id} -> Enum.find_index(ids, &(&1 == id)) || length(ids)
        end

      Map.update!(
        choice,
        :basis,
        &Map.put(&1, "rank", [
          choice.basis["path"],
          if(choice.basis["path"] in ["a", "b"],
            do: Map.get(instance_rank, choice.claim.assertion_id, 1_000_000),
            else: meaning_order
          ),
          meaning_order,
          choice.claim.id
        ])
      )
    end)
  end

  defp choice(r, meaning, witness, path, shown_id) do
    representation = %{
      "subject_label" => label(r.subject_object_id),
      "predicate_phrase" => String.replace(r.predicate.key, "_", " "),
      "object_label" => label(r.object_object_id),
      "entity_kind" => entity_kind(shown_id)
    }

    %{
      key: "claim-#{r.id}-#{witness || 0}",
      claim: r,
      meaning: meaning,
      basis: %{
        "representation" => representation,
        "witness_assertion_revision_id" => witness,
        "shown_object_id" => shown_id,
        "path" => path,
        "supplied_sha256" => Digest.term(representation)
      },
      label:
        Enum.join(
          [
            representation["subject_label"],
            representation["predicate_phrase"],
            representation["object_label"]
          ],
          " "
        )
    }
  end

  def check(item, ids) do
    basis = item.basis || (item.id && ItemBasis.get(item.id))

    representation =
      if is_struct(basis), do: basis.representation, else: basis && basis["representation"]

    witness =
      if is_struct(basis),
        do: basis.witness_assertion_revision_id,
        else: basis && basis["witness_assertion_revision_id"]

    claim = item.assertion_revision_id && Repo.get(AssertionRevision, item.assertion_revision_id)

    cond do
      is_nil(claim) or not claim.is_current or claim.lifecycle_state != :active ->
        {:error, :claim_not_current}

      not Repo.exists?(
        from(r in AssertionRevision, where: r.id == ^claim.id)
        |> Claims.visible(:public)
      ) ->
        {:error, :claim_not_visible}

      is_nil(representation) ->
        {:error, :claim_unlinked}

      true ->
        choices = for_scope(ids)

        case Enum.find(
               choices,
               &(&1.claim.id == claim.id and &1.basis["witness_assertion_revision_id"] == witness)
             ) do
          nil ->
            {:error, :claim_unlinked}

          choice ->
            meaning =
              case choice.meaning do
                {:sense_revision, id} -> item.meaning_sense_revision_id == id
                {:lexeme, id} -> item.meaning_lexeme_id == id
              end

            shown =
              if is_struct(basis),
                do: basis.original_reference["shown_object_id"],
                else: basis["shown_object_id"]

            cond do
              not meaning ->
                {:error, :meaning_mismatch}

              not Repo.exists?(
                from o in Object, where: o.id == ^shown and o.lifecycle_state == :active
              ) ->
                {:error, :object_retired}

              true ->
                :ok
            end
        end
    end
  end

  def label(id) do
    cond do
      e = Repo.get_by(Entity, object_id: id) ->
        e.preferred_label || "entity ##{id}"

      l = Repo.get_by(Lexeme, object_id: id) ->
        l.lemma

      r = Repo.one(from r in SenseRevision, where: r.sense_id == ^id and r.is_current, limit: 1) ->
        r.gloss || "sense ##{id}"

      true ->
        "object ##{id}"
    end
  end

  defp entity_kind(id) do
    case Repo.get_by(Entity, object_id: id) do
      nil -> "sense"
      entity -> to_string(entity.entity_kind)
    end
  end
end
