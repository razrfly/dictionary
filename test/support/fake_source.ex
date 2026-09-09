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

    # `senses` lets a test say what the source publishes *this* time, so a
    # second run can publish less than the first — which is the only way to
    # exercise reconciliation through the real import path rather than by
    # calling `reconcile/2` directly.
    senses =
      case raw["senses"] do
        nil ->
          [
            %{
              key: "fake-#{lemma}",
              lexeme: {"en", lemma, pos},
              source_id: source_id,
              source_record_id: Map.get(record, :id),
              gloss: raw["gloss"] || "a gloss",
              group_key: "fake-group"
            }
          ]

        list ->
          Enum.map(list, fn sense ->
            %{
              key: sense["key"],
              lexeme: {"en", lemma, pos},
              source_id: source_id,
              source_record_id: Map.get(record, :id),
              gloss: sense["gloss"],
              group_key: "fake-group"
            }
          end)
      end

    # `also_lexeme` declares a word without saying anything about it — the shape
    # a scoped Wiktionary batch produces when one record's linkage names a word
    # another record in the same batch also touches. It must not come out marked
    # enriched.
    extra =
      case raw["also_lexeme"] do
        nil -> []
        other -> [%{key: {"en", other, pos}, origin_source_id: source_id}]
      end

    {:ok,
     %{
       lexemes:
         [
           %{
             key: {"en", lemma, pos},
             origin_source_id: source_id,
             forms: raw["forms"] || [],
             pronunciations: raw["pronunciations"] || [],
             etymology: raw["etymology"],
             etymology_source_id: source_id
           }
         ] ++ extra,
       senses: senses,
       # `content_key` makes two records name **one** content item, the shape
       # Wikipedia produces once an article has a canonical publication identity
       # and six probes redirect to it.
       entries:
         case raw["content_key"] do
           nil ->
             []

           key ->
             [
               %{
                 key: key,
                 kind: :article,
                 headword: lemma,
                 body: raw["body"] || "a body",
                 source_id: source_id,
                 source_record_id: Map.get(record, :id)
               }
             ]
         end,
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
