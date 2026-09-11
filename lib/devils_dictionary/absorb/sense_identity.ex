defmodule DevilsDictionary.Absorb.SenseIdentity do
  @moduledoc """
  Deciding whether an incoming sense **is** a sense we already hold.

  The defect this exists to end, reproduced by the 7 September audit and again
  by the Gate 0 spike on the real Wiktionary `bank/noun/1` record: Wiktionary
  keys a sense by its **position** in a list. Delete one meaning from the middle
  and everything after it renumbers, so the row that held *"Money; profit."*
  silently comes to hold something else — and every quote, example and vote
  hanging off that id follows, with no foreign key violated anywhere.

  So for a source that keys a sense by where it sat, `senses.external_key` is
  provenance, never identity. Identity is matched on **content**: same word,
  same part of speech, same etymology number, and a gloss similar enough to be
  the same meaning reworded.

  ## The exception, and why it is not a loophole

  A source whose key is derived from an identifier *the source keeps stable* is
  the opposite case, and content matching there is not merely unnecessary — it
  is wrong. WordNet's `oewn-84481488-n#sequoia` names a synset and a member;
  the synset id is exactly what WordNet promises not to move. And its glosses
  are written to be near-neighbours: *sequoia* the tree and *sequoia* the wood
  differ by the two words "wood of", which is 0.79 similar and well past any
  threshold worth having. Matching those on content collapsed 194 synsets into
  their neighbours on the first full re-import, and left each survivor
  flip-flopping between two glosses — a new revision per pass, for ever.

  So `Absorb.Source.sense_key_stability/0` lets a source say which kind of key
  it has. `:positional` is the default and the assumption that costs nothing if
  it is wrong; `:stable` means the key is the identity and two different keys
  are two different meanings, however alike they read.

  ## The three outcomes

    * **matched** — one candidate scores at or above `strong/0` and beats the
      runner-up by more than `gap/0`. The existing identity is kept, and a new
      revision is written only if the text actually changed.
    * **new** — nothing comes close. A new identity, and nothing is disturbed.
    * **ambiguous** — either nothing reaches the threshold while something is
      close, or two candidates are within `gap/0` of each other. A
      `reconciliation_cases` row opens, the sense goes to `needs_review`, **no
      attachment moves and no id is reused**. Gate 0 measured this at 0.897 with
      a 0.000 gap between two candidates, where the tiebreak would otherwise
      have been the row id.

  ## Why the scoring is in Elixir

  `similarity/2` is a faithful reimplementation of `pg_trgm`'s: normalise, split
  into words, pad each word with two leading spaces and one trailing, take the
  set of trigrams, and divide the intersection by the union. Doing it here
  rather than in SQL means the policy is a pure function — unit-testable with no
  database, which is what row O3 asks of everything else in the absorb path, and
  it means one query per batch rather than one per incoming sense.

  `sense_identity_test.exs` asserts the two agree on a table of real glosses, so
  "faithful" is a checked claim rather than an intention.

  ## The thresholds

  0.62 and 0.05, calibrated on the spike's numbers: the reproduction's genuinely
  new sense scored 0.165, its true matches scored 1.000, and the ambiguous pair
  scored 0.897 apart by 0.000. They are deliberately not tuned to the last
  decimal — a threshold that only works on one corpus is a fit, not a policy —
  and moving one is a decision to record, not a constant to nudge.
  """

  @strong 0.62
  @gap 0.05

  @doc "A score at or above this is close enough to be the same meaning."
  def strong, do: @strong

  @doc "Two candidates within this of each other are too close to choose between."
  def gap, do: @gap

  @doc """
  Decides each incoming sense against the senses already held for its word.

  `incoming` is a list of `%{key:, gloss:, metadata:}`; `existing` is a list of
  `%{object_id:, external_key:, gloss:, metadata:, identity_state:}`.

  Returns one decision per incoming sense, in order:

      {:matched, object_id, score}
      {:new, nil}
      {:ambiguous, [{object_id, score}, ...], reason}

  An existing identity is claimed at most once per call: two incoming senses
  that both look like one old meaning cannot both become it, and the loser is
  ambiguous rather than silently new.

  `stability` is the source's answer to `Absorb.Source.sense_key_stability/0`.
  Under `:stable` the key decides and nothing is scored: the same key is the
  same meaning, a key not held before is new, and two different keys are never
  the same identity. `claimed` carries identities already reserved by unchanged
  rows in the same materialization group.
  """
  def decide(incoming, existing, stability \\ :positional, claimed \\ MapSet.new())

  def decide(incoming, existing, :stable, claimed) do
    held = Map.new(existing, &{to_string(&1[:external_key]), &1})

    {decisions, _claimed} =
      Enum.map_reduce(incoming, claimed, fn sense, claimed ->
        case Map.get(held, to_string(sense[:key])) do
          nil ->
            {{:new, nil}, claimed}

          row ->
            if MapSet.member?(claimed, row.object_id) do
              {{:ambiguous, [{row.object_id, 1.0}], :already_claimed}, claimed}
            else
              {{:matched, row.object_id, 1.0}, MapSet.put(claimed, row.object_id)}
            end
        end
      end)

    decisions
  end

  def decide(incoming, existing, _positional, initially_claimed) do
    prepared = Enum.map(existing, &{&1, trigrams(&1[:gloss])})

    {decisions, _claimed} =
      Enum.map_reduce(incoming, initially_claimed, fn sense, claimed ->
        available =
          Enum.reject(prepared, fn {row, _t} -> MapSet.member?(claimed, row.object_id) end)

        case score(sense, available) do
          {:matched, object_id, s} -> {{:matched, object_id, s}, MapSet.put(claimed, object_id)}
          {:new, nil} -> {claimed_decision(sense, prepared, claimed), claimed}
          other -> {other, claimed}
        end
      end)

    decisions
  end

  # If the only convincing identity has already been taken, the row is not a
  # genuinely new meaning. Surface the collision for review so the caller can
  # retain the row's previous identity instead of either sharing the winner or
  # minting a duplicate.
  defp claimed_decision(sense, prepared, claimed) do
    claimed_rows =
      Enum.filter(prepared, fn {row, _t} -> MapSet.member?(claimed, row.object_id) end)

    case score(sense, claimed_rows) do
      {:matched, object_id, similarity} ->
        {:ambiguous, [{object_id, similarity}], :already_claimed}

      {:ambiguous, candidates, _reason} ->
        {:ambiguous, candidates, :already_claimed}

      {:new, nil} = decision ->
        decision
    end
  end

  # Etymology number is a hard filter, not a score: Wiktionary's four `bank`
  # etymologies are four different words that happen to be spelled alike, and a
  # gloss from one is never a rewording of a gloss from another.
  defp score(sense, prepared) do
    incoming = trigrams(sense[:gloss])

    scored =
      prepared
      |> Enum.filter(fn {row, _t} -> compatible?(sense, row) end)
      |> Enum.map(fn {row, tri} -> {row.object_id, jaccard(incoming, tri)} end)
      |> Enum.sort_by(fn {id, s} -> {-s, id} end)

    case scored do
      [] ->
        {:new, nil}

      [{id, best} | rest] ->
        runner_up =
          case rest do
            [{_, second} | _] -> second
            [] -> 0.0
          end

        cond do
          best >= @strong and best - runner_up > @gap ->
            {:matched, id, best}

          best >= @strong ->
            # Picking the higher would have been decided by the row id.
            {:ambiguous, Enum.take(scored, 3), :too_close}

          best >= @strong / 2 ->
            {:ambiguous, Enum.take(scored, 3), :below_threshold}

          true ->
            {:new, nil}
        end
    end
  end

  defp compatible?(sense, row) do
    etymology(sense[:metadata]) == etymology(row[:metadata])
  end

  defp etymology(nil), do: nil
  defp etymology(metadata), do: metadata["etymology_number"] || metadata[:etymology_number]

  @doc """
  `pg_trgm`'s `similarity/2`, reimplemented so the policy is a pure function.

  Returns 0.0 when either side is empty, and 1.0 for identical text.
  """
  def similarity(a, b), do: jaccard(trigrams(a), trigrams(b))

  defp jaccard(a, b) do
    cond do
      MapSet.size(a) == 0 and MapSet.size(b) == 0 ->
        0.0

      MapSet.size(a) == 0 or MapSet.size(b) == 0 ->
        0.0

      true ->
        shared = MapSet.size(MapSet.intersection(a, b))
        union = MapSet.size(MapSet.union(a, b))
        Float.round(shared / union, 6)
    end
  end

  @doc """
  The trigram set of a string, `pg_trgm`-style.

  Lowercased, non-alphanumerics treated as separators, each word padded with two
  leading spaces and one trailing — which is what makes a short word share
  trigrams with a longer one that starts the same way.
  """
  def trigrams(nil), do: MapSet.new()

  def trigrams(text) do
    text
    |> String.downcase()
    |> String.replace(~r/[^\p{L}\p{N}]+/u, " ")
    |> String.split(" ", trim: true)
    |> Enum.flat_map(&word_trigrams/1)
    |> MapSet.new()
  end

  defp word_trigrams(word) do
    padded = "  " <> word <> " "
    graphemes = String.graphemes(padded)

    graphemes
    |> Enum.chunk_every(3, 1, :discard)
    |> Enum.map(&Enum.join/1)
  end
end
