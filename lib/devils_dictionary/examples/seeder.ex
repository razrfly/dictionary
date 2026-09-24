defmodule DevilsDictionary.Examples.Seeder do
  @moduledoc """
  Seeds an exemplar manifest (#181 build 2) through the one nomination path,
  `Contributions.propose/6`, the way `Corpus.Seeder` seeds a corpus through
  `SourceIdentity.resolve/2`: the file is the whole input, and a second run is
  a no-op.

  Each row becomes, at most, one `illustrates` claim — subject the cited
  thing, object the resolved sense — with `method: "curated"`, no review (so
  `needs_review`, and invisible to the public while its subject is a person),
  the row's rationale, one `community` evidence record per URL, and
  `metadata` naming the file, the row, the curator and the sense it resolved.

  ## What a row can come back as

    * `:created` — the claim was written. `minted: true` when its subject was
      not in the registry and was minted from Wikidata on the way.
    * `:held` — a current claim already says this `(subject, illustrates,
      sense)`. Nothing is written, and the existing claim's id is reported.
    * `:refused` — with a reason, and nothing is written. The reasons a curator
      will meet: `:sense_not_found` / `:sense_ambiguous` (with every gloss of
      that source for the word, so the match can be fixed), `:sense_moved` (a
      re-run resolves the row's meaning to a different sense than the claim it
      wrote — never silently retargeted, #181 R6), `:subject_without_identity`
      (no QID and no entity: #105 rule 3, #165 option 1),
      `:subject_held_as_concept` (the QID is held as an untyped stub, which no
      `illustrates` rule admits — #165's trap), `:subject_kind_mismatch`,
      `:evidence_required_for_person`, and anything the manifest's own
      validation says.
    * `:would_seed` — a dry run's answer for a row that would be proposed;
      `mint: true` when its subject would be minted.
    * `:deferred` — Wikidata could not be asked (budget, a transport error);
      nothing is written and a re-run tries again.

  ## Minting a nominee

  A subject whose QID the registry does not hold is minted through the
  creator path (#164): `Creators.prepare/2` fetches every missing QID in one
  bounded batch **before** any transaction, and `Creators.resolve_identified/3`
  matches or mints under the QID's lock inside it, with `minted_by:
  "community"`. A QID that is not a human or an organization is refused, as a
  creator's is. Nothing is looked up by label.

  The fetch is paced by `:claim` (a `fn stage -> {:ok, wait_ms} | {:error, _}
  end`). The shared `wikidata` budget cannot be used here: its ledger row
  must name a discovery or verification run, and a seed is neither — so the
  mix task paces at Wikidata's own interval and caps the request count. A dry
  run makes no request.
  """

  import Ecto.Query

  alias DevilsDictionary.Claims.{AssertionRevision, Contributions, PredicateEndpointRule}
  alias DevilsDictionary.Examples.{Community, Manifest}
  alias DevilsDictionary.Registry
  alias DevilsDictionary.Registry.{Entity, Lexeme, Sense, SenseRevision}
  alias DevilsDictionary.Repo
  alias DevilsDictionary.SourceIdentity.Creators
  alias DevilsDictionary.SourceIdentity.Entry
  alias DevilsDictionary.Sources.Source

  @predicate "illustrates"

  @doc """
  Seeds one loaded manifest as `scope`'s nominations. Returns `{:ok, summary}`.

  Options: `:dry_run`, `:limit` (the first N rows), `:claim` (paces and
  permits each Wikidata request; without it nothing is fetched and a nominee
  to mint is `:deferred`).
  """
  def run(manifest, scope, opts \\ []) when is_map(manifest) do
    rows =
      manifest["rows"]
      |> Enum.with_index(1)
      |> then(&if opts[:limit], do: Enum.take(&1, opts[:limit]), else: &1)

    planned = Enum.map(rows, fn {row, index} -> {index, row, plan(row, manifest, index)} end)

    prepared =
      if opts[:dry_run] do
        %{}
      else
        planned
        |> Enum.flat_map(fn
          {_i, _row, {:ok, %{subject: {:mint, qid}}}} -> [qid]
          _ -> []
        end)
        |> prepare(opts[:claim])
      end

    dry_run? = opts[:dry_run] || false

    results =
      Enum.map(planned, fn {index, row, plan} ->
        outcome =
          case plan do
            {:error, reason, details} -> refused(reason, details)
            {:ok, plan} when dry_run? -> would_seed(plan)
            {:ok, plan} -> seed(plan, scope, prepared)
          end

        Map.merge(
          %{row: index, word: row["word"], subject: get_in(row, ["subject", "label"])},
          outcome
        )
      end)

    {:ok, summarise(manifest, results)}
  end

  @doc "Loads a committed manifest and seeds it."
  def run_file(path, scope, opts \\ []), do: path |> Manifest.load!() |> run(scope, opts)

  # ── planning: reads only ─────────────────────────────────────────────────

  defp plan(row, manifest, index) do
    with :ok <- tag(Manifest.validate_row(row)),
         {:ok, sense} <- resolve_sense(row["word"], row["sense"]),
         :ok <- not_moved(manifest["manifest"], index, sense),
         {:ok, subject} <- locate_subject(row["subject"]) do
      {:ok,
       %{
         row: row,
         index: index,
         manifest: manifest["manifest"],
         checksum: manifest["checksum"],
         sense: sense,
         subject: subject
       }}
    end
  end

  defp tag(:ok), do: :ok
  defp tag({:error, reason}), do: {:error, reason, %{}}

  @doc """
  Resolves a manifest row's `sense` block to exactly one current sense of the
  word from that source, or says why not with every gloss it could have meant.
  """
  def resolve_sense(word, %{"source" => source, "match" => match}) do
    candidates =
      Repo.all(
        from s in Sense,
          join: l in Lexeme,
          on: l.object_id == s.lexeme_id,
          join: src in Source,
          on: src.id == s.source_id,
          join: rev in SenseRevision,
          on: rev.sense_id == s.object_id and rev.is_current,
          where:
            l.lemma == ^word and l.language_tag == "en" and src.slug == ^source and
              s.identity_state == :active and rev.lifecycle_state == :active,
          order_by: [l.part_of_speech, rev.position, s.object_id],
          select: %{
            id: s.object_id,
            gloss: rev.gloss,
            external_key: s.external_key,
            revision_id: rev.id,
            source: src.slug,
            pos: l.part_of_speech
          }
      )

    needle = String.downcase(String.trim(match))
    glosses = Enum.map(candidates, & &1.gloss)

    case Enum.filter(candidates, &String.contains?(String.downcase(&1.gloss || ""), needle)) do
      [sense] ->
        {:ok, sense}

      [] ->
        {:error, :sense_not_found, %{glosses: glosses}}

      several ->
        {:error, :sense_ambiguous, %{glosses: glosses, matched: Enum.map(several, & &1.gloss)}}
    end
  end

  # A re-run whose match now lands on another sense than the claim this row
  # wrote refuses, printing both: a manifest names a meaning, and a meaning
  # that moved is the curator's to re-read (#181 R6).
  defp not_moved(manifest, index, sense) do
    previous =
      Repo.one(
        from r in AssertionRevision,
          join: p in assoc(r, :predicate),
          join: rev in SenseRevision,
          on: rev.sense_id == r.object_object_id and rev.is_current,
          where:
            p.key == @predicate and r.is_current and r.lifecycle_state == :active and
              fragment("?->>'manifest' = ?", r.metadata, ^manifest) and
              fragment("(?->>'row')::int = ?", r.metadata, ^index),
          order_by: [desc: r.id],
          limit: 1,
          select: %{object_id: r.object_object_id, gloss: rev.gloss}
      )

    case previous do
      %{object_id: id} = previous when id != sense.id ->
        {:error, :sense_moved, %{glosses: [previous.gloss, sense.gloss]}}

      _ ->
        :ok
    end
  end

  defp locate_subject(%{"wikidata" => qid, "kind" => kind}) when is_binary(qid) do
    case Registry.by_external_id("wikidata", qid) do
      nil -> {:ok, {:mint, qid}}
      object_id -> held_subject(Registry.canonical_id(object_id), kind)
    end
  end

  defp locate_subject(%{"entity_id" => id, "kind" => kind}) when is_integer(id) do
    case Repo.get(Entity, Registry.canonical_id(id)) do
      nil -> {:error, :subject_not_found, %{}}
      entity -> held_subject(entity.object_id, kind)
    end
  end

  defp held_subject(object_id, kind) do
    case Repo.get(Entity, object_id) do
      %Entity{entity_kind: :concept} ->
        {:error, :subject_held_as_concept, %{object_id: object_id}}

      %Entity{entity_kind: entity_kind} ->
        cond do
          to_string(entity_kind) != kind ->
            {:error, :subject_kind_mismatch, %{object_id: object_id, held_as: entity_kind}}

          not subject_allowed?(entity_kind) ->
            {:error, :subject_kind_not_allowed, %{object_id: object_id}}

          true ->
            {:ok, {:held, object_id}}
        end

      nil ->
        {:error, :subject_not_an_entity, %{object_id: object_id}}
    end
  end

  defp subject_allowed?(entity_kind) do
    Repo.exists?(
      from rule in PredicateEndpointRule,
        join: p in assoc(rule, :predicate),
        where:
          p.key == @predicate and rule.subject_kind == "entity" and
            rule.subject_subkind == ^to_string(entity_kind) and rule.object_kind == "sense"
    )
  end

  # ── minting: the network, outside every transaction ──────────────────────

  defp prepare([], _claim), do: %{}

  defp prepare(qids, claim) do
    entries =
      qids
      |> Enum.uniq()
      |> Enum.map(fn qid ->
        %Entry{
          relationships: [
            %{target_identifiers: [%{namespace: "wikidata", external_id: qid}]}
          ]
        }
      end)

    opts = if claim, do: [claim: claim], else: []
    Creators.prepare(entries, opts)
  end

  # ── writing ──────────────────────────────────────────────────────────────

  defp seed(%{subject: {:mint, qid}, row: row} = plan, scope, prepared) do
    wanted = row["subject"]["kind"]

    case Map.get(prepared, qid) do
      {:ok, %{kind: kind}} when kind not in [:person, :organization] or wanted == nil ->
        refused(:subject_kind_mismatch, %{qid: qid, held_as: kind})

      {:ok, %{kind: :person}} when wanted != "person" ->
        refused(:subject_kind_mismatch, %{qid: qid, held_as: :person})

      {:ok, %{kind: :organization}} when wanted != "organization" ->
        refused(:subject_kind_mismatch, %{qid: qid, held_as: :organization})

      {:permanent, reason} ->
        refused(:subject_not_mintable, %{qid: qid, why: reason})

      _ ->
        write(plan, scope, prepared)
    end
  end

  defp seed(plan, scope, prepared), do: write(plan, scope, prepared)

  defp write(plan, scope, prepared) do
    Repo.transaction(fn ->
      {subject_id, minted?} = subject!(plan.subject, prepared)

      evidence =
        Enum.map(plan.row["evidence"] || [], fn entry ->
          entry["url"]
          |> Community.cite!(entry["attribution"])
          |> Map.merge(%{
            locator: entry["url"],
            attribution_text: entry["attribution"],
            evidence_role: Map.get(entry, "role", "supports")
          })
        end)

      attrs = %{rationale: plan.row["rationale"], metadata: metadata(plan)}

      case Contributions.propose(scope, subject_id, @predicate, plan.sense.id, attrs, evidence) do
        {:ok, claim} -> %{outcome: :created, assertion_id: claim.id, minted: minted?}
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
    |> case do
      {:ok, result} -> result
      {:error, {:held, assertion_id}} -> %{outcome: :held, assertion_id: assertion_id}
      {:error, {:deferred, reason}} -> %{outcome: :deferred, reason: reason}
      {:error, {:unresolved, reason}} -> refused(:subject_not_mintable, %{why: reason})
      {:error, reason} -> refused(reason, %{})
    end
  end

  defp subject!({:held, object_id}, _prepared), do: {object_id, false}

  defp subject!({:mint, qid}, prepared) do
    case Creators.resolve_identified(
           [%{namespace: "wikidata", external_id: qid}],
           prepared,
           Community.slug()
         ) do
      %{state: :minted, object_id: id} -> {id, true}
      %{state: :matched, object_id: id} -> {id, false}
      %{state: :deferred, reason: reason} -> Repo.rollback({:deferred, reason})
      %{state: _, reason: reason} -> Repo.rollback({:unresolved, reason})
    end
  end

  # Provenance back to the file, and the sense the match resolved to — so a
  # later run can tell the meaning moved (#181 R6).
  defp metadata(plan) do
    %{
      "manifest" => plan.manifest,
      "manifest_checksum" => plan.checksum,
      "row" => plan.index,
      "curator" => plan.row["curator"],
      "sense" => %{
        "source" => plan.sense.source,
        "match" => plan.row["sense"]["match"],
        "external_key" => plan.sense.external_key,
        "sense_revision_id" => plan.sense.revision_id
      }
    }
  end

  defp would_seed(%{subject: subject}),
    do: %{outcome: :would_seed, mint: match?({:mint, _}, subject)}

  defp refused(reason, details), do: Map.merge(%{outcome: :refused, reason: reason}, details)

  defp summarise(manifest, results) do
    count = fn outcome -> Enum.count(results, &(&1.outcome == outcome)) end

    %{
      manifest: manifest["manifest"],
      checksum: manifest["checksum"],
      rows: length(results),
      created: count.(:created),
      minted: Enum.count(results, &(&1[:minted] == true)),
      held: count.(:held),
      refused: count.(:refused),
      deferred: count.(:deferred),
      would_seed: count.(:would_seed),
      results: results
    }
  end
end
