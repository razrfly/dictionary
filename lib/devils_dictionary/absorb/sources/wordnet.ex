defmodule DevilsDictionary.Absorb.Sources.Wordnet do
  @moduledoc """
  Open English WordNet 2025, absorbed in full from the pinned JSON zip.

  The **plus** edition, deliberately: the base edition holds 107,519 synsets and
  135,969 (lemma, pos) pairs and fails scorecard A2, which needs >= 120,000 and
  >= 155,000. The plus edition holds 120,564 and 161,875.

  Three things the packaging forces on us:

    * **Synset ids are bare in the JSON** (`"00015568-n"`) because the constant
      prefix was factored out into the file name. The project's canonical id is
      the prefixed `oewn-00015568-n`, which is what `en-word.net` URLs use. We
      normalise at the parse boundary and inject the id into `raw`, since the
      value object does not contain its own id and `raw` has to be self
      sufficient for offline re-materialization (M2).

    * **There are no `hyponym` or `holonym` edges.** The corpus carries only
      `hypernym` (93,395) and `mero_*` (22,312). Both inverse directions have to
      be derived, and inversion is inherently global while `materialize/1` is
      pure and per record. So `absorb/2` inverts once and writes a fully
      expanded `_edges` list into each record's `raw`.

    * **`definition` is an array**, not a string.

  `similar` (23,176), `instance_hypernym` (8,599), `domain_topic`, `exemplifies`,
  `attribute`, `entails`, `causes` and `domain_region` have no slot in the
  `lexical_relations` type enum, so they land as `:other` with the source's own
  label in `subtype` — which is what #69 §4 asks for. `:synonym` rows are never
  written: in WordNet synonymy is co-membership of a synset, which the word page
  reads off `senses.group_key`.

  22,036 synsets carry a `wikidata` QID. #69's linking ladder does not list that
  rung, but it is free and high-signal, so it is kept in `senses.metadata` for
  S2's linker.
  """

  @behaviour DevilsDictionary.Absorb.Source

  import Ecto.Query

  alias DevilsDictionary.Absorb.Materializer
  alias DevilsDictionary.Lexicon.Lexeme
  alias DevilsDictionary.Repo
  alias DevilsDictionary.Sources
  alias DevilsDictionary.Sources.SourceRecord

  @prefix "oewn-"
  @entity_url "https://en-word.net/id/"

  # Everything on a synset object that is not an edge list.
  @non_relations ~w(definition example members partOfSpeech ili source wikidata id lexfile _edges)

  @pos %{"n" => "noun", "v" => "verb", "a" => "adj", "s" => "adj", "r" => "adv"}

  @record_batch 1_000
  @materialize_batch 500

  @impl true
  def slug, do: "wordnet"

  @impl true
  def rate_limit_ms, do: 0

  @impl true
  def trim(raw), do: raw

  # ── absorb ───────────────────────────────────────────────────────────────

  @impl true
  def absorb(_scope \\ nil, opts \\ []) do
    source = Sources.get_source_by_slug!(slug())
    path = opts[:path] || source.config["dump_file"]

    unless File.exists?(path) do
      raise """
      WordNet dump not found at #{path}.
      Download it first:
        curl -L -o #{path} #{source.config["dump_url"]}
      """
    end

    synsets = read_synsets(path)
    edges = build_edges(synsets)

    records = write_records(source, synsets, edges)
    materialized = materialize_all(source)
    resolved = resolve_targets(source)

    {:ok,
     %{
       synsets: map_size(synsets),
       records: records,
       edges: Enum.reduce(edges, 0, fn {_k, v}, acc -> acc + length(v) end),
       lexemes: count_lexemes(source),
       senses: materialized.senses,
       relations: materialized.relations,
       relations_resolved: resolved
     }}
  end

  # Reads every synset file out of the zip in memory; never unzips to disk.
  defp read_synsets(path) do
    {:ok, files} = :zip.extract(String.to_charlist(path), [:memory])

    files
    |> Enum.reject(fn {name, _} ->
      name = to_string(name)
      String.starts_with?(name, "entries-") or name == "frames.json"
    end)
    |> Enum.reduce(%{}, fn {name, contents}, acc ->
      lexfile = name |> to_string() |> Path.basename(".json")

      contents
      |> Jason.decode!()
      |> Enum.reduce(acc, fn {bare_id, synset}, inner ->
        Map.put(inner, synset_id(bare_id), Map.put(synset, "lexfile", lexfile))
      end)
    end)
  end

  # One pass over every synset, accumulating both the forward edge and, for the
  # relations that have an unstated inverse, the reverse edge on the target.
  defp build_edges(synsets) do
    Enum.reduce(synsets, %{}, fn {id, synset}, acc ->
      synset
      |> Map.drop(@non_relations)
      |> Enum.reduce(acc, fn {key, targets}, acc ->
        targets
        |> List.wrap()
        |> Enum.reduce(acc, fn bare_target, acc ->
          target = synset_id(bare_target)

          acc
          |> push(id, edge(key, target, synsets))
          |> then(fn acc ->
            case inverse(key) do
              nil -> acc
              inverse_key -> push(acc, target, edge(inverse_key, id, synsets))
            end
          end)
        end)
      end)
    end)
  end

  defp push(acc, _id, nil), do: acc
  defp push(acc, id, edge), do: Map.update(acc, id, [edge], &[edge | &1])

  defp edge(key, target, synsets) do
    case Map.get(synsets, target) do
      nil ->
        nil

      synset ->
        {type, subtype} = map_type(key)

        %{
          "type" => to_string(type),
          "subtype" => subtype,
          "to" => target,
          "to_pos" => pos(synset["partOfSpeech"]),
          "to_members" => synset["members"] || []
        }
    end
  end

  defp inverse("hypernym"), do: "hyponym"
  defp inverse("mero_part"), do: "holo_part"
  defp inverse("mero_substance"), do: "holo_substance"
  defp inverse("mero_member"), do: "holo_member"
  defp inverse(_), do: nil

  defp map_type("hypernym"), do: {:hypernym, nil}
  defp map_type("hyponym"), do: {:hyponym, nil}
  defp map_type("mero_part"), do: {:meronym, "part"}
  defp map_type("mero_substance"), do: {:meronym, "substance"}
  defp map_type("mero_member"), do: {:meronym, "member"}
  defp map_type("holo_part"), do: {:holonym, "part"}
  defp map_type("holo_substance"), do: {:holonym, "substance"}
  defp map_type("holo_member"), do: {:holonym, "member"}
  defp map_type("also"), do: {:see_also, nil}
  defp map_type(other), do: {:other, other}

  # `raw` carries everything materialize/1 needs, so re-materializing works with
  # the dump deleted and the network off.
  defp write_records(source, synsets, edges) do
    now = DateTime.utc_now()

    synsets
    |> Enum.map(fn {id, synset} ->
      raw =
        synset
        |> Map.put("id", id)
        |> Map.put("_edges", Map.get(edges, id, []))

      %{
        source_id: source.id,
        external_id: id,
        url: @entity_url <> id,
        raw: raw,
        content_hash: SourceRecord.content_hash(raw),
        fetched_at: now,
        inserted_at: now,
        updated_at: now
      }
    end)
    |> Enum.chunk_every(@record_batch)
    |> Enum.reduce(0, fn chunk, acc ->
      {n, _} =
        Repo.insert_all(SourceRecord, chunk,
          on_conflict: {:replace, [:raw, :url, :content_hash, :fetched_at, :updated_at]},
          conflict_target: [:source_id, :external_id]
        )

      acc + n
    end)
  end

  # Keyset pagination rather than Repo.stream: a stream would need an enclosing
  # transaction, and that would fold every batch into one giant transaction,
  # losing the per-batch atomicity M3 depends on.
  defp materialize_all(source) do
    Stream.unfold(0, fn last_id -> next_batch(source, last_id) end)
    |> Enum.reduce(%{senses: 0, relations: 0}, fn batch, acc ->
      {:ok, counts} = Materializer.run_batch(batch, __MODULE__)

      %{acc | senses: acc.senses + counts.senses, relations: acc.relations + counts.relations}
    end)
  end

  # `raw` is load_in_query: false, so ask for it explicitly for just this page.
  defp next_batch(source, last_id) do
    records =
      Repo.all(
        from r in SourceRecord,
          where: r.source_id == ^source.id and r.id > ^last_id,
          order_by: r.id,
          limit: @materialize_batch,
          select: %{r | raw: r.raw}
      )

    case records do
      [] -> nil
      records -> {records, List.last(records).id}
    end
  end

  # WordNet is a closed graph and sense external ids are deterministic, so the
  # targets resolve in one set-based statement rather than a pass. Idempotent,
  # and it puts scorecard row R1 at 100% inside the absorb (#69 §4: WordNet
  # relations are "resolved at absorb").
  defp resolve_targets(source) do
    %{num_rows: count} =
      Repo.query!(
        """
        UPDATE lexical_relations r
           SET to_sense_id = s.id, to_lexeme_id = s.lexeme_id, updated_at = now()
          FROM senses s
         WHERE r.source_id = $1 AND s.source_id = $1
           AND r.to_sense_id IS NULL
           AND r.to_group_key IS NOT NULL
           AND s.external_id = r.to_group_key || '#' || r.to_lemma
        """,
        [source.id],
        timeout: :infinity
      )

    count
  end

  defp count_lexemes(source) do
    Repo.one(
      from l in Lexeme,
        where: fragment("? = ANY(?)", ^source.id, l.source_ids),
        select: count(l.id)
    )
  end

  # ── materialize (pure) ───────────────────────────────────────────────────

  @impl true
  def materialize(%SourceRecord{raw: raw, source_id: source_id, id: record_id}) do
    id = raw["id"]
    pos = pos(raw["partOfSpeech"])
    members = raw["members"] || []
    definitions = raw["definition"] || []
    gloss = List.first(definitions)

    Enum.each(members, fn member ->
      if String.contains?(member, "#") do
        raise "WordNet member #{inspect(member)} in #{id} contains '#', which is the " <>
                "sense external_id separator"
      end
    end)

    lexemes = Enum.map(members, &%{key: {"en", &1, pos}, origin_source_id: source_id})

    senses =
      members
      |> Enum.with_index()
      |> Enum.map(fn {member, position} ->
        %{
          key: sense_id(id, member),
          lexeme: {"en", member, pos},
          source_id: source_id,
          source_record_id: record_id,
          group_key: id,
          gloss: gloss,
          url: @entity_url <> id,
          position: position,
          examples: Enum.map(raw["example"] || [], &%{"text" => &1}),
          metadata:
            %{
              "ili" => raw["ili"],
              "lexfile" => raw["lexfile"],
              "pos_raw" => raw["partOfSpeech"]
            }
            |> put_some("wikidata", raw["wikidata"])
            |> put_some("definitions", Enum.drop(definitions, 1))
        }
      end)

    relations =
      for edge <- raw["_edges"] || [],
          member <- members,
          target <- edge["to_members"] || [] do
        %{
          source_id: source_id,
          from_lexeme: {"en", member, pos},
          from_sense: sense_id(id, member),
          to_lemma: target,
          to_pos: edge["to_pos"],
          to_group_key: edge["to"],
          type: String.to_existing_atom(edge["type"]),
          subtype: edge["subtype"]
        }
      end

    {:ok,
     %{
       lexemes: lexemes,
       senses: senses,
       entries: [],
       relations: relations,
       concepts: [],
       links: []
     }}
  end

  defp put_some(map, _key, nil), do: map
  defp put_some(map, _key, []), do: map
  defp put_some(map, key, value), do: Map.put(map, key, value)

  defp sense_id(synset_id, member), do: synset_id <> "#" <> member

  defp synset_id(@prefix <> _ = id), do: id
  defp synset_id(bare), do: @prefix <> to_string(bare)

  defp pos(letter), do: Map.get(@pos, letter, "unknown")
end
