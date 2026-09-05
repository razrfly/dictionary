defmodule DevilsDictionary.Absorb.Sources.Bierce do
  @moduledoc """
  Ambrose Bierce, *The Devil's Dictionary* (1911), from Project Gutenberg #972.

  The layer proof (#69 §1): a dead author whose whole text we may import, sitting
  above the institutions on every word page. Also the brand.

  ## Where the parse happens

  `absorb/2` **segments**; `materialize/1` **parses**. Segmenting is the only
  step that needs the whole document — whether a paragraph is a new entry, the
  attribution under someone else's verse, or the second half of a sentence
  interrupted by that verse is a question about *sequence*, so it is answered
  once, here, exactly as WordNet computes its inverse edges at absorb and
  Wikipedia embeds its probe.

  What lands in `raw` is therefore the entry's own markup, unchanged:

      %{"headword" => "BABE", "pos" => "n", "alt_headwords" => ["BABY"],
        "letter" => "B", "anchor" => "link2H_4_0003", "position" => 122,
        "html" => ["<p>BABE or BABY, n. A misshapen creature…</p>",
                   "<pre>  Verse…</pre>",
                   "<p>G.J.</p>"]}

  Everything after that is a pure function of those fragments: the body with its
  verse, the alternate headwords, the cross-references. So when the parser is
  wrong about an entry — and with this text it will be — the fix is

      mix dd.materialize --source bierce --all

  with the network off and the file never re-read. That is scorecard row M2 in
  practice rather than in principle.

  ## What the text actually contains

  Measured on `priv/sources/bierce/972-h.htm`, not assumed:

    * **997 entries**, 996 unique headwords (`REASON` is both a verb and a noun).
      The often-quoted 959 comes from a single regex; it misses 21 stubs whose
      whole definition is the verse below them (`ABRACADABRA.`,
      `INSECTIVORA, n.`), the six letter essays that open chapters I, J, K, T, W
      and X (chapter X is *only* that), `HABEAS CORPUS.`, `CUI BONO?`,
      `FORMA PAUPERIS.`, `LL.D.`, `R.I.P.`, and one missing comma in the source
      (`IMPOSTOR n.`).
    * **247 verse blocks** in `<pre>`, across 239 entries, plus one `<pre>` that
      is not verse at all: the HTML mis-wraps `EUCHARIST`.
    * **190 attribution paragraphs** (initials and invented poets) and **107
      continuation paragraphs** across 58 entries — `STORY` has 26 of them.

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

  # The document we parse, and the anchor scheme it uses. Each entry links to
  # its letter chapter: Gutenberg gives the text no per-entry anchors at all —
  # only 27 `id`s, one per chapter heading.
  @document_url "https://www.gutenberg.org/files/972/972-h/972-h.htm"
  @year 1911
  @author_slug "ambrose-bierce"

  @impl true
  def slug, do: "bierce"

  @impl true
  def rate_limit_ms, do: 0

  @impl true
  def trim(raw), do: raw

  # ── absorb ───────────────────────────────────────────────────────────────

  @impl true
  def absorb(scope \\ nil, opts \\ [])

  def absorb(_scope, opts) do
    source = Sources.get_source_by_slug!(slug())
    path = opts[:path] || source.config["file"]

    unless File.exists?(path) do
      raise """
      Bierce source file not found: #{path}

      It is checked in; `sources.config["file"]` should point at
      priv/sources/bierce/972-h.htm.
      """
    end

    entries = path |> File.read!() |> segment()

    records = Sources.insert_records(source, Enum.map(entries, &record_row/1), @record_batch)
    materialized = Batch.run(__MODULE__, source, batch_size: @materialize_batch)

    {:ok,
     %{
       entries: length(entries),
       headwords: entries |> Enum.map(& &1.headword) |> Enum.uniq() |> length(),
       records: records,
       verse_blocks: Enum.sum(Enum.map(entries, &count_kind(&1, :verse))),
       attributions: Enum.sum(Enum.map(entries, &count_kind(&1, :attribution))),
       continuations: Enum.sum(Enum.map(entries, &count_kind(&1, :continuation))),
       alt_headwords: Enum.sum(Enum.map(entries, &length(&1.alt_headwords))),
       lexemes: materialized.lexemes,
       materialized_entries: materialized.entries,
       relations: materialized.relations
     }}
  end

  defp count_kind(entry, kind), do: Enum.count(entry.blocks, &(elem(&1, 0) == kind))

  defp record_row(entry) do
    raw = %{
      "headword" => entry.headword,
      "pos" => entry.pos,
      "alt_headwords" => entry.alt_headwords,
      "letter" => entry.letter,
      "anchor" => entry.anchor,
      "position" => entry.position,
      # The kind of each fragment, not just the fragment. Whether a paragraph
      # under verse is the poet's name or the definition resuming is a question
      # about sequence, which only the segmenter can answer; `materialize/1`
      # sees one entry at a time and would have to guess.
      "kinds" => Enum.map(entry.blocks, &(&1 |> elem(0) |> Atom.to_string())),
      "html" => Enum.map(entry.blocks, &elem(&1, 1))
    }

    %{
      external_id: external_id(entry.headword, entry.pos),
      url: "#{@document_url}##{entry.anchor}",
      raw: raw
    }
  end

  @doc """
  The record key for a headword: `"HEADWORD/pos"` (#69 §4).

  Keyed on the **first** headword, so `BABE or BABY` is one record and `BABY`
  is an alias relation rather than a second entry. `REASON` legitimately yields
  two records, because Bierce defines it twice under different parts of speech.
  """
  def external_id(headword, pos), do: "#{headword}/#{pos || "-"}"

  # ── segmentation ─────────────────────────────────────────────────────────

  # A short line under someone else's verse is a name, not a definition.
  @attribution_max_length 60

  @doc """
  Splits the document into entries. Public so the tests can drive it on a
  snippet rather than on 420 KB.
  """
  def segment(html) do
    html
    |> Floki.parse_document!()
    |> Floki.find("div.chapter")
    |> Enum.filter(&letter_chapter?/1)
    |> Enum.flat_map(&chapter_entries/1)
    |> Enum.with_index()
    |> Enum.map(fn {entry, i} -> %{entry | position: i} end)
  end

  # The preface is a chapter too. A dictionary chapter's heading is one letter.
  defp letter_chapter?(div) do
    div |> heading_letter() |> is_binary()
  end

  defp heading_letter(div) do
    text = div |> Floki.find("h2") |> Floki.text() |> String.trim()
    if String.match?(text, ~r/^[A-Z]$/), do: text, else: nil
  end

  defp chapter_entries(div) do
    letter = heading_letter(div)
    anchor = div |> Floki.find("h2 a") |> Floki.attribute("id") |> List.first()

    div
    |> Floki.children()
    |> Enum.filter(&match?({tag, _, _} when tag in ["p", "pre"], &1))
    |> Enum.reduce([], &absorb_block(&1, &2, letter, anchor))
    |> Enum.reverse()
    |> Enum.map(fn entry -> %{entry | blocks: Enum.reverse(entry.blocks)} end)
  end

  # The state machine. `entries` is reverse-ordered and its head is the entry
  # currently open, so "belongs to the entry above" is a push onto the head.
  defp absorb_block({tag, _, _} = node, entries, letter, anchor) do
    text = node |> Floki.text() |> squish()
    first? = entries == []

    case headword(text, tag, first?) do
      {:ok, headword, alt, pos} ->
        [new_entry(headword, alt, pos, letter, anchor, node, text) | entries]

      :no ->
        case entries do
          [] -> []
          [open | rest] -> [push(open, node, text, tag) | rest]
        end
    end
  end

  defp new_entry(headword, alt, pos, letter, anchor, node, text) do
    %{
      headword: headword,
      alt_headwords: alt,
      pos: pos,
      letter: letter,
      anchor: anchor,
      position: 0,
      blocks: [{:headword, raw_html(node), text}]
    }
  end

  defp push(entry, node, text, tag) do
    kind =
      cond do
        tag == "pre" -> :verse
        attribution?(entry, text) -> :attribution
        true -> :continuation
      end

    %{entry | blocks: [{kind, raw_html(node), text} | entry.blocks]}
  end

  # Only verse has attributions under it, and `PIE` shows they can run to two
  # paragraphs. A long line, or one that starts mid-sentence, is the definition
  # resuming instead: `MONUMENT` interrupts itself with two lines of Byron and
  # comes back with "but Agammemnon's fame…".
  defp attribution?(%{blocks: blocks}, text) do
    last_kind = blocks |> List.first() |> elem(0)

    last_kind in [:verse, :attribution] and
      String.length(text) <= @attribution_max_length and
      not String.match?(text, ~r/^[a-z]/)
  end

  defp raw_html(node), do: Floki.raw_html(node)

  # ── headword rules ───────────────────────────────────────────────────────

  # A headword is one or more capitalised tokens, and Bierce writes alternates
  # three different ways: `BABE or BABY`, `CONFIDANT, CONFIDANTE`, and
  # `TZETZE (or TSETSE) FLY`. All three are part of the headword, so the pattern
  # has to admit a lowercase "or", an internal comma and a parenthesis — and
  # nothing else, which is what keeps ordinary prose out.
  @token "[A-Z][A-Z'’\\-.]*"
  @hw "#{@token}(?:\\s*\\(or\\s+#{@token}(?:\\s+#{@token})*\\)|\\s+(?:or\\s+)?#{@token}|\\s*,\\s*#{@token})*"

  # 1 & 2. "HEADWORD, pos." — with a definition after it, or with nothing after
  #        it because the joke is the verse below (`INSECTIVORA, n.`).
  @with_pos Regex.compile!("^(?<hw>#{@hw})\\s*,\\s+(?<pos>[a-z]+(?:\\.[a-z]+)*)\\.(?:\\s|$)")

  # 3a. The source's own typo: `IMPOSTOR n.` lost its comma in 1911 and has
  #     never got it back.
  @missing_comma Regex.compile!("^(?<hw>#{@hw})\\s+(?<pos>[a-z]+(?:\\.[a-z]+)*)\\.\\s+\\S")

  # 3b. A bare all-caps word whose body is the verse below (`ABRACADABRA.`).
  #     Internal periods are excluded so initials stay attributions.
  @bare_stub ~r/^(?<hw>[A-Z][A-Z'’\-]{3,})\.$/

  # 3c. No part of speech at all, but a definition follows: `HABEAS CORPUS.`,
  #     `CUI BONO?`, `LL.D.`, `R.I.P.`. This is the loosest rule in the set: it
  #     has the same shape as the attribution `W.J. Candleton`. What separates
  #     them is that a definition is a *sentence* — see `definition?/1`.
  @no_pos Regex.compile!("^(?<hw>#{@hw})[.?]\\s+(?<rest>\\S.*)$")

  defp headword(text, tag, first_in_chapter?) do
    cond do
      # 4. A chapter's first block always opens an entry. That is what catches
      #    the six letter essays — "I is the first letter of the alphabet…" —
      #    which otherwise glue themselves onto the previous chapter's last
      #    entry, and it costs nothing elsewhere: every other chapter opens on a
      #    normal headword paragraph anyway.
      first_in_chapter? ->
        letter_essay_or_rule(text)

      captures = Regex.named_captures(@with_pos, text) ->
        from_pos(captures)

      captures = Regex.named_captures(@missing_comma, text) ->
        from_pos(captures)

      captures = Regex.named_captures(@bare_stub, text) ->
        from_no_pos(captures)

      # `W.J. Candleton` has exactly the shape of `LL.D. Letters indicating…` —
      # initials, a stop, more text — so the last rule tests what actually
      # differs: a definition is a sentence, an attribution is a name.
      captures = Regex.named_captures(@no_pos, text) ->
        if definition?(captures["rest"]), do: from_no_pos(captures), else: :no

      # A `<pre>` is verse unless it opens with a headword, which is how the
      # HTML's one mis-wrapped entry (`EUCHARIST`) gets in.
      tag == "pre" ->
        :no

      true ->
        :no
    end
  end

  defp letter_essay_or_rule(text) do
    case headword_rules(text) do
      :no ->
        # "I is the first letter…", "W (double U) has…". The headword is the
        # letter itself, printed as Bierce printed it.
        {:ok, String.first(text), [], nil}

      other ->
        other
    end
  end

  defp headword_rules(text) do
    cond do
      captures = Regex.named_captures(@with_pos, text) -> from_pos(captures)
      captures = Regex.named_captures(@missing_comma, text) -> from_pos(captures)
      captures = Regex.named_captures(@bare_stub, text) -> from_no_pos(captures)
      captures = Regex.named_captures(@no_pos, text) -> maybe_no_pos(captures)
      true -> :no
    end
  end

  defp maybe_no_pos(captures) do
    if definition?(captures["rest"]), do: from_no_pos(captures), else: :no
  end

  # A definition contains ordinary lowercase words. "Candleton" and "Railey" do
  # not; "Letters indicating the degree…" does.
  defp definition?(rest), do: String.match?(rest || "", ~r/\b[a-z]{2,}\b/)

  defp from_pos(%{"hw" => hw, "pos" => pos}) do
    {headword, alt} = split_alternates(hw)
    {:ok, headword, alt, pos}
  end

  defp from_no_pos(%{"hw" => hw}) do
    {headword, alt} = split_alternates(hw)
    {:ok, headword, alt, nil}
  end

  @doc """
  `BABE or BABY` → `{"BABE", ["BABY"]}`.

  Three shapes in the text: `A or B`, `A, B` (`CONFIDANT, CONFIDANTE`) and
  `A (or B) C` (`TZETZE (or TSETSE) FLY`). The entry attaches to the first; the
  others become `alt_of` relations pointing at it (#70's S3 notes).
  """
  def split_alternates(headword) do
    headword = headword |> String.trim() |> String.trim_trailing(".")

    cond do
      # TZETZE (or TSETSE) FLY → TZETZE FLY, alt TSETSE FLY
      captures =
          Regex.named_captures(~r/^(?<a>.+?)\s+\(OR\s+(?<b>[^)]+)\)\s*(?<tail>.*)$/i, headword) ->
        tail = String.trim(captures["tail"])
        {join(captures["a"], tail), [join(captures["b"], tail)]}

      String.match?(headword, ~r/\s+or\s+/i) ->
        [first | rest] = Regex.split(~r/\s+or\s+/i, headword)
        {String.trim(first), Enum.map(rest, &String.trim/1)}

      String.contains?(headword, ",") ->
        [first | rest] = String.split(headword, ",")
        {String.trim(first), rest |> Enum.map(&String.trim/1) |> Enum.reject(&(&1 == ""))}

      true ->
        {headword, []}
    end
  end

  defp join(a, ""), do: String.trim(a)
  defp join(a, tail), do: String.trim(a) <> " " <> tail

  defp squish(text) do
    text
    |> String.replace(~r/\s+/u, " ")
    |> String.trim()
  end

  # ── part of speech ───────────────────────────────────────────────────────

  @pos %{
    "n" => "noun",
    "n.pl" => "noun",
    "v" => "verb",
    "v.i" => "verb",
    "v.t" => "verb",
    "pp" => "verb",
    "p.p" => "verb",
    "adj" => "adj",
    "adv" => "adv",
    "pro" => "pron",
    "pron" => "pron",
    # Not a mistake and not a missing value: `HASH, x. There is no definition
    # for this word — nobody knows what hash is.`
    "x" => "unknown"
  }

  @doc """
  Bierce's marker → the lexicon's part of speech.

  One function, called by the segmenter and by `materialize/1`. If the two ever
  disagreed by so much as a default, the entry would attach to a second lexeme
  beside the index row and the word page would show the word twice — which is
  the mistake S1 made once already with Wiktionary.
  """
  def pos(nil), do: "unknown"
  def pos(marker), do: Map.get(@pos, marker, "unknown")

  @doc "The markers this source is known to use, for the tests and the docs."
  def pos_markers, do: Map.keys(@pos)

  # ── materialize ──────────────────────────────────────────────────────────

  @impl true
  def materialize(%SourceRecord{raw: raw} = record) when map_size(raw) > 0 do
    headword = raw["headword"]
    lemma = String.downcase(headword)
    pos = pos(raw["pos"])
    alts = raw["alt_headwords"] || []

    blocks = parse_blocks(raw["html"] || [], raw["kinds"] || [], headword, raw["pos"])
    {body, metadata} = render(blocks)

    lexemes =
      for lemma <- [lemma | Enum.map(alts, &String.downcase/1)] do
        %{key: {"en", lemma, pos}, origin_source_id: record.source_id}
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
          "letter" => raw["letter"]
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

  # Each stored fragment is re-parsed here; its kind comes from the record.
  defp parse_blocks(fragments, kinds, headword, marker) do
    fragments
    |> Enum.zip(kinds ++ List.duplicate("continuation", length(fragments)))
    |> Enum.map(fn {fragment, kind} ->
      [node] = Floki.parse_fragment!(fragment)
      kind = String.to_existing_atom(kind)
      text = node |> Floki.text() |> squish()

      %{kind: kind, node: node, text: text, markdown: to_markdown(node, kind, headword, marker)}
    end)
  end

  # `<i>` is the only inline tag in the corpus (171 pairs: foreign phrases and
  # book titles), and it is worth keeping — which is the reason the fragments
  # are stored as markup rather than as flattened text.
  defp to_markdown(node, :verse, _headword, _marker) do
    node
    |> inline_text()
    |> String.split("\n")
    |> Enum.map(&String.trim_trailing/1)
    |> Enum.drop_while(&(&1 == ""))
    |> Enum.reverse()
    |> Enum.drop_while(&(&1 == ""))
    |> Enum.reverse()
    |> Enum.map_join("\n", &("> " <> &1))
  end

  defp to_markdown(node, :headword, headword, marker) do
    node
    |> inline_text()
    |> squish()
    |> strip_headword(headword, marker)
  end

  defp to_markdown(node, :attribution, _headword, _marker) do
    "— " <> (node |> inline_text() |> squish())
  end

  defp to_markdown(node, _kind, _headword, _marker), do: node |> inline_text() |> squish()

  # The headword and its marker are columns of their own; the body starts at the
  # definition. What is left when nothing follows is an empty string — the 21
  # entries whose whole joke is the verse underneath.
  defp strip_headword(text, headword, marker) do
    prefixes =
      [
        "#{headword}, #{marker}.",
        "#{headword} #{marker}.",
        "#{headword},",
        "#{headword}.",
        "#{headword}?",
        headword
      ]
      |> Enum.reject(&(&1 == "" or (is_nil(marker) and String.contains?(&1, "nil"))))

    Enum.find_value(prefixes, text, fn prefix ->
      if String.starts_with?(text, prefix) do
        text
        |> binary_part(byte_size(prefix), byte_size(text) - byte_size(prefix))
        |> String.trim()
      end
    end)
  end

  defp inline_text({"i", _, children}), do: "*" <> Enum.map_join(children, &inline_text/1) <> "*"
  defp inline_text({_tag, _, children}), do: Enum.map_join(children, &inline_text/1)
  defp inline_text(text) when is_binary(text), do: text
  defp inline_text(_), do: ""

  defp render(blocks) do
    body =
      blocks
      |> Enum.map(& &1.markdown)
      |> Enum.reject(&(&1 == ""))
      |> Enum.join("\n\n")

    metadata = %{
      "verse" => Enum.any?(blocks, &(&1.kind == :verse)),
      "attributions" => for(b <- blocks, b.kind == :attribution, do: b.text),
      "continuations" => Enum.count(blocks, &(&1.kind == :continuation))
    }

    {body, metadata}
  end

  # ── relations ────────────────────────────────────────────────────────────

  # "See HUSBAND." and "(See GIAOUR.)" — six entries, and the format is not
  # consistent between them. `[from ACADEME]` is one entry. The `[Latin]`
  # brackets are a language tag, not a cross-reference, so they stay in metadata.
  @see_also ~r/\(?\bSee\s+(?<target>[A-Z][A-Za-z'’\- ]*?)\.?\)?[.\s]/
  @from ~r/\[from\s+(?<target>[A-Z][A-Za-z'’\- ]*?)\]/

  defp relations(record, lemma, pos, alts, blocks) do
    text = Enum.map_join(blocks, " ", & &1.text)

    alt_rows =
      for alt <- alts do
        %{
          source_id: record.source_id,
          from_lexeme: {"en", String.downcase(alt), pos},
          to_lemma: lemma,
          to_pos: pos,
          type: :alt_of
        }
      end

    alt_rows ++
      cross_references(record, lemma, pos, text, @see_also, :see_also) ++
      cross_references(record, lemma, pos, text, @from, :related)
  end

  defp cross_references(record, lemma, pos, text, regex, type) do
    for %{"target" => target} <- Regex.scan(regex, text, capture: :all_names) |> names(),
        target = target |> String.trim() |> String.downcase(),
        target != "" and target != lemma do
      %{
        source_id: record.source_id,
        from_lexeme: {"en", lemma, pos},
        to_lemma: target,
        type: type
      }
    end
    |> Enum.uniq_by(& &1.to_lemma)
  end

  defp names(matches), do: Enum.map(matches, fn [target] -> %{"target" => target} end)

  # A dead author publishes once; there is nothing to fetch on demand.
  @impl true
  def enrich(_target, _opts), do: {:error, :not_supported}

  @doc "The lexeme slug for a headword, so the tests and the UI agree."
  def slug_for(headword), do: headword |> String.downcase() |> Lexeme.slug()
end
