defmodule DevilsDictionary.Curation.Eligibility do
  @moduledoc """
  Whether each item of an arrangement may be shown now, from the registry as
  it stands. It answers `:ok` or the reason it may not, and never a
  replacement (R6).

  An item is eligible when:

    * **its exact revision still exists**: a deletion nulls the reference
      (R7), and a nulled one is `:revision_deleted`;
    * **that revision is the current, active one of its own object**: a
      newer revision is `:revision_superseded`; a pin is a pin;
    * **display is allowed** at every layer. That means the revision's rights
      (`Claims.Visibility`), its source record's `display_allowed`, and the
      source being active;
    * **for a quotation**, the example at its locator still hashes to the
      words that were chosen (`:words_changed`);
    * **for a catalog work**, the committed manifest still has the pinned
      checksum and row (`:catalog_changed`, `:catalog_row_missing`);
    * **its intended meaning is on the scope**: a member lexeme, or a
      current sense of one;
    * **its claim, if it cites one**, is current, active and publicly
      visible (`Claims.visible/2`). This slice writes no claim; it reads the
      state #190's review workflow leaves.

  `evaluate/3` also applies the lead rule and returns the **eligibility
  fingerprint**: the digest of the scope, the applicable Bierce entries and
  every item's result. A review accepts a fingerprint, and a publication
  publishes the one that was accepted. Anything that changes an item's
  eligibility, or the lead rule's inputs, changes it (R4).
  """

  import Ecto.Query

  alias DevilsDictionary.Artworks.Corpus.Manifest
  alias DevilsDictionary.Claims
  alias DevilsDictionary.Claims.{AssertionRevision, Visibility}
  alias DevilsDictionary.Corpus.SourceRecordRevision
  alias DevilsDictionary.Curation.{CompositionItem, Digest, LeadRule}
  alias DevilsDictionary.Registry.{ContentItem, ContentRevision, Object, Sense, SenseRevision}
  alias DevilsDictionary.Repo
  alias DevilsDictionary.Sources.{Source, SourceRecord}

  @doc """
  Evaluates an arrangement against a scope's member lexeme ids. Returns
  `%{results: [{role, position, :ok | reason}], lead_rule: {:ok, rule} |
  {:error, reason}, applicable: [id], fingerprint: hex, ok?: boolean}`.
  """
  def evaluate(items, member_ids, scope_signature) do
    applicable = LeadRule.applicable(member_ids)
    lead = Enum.find(items, &(&1.role == :lead))
    lead_rule = LeadRule.check(member_ids, lead && lead.item_object_id, applicable)

    results =
      items
      |> Enum.sort_by(&{to_string(&1.role), &1.position})
      |> Enum.map(&{&1.role, &1.position, status(check(&1, member_ids))})

    %{
      results: results,
      lead_rule: lead_rule,
      applicable: applicable,
      ok?: match?({:ok, _}, lead_rule) and Enum.all?(results, &(elem(&1, 2) == :ok)),
      fingerprint: fingerprint(scope_signature, applicable, lead_rule, results)
    }
  end

  defp status(:ok), do: :ok
  defp status({:error, reason}), do: reason

  defp fingerprint(scope_signature, applicable, lead_rule, results) do
    Digest.term(%{
      "scope" => scope_signature,
      "priority_leads" => applicable,
      "lead_rule" => lead_rule |> elem(1) |> to_string(),
      "items" =>
        Enum.map(results, fn {role, pos, st} -> [to_string(role), pos, to_string(st)] end)
    })
  end

  @doc "`:ok`, or `{:error, reason}` for one item on a scope of member lexeme ids."
  def check(%CompositionItem{} = item, member_ids) do
    with :ok <- reference(item),
         :ok <- meaning(item, member_ids) do
      assertion(item.assertion_revision_id)
    end
  end

  # ── the reference itself ──────────────────────────────────────────────────

  defp reference(%CompositionItem{item_kind: :content} = item) do
    with {:ok, id} <- need(item.content_revision_id, :revision_deleted),
         {:ok, revision} <-
           need(
             Repo.one(
               from r in ContentRevision,
                 where: r.id == ^id and r.content_id == ^item.item_object_id
             ),
             :revision_deleted
           ),
         :ok <- current(revision),
         :ok <- ensure(Visibility.content_displayable?(revision), :display_restricted),
         :ok <- object_active(item.item_object_id),
         :ok <- content_source_active(item.item_object_id) do
      record_displayable(revision.source_record_revision_id)
    end
  end

  defp reference(%CompositionItem{item_kind: :sense_quotation} = item) do
    with {:ok, id} <- need(item.sense_revision_id, :revision_deleted),
         {:ok, revision} <-
           need(
             Repo.one(
               from r in SenseRevision,
                 where: r.id == ^id and r.sense_id == ^item.item_object_id
             ),
             :revision_deleted
           ),
         :ok <- current(revision),
         :ok <- object_active(item.item_object_id),
         :ok <- sense_source_active(item.item_object_id),
         :ok <- record_displayable(revision.source_record_revision_id) do
      words(revision, item.locator, item.words_sha256)
    end
  end

  defp reference(%CompositionItem{item_kind: :work, catalog_manifest: name} = item)
       when is_binary(name) do
    with :ok <- catalog(name, item.catalog_checksum, item.catalog_identity) do
      if item.item_object_id, do: object_active(item.item_object_id), else: :ok
    end
  end

  defp reference(%CompositionItem{item_kind: :work} = item) do
    with {:ok, id} <- need(item.source_record_revision_id, :revision_deleted),
         :ok <- record_displayable(id) do
      if item.item_object_id, do: object_active(item.item_object_id), else: :ok
    end
  end

  defp current(%{is_current: true, lifecycle_state: :active}), do: :ok
  defp current(%{is_current: true}), do: {:error, :revision_withdrawn}
  defp current(_revision), do: {:error, :revision_superseded}

  defp object_active(nil), do: {:error, :revision_deleted}

  defp object_active(id) do
    ensure(
      Repo.exists?(from o in Object, where: o.id == ^id and o.lifecycle_state == :active),
      :object_retired
    )
  end

  defp content_source_active(content_id) do
    query =
      from ci in ContentItem,
        left_join: s in Source,
        on: s.id == ci.source_id,
        where: ci.object_id == ^content_id and (is_nil(ci.source_id) or s.active)

    ensure(Repo.exists?(query), :source_inactive)
  end

  defp sense_source_active(sense_id) do
    query =
      from s in Sense,
        join: src in Source,
        on: src.id == s.source_id,
        where: s.object_id == ^sense_id and src.active and s.identity_state == :active

    ensure(Repo.exists?(query), :source_inactive)
  end

  # A revision with no source record is our own; one with a record is shown
  # only while the record allows display and its source is active.
  defp record_displayable(nil), do: :ok

  defp record_displayable(revision_id) do
    case Repo.one(
           from rev in SourceRecordRevision,
             join: rec in SourceRecord,
             on: rec.id == rev.source_record_id,
             join: s in Source,
             on: s.id == rec.source_id,
             where: rev.id == ^revision_id,
             select: {rec.display_allowed, s.active}
         ) do
      nil -> {:error, :revision_deleted}
      {true, true} -> :ok
      {false, _active} -> {:error, :display_restricted}
      {_allowed, false} -> {:error, :source_inactive}
    end
  end

  defp words(%SenseRevision{examples: examples}, "quotation:" <> index, sha256)
       when is_list(examples) do
    with {n, ""} <- Integer.parse(index),
         %{"type" => "quotation", "text" => text} when is_binary(text) <- Enum.at(examples, n),
         true <- Digest.sha256(text) == sha256 do
      :ok
    else
      _ -> {:error, :words_changed}
    end
  end

  defp words(_revision, _locator, _sha256), do: {:error, :words_changed}

  # A committed catalog manifest is the exact revision of a catalog work. It
  # is read from this build's priv/ and verified, and any file or validation
  # failure withholds rather than raises.
  @manifest_name ~r/\A[a-z0-9][a-z0-9-]*\z/

  defp catalog(name, checksum, identity) do
    with :ok <- ensure(Regex.match?(@manifest_name, name), :catalog_changed),
         {:ok, manifest} <- committed_manifest(name),
         :ok <- ensure(manifest["checksum"] == checksum, :catalog_changed),
         field = Manifest.identity_field(manifest["kind"]),
         :ok <-
           ensure(
             Enum.any?(manifest["rows"], &(to_string(&1[field]) == identity)),
             :catalog_row_missing
           ) do
      ensure(
        Repo.exists?(from s in Source, where: s.slug == ^manifest["source"] and s.active),
        :source_inactive
      )
    end
  end

  defp committed_manifest(name) do
    path = Application.app_dir(:devils_dictionary, "priv/artworks/manifests/#{name}.json")

    try do
      {:ok, Manifest.load!(path)}
    rescue
      _error in [File.Error, Jason.DecodeError, ArgumentError, KeyError] ->
        {:error, :catalog_changed}
    end
  end

  # ── the meaning and the claim ─────────────────────────────────────────────

  defp meaning(%CompositionItem{meaning_lexeme_id: id}, member_ids) when is_integer(id),
    do: ensure(id in member_ids, :meaning_off_scope)

  defp meaning(%CompositionItem{meaning_sense_revision_id: id}, member_ids)
       when is_integer(id) do
    query =
      from r in SenseRevision,
        join: s in Sense,
        on: s.object_id == r.sense_id,
        where: r.id == ^id,
        select: {r, s.lexeme_id}

    case Repo.one(query) do
      nil -> {:error, :meaning_deleted}
      {revision, lexeme_id} -> with :ok <- current(revision), do: on_scope(lexeme_id, member_ids)
    end
  end

  defp meaning(_item, _member_ids), do: {:error, :meaning_deleted}

  defp on_scope(lexeme_id, member_ids), do: ensure(lexeme_id in member_ids, :meaning_off_scope)

  defp assertion(nil), do: :ok

  defp assertion(id) do
    from(r in AssertionRevision,
      where: r.id == ^id and r.is_current and r.lifecycle_state == :active
    )
    |> Claims.visible(:public)
    |> Repo.exists?()
    |> ensure(:claim_not_visible)
  end

  defp need(nil, reason), do: {:error, reason}
  defp need(value, _reason), do: {:ok, value}

  defp ensure(true, _reason), do: :ok
  defp ensure(_condition, reason), do: {:error, reason}
end
