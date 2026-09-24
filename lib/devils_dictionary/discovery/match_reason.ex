defmodule DevilsDictionary.Discovery.MatchReason do
  @moduledoc """
  Why one result is on one page, as a fact rather than a phrase.

  K3 of #109. Before this there were three of these: `Culture.match_detail/2`
  branched on whether a persisted result's `match_details` map held Met tags,
  CineGraph keywords or neither; `Artworks.suggestions/2` composed a sentence
  into `match_reason.detail`; and `Artwork.card` prefixed that sentence with a
  word of its own. Four content types and a text provider were about to make
  that four. One struct and one `describe/1` instead.

  Every field is something a provider or a manifest recorded:

    * `kind` — what did the matching. `:keyword`, `:tag`, `:depiction`, `:gene`,
      `:attestation`, or `:query` for a provider that returned a result for the
      word and named no reason at all.
    * `identifier` — the provider's own identity for it: a TMDb keyword id, a
      Wikidata QID, an Artsy gene id. This is the part that makes the reason
      checkable.
    * `term` — the text that carried the identifier, as the provider spells it.
    * `relation` — `:exact`, `:broader`, `:related`, or `:attests` for a text
      that *uses* the word (K11) rather than being about it.
    * `scope` — `:sense` when the evidence is a claim about one meaning,
      `:lexeme` when it is a claim about the word. A `:lexeme` reason says so
      out loud, because a word-level link is not a statement about a meaning.
    * `locator` — the citable evidence locator, carried into `/connect`.
    * `note` — one further sentence of context, or `nil`.
    * `reached` — the label of the identity a non-`:exact` relation arrived at.

  `evidence/1` folds the kinds into the three classes the content-type table's
  `evidence` column is written in — `:identity`, `:attestation`, `:query` —
  so whether a shelf may show a reason at all is data the conformance suite
  asserts and the renderer reads (#116).

  ## The declaration (#144 Phase 0)

  A result says what it is rather than being guessed at. Every provider writes
  two keys into `match_details`:

    * `"kind"` — which builder reads this result's reason shape, one of
      `kinds/0`. It is the extension point: a twelfth provider with a new shape
      adds a kind and a clause here, and until it does its suite is red.
    * `"evidence"` — the class the reason belongs to, `"identity"`,
      `"attestation"` or `"query"`, read back by `declared_evidence/1`.
      Conformance asserts it is present, that it equals `evidence/1` of the
      reason the builder actually produced, and that the content type's row
      admits it.

  Before this, `from_result/2` dispatched on the *presence* of `"tags"`,
  `"depicts"`, `"keywords"` or `"lines"`. Those four keys are still read — a
  result persisted before the declaration existed has no `"kind"` — but they
  are the **legacy** path and nothing new should arrive on it: a shape none of
  them matched became a `:query` with nothing to say, on a shelf that may not
  admit one, with no check anywhere to notice.

  `reached` is an eighth field #109's K3 does not list, and the shelf cannot be
  built without it: the Met's two-step broader walk says *Related to “War”
  through the tag “World War I” (Q361)*, in which `Q361` is the tag's QID and
  “War” is the concept the walk reached. Neither `term` nor `note` can hold it
  without one of them meaning two different things.

  `via` and `word` are the concept hop's (#172 build A): a sitelink reached
  from a sense's item by `ConceptHop`'s properties, not on it. `via` is the
  properties in order (`["P1552"]`), and `word` the page's word the sentence
  names — *the concept a sense of “coward” has as its characteristic*. Each
  property's phrase is `ConceptHop.wording/1`'s, so there is one per property
  and it lives beside the list it belongs to.

  `level` is the word-level tier's (#172 build B). A result whose recipe was
  read from a corroborated `lexeme_entity_candidate` rather than a sense's
  `refers_to` says so in `match_details["level"]`, and every identity reason
  on it is `level: :word`: still an identifier, but one the ladder reached for
  the word, so its class is `:word_identity` and not `:identity`, and its
  sentence ends with the one #172 decided — *For the word “grief”, not a
  particular sense.* (`word_level_note/1`). It is not *Search result for…*:
  that phrase is a `:query`'s, and this is not one.
  """

  alias DevilsDictionary.Discovery.ConceptHop

  defstruct [
    :kind,
    :identifier,
    :term,
    :relation,
    :scope,
    :locator,
    :note,
    :reached,
    :word,
    :level,
    via: []
  ]

  @type t :: %__MODULE__{
          kind: atom(),
          identifier: String.t() | nil,
          term: String.t() | nil,
          relation: :exact | :broader | :related | :attests,
          scope: :sense | :lexeme | nil,
          locator: String.t() | nil,
          note: String.t() | nil,
          reached: String.t() | nil,
          word: String.t() | nil,
          level: :sense | :word | nil,
          via: [String.t()]
        }

  @doc """
  The reasons a persisted or transient provider result carries.

  Read from the item's own `match_details`, which is what the provider wrote and
  the pipeline stored unaltered. `term` is the page's term, used only by the
  `:query` fallback — a provider that named no reason has none to name, and
  saying so is better than inventing one.
  """
  def from_result(details, term) when is_map(details) do
    case declared(details) do
      nil -> legacy(details)
      reasons -> reasons
    end
    |> leveled(details)
    |> fallback(term)
  end

  def from_result(_details, term), do: [%__MODULE__{kind: :query, relation: :exact, term: term}]

  defp fallback([], term), do: [%__MODULE__{kind: :query, relation: :exact, term: term}]
  defp fallback(reasons, _term), do: reasons

  # A word-level recipe's results (#172 build B): every identity on them was
  # reached for the word, and names it. A text's attestation is about the
  # word already, and a search names no identity to qualify.
  defp leveled(reasons, %{"level" => "word"} = details) do
    Enum.map(reasons, fn
      %__MODULE__{kind: kind} = reason when kind in [:attestation, :query] ->
        reason

      reason ->
        %{reason | level: :word, word: word_of(details["query"])}
    end)
  end

  defp leveled(reasons, _details), do: reasons

  defp word_of(term) when is_binary(term) and term != "", do: term
  defp word_of(_term), do: nil

  # The declaration: `"kind"` names the builder, and the builder is the whole
  # of the extension point. A twelfth provider with a reason shape none of
  # these reads adds its kind to `@builders` and its clause below — one
  # declared edit in shared code, where before it silently became a `:query`
  # and failed conformance on any identity shelf with nothing to point at.
  defp declared(%{"kind" => kind} = details) when is_binary(kind) do
    case kind do
      "tag" -> tags(details)
      "depiction" -> depictions(details)
      "keyword" -> keywords(details)
      "attestation" -> attestations(details)
      "sitelink" -> sitelinks(details)
      "query" -> []
      _unknown -> nil
    end
  end

  defp declared(_details), do: nil

  # The legacy path, kept for rows persisted before the declaration existed
  # (#144 Phase 0) and for a provider that has not declared one yet: the shape
  # of `match_details` decides, by the presence of one of four magic keys.
  # Nothing new should rely on it — a kind that reaches here is a `:query` with
  # no reason to give, which is exactly the silence the declaration ends.
  defp legacy(details) do
    tags(details) ++ depictions(details) ++ keywords(details) ++ attestations(details)
  end

  @builders ~w(tag depiction keyword attestation sitelink query)

  @doc """
  Every `match_details["kind"]` the reason builder knows how to read.

  A provider declares one of these; conformance asserts the declaration against
  this list, so a new reason shape is a red suite and a named edit here rather
  than a result that quietly describes itself as a search.
  """
  def kinds, do: @builders

  @doc "True when a provider's declared kind names a builder this module has."
  def known_kind?(kind) when is_binary(kind), do: kind in @builders
  def known_kind?(_kind), do: false

  @doc """
  The evidence class a result *declares*, from `match_details["evidence"]`.

  The declaration and not an inference: a result says which of the content-type
  table's three classes it belongs to, and `evidence/1` computed from the built
  reason is what conformance compares it against. `nil` means the result was
  persisted before the declaration existed, or by a provider that does not make
  one; the legacy path in `from_result/2` still describes it.
  """
  def declared_evidence(details) when is_map(details) do
    case details["evidence"] do
      "identity" -> :identity
      "attestation" -> :attestation
      "query" -> :query
      "word_identity" -> :word_identity
      _other -> nil
    end
  end

  def declared_evidence(_details), do: nil

  defp tags(details) do
    details
    |> Map.get("tags", [])
    |> List.wrap()
    |> Enum.filter(&(is_map(&1) and is_binary(&1["term"]) and is_binary(&1["qid"])))
    |> Enum.uniq_by(& &1["qid"])
    |> Enum.map(fn tag ->
      %__MODULE__{
        kind: :tag,
        identifier: tag["qid"],
        term: tag["term"],
        relation: relation(tag["relation"]),
        scope: :sense,
        reached: tag["entity_label"],
        locator: "tag #{tag["qid"]}"
      }
    end)
  end

  # A live depiction (#109 Phase 3a): a Wikimedia Commons file's own `P180`
  # statement names a QID a sense refers to. The same fact a corpus row records
  # as `depicted_qid`, read from a provider result instead of a manifest, so it
  # ends as the same struct and the same sentence.
  defp depictions(details) do
    details
    |> Map.get("depicts", [])
    |> List.wrap()
    |> Enum.filter(&(is_map(&1) and is_binary(&1["qid"]) and &1["qid"] != ""))
    |> Enum.uniq_by(& &1["qid"])
    |> Enum.map(fn depiction ->
      %__MODULE__{
        kind: :depiction,
        identifier: depiction["qid"],
        relation: relation(depiction["relation"]),
        scope: :sense,
        reached: depiction["entity_label"],
        locator: "depicts #{depiction["qid"]}"
      }
    end)
  end

  defp keywords(details) do
    details
    |> Map.get("keywords", [])
    |> List.wrap()
    |> Enum.filter(&(is_map(&1) and is_binary(&1["name"]) and &1["name"] != ""))
    |> Enum.uniq_by(& &1["name"])
    |> Enum.map(fn keyword ->
      %__MODULE__{
        kind: :keyword,
        identifier: identifier(keyword["tmdbId"]),
        term: keyword["name"],
        relation: :exact,
        scope: :lexeme,
        locator: keyword["tmdbId"] && "keyword #{keyword["tmdbId"]}"
      }
    end)
  end

  # A page of another wiki that a QID a sense refers to links to by its own
  # sitelink (#158 build 4): Wikiquote's *Grief* is `enwikiquote` on the
  # concept Q.... The sitelink is Wikidata's statement, not a title match, so it
  # is identity evidence at the meaning's scope — the same standing as a Met
  # tag QID, one wiki further. A hop (#172 build A) is the same evidence one
  # stated relation further, and its `"reached"` properties say which.
  defp sitelinks(details) do
    details
    |> Map.get("sitelinks", [])
    |> List.wrap()
    |> Enum.filter(&(is_map(&1) and is_binary(&1["qid"]) and is_binary(&1["title"])))
    |> Enum.uniq_by(& &1["qid"])
    |> Enum.map(fn link ->
      via =
        link
        |> Map.get("reached")
        |> List.wrap()
        |> Enum.filter(&is_binary(ConceptHop.wording(&1)))

      %__MODULE__{
        kind: :sitelink,
        identifier: link["qid"],
        term: link["title"],
        relation: if(via == [], do: :exact, else: :related),
        scope: :sense,
        via: via,
        word: if(via != [] and is_binary(details["query"]), do: details["query"]),
        # The wiki's display name travels in the reason, so this module still
        # names no provider (promise 9).
        reached: link["wiki"],
        locator: "sitelink #{link["site"]}"
      }
    end)
  end

  # A text provider's evidence (K11): the word appears at a locator in a work,
  # which is evidence the word is used and never evidence of what it means.
  #
  # The locator is the line map's own `"locator"` when it names one, and the
  # line form otherwise. Before #116 Phase 1 it was hardcoded as `"line N"`,
  # and Open Library (#109 Phase 3c) left its locator empty rather than call a
  # page a line; a newspaper page or a dated article is the next shape.
  defp attestations(details) do
    details
    |> Map.get("lines", [])
    |> List.wrap()
    |> Enum.filter(&(is_map(&1) and is_binary(&1["text"])))
    |> Enum.map(fn line ->
      %__MODULE__{
        kind: :attestation,
        identifier: identifier(line["number"]) || identifier(line["locator"]),
        term: details["query"],
        relation: :attests,
        scope: :lexeme,
        locator: attestation_locator(line),
        note: line["text"]
      }
    end)
  end

  defp attestation_locator(%{"locator" => locator}) when is_binary(locator) and locator != "",
    do: locator

  defp attestation_locator(%{"number" => number})
       when is_integer(number) or (is_binary(number) and number != ""),
       do: "line #{number}"

  defp attestation_locator(_line), do: nil

  @doc """
  The reason a catalog candidate is on a page.

  A corpus candidate is a shelf item with a match reason (K2), and this is that
  reason: the committed manifest recorded what a work depicts or which genes
  Artsy assigned it, the encyclopedia recorded what a meaning or a word refers
  to, and an equal identifier is the match — the same identity-not-text rule a
  live provider matches on, asked of the catalog.
  """
  def from_candidate(%{match_reason: reason} = candidate) do
    %__MODULE__{
      kind: kind(reason.kind),
      identifier: reason[:qid] || reason[:gene_id],
      term: reason[:term] || reason[:gene_name],
      relation: relation(candidate.match_type),
      scope: reason[:scope] || :sense,
      # A catalog match through the word's candidate is the word-level tier's
      # (#172), and says so like a live one.
      level: if(reason[:scope] == :lexeme, do: :word),
      reached: reason[:entity_label],
      locator: reason[:locator],
      note: reason[:note]
    }
  end

  defp kind("depicted_qid"), do: :depiction
  defp kind("direct_gene_assignment"), do: :gene
  defp kind(_kind), do: :query

  defp relation(relation) when relation in [:exact, :broader, :related, :attests], do: relation
  defp relation("broader"), do: :broader
  defp relation("related"), do: :related
  defp relation("attests"), do: :attests
  defp relation(_relation), do: :exact

  defp identifier(value) when is_integer(value), do: Integer.to_string(value)
  defp identifier(value) when is_binary(value) and value != "", do: value
  defp identifier(_value), do: nil

  @doc """
  Which class of evidence a reason is, for the content-type table's
  `evidence` column (#116): `:identity` for a tag, depiction, gene or
  keyword — an identifier the encyclopedia already asserts; `:word_identity`
  for the same reached from a word-level candidate rather than a sense
  (#172); `:attestation` for a text that uses the word; `:query` for a
  provider that named no reason at all, or a stock-photo search that is
  honest about being one.
  """
  def evidence(%__MODULE__{kind: :attestation}), do: :attestation
  def evidence(%__MODULE__{kind: :query}), do: :query
  def evidence(%__MODULE__{level: :word}), do: :word_identity
  def evidence(%__MODULE__{}), do: :identity

  @doc """
  The sentence a word-level identity carries, on its reason and once on its
  shelf (#172, decided there so no provider invents one).
  """
  def word_level_note(word) when is_binary(word) and word != "",
    do: "For the word #{quoted(word)}, not a particular sense."

  def word_level_note(_word), do: "For this word, not a particular sense."

  @doc """
  One sentence, composed from the fields and nothing else.

  The only renderer. It names the identifier wherever there is one, because an
  identifier is what separates a reason from a claim: *tagged “Soldiers”* is a
  reader's impression and *tagged “Soldiers” (Q4991371)* is a fact anyone can go
  and check.

  A word-level reason is the same sentence, said of the word rather than a
  meaning, and then `word_level_note/1`.
  """
  def describe(%__MODULE__{level: :word} = reason),
    do: word_level(reason) <> " " <> word_level_note(reason.word)

  def describe(%__MODULE__{kind: :tag, relation: :exact} = reason),
    do:
      "Tagged #{quoted(reason.term)}#{parenthesis(reason.identifier)}, the concept this " <>
        scoped(reason) <> " refers to."

  def describe(%__MODULE__{kind: :tag, reached: reached} = reason) when is_binary(reached),
    do:
      "Related to #{quoted(reached)} through the tag #{quoted(reason.term)}#{parenthesis(reason.identifier)}."

  def describe(%__MODULE__{kind: :tag} = reason),
    do: "Reached through the tag #{quoted(reason.term)}#{parenthesis(reason.identifier)}."

  def describe(%__MODULE__{kind: :sitelink, via: [_ | _] = via} = reason),
    do:
      "From #{wiki(reason.reached)}page #{quoted(reason.term)}, the concept a sense of " <>
        "#{word(reason.word)} #{hop(via)}#{parenthesis(reason.identifier)}."

  def describe(%__MODULE__{kind: :sitelink} = reason),
    do:
      "From #{wiki(reason.reached)}page #{quoted(reason.term)}, the page of the concept this " <>
        scoped(reason) <> " refers to#{parenthesis(reason.identifier)}."

  def describe(%__MODULE__{kind: :keyword} = reason),
    do:
      "Matched the keyword #{quoted(reason.term)}#{parenthesis(reason.identifier)} for this term."

  def describe(%__MODULE__{kind: :attestation, term: term} = reason) when is_binary(term),
    do: "Uses #{quoted(term)}#{at(reason.locator)}."

  def describe(%__MODULE__{kind: :attestation} = reason),
    do: "Uses this word#{at(reason.locator)}."

  def describe(%__MODULE__{kind: :depiction, scope: :lexeme} = reason),
    do:
      "#{relation_word(reason.relation)} depiction of #{quoted(reason.reached)}#{parenthesis(reason.identifier)}, " <>
        "matched to the word and not to this meaning."

  def describe(%__MODULE__{kind: :depiction} = reason),
    do:
      "#{relation_word(reason.relation)} depiction of #{quoted(reason.reached)}#{parenthesis(reason.identifier)}" <>
        tagged(reason.term) <> "."

  def describe(%__MODULE__{kind: :gene} = reason),
    do: "#{relation_word(reason.relation)} Artsy gene #{quoted(reason.term)}."

  def describe(%__MODULE__{term: term}) when is_binary(term) and term != "",
    do: "The provider returned this result for #{quoted(term)}."

  def describe(%__MODULE__{}), do: "The provider returned this result."

  @doc """
  One sentence, on a shelf that admits the classes in `admits`.

  The same as `describe/1` for every reason but a `:query`. A search result
  on a shelf whose row admits `:query` (the content-type table's `evidence`,
  M6 of #116) is described as the search result it is; on any other shelf a
  reason with nothing in it stays the prompt it was meant to be — *the
  provider returned this result*, which is embarrassing enough to get fixed.
  """
  def describe(%__MODULE__{kind: :query, term: term}, admits)
      when is_list(admits) and is_binary(term) and term != "" do
    if :query in admits,
      do:
        "Search result for #{quoted(term)}, ranked by the provider and not matched on an identifier.",
      else: describe(%__MODULE__{kind: :query, term: term})
  end

  def describe(%__MODULE__{} = reason, admits) when is_list(admits), do: describe(reason)

  @doc "Every reason on one item, as one paragraph; `admits` as in `describe/2`."
  def describe_all(reasons, admits \\ nil)

  def describe_all(reasons, nil) when is_list(reasons),
    do: reasons |> Enum.map(&describe/1) |> Enum.join(" ")

  def describe_all(reasons, admits) when is_list(reasons) and is_list(admits),
    do: reasons |> Enum.map(&describe(&1, admits)) |> Enum.join(" ")

  # The sense-level sentence, turned to the word where it names a meaning.
  defp word_level(%__MODULE__{kind: :sitelink, via: []} = reason),
    do:
      "From #{wiki(reason.reached)}page #{quoted(reason.term)}, the concept the word " <>
        "#{word(reason.word)} names#{parenthesis(reason.identifier)}."

  defp word_level(%__MODULE__{kind: :sitelink, via: via} = reason),
    do:
      "From #{wiki(reason.reached)}page #{quoted(reason.term)}, the concept the word " <>
        "#{word(reason.word)} #{hop(via)}#{parenthesis(reason.identifier)}."

  # A tag reads *the concept this word refers to*; a depiction is the
  # sense-level sentence, not the older `:lexeme` one, whose *matched to the
  # word and not to this meaning* the note already says.
  defp word_level(%__MODULE__{kind: :depiction} = reason),
    do: describe(%{reason | level: nil, scope: :sense})

  defp word_level(%__MODULE__{} = reason), do: describe(%{reason | level: nil, scope: :lexeme})

  defp relation_word(:broader), do: "Broader-context"
  defp relation_word(:related), do: "Related"
  defp relation_word(_relation), do: "Direct"

  # One step reads as its property's phrase; two read as both, in order,
  # because a sentence that folds a path into one verb hides the middle item.
  defp hop([property]), do: ConceptHop.wording(property)

  defp hop(properties),
    do:
      "reaches in #{count(length(properties))} steps (" <>
        Enum.map_join(properties, ", then ", &ConceptHop.wording/1) <> ")"

  defp count(2), do: "two"
  defp count(n), do: Integer.to_string(n)

  defp word(word) when is_binary(word) and word != "", do: quoted(word)
  defp word(_word), do: "this word"

  defp wiki(name) when is_binary(name) and name != "", do: "#{name}'s "
  defp wiki(_name), do: "the "

  defp scoped(%__MODULE__{scope: :lexeme}), do: "word"
  defp scoped(%__MODULE__{}), do: "meaning"

  defp tagged(term) when is_binary(term) and term != "", do: " tagged #{quoted(term)}"
  defp tagged(_term), do: ""

  # *at line 4* and *at page 12*, but *in a headline* and *in the text*.
  #
  # The preposition belongs to the renderer rather than to the locator a
  # provider writes, and it was fixed at *at* until #142. That was right for
  # the two locators the kit had — a line and a page are points, and you cite
  # something *at* one — and wrong for the third shape Bing introduced (#135),
  # which is a part of a work: *Uses “bestiality” at a headline, Wired, 15
  # September 2026* is not English. #140 measured it in the browser and
  # reported it rather than fixing it, because that issue put this module out
  # of scope; #142 was editing the attestation tests anyway and took it.
  #
  # A determiner is the discriminator because it is what distinguishes the two
  # classes in every locator the kit writes: a numbered point never has one
  # (*line 4*, *page 12*) and a named part always does (*a headline*, *the
  # text*). A provider wanting the other preposition writes the other shape.
  defp at(locator) when is_binary(locator) and locator != "" do
    if Regex.match?(~r/^(a|an|the)\s/iu, locator),
      do: " in #{locator}",
      else: " at #{locator}"
  end

  defp at(_locator), do: ""

  defp quoted(value) when is_binary(value), do: "“#{value}”"
  defp quoted(_value), do: "“it”"

  defp parenthesis(value) when is_binary(value) and value != "", do: " (#{value})"
  defp parenthesis(_value), do: ""
end
