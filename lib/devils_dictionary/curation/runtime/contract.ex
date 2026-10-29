defmodule DevilsDictionary.Curation.Runtime.Contract do
  @moduledoc """
  The output contract of one call (#195, C1–C3): the JSON schema sent as
  Ollama's `format`, and the independent validation of what comes back.

  Structured output constrains the tokens; it proves nothing about the
  evidence. Syntactically valid JSON is a *claim*. `validate/3` checks it,
  collecting every problem rather than stopping at the first:

    * **Bounds and shape (C1).** The size is within `max_output_bytes`, the
      response parses, it has exactly the schema's keys and types, and
      decision and content agree. It has no tool calls, and was not cut short
      by the output limit.
    * **References (C2).** Every `candidate_id` is in the packet and used
      once, every `meaning_id` is allowed for its candidate, there are at most
      three highlights, and every quote is an exact substring of its
      candidate's excerpt. A `work` or an `exemplar` has no excerpt, only a
      label, so a quote on one is refused (`quote_not_allowed`, #262).
    * **Evidence and policy now (C3).** Every selected item passes
      `Curation.Eligibility`, and the lead passes `Curation.LeadRule`: Bierce
      first, among definitions on the page.

  The result keeps ids, meanings, reasons and each quote as a hash and a range
  of its excerpt, never the quoted words. A model's tool call is refused,
  never executed. Emitted reasoning is measured as a length and discarded.
  """

  alias DevilsDictionary.Curation.{Digest, LeadRule}
  alias DevilsDictionary.Curation.Runtime.{Endpoint, Packet, SectionOutput}

  @version "selection-output-v1"
  @max_reason_chars 280
  @max_quote_chars 400

  def version, do: @version
  def version("voltaire-whole-entry-v3"), do: "selection-output-v4"
  def version("voltaire-whole-entry-v2"), do: "selection-output-v3"
  def version("voltaire-whole-entry-v1"), do: "selection-output-v2"
  def version(_), do: @version

  @doc "The JSON schema for Ollama's `format`."
  def schema(packet \\ %{}) do
    if SectionOutput.enabled?(packet), do: SectionOutput.schema(packet), else: flat_schema(packet)
  end

  defp flat_schema(packet) do
    max = if DevilsDictionary.Curation.WholeEntry.packet?(packet), do: 12, else: 3
    reason = %{"type" => "string", "maxLength" => @max_reason_chars}

    choice = fn extra ->
      %{
        "type" => "object",
        "properties" =>
          Map.merge(
            %{
              "candidate_id" => %{"type" => "string"},
              "meaning_id" => %{"type" => "string"},
              "reason" => reason
            },
            extra
          ),
        "required" => ["candidate_id", "meaning_id", "reason"] ++ Map.keys(extra),
        "additionalProperties" => false
      }
    end

    %{
      "type" => "object",
      "properties" => %{
        "decision" => %{"type" => "string", "enum" => ["select", "abstain"]},
        "lead" => %{"anyOf" => [%{"type" => "null"}, choice.(%{})]},
        "highlights" => %{
          "type" => "array",
          "maxItems" => max,
          "items" =>
            choice.(%{
              "quote" =>
                if(packet["instruction_version"] == "voltaire-whole-entry-v2",
                  do: %{"type" => "null"},
                  else: %{
                    "anyOf" => [
                      %{"type" => "null"},
                      %{"type" => "string", "maxLength" => @max_quote_chars}
                    ]
                  }
                )
            })
        },
        "abstain_reason" => %{"anyOf" => [%{"type" => "null"}, reason]}
      },
      "required" => ["decision", "lead", "highlights", "abstain_reason"],
      "additionalProperties" => false
    }
  end

  @doc """
  Validates one `/api/chat` response against a frozen packet. Returns `{:ok,
  %{outcome: :accepted | :abstained, result: map, observed: map}}` or
  `{:refused, reasons, observed}`. `observed` is what the response said about
  itself, such as the length of emitted reasoning and the done reason, for
  the attempt's metrics.
  """
  def validate(response, %{packet: packet}, opts \\ []) do
    message = response["message"] || %{}
    content = message["content"] || ""
    observed = observed(response, message)

    with :ok <- no_tools(message),
         :ok <- not_truncated(response),
         :ok <- bounded(content, opts),
         {:ok, decoded} <- decode(content),
         {:ok, decoded} <- SectionOutput.normalize(decoded, packet),
         :ok <- shape(decoded, packet) do
      # `registry: false` is the smoke call's fixed packet, which names no
      # registry rows: shape and references only.
      evidence = if opts[:registry] == false, do: [], else: evidence(decoded, packet)

      case references(decoded, packet) ++ evidence do
        [] ->
          {:ok, accepted(decoded, packet, observed)}

        reasons ->
          {:refused, reasons, Map.put(observed, "refused_shape", refused_shape(decoded, packet))}
      end
    else
      {:refused, reasons} -> {:refused, reasons, observed}
    end
  end

  defp observed(response, message) do
    %{
      "done_reason" => safe_done_reason(response["done_reason"]),
      "thinking_chars" => String.length(message["thinking"] || ""),
      "output_bytes" => byte_size(message["content"] || "")
    }
  end

  defp safe_done_reason(reason) when reason in [nil, "stop", "length", "load", "unload"],
    do: reason

  defp safe_done_reason(reason), do: "unknown:" <> Digest.term(reason)

  # What a well-shaped but refused answer pointed at, so the refusal can be
  # read: the decision and the ids it named, each id cut to 24 characters.
  # Never its reasons or quote text; only whether it gave a quote.
  defp refused_shape(decoded, packet) do
    known =
      Enum.map(packet["candidates"], & &1["candidate_id"]) ++
        Enum.map(packet["meanings"], & &1["meaning_id"])

    id = fn value -> if value in known, do: value, else: "unknown-id:" <> Digest.sha256(value) end
    pair = fn choice -> [id.(choice["candidate_id"]), id.(choice["meaning_id"])] end

    %{
      "decision" => decoded["decision"],
      "lead" => decoded["lead"] && pair.(decoded["lead"]),
      "highlights" =>
        Enum.map(decoded["highlights"], fn h -> pair.(h) ++ [is_binary(h["quote"])] end)
    }
  end

  defp no_tools(%{"tool_calls" => [_ | _]}), do: {:refused, [["response", "tool_call_refused"]]}
  defp no_tools(_message), do: :ok

  defp not_truncated(%{"done_reason" => "length"}),
    do: {:refused, [["response", "output_truncated"]]}

  defp not_truncated(_response), do: :ok

  defp bounded(content, opts) do
    if byte_size(content) <= Endpoint.get(:max_output_bytes, opts),
      do: :ok,
      else: {:refused, [["response", "output_too_large"]]}
  end

  defp decode(content) do
    case Jason.decode(content) do
      {:ok, %{} = decoded} -> {:ok, decoded}
      {:ok, _other} -> {:refused, [["response", "wrong_shape"]]}
      {:error, _} -> {:refused, [["response", "malformed_json"]]}
    end
  end

  # ── C1: exactly the schema's shape ──────────────────────────────────────────

  @top ~w(abstain_reason decision highlights lead)
  @choice ~w(candidate_id meaning_id reason)
  @highlight ~w(candidate_id meaning_id quote reason)

  defp shape(decoded, packet) do
    max = if DevilsDictionary.Curation.WholeEntry.packet?(packet), do: 12, else: 3

    decision =
      if decoded["decision"] in ["select", "abstain"], do: [], else: [["decision", "wrong_shape"]]

    problems =
      exact_keys(decoded, @top, "response") ++
        decision ++
        lead_shape(decoded["lead"]) ++
        highlights_shape(decoded["highlights"], max) ++
        nullable_text(decoded["abstain_reason"], "abstain_reason") ++
        consistent(decoded)

    if problems == [], do: :ok, else: {:refused, problems}
  end

  defp exact_keys(%{} = map, keys, where) do
    if Enum.sort(Map.keys(map)) == keys, do: [], else: [[where, "wrong_shape"]]
  end

  defp exact_keys(_value, _keys, where), do: [[where, "wrong_shape"]]

  defp lead_shape(nil), do: []
  defp lead_shape(%{} = lead), do: exact_keys(lead, @choice, "lead") ++ choice_types(lead, "lead")
  defp lead_shape(_lead), do: [["lead", "wrong_shape"]]

  defp highlights_shape(list, max) when is_list(list) do
    over = if length(list) > max, do: [["highlights", "too_many_highlights"]], else: []

    over ++
      Enum.flat_map(Enum.with_index(list, 1), fn {h, n} ->
        where = "highlight_#{n}"

        exact_keys(h, @highlight, where) ++
          choice_types(h, where) ++ nullable_text(h["quote"], where, @max_quote_chars)
      end)
  end

  defp highlights_shape(_value, _max), do: [["highlights", "wrong_shape"]]

  defp choice_types(%{} = choice, where) do
    ids =
      if is_binary(choice["candidate_id"]) and is_binary(choice["meaning_id"]),
        do: [],
        else: [[where, "wrong_shape"]]

    ids ++ reason_text(choice["reason"], where)
  end

  defp choice_types(_value, where), do: [[where, "wrong_shape"]]

  defp reason_text(reason, where) when is_binary(reason) do
    cond do
      String.trim(reason) == "" -> [[where, "reason_missing"]]
      String.length(reason) > @max_reason_chars -> [[where, "reason_too_long"]]
      true -> []
    end
  end

  defp reason_text(_reason, where), do: [[where, "wrong_shape"]]

  defp nullable_text(value, where, max \\ @max_reason_chars)
  defp nullable_text(nil, _where, _max), do: []

  defp nullable_text(value, where, max) when is_binary(value),
    do: if(String.length(value) > max, do: [[where, "text_too_long"]], else: [])

  defp nullable_text(_value, where, _max), do: [[where, "wrong_shape"]]

  defp consistent(%{"decision" => "abstain"} = d) do
    if is_nil(d["lead"]) and d["highlights"] == [] and is_binary(d["abstain_reason"]) and
         String.trim(d["abstain_reason"]) != "",
       do: [],
       else: [["decision", "decision_inconsistent"]]
  end

  defp consistent(%{"decision" => "select"} = d) do
    if is_nil(d["abstain_reason"]) and (not is_nil(d["lead"]) or d["highlights"] not in [nil, []]),
      do: [],
      else: [["decision", "decision_inconsistent"]]
  end

  defp consistent(_decoded), do: []

  # ── C2: every reference from the packet ───────────────────────────────────

  defp choices(decoded) do
    lead = if decoded["lead"], do: [{"lead", decoded["lead"]}], else: []

    highlights =
      decoded["highlights"]
      |> Enum.with_index(1)
      |> Enum.map(fn {h, n} -> {"highlight_#{n}", h} end)

    lead ++ highlights
  end

  defp references(decoded, packet) do
    candidates = Map.new(packet["candidates"], &{&1["candidate_id"], &1})
    chosen = choices(decoded)
    ids = Enum.map(chosen, fn {_where, c} -> c["candidate_id"] end)

    duplicates =
      if length(Enum.uniq(ids)) == length(ids),
        do: [],
        else: [["selection", "duplicate_candidate"]]

    DevilsDictionary.Curation.WholeEntry.validate(decoded, packet) ++
      duplicates ++
      Enum.flat_map(chosen, fn {where, choice} ->
        case candidates[choice["candidate_id"]] do
          nil ->
            [[where, "unknown_candidate"]]

          candidate ->
            meaning(where, choice, candidate) ++
              quote_for_version(where, choice, candidate, packet) ++
              lead_kind(where, candidate, packet)
        end
      end)
  end

  defp meaning(where, choice, candidate) do
    if choice["meaning_id"] in candidate["allowed_meanings"],
      do: [],
      else: [[where, "meaning_not_allowed"]]
  end

  defp quote_for_version(where, choice, candidate, packet) do
    if packet["instruction_version"] in ["voltaire-whole-entry-v2", "voltaire-whole-entry-v3"] and
         not is_nil(choice["quote"]),
       do: [[where, "quote_not_allowed"]],
       else: quote_problem(where, choice, candidate)
  end

  defp quote_problem(_where, %{"quote" => nil}, _candidate), do: []

  defp quote_problem(where, %{"quote" => quote}, %{"kind" => kind})
       when is_binary(quote) and kind in ["work", "exemplar", "claim", "shelf"],
       do: [[where, "quote_not_allowed"]]

  defp quote_problem(where, %{"quote" => quote}, candidate) when is_binary(quote) do
    if quote != "" and is_binary(candidate["excerpt"]) and
         String.contains?(candidate["excerpt"], quote),
       do: [],
       else: [[where, "fabricated_quote"]]
  end

  defp quote_problem(_where, _choice, _candidate), do: []

  defp lead_kind("lead", %{"kind" => "content"}, _packet), do: []

  defp lead_kind("lead", %{"kind" => "sense_definition"}, %{
         "packet_version" => "runtime-packet-v4"
       }),
       do: []

  defp lead_kind("lead", _candidate, _packet), do: [["lead", "lead_not_a_definition"]]
  defp lead_kind(_where, _candidate, _packet), do: []

  # ── C3: the evidence, and the lead rule, now ──────────────────────────────

  defp evidence(decoded, packet) do
    candidates = Map.new(packet["candidates"], &{&1["candidate_id"], &1})
    meanings = Map.new(packet["meanings"], &{&1["meaning_id"], &1})
    ids = get_in(packet, ["target", "lexeme_ids"])

    # Only well-referenced choices reach the registry; the rest were refused
    # above for what they named.
    items =
      Enum.flat_map(choices(decoded), fn {where, choice} ->
        candidate = candidates[choice["candidate_id"]]
        meaning = meanings[choice["meaning_id"]]

        if candidate && meaning && choice["meaning_id"] in candidate["allowed_meanings"],
          do: [{where, candidate, meaning}],
          else: []
      end)

    eligibility =
      Enum.flat_map(items, fn {where, candidate, meaning} ->
        case Packet.check(candidate, meaning, ids) do
          :ok -> []
          {:error, reason} -> [[where, to_string(reason)]]
        end
      end)

    eligibility ++ lead_rule(decoded, candidates, ids)
  end

  # The lead rule holds whenever something is selected; an abstention
  # proposes no arrangement, so there is nothing for it to hold on.
  defp lead_rule(%{"decision" => "abstain"}, _candidates, _ids), do: []

  defp lead_rule(decoded, candidates, ids) do
    lead_object =
      case decoded["lead"] do
        %{"candidate_id" => id} ->
          case candidates[id] do
            %{"kind" => "sense_definition", "sense_revision_id" => rid} ->
              {:sense_definition, rid}

            candidate ->
              candidate && candidate["object_id"]
          end

        _ ->
          nil
      end

    unknown_lead? = match?(%{"candidate_id" => _}, decoded["lead"]) and is_nil(lead_object)

    if unknown_lead? do
      []
    else
      case LeadRule.check(ids, lead_object) do
        {:ok, _rule} -> []
        {:error, reason} -> [["lead", to_string(reason)]]
      end
    end
  end

  # ── the result kept ──────────────────────────────────────────────────────

  defp accepted(decoded, packet, observed) do
    candidates = Map.new(packet["candidates"], &{&1["candidate_id"], &1})

    keep = fn choice ->
      base = Map.take(choice, ["candidate_id", "meaning_id", "reason"])
      fields = Enum.flat_map(packet["candidates"], &(&1["expiring_text"] || []))
      marker = DevilsDictionary.Curation.ProviderText.match(base["reason"], fields)

      base =
        if marker,
          do: base |> Map.put("reason", nil) |> Map.put("reason_withheld", marker),
          else: base

      case choice["quote"] do
        quote when is_binary(quote) ->
          excerpt = candidates[choice["candidate_id"]]["excerpt"]
          {start, _} = :binary.match(excerpt, quote)

          Map.put(base, "quote", %{
            "sha256" => Digest.sha256(quote),
            "byte_offset" => start,
            "byte_length" => byte_size(quote)
          })

        _ ->
          base
      end
    end

    result = %{
      "contract" => version(packet["instruction_version"]),
      "decision" => decoded["decision"],
      "lead" => decoded["lead"] && keep.(decoded["lead"]),
      "highlights" => Enum.map(decoded["highlights"], keep),
      "abstain_reason" => decoded["abstain_reason"]
    }

    fields = Enum.flat_map(packet["candidates"], &(&1["expiring_text"] || []))
    marker = DevilsDictionary.Curation.ProviderText.match(result["abstain_reason"], fields)

    result =
      if marker,
        do:
          result |> Map.put("abstain_reason", nil) |> Map.put("abstain_reason_withheld", marker),
        else: result

    outcome = if decoded["decision"] == "abstain", do: :abstained, else: :accepted
    %{outcome: outcome, result: result, observed: observed}
  end
end
