defmodule DevilsDictionary.Absorb.Sources.Johnson do
  @moduledoc """
  Samuel Johnson, *A Dictionary of the English Language* (1755), from the LEME
  TEI-XML transcription.

  The **extensibility proof** (#69 §7, row E1): the sixth source, added after
  MVP-0 was accepted, costing one `sources` row, one entry in `Absorb`'s
  registry, this module, fixtures and tests — and zero migrations. Every
  enum-like column in the schema is a plain string backed by `Ecto.Enum`, so a
  new tier, kind or relation type would cost none either.

  ## The text

  Not the Gutenberg scans and not the UCF site (nicer, but non-commercial-only
  with no API): the **LEME** transcription edited by Ian Lancashire at the
  University of Toronto, released **CC BY 4.0** on TSpace under handle
  `1807/124274`. The 1755 text is public domain; the transcription is not, so
  the attribution on the `sources` row is a licence condition, not a courtesy.

  Checked in gzipped at `priv/sources/johnson/johnson-1755-leme.xml.gz`
  (8.8 MB packed, 29 MB open) so the absorb rebuilds offline from a fresh clone,
  exactly as Bierce's HTML does.

  ## Where the parse happens

  As in `Bierce`: `absorb/2` **segments**, `materialize/1` **parses**. Only the
  segmenter sees the whole document, and the one thing it knows that a single
  record cannot is *which* `CAT` this is — Johnson defines the word twice (the
  animal, and "a sort of ship"), `A` ten times, `DOWN` and `SOUND` six. So the
  occurrence index is decided once, at absorb, and lives in the record key.

  What lands in `raw` is the entry's own markup, unchanged:

      %{"headword" => "A'BBEY", "alt_headwords" => ["ABBY"],
        "printed_headword" => "A'BBEY, or ABBY.", "pos" => "n. s.",
        "position" => 371, "occurrence" => 0,
        "xpln" => "<xpln lang=\\"en\\"><etym…>…</etym> A monastery…</xpln>"}

  Everything after that is a pure function of that fragment, so a parser fix is

      mix dd.materialize --source johnson --all

  with the network off and the file never re-read (scorecard M2).

  ## What the file actually contains

  Measured on the checked-in file, not assumed:

    * **42,726 `<wordentry type="h">`**, **37,135 distinct lemmas** once the
      printed headword is normalized. 34,124 of those (**91.9 %**) are already
      in the Wiktionary index; the rest are Johnson's own eighteenth-century
      spellings (*domestick*, *chuse*, *ake*), which are correct misses.
    * **39,352 `<class type="pos">`** — 3,374 entries print no part of speech
      at all, and 212 distinct markers appear across the rest, from `n. s.`
      (20,725) down to `n. s. It has no singular.` (3). The head of that
      distribution is mapped; the tail falls through to `unknown` with the
      printed marker kept in `metadata`.
    * **113,997 `<term lang="quo">` quotations** across 36,423 entries. These
      are the *point* of Johnson the way the verse is the point of Bierce, and
      they are kept in `entries.body` in order, as blockquotes.
    * **36,342 `<etym>`** etymologies, **11,342** entries with numbered senses,
      **742** with a `See HEADWORD` cross-reference, and **60** with a genuine
      alternate headword (`A'BBEY, or ABBY`). Comma-separated parts are *not*
      alternates by default: most of them are Johnson explaining himself
      (`METHO'UGHT, the preterite of methinks`), and splitting on the comma
      naively puts that sentence in the lexicon as a word. See
      `split_headword/1`.

  ## Three transcription conventions that decide the lemma

    * The apostrophe in a headword is a **stress mark**, not a letter:
      `ABA'CKE` is *abacke*. Both `’` (30,005 forms) and `'` (4,549) are used.
    * **Soft hyphens** (U+00AD, 27,339 in the body) mark where the printed line
      broke mid-word: `the lowest or­\\r\\nder` is *the lowest order*.
    * A leading **`To `** is the verb marker of the period, not part of the
      word — 7,793 entries.

  A headword that is a run of single-letter abbreviations (`A. Bp.`, `F. R. S.`,
  `M. D.`) is kept whole; anything else in lower case after the headword is a
  printed grammar note (`To CUT. pret. cut; part. pass. cut.`) and is dropped.

  **Known nits, 77 entries** where the printed headword contains lower case.
  Most are Johnson's real phrase entries and are kept as printed — `An
  ABRIDGER`, `To hang an ARSE`, `JACOB's Ladder`, `At LEAST`, `SHEET-anchor`.
  A handful are small-capital artefacts of the transcription (`MUsculous`,
  `PLAguily`, `REPERCUssion`), and those still yield the right lemma because
  `lemma/1` downcases. Three are simply wrong — `ToSTOW`, `To Rda'rgue`,
  `To. preposition` — and would need a rule for three entries.

  `trim/1` is the identity: a public-domain dictionary is imported in full
  (#69 decision 11), so `Sources.insert_records/3` hashes `raw` itself.
  """

  @behaviour DevilsDictionary.Absorb.Source

  alias DevilsDictionary.Absorb.Batch
  alias DevilsDictionary.Lexicon.Lexeme
  alias DevilsDictionary.Sources
  alias DevilsDictionary.Sources.SourceRecord

  @record_batch 500
  @materialize_batch 200

  # LEME gives the lexicon one page and no per-entry anchors, so every record
  # carries the whole-document url — the fallback A9 accepts, and the same
  # bargain the Bierce row makes with Gutenberg's letter chapters.
  @document_url "https://leme.library.utoronto.ca/lexicons/1345/"
  @year 1755
  @author_slug "samuel-johnson"

  # The custom DTD declares a few hundred entities; exactly one of them is used
  # in the body, 290 times. Everything else is a numeric reference, which the
  # parser handles. So the prologue is dropped rather than resolved.
  @wyn "ƿ"

  @entry ~r|<wordentry type="h">.*?</wordentry>|s
  @xpln ~r|<xpln\b.*?</xpln>|s

  @impl true
  def slug, do: "johnson"

  @impl true
  def rate_limit_ms, do: 0

  @impl true
  def trim(raw), do: raw

  # A dead author publishes once; there is nothing to fetch on demand.
  @impl true
  def enrich(_target, _opts), do: {:error, :not_supported}

  # ── absorb ───────────────────────────────────────────────────────────────

  @impl true
  def absorb(scope \\ nil, opts \\ [])

  def absorb(_scope, opts) do
    source = Sources.get_source_by_slug!(slug())
    path = opts[:path] || source.config["file"]

    unless File.exists?(path) do
      raise """
      Johnson source file not found: #{path}

      It is checked in; `sources.config["file"]` should point at
      priv/sources/johnson/johnson-1755-leme.xml.gz.
      """
    end

    verify!(path, source.config["sha256"])

    entries = path |> read!() |> segment()

    records = Sources.insert_records(source, Enum.map(entries, &record_row/1), @record_batch)
    materialized = Batch.run(__MODULE__, source, batch_size: @materialize_batch)

    {:ok,
     %{
       entries: length(entries),
       headwords: entries |> Enum.map(& &1.headword) |> Enum.uniq() |> length(),
       records: records,
       homographs: Enum.count(entries, &(&1.occurrence > 0)),
       without_pos: Enum.count(entries, &is_nil(&1.pos)),
       alt_headwords: Enum.sum(Enum.map(entries, &length(&1.alt_headwords))),
       lexemes: materialized.lexemes,
       materialized_entries: materialized.entries,
       relations: materialized.relations
     }}
  end

  # The file is committed and the numbers in the moduledoc were measured on it,
  # so a mismatch is a different text and not a smaller problem.
  defp verify!(_path, nil), do: :ok

  defp verify!(path, expected) do
    actual = :crypto.hash(:sha256, File.read!(path)) |> Base.encode16(case: :lower)

    if actual != expected do
      raise """
      Johnson source file does not match the pinned checksum.

        expected #{expected}
        actual   #{actual}
        file     #{path}

      Every figure in this module was measured on the pinned file. Update
      `sources.config["sha256"]` deliberately, with new measurements.
      """
    end
  end

  @doc "Reads the gzipped XML and drops the DTD prologue."
  def read!(path) do
    path
    |> File.read!()
    |> :zlib.gunzip()
    |> strip_prologue()
    |> String.replace("&wyn;", @wyn)
  end

  defp strip_prologue(xml) do
    case String.split(xml, "]>", parts: 2) do
      [_dtd, body] -> body
      [body] -> body
    end
  end

  @doc """
  Splits the document into entries, keyed and counted.

  Public so tests can drive it on a snippet rather than on 29 MB. The
  occurrence counter is per `{headword, printed pos}` and is the only thing
  here that needs the whole document.
  """
  def segment(body) do
    @entry
    |> Regex.scan(body, capture: :first)
    |> Enum.map(&hd/1)
    |> Enum.with_index()
    |> Enum.map_reduce(%{}, &entry/2)
    |> elem(0)
  end

  defp entry({fragment, position}, seen) do
    [node] = Floki.parse_fragment!(fragment)

    {printed, marker} = form(node)
    {[headword | alts], _to_verb} = split_headword(printed)

    key = {headword, marker}
    occurrence = Map.get(seen, key, 0)

    entry = %{
      printed_headword: printed,
      headword: headword,
      alt_headwords: alts,
      pos: marker,
      position: position,
      occurrence: occurrence,
      xpln: Regex.run(@xpln, fragment, capture: :first) |> one() || ""
    }

    {entry, Map.put(seen, key, occurrence + 1)}
  end

  defp one([value]), do: value
  defp one(_), do: nil

  # `<form lang="en">CAT. <class type="pos">n. s.</class></form>` — the printed
  # headword is everything in the form that is not the part-of-speech class.
  defp form(node) do
    marker =
      node
      |> Floki.find("form class[type=pos]")
      |> Floki.text()
      |> squish()
      |> presence()

    printed =
      node
      |> Floki.find("form")
      |> Floki.traverse_and_update(fn
        {"class", _attrs, _children} -> nil
        other -> other
      end)
      |> Floki.text()
      |> unhyphenate()
      |> squish()

    {printed, marker}
  end

  # Johnson prints the headword first and then, in lower case, whatever he wants
  # to say about it. Two different things can follow:
  #
  #   * the rest of the *phrase* — `CAT in the pan`, `APPLE of Love`,
  #     `SENSITIVE Plant`, `HALF-SEAS over`, `To DIG up` — which is the headword;
  #   * a printed *grammar note* — `SINK pret I sunk`, `n. s.` that leaked out of
  #     `<class>`, `the preterite of methinks` — which is not.
  #
  # So the run ends at a full stop or at a grammar marker, and nowhere else.
  # "Everything up to the first period" is the obvious rule and it is wrong for
  # `To SINK pret I sunk` (no period after the headword) and for `A. Bp.` (all
  # periods); "everything up to the first lower-case word" is wrong for all 565
  # phrase headwords.
  @abbreviation ~r/^(?:[A-Z]\.\s*){2,}|^[A-Z]\.\s+[A-Z][a-z]+\./
  # `A'BBEY, or ABBY.` and `A, B, C.` — the comma is optional before the
  # conjunction, so that branch is tried first or the comma eats it.
  @alternates ~r/[,;]?\s*\b(?:or|and)\b\s+|[,;]\s*/

  # Read off the file: the lower-case tokens that actually follow a headword,
  # ranked. `n` (972), `adj` (639), `v` (399) and `adv` (240) are parts of
  # speech that leaked out of `<class type="pos">` into the form; the rest are
  # Johnson's grammar abbreviations. Deliberately absent: `of`, `the`, `in`,
  # `up`, `for`, `and`, `without`, `Tree`, `Stone`, `Root`, `Grass` — every one
  # of those is a word of a phrase headword — and `a`, which is why `APRON of a
  # Ship` and `To smell a RAT` keep their tails.
  @grammar_markers ~w(n v adj adv noun verb adjective adverb prep pron pronoun
                      conj conjunct conjunction interj interject interjection
                      part particip participle participial pass
                      pret preter preterite plur plural pl sing singular
                      substantive obsolete)

  @doc """
  The printed headword split into its alternates, and whether it was a verb.

  `"A'BBEY, or ABBY."` → `{["A'BBEY", "ABBY"], false}`;
  `"To ABI'DE.  I abode or abid."` → `{["ABI'DE"], true}`;
  `"METHO'UGHT, the preterite of methinks."` → `{["METHO'UGHT"], false}`;
  `"CAT in the pan."` → `{["CAT in the pan"], false}`.

  The entry attaches to the first; the others become `alt_of` relations, the
  same bargain `BABE or BABY` strikes in Bierce. A comma-separated part is only
  an alternate if it survives the run rule whole and every word of it is
  capitalised — otherwise it is Johnson explaining himself, and splitting on the
  comma naively puts that sentence in the lexicon as a word.
  """
  def split_headword(printed) do
    printed = printed |> unhyphenate() |> squish()

    case Regex.run(@abbreviation, printed, capture: :first) do
      [abbreviation] ->
        {[clean_part(abbreviation) <> "."], false}

      nil ->
        to_verb = String.match?(printed, ~r/^To\s+/)

        [first | rest] =
          printed
          |> String.replace(~r/^To\s+/, "")
          # `CE'LANDINE, (the lesser, or Pilewort.)` — the parenthesis is a
          # separator, and keeping it would put a bracket in the lemma.
          |> String.replace(~r/[()]/, " ")
          |> String.split(@alternates)

        alternates =
          for part <- rest,
              run = headword_run(part),
              run != "" and run == clean_part(part),
              capitalised?(run),
              do: run

        parts = [headword_run(first) | alternates] |> Enum.reject(&(&1 == "")) |> Enum.uniq()

        {(parts == [] && [clean_part(printed)]) || parts, to_verb}
    end
  end

  # The headword itself: the run of tokens that ends after one closing with a
  # full stop, or before a grammar marker, and it never starts on one.
  defp headword_run(part) do
    part
    |> String.split(~r/\s+/)
    |> Enum.reduce_while([], fn token, acc ->
      cond do
        acc != [] and marker?(token) -> {:halt, acc}
        String.ends_with?(token, ".") -> {:halt, [String.replace(token, ".", "") | acc]}
        true -> {:cont, [token | acc]}
      end
    end)
    |> Enum.reverse()
    |> Enum.join(" ")
    |> clean_part()
  end

  defp marker?(token) do
    bare = token |> String.replace(~r/[^\p{L}]/u, "") |> String.downcase()
    bare in @grammar_markers
  end

  defp capitalised?(run) do
    run |> String.split(~r/\s+/) |> Enum.all?(&(not Regex.match?(~r/^\p{Ll}/u, &1)))
  end

  # A character class, not `String.trim/2`: that takes the whole binary as one
  # string to strip, so `String.trim("C.", " .,;:")` is `"C."`.
  @edge_punctuation ~r/^[\s.,;:!?]+|[\s.,;:!?]+$/u

  defp clean_part(part) do
    part |> squish() |> String.replace(@edge_punctuation, "")
  end

  @doc """
  The lexicon key for a printed headword: stress marks dropped, downcased.

  `"ABA'CKE"` → `"abacke"`. Both apostrophes are stress marks in this
  transcription; neither is a letter.
  """
  def lemma(headword) do
    headword
    |> String.replace(["’", "'"], "")
    |> String.downcase()
  end

  @doc """
  The record key: `"HEADWORD/pos/occurrence"`.

  The occurrence index is what keeps Johnson's homographs apart — `A` is ten
  records, `CAT` two — the way Wiktionary's `word/pos/etymology_number` does.
  """
  def external_id(headword, pos, occurrence), do: "#{headword}/#{pos || "-"}/#{occurrence}"

  defp record_row(entry) do
    raw = %{
      "headword" => entry.headword,
      "alt_headwords" => entry.alt_headwords,
      "printed_headword" => entry.printed_headword,
      "pos" => entry.pos,
      "position" => entry.position,
      "occurrence" => entry.occurrence,
      "xpln" => entry.xpln
    }

    %{
      external_id: external_id(entry.headword, entry.pos, entry.occurrence),
      url: @document_url,
      raw: raw
    }
  end

  # ── part of speech ───────────────────────────────────────────────────────

  # The head of the distribution, which is 39,150 of the 39,352 entries that
  # print one. The tail is 200-odd one-off phrasings; `pos/1` normalizes and
  # then falls back to the first marker it recognises inside them, so
  # `"n. s. It has no singular."` is a noun and `"tree. n. s."` is a noun, while
  # a genuinely unreadable marker is `unknown` rather than a guess.
  @pos %{
    "n. s." => "noun",
    "n.s." => "noun",
    "n s." => "noun",
    "n. a." => "noun",
    "n." => "noun",
    "adj." => "adj",
    "adj" => "adj",
    "ad." => "adj",
    "a." => "adj",
    "v. a." => "verb",
    "v. n." => "verb",
    "v.a." => "verb",
    "v.n." => "verb",
    "v." => "verb",
    "adv." => "adv",
    "prep." => "prep",
    "pron." => "pron",
    "pronoun." => "pron",
    "conj." => "conj",
    "conjunct." => "conj",
    "conjunction." => "conj",
    "interj." => "intj",
    "interject." => "intj",
    "interjection." => "intj",
    "part." => "verb",
    "particip." => "verb",
    "participle." => "verb",
    "part. adj." => "adj",
    "particip. adj." => "adj",
    "participial adj." => "adj",
    "part. pass." => "verb",
    "particip. pass." => "verb"
  }

  @doc """
  The lexicon part of speech for a printed marker.

  One function, shared by the segmenter and the materializer. If the two ever
  disagreed by so much as a default, the entry would attach to a second lexeme
  beside the index row — the invariant `Bierce.pos/1` states and this keeps.
  """
  def pos(nil), do: "unknown"

  def pos(marker) do
    normalized = marker |> squish() |> String.downcase()

    case Map.fetch(@pos, normalized) do
      {:ok, pos} -> pos
      :error -> fallback_pos(normalized)
    end
  end

  defp fallback_pos(normalized) do
    @pos
    |> Enum.sort_by(fn {marker, _} -> -String.length(marker) end)
    |> Enum.find_value("unknown", fn {marker, pos} ->
      String.contains?(normalized, marker) && pos
    end)
  end

  @doc "Every printed marker `pos/1` maps directly."
  def pos_markers, do: Map.keys(@pos)

  # ── materialize ──────────────────────────────────────────────────────────

  @impl true
  def materialize(%SourceRecord{raw: raw} = record) when map_size(raw) > 0 do
    headword = raw["headword"]
    lemma = lemma(headword)
    pos = pos(raw["pos"])
    alts = raw["alt_headwords"] || []

    blocks = parse_xpln(raw["xpln"] || "")
    {body, metadata} = render(blocks)

    lexemes =
      for one <- [lemma | Enum.map(alts, &lemma/1)] do
        %{key: {"en", one, pos}, origin_source_id: record.source_id}
      end

    entry = %{
      source_id: record.source_id,
      source_record_id: record.id,
      lexeme: {"en", lemma, pos},
      author: @author_slug,
      headword: headword,
      pos: raw["pos"],
      body: body,
      body_format: :markdown,
      url: record.url,
      year: @year,
      position: 0,
      metadata:
        Map.merge(metadata, %{
          "pos_marker" => raw["pos"],
          "alt_headwords" => alts,
          "printed_headword" => raw["printed_headword"],
          "occurrence" => raw["occurrence"]
        })
    }

    {:ok,
     %{
       lexemes: Enum.uniq_by(lexemes, & &1.key),
       entries: [entry],
       relations: relations(record, lemma, pos, alts, blocks)
     }}
  end

  def materialize(%SourceRecord{}), do: {:ok, %{}}

  # The explanation is a flat run of text, etymology brackets and quotations.
  # Consecutive prose collapses into one block; every quotation is its own.
  defp parse_xpln(""), do: []

  defp parse_xpln(fragment) do
    [{"xpln", _attrs, children}] = Floki.parse_fragment!(fragment)

    children
    |> Enum.flat_map(&child_blocks/1)
    |> merge_prose()
    |> Enum.reject(&(&1.text == ""))
  end

  defp child_blocks({"etym", _attrs, _children} = node),
    do: [%{kind: :etymology, text: node |> inline_text() |> unhyphenate() |> squish()}]

  defp child_blocks({"term", attrs, _children} = node) do
    if List.keyfind(attrs, "lang", 0) == {"lang", "quo"} do
      [%{kind: :quotation, text: node |> inline_text() |> unhyphenate() |> trim_lines()}]
    else
      [%{kind: :prose, text: node |> inline_text() |> unhyphenate()}]
    end
  end

  defp child_blocks(text) when is_binary(text), do: [%{kind: :prose, text: unhyphenate(text)}]
  defp child_blocks(node), do: [%{kind: :prose, text: node |> inline_text() |> unhyphenate()}]

  # Johnson numbers his senses, and the numbers open a line in the transcription
  # — so the split happens before the newlines are collapsed, where it is
  # unambiguous. `Shak. 2.` mid-sentence is left alone.
  @sense_break ~r/\n(?=\s*\d{1,2}\.\s)/

  defp merge_prose(blocks) do
    blocks
    |> Enum.chunk_by(& &1.kind)
    |> Enum.flat_map(fn
      [%{kind: :prose} | _] = run ->
        run
        |> Enum.map_join(& &1.text)
        |> String.split(@sense_break)
        |> Enum.map(&%{kind: :prose, text: squish(&1)})

      other ->
        other
    end)
  end

  defp render(blocks) do
    body =
      blocks
      |> Enum.reject(&(&1.kind == :etymology))
      |> Enum.map_join("\n\n", &markdown/1)

    metadata = %{
      "etymology" => blocks |> Enum.find(&(&1.kind == :etymology)) |> text_of(),
      "quotations" => Enum.count(blocks, &(&1.kind == :quotation)),
      "senses" => Enum.count(blocks, &(&1.kind == :prose))
    }

    {body, metadata}
  end

  defp text_of(nil), do: nil
  defp text_of(%{text: text}), do: text

  # A quotation keeps its line breaks: half of them are verse, and the source
  # named at the end of the last line (`Shakesp. Macbeth.`) is Johnson's own
  # citation, not ours to move.
  defp markdown(%{kind: :quotation, text: text}) do
    text |> String.split("\n") |> Enum.map_join("\n", &("> " <> &1))
  end

  defp markdown(%{text: text}), do: text

  defp inline_text({"term", attrs, children}) do
    inner = Enum.map_join(children, &inline_text/1)

    case List.keyfind(attrs, "lang", 0) do
      {"lang", lang} when lang not in ["quo", "en"] and inner != "" -> "*" <> inner <> "*"
      _ -> inner
    end
  end

  defp inline_text({_tag, _attrs, children}), do: Enum.map_join(children, &inline_text/1)
  defp inline_text(text) when is_binary(text), do: text
  defp inline_text(_), do: ""

  # ── relations ────────────────────────────────────────────────────────────

  # "See CAT." and "See the article CAT." — 742 entries. The target is printed
  # in the small capitals the transcription renders as an upper-case run.
  @see_also ~r/\bSee\s+(?:the\s+(?:article|word)\s+)?(?<target>[A-Z][A-Z'’\-]{1,}(?:\s[A-Z'’\-]{2,})*)/

  defp relations(record, lemma, pos, alts, blocks) do
    text = Enum.map_join(blocks, " ", & &1.text)

    alt_rows =
      for alt <- alts do
        %{
          source_id: record.source_id,
          from_lexeme: {"en", lemma(alt), pos},
          to_lemma: lemma,
          to_pos: pos,
          type: :alt_of
        }
      end

    alt_rows ++ cross_references(record, lemma, pos, text)
  end

  defp cross_references(record, lemma, pos, text) do
    for [target] <- Regex.scan(@see_also, text, capture: ["target"]),
        target = target |> String.trim() |> lemma(),
        target != "" and target != lemma do
      %{
        source_id: record.source_id,
        from_lexeme: {"en", lemma, pos},
        to_lemma: target,
        type: :see_also
      }
    end
    |> Enum.uniq_by(& &1.to_lemma)
  end

  # ── text ─────────────────────────────────────────────────────────────────

  # A soft hyphen marks where the printed line broke inside a word, so it takes
  # the line break with it: `the lowest or­\r\nder` is `the lowest order`.
  defp unhyphenate(text), do: String.replace(text, ~r/\x{00AD}\s*/u, "")

  defp squish(text) do
    text
    |> String.replace(~r/\s+/u, " ")
    |> String.trim()
  end

  defp trim_lines(text) do
    text
    |> String.split(~r/\r?\n/)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.join("\n")
  end

  defp presence(""), do: nil
  defp presence(value), do: value

  @doc "The lexeme slug for a headword, so the tests and the UI agree."
  def slug_for(headword), do: headword |> lemma() |> Lexeme.slug()
end
