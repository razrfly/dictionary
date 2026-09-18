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

  `reached` is an eighth field #109's K3 does not list, and the shelf cannot be
  built without it: the Met's two-step broader walk says *Related to “War”
  through the tag “World War I” (Q361)*, in which `Q361` is the tag's QID and
  “War” is the concept the walk reached. Neither `term` nor `note` can hold it
  without one of them meaning two different things.
  """

  defstruct [:kind, :identifier, :term, :relation, :scope, :locator, :note, :reached]

  @type t :: %__MODULE__{
          kind: atom(),
          identifier: String.t() | nil,
          term: String.t() | nil,
          relation: :exact | :broader | :related | :attests,
          scope: :sense | :lexeme | nil,
          locator: String.t() | nil,
          note: String.t() | nil,
          reached: String.t() | nil
        }

  @doc """
  The reasons a persisted or transient provider result carries.

  Read from the item's own `match_details`, which is what the provider wrote and
  the pipeline stored unaltered. `term` is the page's term, used only by the
  `:query` fallback — a provider that named no reason has none to name, and
  saying so is better than inventing one.
  """
  def from_result(details, term) when is_map(details) do
    case tags(details) ++ depictions(details) ++ keywords(details) ++ attestations(details) do
      [] -> [%__MODULE__{kind: :query, relation: :exact, term: term}]
      reasons -> reasons
    end
  end

  def from_result(_details, term), do: [%__MODULE__{kind: :query, relation: :exact, term: term}]

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

  # A text provider's evidence (K11): the word appears at a locator in a work,
  # which is evidence the word is used and never evidence of what it means.
  defp attestations(details) do
    details
    |> Map.get("lines", [])
    |> List.wrap()
    |> Enum.filter(&(is_map(&1) and is_binary(&1["text"])))
    |> Enum.map(fn line ->
      %__MODULE__{
        kind: :attestation,
        identifier: identifier(line["number"]),
        term: details["query"],
        relation: :attests,
        scope: :lexeme,
        locator: line["number"] && "line #{line["number"]}",
        note: line["text"]
      }
    end)
  end

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
  One sentence, composed from the fields and nothing else.

  The only renderer. It names the identifier wherever there is one, because an
  identifier is what separates a reason from a claim: *tagged “Soldiers”* is a
  reader's impression and *tagged “Soldiers” (Q4991371)* is a fact anyone can go
  and check.
  """
  def describe(%__MODULE__{kind: :tag, relation: :exact} = reason),
    do:
      "Tagged #{quoted(reason.term)}#{parenthesis(reason.identifier)}, the concept this " <>
        scoped(reason) <> " refers to."

  def describe(%__MODULE__{kind: :tag, reached: reached} = reason) when is_binary(reached),
    do:
      "Related to #{quoted(reached)} through the tag #{quoted(reason.term)}#{parenthesis(reason.identifier)}."

  def describe(%__MODULE__{kind: :tag} = reason),
    do: "Reached through the tag #{quoted(reason.term)}#{parenthesis(reason.identifier)}."

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

  @doc "Every reason on one item, as one paragraph."
  def describe_all(reasons) when is_list(reasons),
    do: reasons |> Enum.map(&describe/1) |> Enum.join(" ")

  defp relation_word(:broader), do: "Broader-context"
  defp relation_word(:related), do: "Related"
  defp relation_word(_relation), do: "Direct"

  defp scoped(%__MODULE__{scope: :lexeme}), do: "word"
  defp scoped(%__MODULE__{}), do: "meaning"

  defp tagged(term) when is_binary(term) and term != "", do: " tagged #{quoted(term)}"
  defp tagged(_term), do: ""

  defp at(locator) when is_binary(locator) and locator != "", do: " at #{locator}"
  defp at(_locator), do: ""

  defp quoted(value) when is_binary(value), do: "“#{value}”"
  defp quoted(_value), do: "“it”"

  defp parenthesis(value) when is_binary(value) and value != "", do: " (#{value})"
  defp parenthesis(_value), do: ""
end
