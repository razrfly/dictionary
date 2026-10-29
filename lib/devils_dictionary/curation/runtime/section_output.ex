defmodule DevilsDictionary.Curation.Runtime.SectionOutput do
  @moduledoc "Versioned wire shape for one-call whole-entry selections; no separate storage or approval."
  alias DevilsDictionary.Curation.WholeEntry
  @instructions ["voltaire-whole-entry-v3", "voltaire-whole-entry-v4", "voltaire-whole-entry-v5"]
  @top ~w(decision lead selections abstain_reason)
  @choice ~w(candidate_id meaning_id reason quote)
  def enabled?(packet), do: packet["instruction_version"] in @instructions

  def schema(packet) do
    candidates = packet["candidates"]
    priority = packet["priority_candidates"]
    leads = Enum.filter(candidates, &(&1["kind"] in ["content", "sense_definition"]))

    leads =
      if priority == [], do: leads, else: Enum.filter(leads, &(&1["candidate_id"] in priority))

    sections =
      Map.new(WholeEntry.sections(), fn section ->
        rows = Enum.filter(candidates, &(WholeEntry.section(&1) == section))

        rows =
          if section == "definitions",
            do: Enum.reject(rows, &(&1["candidate_id"] in priority)),
            else: rows

        value =
          if section in ["examples", "quotes"] do
            %{
              "type" => "array",
              "maxItems" => min(2, length(rows)),
              "items" => if(rows == [], do: %{"type" => "null"}, else: choices(rows, true)),
              "uniqueItems" => true
            }
          else
            nullable(rows, true)
          end

        {section, value}
      end)

    %{
      "type" => "object",
      "additionalProperties" => false,
      "required" => @top,
      "properties" => %{
        "decision" => %{"type" => "string", "enum" => ["select", "abstain"]},
        "lead" => nullable(leads, false),
        "selections" => %{
          "type" => "object",
          "additionalProperties" => false,
          "required" => WholeEntry.sections(),
          "properties" => sections
        },
        "abstain_reason" => %{
          "anyOf" => [%{"type" => "null"}, %{"type" => "string", "maxLength" => 100}]
        }
      }
    }
  end

  defp nullable([], _), do: %{"type" => "null"}

  defp nullable(rows, highlight?),
    do: %{"anyOf" => [%{"type" => "null"}, choices(rows, highlight?)]}

  defp choices(rows, highlight?) do
    %{
      "anyOf" =>
        Enum.map(rows, fn row ->
          properties = %{
            "candidate_id" => %{"type" => "string", "enum" => [row["candidate_id"]]},
            "meaning_id" => %{"type" => "string", "enum" => row["allowed_meanings"]},
            "reason" => %{"type" => "string", "maxLength" => 100}
          }

          properties =
            if highlight?, do: Map.put(properties, "quote", %{"type" => "null"}), else: properties

          %{
            "type" => "object",
            "additionalProperties" => false,
            "required" => if(highlight?, do: @choice, else: @choice -- ["quote"]),
            "properties" => properties
          }
        end)
    }
  end

  @doc "Validate the entire new raw envelope, then canonically flatten; never repair or drop invalid choices."
  def normalize(decoded, packet) do
    if enabled?(packet), do: normalize_sections(decoded, packet), else: {:ok, decoded}
  end

  defp normalize_sections(decoded, packet) do
    with true <- is_map(decoded) and Enum.sort(Map.keys(decoded)) == Enum.sort(@top),
         sections when is_map(sections) <- decoded["selections"],
         true <- Enum.sort(Map.keys(sections)) == Enum.sort(WholeEntry.sections()) do
      candidates = Map.new(packet["candidates"], &{&1["candidate_id"], &1})

      {highlights, errors} =
        Enum.reduce(WholeEntry.sections(), {[], []}, fn section, {items, errors} ->
          case section_choices(sections[section], section) do
            {:ok, choices} ->
              problems =
                Enum.flat_map(choices, fn choice ->
                  cond do
                    Enum.sort(Map.keys(choice)) != Enum.sort(@choice) ->
                      [[section, "wrong_shape"]]

                    is_map(candidates[choice["candidate_id"]]) and
                        WholeEntry.section(candidates[choice["candidate_id"]]) != section ->
                      [[section, "wrong_section"]]

                    section == "definitions" and
                        choice["candidate_id"] in packet["priority_candidates"] ->
                      [[section, "lead_candidate_repeated"]]

                    true ->
                      []
                  end
                end)

              {items ++ choices, errors ++ problems}

            :error ->
              {items, errors ++ [[section, "wrong_shape"]]}
          end
        end)

      reason_errors =
        ([{"lead", decoded["lead"]}] ++ Enum.with_index(highlights, 1))
        |> Enum.map(fn
          {label, choice} when is_binary(label) -> {label, choice}
          {choice, index} -> {"highlight_#{index}", choice}
        end)
        |> Enum.flat_map(fn {label, choice} ->
          if is_map(choice) and is_binary(choice["reason"]) and
               String.length(choice["reason"]) > 100, do: [[label, "reason_too_long"]], else: []
        end)

      abstain_errors =
        if is_binary(decoded["abstain_reason"]) and String.length(decoded["abstain_reason"]) > 100,
          do: [["abstain_reason", "reason_too_long"]],
          else: []

      errors = errors ++ reason_errors ++ abstain_errors

      if errors == [],
        do:
          {:ok,
           %{
             "decision" => decoded["decision"],
             "lead" => decoded["lead"],
             "highlights" => highlights,
             "abstain_reason" => decoded["abstain_reason"]
           }},
        else: {:refused, errors}
    else
      _ -> {:refused, [["selections", "wrong_shape"]]}
    end
  end

  defp section_choices(value, section) when section in ["examples", "quotes"] do
    if is_list(value) and length(value) <= 2 and Enum.all?(value, &is_map/1),
      do: {:ok, value},
      else: :error
  end

  defp section_choices(nil, _), do: {:ok, []}
  defp section_choices(value, _) when is_map(value), do: {:ok, [value]}
  defp section_choices(_, _), do: :error
end
