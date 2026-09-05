defmodule DevilsDictionary.FakeSource do
  @moduledoc """
  A source that exists only to exercise the `Materializer` in isolation.

  `materialize/1` reads its instructions out of the record's `raw`, so a test
  can ask for a well-formed output or a poisoned one without needing a real
  dump.
  """

  @behaviour DevilsDictionary.Absorb.Source

  @impl true
  def slug, do: "fake"

  @impl true
  def rate_limit_ms, do: 0

  @impl true
  def trim(raw), do: raw

  @impl true
  def materialize(%{raw: %{"mode" => "poison"} = raw, source_id: source_id}) do
    {:ok, out} =
      materialize(%{raw: Map.put(raw, "mode", "ok"), source_id: source_id, id: raw["record_id"]})

    # A NOT NULL violation deep inside the writes: the record itself is fine,
    # so only an atomic materializer prevents half of it landing.
    {:ok, %{out | senses: Enum.map(out.senses, &Map.put(&1, :source_id, nil))}}
  end

  def materialize(%{raw: raw, source_id: source_id} = record) do
    lemma = raw["lemma"]
    pos = raw["pos"] || "noun"

    {:ok,
     %{
       lexemes: [%{key: {"en", lemma, pos}, origin_source_id: source_id}],
       senses: [
         %{
           key: "fake-#{lemma}",
           lexeme: {"en", lemma, pos},
           source_id: source_id,
           source_record_id: Map.get(record, :id),
           gloss: raw["gloss"] || "a gloss",
           group_key: "fake-group"
         }
       ],
       entries: [],
       relations: [
         %{
           source_id: source_id,
           from_lexeme: {"en", lemma, pos},
           from_sense: "fake-#{lemma}",
           to_lemma: raw["to_lemma"] || "thing",
           to_pos: "noun",
           type: :hypernym
         }
       ],
       concepts: [],
       links: []
     }}
  end
end
