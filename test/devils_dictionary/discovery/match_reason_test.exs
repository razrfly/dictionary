defmodule DevilsDictionary.Discovery.MatchReasonTest do
  @moduledoc """
  One struct and one renderer for every reason a result is on a page (K3 of
  #109). Each case here is a sentence a reader sees, and every one of them was
  composed somewhere else before: two branches in `Culture.match_detail/2`, a
  sentence built in `Artworks.suggestions/2`, and a relation word prefixed onto
  it by `Artwork.card`.
  """

  use ExUnit.Case, async: true

  alias DevilsDictionary.Discovery.MatchReason

  describe "from_result/2 — what a provider wrote, read back" do
    test "a Met tag whose QID is the sense's own names the tag and the QID" do
      assert [reason] =
               MatchReason.from_result(
                 %{
                   "kind" => "tag",
                   "query" => "soldier",
                   "tags" => [
                     %{
                       "term" => "Soldiers",
                       "qid" => "Q4991371",
                       "relation" => "exact",
                       "entity_label" => "soldier"
                     }
                   ]
                 },
                 "soldier"
               )

      assert reason.kind == :tag
      assert reason.identifier == "Q4991371"
      assert reason.term == "Soldiers"
      assert reason.relation == :exact
      assert reason.scope == :sense

      assert MatchReason.describe(reason) ==
               "Tagged “Soldiers” (Q4991371), the concept this meaning refers to."
    end

    test "a broader tag names the narrower thing that carried it and what it reached" do
      assert [reason] =
               MatchReason.from_result(
                 %{
                   "tags" => [
                     %{
                       "term" => "World War I",
                       "qid" => "Q361",
                       "relation" => "broader",
                       "entity_qid" => "Q198",
                       "entity_label" => "War"
                     }
                   ]
                 },
                 "war"
               )

      assert reason.relation == :broader
      assert reason.reached == "War"

      assert MatchReason.describe(reason) ==
               "Related to “War” through the tag “World War I” (Q361)."
    end

    test "a Commons depiction names what the file depicts and its QID, as one meaning's" do
      assert [reason] =
               MatchReason.from_result(
                 %{
                   "kind" => "depiction",
                   "depicts" => [
                     %{
                       "qid" => "Q4991371",
                       "relation" => "exact",
                       "entity_qid" => "Q4991371",
                       "entity_label" => "soldier"
                     }
                   ]
                 },
                 "soldier"
               )

      assert reason.kind == :depiction
      assert reason.identifier == "Q4991371"
      assert reason.relation == :exact
      assert reason.scope == :sense
      assert reason.locator == "depicts Q4991371"

      assert MatchReason.describe(reason) == "Direct depiction of “soldier” (Q4991371)."
    end

    test "a CineGraph keyword names the keyword and its TMDb id" do
      assert [reason] =
               MatchReason.from_result(
                 %{"kind" => "keyword", "keywords" => [%{"tmdbId" => 273_967, "name" => "war"}]},
                 "war"
               )

      assert reason.kind == :keyword
      assert reason.identifier == "273967"
      assert reason.locator == "keyword 273967"

      assert MatchReason.describe(reason) ==
               "Matched the keyword “war” (273967) for this term."
    end

    test "every matched keyword is its own fact, one sentence each" do
      reasons =
        MatchReason.from_result(
          %{
            "keywords" => [
              %{"tmdbId" => 1, "name" => "war"},
              %{"tmdbId" => 2, "name" => "warfare"}
            ]
          },
          "war"
        )

      assert length(reasons) == 2

      assert MatchReason.describe_all(reasons) ==
               "Matched the keyword “war” (1) for this term. " <>
                 "Matched the keyword “warfare” (2) for this term."
    end

    test "a text attestation says the work uses the word, never that it is about it" do
      assert [reason] =
               MatchReason.from_result(
                 %{"query" => "war", "lines" => [%{"number" => 12, "text" => "the dogs of war"}]},
                 "war"
               )

      assert reason.relation == :attests
      assert reason.note == "the dogs of war"
      assert MatchReason.describe(reason) == "Uses “war” at line 12."
    end

    test "an attestation cites the locator the provider named, or the line, or nothing" do
      # Before #116 Phase 1 the locator was hardcoded as `"line N"`, and Open
      # Library left its number empty rather than call a page a line.
      assert [page] =
               MatchReason.from_result(
                 %{
                   "query" => "war",
                   "lines" => [%{"number" => nil, "locator" => "page 12", "text" => "of war"}]
                 },
                 "war"
               )

      assert page.locator == "page 12"
      assert page.identifier == "page 12"
      assert MatchReason.describe(page) == "Uses “war” at page 12."

      # A locator beats a number when both are present: the provider said
      # where, and the line form is only the fallback.
      assert [both] =
               MatchReason.from_result(
                 %{
                   "query" => "war",
                   "lines" => [%{"number" => 3, "locator" => "stanza 2", "text" => "war"}]
                 },
                 "war"
               )

      assert both.locator == "stanza 2"
      assert both.identifier == "3"

      assert [none] =
               MatchReason.from_result(
                 %{"query" => "war", "lines" => [%{"number" => nil, "text" => "of war"}]},
                 "war"
               )

      assert none.locator == nil
      assert MatchReason.describe(none) == "Uses “war”."
    end

    test "a provider that named no reason is not given one" do
      assert [reason] = MatchReason.from_result(%{"kind" => "keyword"}, "war")
      assert reason.kind == :query
      assert MatchReason.describe(reason) == "The provider returned this result for “war”."
    end

    test "evidence/1 folds the kinds into the three classes the content-type table admits" do
      assert MatchReason.evidence(%MatchReason{kind: :tag}) == :identity
      assert MatchReason.evidence(%MatchReason{kind: :depiction}) == :identity
      assert MatchReason.evidence(%MatchReason{kind: :gene}) == :identity
      assert MatchReason.evidence(%MatchReason{kind: :keyword}) == :identity
      assert MatchReason.evidence(%MatchReason{kind: :attestation}) == :attestation
      assert MatchReason.evidence(%MatchReason{kind: :query}) == :query
    end

    test "a search result is called one only on a shelf that admits it (M6 of #116)" do
      [reason] = MatchReason.from_result(%{}, "war")

      assert MatchReason.describe(reason, [:identity, :query]) ==
               "Search result for “war”, ranked by the provider and not matched on an identifier."

      # Anywhere else the empty reason keeps the sentence that prompts a fix.
      assert MatchReason.describe(reason, [:identity]) ==
               "The provider returned this result for “war”."

      # And every other kind reads the same whichever shelf it is on.
      [tag] =
        MatchReason.from_result(
          %{"tags" => [%{"term" => "Soldiers", "qid" => "Q4991371", "relation" => "exact"}]},
          "soldier"
        )

      assert MatchReason.describe(tag, [:identity, :query]) == MatchReason.describe(tag)

      assert MatchReason.describe_all([tag, reason], [:identity, :query]) ==
               MatchReason.describe(tag) <>
                 " Search result for “war”, ranked by the provider and not matched on an identifier."
    end

    test "a malformed tag or keyword is not a reason" do
      details = %{
        "tags" => [%{"term" => "Soldiers"}, "not a map"],
        "keywords" => [%{"tmdbId" => 1, "name" => ""}]
      }

      assert [%MatchReason{kind: :query}] = MatchReason.from_result(details, "war")
      assert [%MatchReason{kind: :query}] = MatchReason.from_result(nil, "war")
    end
  end

  describe "from_candidate/1 — what a committed corpus and the encyclopedia agree on" do
    test "a depicted QID equal to a sense's entity is a direct depiction" do
      reason = MatchReason.from_candidate(depiction(:sense, "direct"))

      assert reason.kind == :depiction
      assert reason.identifier == "Q198"
      assert reason.scope == :sense
      assert reason.locator == "The Met depiction Q198"

      assert MatchReason.describe(reason) ==
               "Direct depiction of “War” (Q198) tagged “war”."
    end

    test "a word-level link says so rather than implying a meaning" do
      reason = MatchReason.from_candidate(depiction(:lexeme, "related"))

      assert reason.scope == :lexeme

      assert MatchReason.describe(reason) ==
               "Related depiction of “War” (Q198), matched to the word and not to this meaning."
    end

    test "an Artsy gene assignment names the gene" do
      candidate = %{
        match_type: "related",
        match_reason: %{
          provider: "Artsy",
          kind: "direct_gene_assignment",
          gene_id: "conflict",
          gene_name: "Conflict",
          locator: "Artsy direct gene conflict",
          note: nil
        }
      }

      reason = MatchReason.from_candidate(candidate)

      assert reason.kind == :gene
      assert reason.identifier == "conflict"
      assert MatchReason.describe(reason) == "Related Artsy gene “Conflict”."
    end
  end

  defp depiction(scope, match_type) do
    %{
      match_type: match_type,
      match_reason: %{
        provider: "The Met",
        kind: "depicted_qid",
        qid: "Q198",
        term: "war",
        entity_label: "War",
        scope: scope,
        locator: "The Met depiction Q198",
        note: "The catalog records this work as depicting Q198."
      }
    }
  end
end
