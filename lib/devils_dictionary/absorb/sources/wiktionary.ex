defmodule DevilsDictionary.Absorb.Sources.Wiktionary do
  @moduledoc """
  English Wiktionary, via the Kaikki raw wiktextract dump.

  Two passes, and S0b only runs the first:

    * **index** (`--index`) — stream all ~2.7M records, keep the English ones,
      and write one bare `lexemes` row per (lemma, pos) with its inflected
      `forms`. This is decision #3: the full English index exists from day one,
      so every word has a page even if nothing else has been absorbed about it.
      Bare rows have `enriched_at` nil and no `source_record`.

    * **scoped** (`--scope`) — trimmed raw records plus senses, pronunciations,
      etymology and relations, for the lemmas in a scope.

  Scope membership is **by lemma** (#69 §3): if `dog` is in scope, its noun,
  verb and adjective entries are all absorbed. The scope holds 21,277 lexemes
  but only 19,957 distinct lemmas, and that smaller number is what the dump is
  filtered against.

  The dump is 2.6 GB compressed and ~23 GB expanded, so it is streamed and never
  written to disk (see `DevilsDictionary.Absorb.GzipLines`).

  ## Why the index stores categories

  The Animals scope rule matches Wiktionary entries carrying a category in the
  `en:Animals` tree, but the dump has no category *hierarchy* — just flat strings
  per entry, mixing grammar labels ("English countable nouns") with topical ones
  ("en:Corvids"). The tree is walked once over the API and pinned into
  `scopes.rules` (`mix dd.scope.categories`); the per-entry side is kept here, in
  `lexemes.metadata["wikt_categories"]`, narrowed to the `en:`-prefixed topical
  ones (a few per record at most).

  That is a small deviation from #69, which describes the index row as carrying
  only `forms`. It buys a lot: without it, every scope build would need a second
  full pass over the 2.6 GB dump. With it, building any future scope is one SQL
  query against a GIN index — which is what scorecard E2 actually promises.
  """

  @behaviour DevilsDictionary.Absorb.Source

  import Ecto.Query

  alias DevilsDictionary.Absorb.{Batch, GzipLines}
  alias DevilsDictionary.Lexicon.{Lexeme, Scope, ScopeLexeme}
  alias DevilsDictionary.Repo
  alias DevilsDictionary.Sources
  alias DevilsDictionary.Sources.SourceRecord

  # Top-level fields we never materialize.
  @trim ~w(translations descendants etymology_templates head_templates hyphenations wikipedia)

  # Sense-level fields we never materialize. `links` is the wikilink pairs
  # behind the gloss text, which we never render.
  @trim_senses ~w(links)

  # The fields of an example we actually render. `bold_text_offsets` describes
  # highlighting we do not do.
  @example_keys ~w(text ref type)

  # A cheap reject before the expensive JSON decode. Verified against the real
  # dump's serialization, which puts a space after the colon. It can only
  # over-accept (a nested occurrence), never under-accept, and the decoded
  # record is re-checked properly.
  @en_marker ~S("lang_code": "en")

  @decode_chunk 500
  @insert_chunk 2_000
  @record_chunk 500
  @materialize_batch 200

  @page_url "https://en.wiktionary.org/wiki/"

  # Kaikki linkage keys that have a slot in the LexicalRelation type enum.
  # Anything else it emits (troponyms, instances, proverbs, anagrams, ...) lands
  # as :other with the source's own key in `subtype`, which is what #69 §4 asks
  # for.
  @linkage %{
    "synonyms" => :synonym,
    "antonyms" => :antonym,
    "hypernyms" => :hypernym,
    "hyponyms" => :hyponym,
    "meronyms" => :meronym,
    "holonyms" => :holonym,
    "derived" => :derived,
    "related" => :related,
    "coordinate_terms" => :coordinate
  }

  # Keys on a record that are linkage lists rather than content.
  @linkage_keys Map.keys(@linkage) ++
                  ~w(troponyms instances proverbs anagrams abbreviations
                     alt_forms descendants_linkage)

  # The dump holds ~2.7M records across all languages. Multi-member gzip
  # truncates *silently* with inflateInit/31, so a short read must be an error
  # rather than a quietly tiny index.
  @expect_min_lines 2_000_000

  @impl true
  def slug, do: "wiktionary"

  @impl true
  def rate_limit_ms, do: 0

  @doc """
  Drops the parts of a record we never materialize (scorecard M4).

  Two shapes of waste, and both have to go for the saving to be real:

    * whole fields nothing reads — translations (the bulk of a common word's
      record), descendants, the two template lists, hyphenations, the
      `wikipedia` backlinks, and each sense's `links`
    * **categories**, which are kept but narrowed. A record carries every
      category its page belongs to, and for a word like `cat` that is a hundred
      strings of the shape "Requests for translations into Aiton" and "English
      3-letter words". Only the `en:`-prefixed topical ones are ever read
      (`categories/1`), and on the real scoped records the rest were 36 % of
      everything stored.

  Narrowing rather than dropping is what keeps `materialize/1` pure: it reads
  the same values from a trimmed record as from an untrimmed one, which is the
  invariant the M4 test pins (`materialize(trim(r)) == materialize(r)`) and what
  lets M2 rebuild every derived row from `raw` alone.
  """
  @impl true
  def trim(raw) when is_map(raw) do
    raw
    |> Map.drop(@trim)
    |> narrow("categories", &topical/1)
    |> narrow("senses", fn senses -> Enum.map(senses, &trim_sense/1) end)
  end

  defp trim_sense(sense) when is_map(sense) do
    sense
    |> Map.drop(@trim_senses)
    |> narrow("categories", &topical/1)
    |> narrow("examples", fn examples ->
      Enum.map(examples, fn
        example when is_map(example) -> Map.take(example, @example_keys)
        other -> other
      end)
    end)
  end

  defp trim_sense(other), do: other

  defp narrow(map, key, fun) do
    case Map.get(map, key) do
      list when is_list(list) -> Map.put(map, key, fun.(list))
      _ -> map
    end
  end

  defp topical(categories) do
    Enum.filter(categories, &(is_binary(&1) and String.starts_with?(&1, "en:")))
  end

  @doc """
  The top-level fields this source never keeps.
  """
  def trimmed_keys, do: @trim

  # ── materialize (pure) ───────────────────────────────────────────────────

  @doc """
  One trimmed Kaikki record in, normalized rows out. Pure; unit tested.

  Emits no `concepts` or `links` even though senses carry Wikidata QIDs:
  `concept_links.concept_id` is NOT NULL and no `concepts` row exists before
  S2, so the QIDs ride in `senses.metadata["wikidata"]` — the same convention
  WordNet already uses for its 22,036 QID-bearing synsets — and S2's linker
  reads them from there.
  """
  @impl true
  def materialize(%SourceRecord{raw: raw, source_id: source_id, id: record_id}) do
    word = raw["word"]
    pos = pos(raw)
    key = {"en", word, pos}
    external_id = external_id(raw)
    url = page_url(word)

    raw_senses = raw["senses"] || []

    senses =
      raw_senses
      |> Enum.with_index()
      |> Enum.flat_map(fn {sense, position} ->
        case gloss(sense) do
          nil ->
            []

          gloss ->
            [
              %{
                key: sense_id(external_id, position),
                lexeme: key,
                source_id: source_id,
                source_record_id: record_id,
                gloss: gloss,
                url: url,
                position: position,
                tags: strings(sense["tags"]),
                topics: strings(sense["topics"]),
                examples: examples(sense),
                metadata:
                  %{}
                  |> put_some("raw_glosses", strings(sense["raw_glosses"]))
                  |> put_some("etymology_number", raw["etymology_number"])
                  |> put_some("senseid", strings(sense["senseid"]))
                  |> put_some("wikidata", strings(sense["wikidata"]))
                  |> put_some("qualifier", sense["qualifier"])
              }
            ]
        end
      end)

    entry_relations = relations(raw, key, nil, source_id, word)

    sense_relations =
      raw_senses
      |> Enum.with_index()
      |> Enum.flat_map(fn {sense, position} ->
        from_sense = if gloss(sense), do: sense_id(external_id, position)

        relations(sense, key, from_sense, source_id, word) ++
          form_relations(sense, key, from_sense, source_id, word)
      end)

    lexeme =
      %{
        key: key,
        forms: forms(raw),
        pronunciations: pronunciations(raw),
        origin_source_id: source_id,
        metadata: metadata(raw)
      }
      |> put_some(:etymology, raw["etymology_text"])
      |> then(fn row ->
        if row[:etymology], do: Map.put(row, :etymology_source_id, source_id), else: row
      end)

    {:ok,
     %{
       lexemes: [lexeme],
       senses: senses,
       entries: [],
       relations: entry_relations ++ sense_relations,
       concepts: [],
       links: []
     }}
  end

  @doc """
  A record's stable identity: `"word/pos/etymology_number"` (#69 §4).

  Wiktionary gives `bank` two noun entries under different etymologies, and
  they are different records but the *same* lexeme — the etymology number
  survives on each sense's metadata.
  """
  def external_id(raw) do
    Enum.join([raw["word"], pos(raw), raw["etymology_number"] || 0], "/")
  end

  @doc """
  The part of speech, normalized the same way for the index pass and the scoped
  pass.

  This has to be one function. If the two passes disagree by so much as a
  default, the scoped absorb creates a second lexeme beside the index row
  instead of enriching it, and the word page shows the word twice.
  """
  def pos(%{"pos" => pos}) when is_binary(pos) and pos != "", do: pos
  def pos(_), do: "unknown"

  @doc """
  The canonical Wiktionary page for a lemma. Every sense links back through it
  (scorecard row A9); the dump has no per-sense anchor we can trust.
  """
  def page_url(word) do
    @page_url <> URI.encode(String.replace(word, " ", "_"), &URI.char_unreserved?/1) <> "#English"
  end

  defp sense_id(external_id, position), do: external_id <> "#" <> Integer.to_string(position)

  # The last gloss is the most specific one: Kaikki nests them, so `cat` reads
  # ["Terms relating to animals.", "A mammal of the family Felidae."].
  defp gloss(sense) do
    case strings(sense["glosses"]) || strings(sense["raw_glosses"]) do
      nil -> nil
      glosses -> List.last(glosses)
    end
  end

  defp examples(sense) do
    (sense["examples"] || [])
    |> Enum.filter(&is_map/1)
    |> Enum.map(&Map.take(&1, ["text", "ref", "type"]))
    |> Enum.reject(&(&1["text"] in [nil, ""]))
  end

  # Only the sounds we can render: an IPA transcription or an audio file. `enpr`
  # respellings, rhymes and homophones are dropped.
  defp pronunciations(raw) do
    (raw["sounds"] || [])
    |> Enum.filter(&(is_map(&1) and (&1["ipa"] || &1["audio"])))
    |> Enum.map(fn sound ->
      %{"source" => "wiktionary"}
      |> put_some("ipa", sound["ipa"])
      |> put_some("audio", sound["audio"])
      |> put_some("mp3_url", sound["mp3_url"])
      |> put_some("ogg_url", sound["ogg_url"])
      |> put_some("tags", strings(sound["tags"]))
    end)
    |> Enum.uniq()
  end

  # Entry- and sense-level linkages both have this shape, so one function reads
  # both; `from_sense` is what distinguishes them.
  defp relations(container, from_lexeme, from_sense, source_id, word) do
    container
    |> Map.take(@linkage_keys)
    |> Enum.flat_map(fn {key, items} ->
      {type, subtype} =
        case Map.fetch(@linkage, key) do
          {:ok, type} -> {type, nil}
          :error -> {:other, key}
        end

      items
      |> List.wrap()
      |> Enum.flat_map(&relation(&1, from_lexeme, from_sense, source_id, word, type, subtype))
    end)
  end

  # A sense that is "plural of monkey" carries the target in form_of/alt_of.
  # These are the edges dd.resolve turns into canonical_lexeme_id.
  defp form_relations(sense, from_lexeme, from_sense, source_id, word) do
    Enum.flat_map([{"form_of", :form_of}, {"alt_of", :alt_of}], fn {key, type} ->
      sense
      |> Map.get(key)
      |> List.wrap()
      |> Enum.flat_map(&relation(&1, from_lexeme, from_sense, source_id, word, type, nil))
    end)
  end

  defp relation(item, from_lexeme, from_sense, source_id, word, type, subtype) do
    raw_word = if is_map(item), do: item["word"], else: item

    case clean_target(raw_word) do
      nil ->
        []

      # A thesaurus page lists the headword among its own synonyms.
      ^word when type in [:synonym, :related, :coordinate] ->
        []

      target ->
        metadata =
          %{}
          |> put_some("sense", is_map(item) && item["sense"])
          |> put_some("tags", is_map(item) && strings(item["tags"]))
          |> put_some("topics", is_map(item) && strings(item["topics"]))
          |> put_some("source", is_map(item) && item["source"])
          |> put_some("raw", raw_word != target && raw_word)

        [
          %{
            source_id: source_id,
            from_lexeme: from_lexeme,
            from_sense: from_sense,
            to_lemma: target,
            type: type,
            subtype: subtype,
            metadata: metadata
          }
        ]
    end
  end

  @doc """
  Cleans a linkage target down to the lemma `dd.resolve` can look up.

  The dump is not tidy here: the checked-in `cat` fixture lists a synonym as
  `"panther[Panthera"`, an unclosed taxonomic gloss. Wiki markup, a trailing
  qualifier and namespaced pages all have to go, and what is thrown away is
  kept on the relation's `metadata["raw"]` so nothing is lost silently.
  """
  def clean_target(nil), do: nil

  def clean_target(word) when is_binary(word) do
    cleaned =
      word
      |> String.replace(~r/\[\[([^\]|]*\|)?([^\]]*)\]\]/, "\\2")
      |> String.split("[", parts: 2)
      |> hd()
      |> String.trim()

    cond do
      cleaned == "" -> nil
      String.contains?(cleaned, ":") -> nil
      true -> cleaned
    end
  end

  def clean_target(_), do: nil

  defp strings(nil), do: nil

  defp strings(list) when is_list(list) do
    case Enum.filter(list, &(is_binary(&1) and &1 != "")) do
      [] -> nil
      values -> values
    end
  end

  defp strings(_), do: nil

  defp put_some(map, _key, nil), do: map
  defp put_some(map, _key, false), do: map
  defp put_some(map, _key, []), do: map
  defp put_some(map, key, value), do: Map.put(map, key, value)

  # ── absorb ───────────────────────────────────────────────────────────────

  @impl true
  def absorb(scope \\ nil, opts \\ [])

  def absorb(nil, opts) do
    if opts[:index] do
      index(opts)
    else
      raise """
      Wiktionary needs to know which pass to run:
        mix dd.absorb wiktionary --index            # the full English index
        mix dd.absorb wiktionary --scope animals    # trimmed records for a scope
      """
    end
  end

  def absorb(%Scope{} = scope, opts) do
    if opts[:index], do: index(opts), else: scoped(scope, opts)
  end

  # ── scoped absorb ────────────────────────────────────────────────────────

  # One more pass over the 2.6 GB dump, keeping only the records whose headword
  # is in the scope, trimmed. Then materialize them in reason order.
  defp scoped(scope, opts) do
    source = Sources.get_source_by_slug!(slug())
    path = dump_path!(source, opts)

    wanted = scope_lemmas(scope, opts[:reason])

    if MapSet.size(wanted) == 0 do
      raise """
      Scope #{scope.slug} has no lemmas#{if opts[:reason], do: " with reason #{opts[:reason]}"}.
      Build it first: mix dd.scope.build #{scope.slug}
      """
    end

    stats =
      path
      |> GzipLines.stream!()
      |> then(fn stream ->
        case opts[:limit] do
          nil -> stream
          n -> Stream.take(stream, n)
        end
      end)
      |> Stream.chunk_every(@decode_chunk)
      |> Task.async_stream(&select_chunk(&1, wanted),
        max_concurrency: System.schedulers_online(),
        ordered: false,
        timeout: :infinity
      )
      |> Enum.reduce(new_scoped_stats(), fn {:ok, {rows, counts}}, acc ->
        acc
        |> merge_scoped_counts(counts)
        |> buffer_records(source, rows)
      end)
      |> flush_records(source)

    if is_nil(opts[:limit]) and stats.lines < @expect_min_lines do
      raise """
      gzip stream ended after #{stats.lines} lines, expected at least #{@expect_min_lines}.
      Multi-member gzip files truncate silently with inflateInit/31 — check `gzip -t #{path}`.
      """
    end

    materialized = materialize_in_reason_order(source, scope)

    {:ok,
     %{
       lines: stats.lines,
       en_records: stats.en,
       wanted_lemmas: MapSet.size(wanted),
       matched_lemmas: MapSet.size(stats.matched),
       records: stats.written,
       lexemes: materialized.lexemes,
       senses: materialized.senses,
       relations: materialized.relations,
       bytes_raw: stats.bytes_raw,
       bytes_trimmed: stats.bytes_trimmed,
       trim_saving_pct: saving_pct(stats.bytes_raw, stats.bytes_trimmed)
     }}
  end

  @doc """
  The distinct lemmas of a scope, optionally narrowed to one build reason.

  Distinct *lemmas*, not lexemes: membership is by lemma (#69 §3), so one
  matching entry pulls every part of speech the dump has for the word.
  """
  def scope_lemmas(%Scope{id: scope_id}, reason \\ nil) do
    query =
      from sl in ScopeLexeme,
        join: l in Lexeme,
        on: l.id == sl.lexeme_id,
        where: sl.scope_id == ^scope_id,
        select: l.lemma,
        distinct: true

    query =
      case reason do
        nil -> query
        reason -> from [sl, _l] in query, where: fragment("? = ANY(?)", ^reason, sl.reasons)
      end

    query |> Repo.all() |> MapSet.new()
  end

  # Same shape as the index pass's projection: decode in a task, hand back rows
  # plus counts, never touch the database from inside the task.
  defp select_chunk(lines, wanted) do
    Enum.reduce(lines, {[], new_chunk_counts(length(lines))}, fn line, {rows, counts} ->
      if :binary.match(line, @en_marker) == :nomatch do
        {rows, counts}
      else
        case Jason.decode(line, strings: :copy) do
          {:ok, %{"lang_code" => "en", "word" => word} = record} ->
            counts = %{counts | en: counts.en + 1}

            if MapSet.member?(wanted, word) do
              trimmed = trim(record)

              row = %{
                external_id: external_id(record),
                url: page_url(word),
                raw: trimmed
              }

              {[row | rows],
               %{
                 counts
                 | matched: MapSet.put(counts.matched, word),
                   bytes_raw: counts.bytes_raw + encoded_size(record),
                   bytes_trimmed: counts.bytes_trimmed + encoded_size(trimmed)
               }}
            else
              {rows, counts}
            end

          _ ->
            {rows, counts}
        end
      end
    end)
  end

  # M4 on the real records rather than only the three fixtures: the untrimmed
  # payload is never stored, so both sizes have to be taken here, in flight.
  defp encoded_size(record), do: record |> Jason.encode!() |> byte_size()

  defp saving_pct(0, _trimmed), do: 0.0
  defp saving_pct(raw, trimmed), do: Float.round((1 - trimmed / raw) * 100, 1)

  defp new_chunk_counts(lines),
    do: %{lines: lines, en: 0, matched: MapSet.new(), bytes_raw: 0, bytes_trimmed: 0}

  defp new_scoped_stats,
    do: %{
      lines: 0,
      en: 0,
      matched: MapSet.new(),
      bytes_raw: 0,
      bytes_trimmed: 0,
      written: 0,
      buffer: [],
      buffered: 0
    }

  defp merge_scoped_counts(acc, counts) do
    %{
      acc
      | lines: acc.lines + counts.lines,
        en: acc.en + counts.en,
        matched: MapSet.union(acc.matched, counts.matched),
        bytes_raw: acc.bytes_raw + counts.bytes_raw,
        bytes_trimmed: acc.bytes_trimmed + counts.bytes_trimmed
    }
  end

  defp buffer_records(acc, source, rows) do
    acc = %{acc | buffer: [rows | acc.buffer], buffered: acc.buffered + length(rows)}
    if acc.buffered >= @record_chunk, do: flush_records(acc, source), else: acc
  end

  defp flush_records(%{buffered: 0} = acc, _source), do: %{acc | buffer: []}

  defp flush_records(acc, source) do
    written =
      acc.buffer |> Enum.concat() |> then(&Sources.insert_records(source, &1, @record_chunk))

    %{acc | buffer: [], buffered: 0, written: acc.written + written}
  end

  # #70's S0 audit asks for the `wordnet_closure` lemmas (7,692, including the
  # 2,027 overlap and all three flagship words) before the category-only tail,
  # so a run that has to be stopped early has still enriched the words the word
  # page is judged on.
  #
  # The phase filter reads `raw->>'word'` rather than splitting `external_id`:
  # lemmas like `and/or` and `km/h` contain the separator.
  defp materialize_in_reason_order(source, scope) do
    first = scope |> scope_lemmas("wordnet_closure") |> MapSet.to_list()

    phases = [
      dynamic([r], fragment("?->>'word' = ANY(?)", r.raw, ^first)),
      dynamic([r], not fragment("?->>'word' = ANY(?)", r.raw, ^first))
    ]

    Enum.reduce(phases, %{lexemes: 0, senses: 0, relations: 0}, fn where, acc ->
      counts =
        Batch.run(__MODULE__, source,
          where: where,
          batch_size: @materialize_batch,
          only_stale: true
        )

      %{
        lexemes: acc.lexemes + counts.lexemes,
        senses: acc.senses + counts.senses,
        relations: acc.relations + counts.relations
      }
    end)
  end

  defp dump_path!(source, opts) do
    path = opts[:path] || source.config["dump_file"]

    unless File.exists?(path) do
      raise """
      Wiktionary dump not found at #{path}.
      Download it first (2.6 GB):
        curl -L -C - -o #{path} #{source.config["dump_url"]}
      """
    end

    path
  end

  defp index(opts) do
    source = Sources.get_source_by_slug!(slug())
    path = dump_path!(source, opts)

    if opts[:rebuild_indexes], do: drop_load_indexes()

    stats =
      path
      |> GzipLines.stream!()
      |> then(fn stream ->
        case opts[:limit] do
          nil -> stream
          n -> Stream.take(stream, n)
        end
      end)
      |> Stream.chunk_every(@decode_chunk)
      |> Task.async_stream(&project_chunk(&1, source.id),
        max_concurrency: System.schedulers_online(),
        ordered: false,
        timeout: :infinity
      )
      |> Enum.reduce(new_stats(), fn {:ok, {rows, counts}}, acc ->
        acc
        |> merge_counts(counts)
        |> buffer(rows)
      end)
      |> flush()

    if opts[:rebuild_indexes], do: create_load_indexes()

    if is_nil(opts[:limit]) and stats.lines < @expect_min_lines do
      raise """
      gzip stream ended after #{stats.lines} lines, expected at least #{@expect_min_lines}.
      Multi-member gzip files truncate silently with inflateInit/31 — check `gzip -t #{path}`.
      """
    end

    {:ok,
     %{
       lines: stats.lines,
       en_records: stats.en,
       form_of_records: stats.form_of,
       with_categories: stats.with_categories,
       lexemes_written: stats.written
     }}
  end

  # ── projection (pure) ────────────────────────────────────────────────────

  defp project_chunk(lines, source_id) do
    Enum.reduce(lines, {[], {length(lines), 0, 0, 0}}, fn line,
                                                          {rows, {n, en, form_of, with_cats}} ->
      if :binary.match(line, @en_marker) == :nomatch do
        {rows, {n, en, form_of, with_cats}}
      else
        # strings: :copy is not optional. Without it every retained lemma is a
        # sub-binary pinning its whole ~2 MB parent chunk, and a batched load
        # pins gigabytes.
        case Jason.decode(line, strings: :copy) do
          {:ok, %{"lang_code" => "en"} = record} ->
            row = index_row(record, source_id)
            cats = row.metadata["wikt_categories"] || []

            {[row | rows],
             {n, en + 1, form_of + if(form_of?(record), do: 1, else: 0),
              with_cats + if(cats == [], do: 0, else: 1)}}

          _ ->
            {rows, {n, en, form_of, with_cats}}
        end
      end
    end)
    |> then(fn {rows, {n, en, form_of, with_cats}} ->
      {rows, %{lines: n, en: en, form_of: form_of, with_categories: with_cats}}
    end)
  end

  @doc """
  Projects one raw Kaikki record onto a bare index row. Pure; unit tested.
  """
  def index_row(record, source_id) do
    lemma = record["word"]

    %{
      lang: "en",
      lemma: lemma,
      pos: pos(record),
      slug: Lexeme.slug(lemma),
      forms: forms(record),
      pronunciations: [],
      etymology: nil,
      origin_source_id: source_id,
      source_ids: [source_id],
      metadata: metadata(record),
      inserted_at: {:placeholder, :now},
      updated_at: {:placeholder, :now}
    }
  end

  defp forms(record) do
    (record["forms"] || [])
    |> Enum.filter(&(is_map(&1) and Map.has_key?(&1, "form")))
    |> Enum.map(&Map.take(&1, ["form", "tags"]))
  end

  @doc """
  The `en:`-prefixed topical categories on a record, entry- and sense-level.
  """
  def categories(record) do
    sense_categories = Enum.flat_map(record["senses"] || [], &(&1["categories"] || []))

    ((record["categories"] || []) ++ sense_categories)
    |> Enum.filter(&(is_binary(&1) and String.starts_with?(&1, "en:")))
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp metadata(record) do
    case categories(record) do
      [] -> %{}
      cats -> %{"wikt_categories" => cats}
    end
  end

  @doc """
  Whether a record is an inflected form of another word ("dogs" -> "dog")
  rather than a headword in its own right. Reported by scorecard row A3.
  """
  def form_of?(record) do
    Enum.any?(record["senses"] || [], fn sense ->
      Map.has_key?(sense, "form_of") or
        Enum.any?(sense["tags"] || [], &(&1 == "form-of"))
    end)
  end

  # ── buffered writing ─────────────────────────────────────────────────────

  defp new_stats,
    do: %{lines: 0, en: 0, form_of: 0, with_categories: 0, written: 0, buffer: [], buffered: 0}

  defp merge_counts(acc, counts) do
    %{
      acc
      | lines: acc.lines + counts.lines,
        en: acc.en + counts.en,
        form_of: acc.form_of + counts.form_of,
        with_categories: acc.with_categories + counts.with_categories
    }
  end

  defp buffer(acc, rows) do
    acc = %{acc | buffer: [rows | acc.buffer], buffered: acc.buffered + length(rows)}
    if acc.buffered >= @insert_chunk, do: flush(acc), else: acc
  end

  defp flush(%{buffered: 0} = acc), do: %{acc | buffer: []}

  defp flush(acc) do
    written =
      acc.buffer
      |> Enum.concat()
      # The unique index cannot help inside a single statement: Postgres rejects
      # a batch that hits the same conflict key twice.
      |> Enum.uniq_by(&{&1.lang, &1.lemma, &1.pos})
      |> Enum.chunk_every(@insert_chunk)
      |> Enum.reduce(0, fn chunk, written ->
        {n, _} =
          Repo.insert_all(Lexeme, chunk,
            placeholders: %{now: DateTime.utc_now()},
            on_conflict: index_conflict(),
            conflict_target: [:lang, :lemma, :pos]
          )

        written + n
      end)

    %{acc | buffer: [], buffered: 0, written: acc.written + written}
  end

  # Merge rather than clobber: WordNet may have created the lexeme first, and it
  # sets neither forms nor categories. `origin_source_id` keeps whoever got here
  # first; `source_ids` accumulates everyone who attests the word.
  defp index_conflict do
    import Ecto.Query

    from(l in Lexeme,
      update: [
        set: [
          forms: fragment("EXCLUDED.forms"),
          metadata: fragment("? || EXCLUDED.metadata", l.metadata),
          origin_source_id:
            fragment("COALESCE(?, EXCLUDED.origin_source_id)", l.origin_source_id),
          source_ids:
            fragment(
              "(SELECT array_agg(DISTINCT x) FROM unnest(? || EXCLUDED.source_ids) AS x)",
              l.source_ids
            ),
          updated_at: fragment("EXCLUDED.updated_at")
        ]
      ]
    )
  end

  # A live gin_trgm_ops index makes a 1.4M-row load several times slower.
  defp drop_load_indexes do
    Repo.query!("SET maintenance_work_mem = '1GB'")
    Repo.query!("DROP INDEX IF EXISTS lexemes_lemma_trgm_index")
    Repo.query!("DROP INDEX IF EXISTS lexemes_forms_index")
    Repo.query!("DROP INDEX IF EXISTS lexemes_metadata_index")
  end

  defp create_load_indexes do
    Repo.query!("SET maintenance_work_mem = '1GB'")

    Repo.query!(
      "CREATE INDEX lexemes_lemma_trgm_index ON lexemes USING gin (lemma gin_trgm_ops)",
      [],
      timeout: :infinity
    )

    Repo.query!("CREATE INDEX lexemes_forms_index ON lexemes USING gin (forms)", [],
      timeout: :infinity
    )

    Repo.query!("CREATE INDEX lexemes_metadata_index ON lexemes USING gin (metadata)", [],
      timeout: :infinity
    )
  end
end
