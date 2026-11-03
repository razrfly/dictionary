defmodule DevilsDictionary.Curation.Runtime.EvidenceGuidance do
  @moduledoc """
  Candidate-specific inference guidance for the grounded whole-entry
  instructions: v7 and the comparison arms built on its evidence policy
  (#298 C3, C9). These schema descriptions are prompts, not semantic
  validation or permission to fetch additional fields. Earlier instruction
  schemas and stored choice/basis/receipt shapes stay intact.

  Guidance is activated by a whole-entry policy list, not by one literal
  instruction, so a control arm sees exactly the guidance v7 sees. A new
  grounded instruction joins the list under the same policy version.
  """

  @policy "evidence-guidance-v1"
  @instructions [
    "voltaire-whole-entry-v7",
    "generic-whole-entry-v1",
    "voltaire-whole-entry-v7-fixed-lead-v1"
  ]

  @doc "The instructions guided under `evidence-guidance-v1`."
  def instructions, do: @instructions

  @doc "The guidance policy version an instruction is rendered under, or nil."
  def policy(instruction) when instruction in @instructions, do: @policy
  def policy(_instruction), do: nil

  @doc "Render compact evidence scopes into the guided instructions' model-visible prompt."
  def visible(visible, %{"instruction_version" => instruction} = packet)
      when instruction in @instructions do
    rows = Map.new(packet["candidates"], &{&1["candidate_id"], &1})
    rules = Map.new(packet["candidates"], &{scope(&1), description(&1)})

    visible
    |> Map.put("evidence_rules", rules)
    |> Map.update!("candidates", fn candidates ->
      Enum.map(
        candidates,
        &Map.put(&1, "evidence_scope", scope(Map.fetch!(rows, &1["candidate_id"])))
      )
    end)
  end

  def visible(visible, _packet), do: visible

  defp scope(%{"kind" => "shelf", "shelf" => %{"shelf_kind" => kind}}), do: "shelf_" <> kind
  defp scope(%{"kind" => kind}), do: kind

  def annotate(schema, %{"instruction_version" => instruction} = packet)
      when instruction in @instructions do
    rows = Map.new(packet["candidates"], &{&1["candidate_id"], &1})
    schema = walk(schema, rows)
    leads = Enum.count(packet["candidates"], &(&1["kind"] in ["content", "sense_definition"]))

    # The decision's description is lead guidance: under a rule-fixed lead
    # (#298 C9) it says so, and otherwise it is v7's, word for word.
    description =
      if is_binary(packet["fixed_lead"]),
        do:
          "The lead is fixed by rule (fixed_lead): return lead null and decision select. Choose only optional records whose supplied fields support them; leave weak sections empty.",
        else:
          "#{leads} definition candidates are supplied. Evaluate them first: sense_definition needs no content entry. Select a suitable lead and omit weak extras; abstain only when definition evidence is irrelevant, unsafe or insufficient."

    put_in(schema, ["properties", "decision", "description"], description)
  end

  def annotate(schema, _packet), do: schema

  defp walk(value, rows) when is_list(value), do: Enum.map(value, &walk(&1, rows))

  defp walk(value, rows) when is_map(value) do
    value = Map.new(value, fn {key, child} -> {key, walk(child, rows)} end)

    case get_in(value, ["properties", "candidate_id", "enum"]) do
      [id] ->
        case rows[id] do
          nil -> value
          row -> put_in(value, ["properties", "reason", "description"], description(row))
        end

      _ ->
        value
    end
  end

  defp walk(value, _rows), do: value

  defp description(row) do
    basis =
      case row["kind"] do
        kind when kind in ["content", "sense_definition"] ->
          "Definition excerpt supplied: explain its meaning, not missing optional materials."

        "sense_quotation" ->
          "Quotation excerpt supplied: preserve its point; invent no author, genre or work."

        "claim" ->
          "Only the supplied claim representation is evidence, not a newly verified fact."

        "exemplar" ->
          "Use the supplied reviewed relationship/context, not an unseen depiction or passage."

        "work" ->
          "Catalog label only: title/creator/type/date do not establish unseen content."

        "shelf" ->
          case get_in(row, ["shelf", "shelf_kind"]) do
            "news" ->
              "News metadata only: a descriptive headline may support a modest connection; no article body is supplied."

            "images" ->
              "Image metadata only: a supplied descriptive caption may support its own words, not unseen imagery."

            "quotes" ->
              "Use only quotation words and creator actually supplied in the label."

            kind ->
              "#{kind} metadata only: no plot, themes, lyrics or passage is supplied."
          end
      end

    basis <>
      " Allowed meanings are routing eligibility, not proof of relevance. Title/name match alone is insufficient. Omit this choice rather than invent a reason."
  end
end
