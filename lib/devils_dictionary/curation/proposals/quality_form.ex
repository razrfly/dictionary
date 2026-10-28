defmodule DevilsDictionary.Curation.Proposals.QualityForm do
  @moduledoc """
  The quality form, `quality-form-v1` (#253 §10, #264 R11.5): the owner's
  judgment of a proposal, the deliverable of the five-proposal baseline.

  One entry per proposal item (the lead and each highlight, carried items
  included), each with five yes/no answers:

    * `relevant`: relevant to the word;
    * `correct_meaning`: the meaning it is given is right;
    * `reason_useful`: its reason is useful to a reader;
    * `not_duplicate`: not a duplicate of the lead or another highlight;
    * `attribution_correct`: who it is attributed to is right;

  and one free note for the whole proposal. It is stored once, on the
  proposal row, with the reviewer and the time.

  It is required **complete** (every item, every answer a yes or a no) for
  Take and Edit-publish, and may be complete or absent on Dismiss: a
  partial form is refused. A proposal counts toward #253 §10's five only
  with a complete form (`counts?/1`). The session never fills it: the owner
  does, on the screen.
  """

  alias DevilsDictionary.Curation.{CompositionItem, Proposal}

  @version "quality-form-v1"
  @questions ~w(relevant correct_meaning reason_useful not_duplicate attribution_correct)

  @labels %{
    "relevant" => "relevant to the word",
    "correct_meaning" => "correct meaning",
    "reason_useful" => "reason useful to a reader",
    "not_duplicate" => "not a duplicate",
    "attribution_correct" => "attribution correct"
  }

  def version, do: @version

  @doc "The five questions, in order."
  def questions, do: @questions

  @doc "A question's words, as the form and the export print them."
  def label(question), do: Map.fetch!(@labels, question)

  @doc "The slot an item answers under: `\"lead\"` or `\"highlight:N\"`."
  def slot(%CompositionItem{role: :lead}), do: "lead"
  def slot(%CompositionItem{role: :highlight, position: n}), do: "highlight:#{n}"

  @doc """
  The form a reviewer filled, as it is stored: from `answers`, a map of
  slot → question → `"yes"`/`"no"` (or booleans), and `note`, over the
  proposal's `items`. Answers `{:ok, form}`, `{:ok, nil}` when nothing was
  answered, or `{:error, :quality_form_incomplete}` for a partial form.
  """
  def build(items, answers, note, reviewer_actor_id, at \\ DateTime.utc_now()) do
    answers = answers || %{}
    note = note && String.trim(note)

    entries =
      for item <- items do
        given = Map.get(answers, slot(item), %{})

        %{
          "slot" => slot(item),
          "item_id" => item.id,
          "item_kind" => to_string(item.item_kind),
          "selection_origin" => to_string(item.selection_origin),
          "answers" => Map.new(@questions, &{&1, answer(given[&1])})
        }
      end

    answered = for e <- entries, {_q, a} <- e["answers"], not is_nil(a), do: a

    cond do
      answered == [] and note in [nil, ""] ->
        {:ok, nil}

      length(answered) == length(entries) * length(@questions) ->
        {:ok,
         %{
           "version" => @version,
           "items" => entries,
           "note" => if(note in [nil, ""], do: nil, else: note),
           "reviewer_actor_id" => reviewer_actor_id,
           "at" => DateTime.to_iso8601(at)
         }}

      true ->
        {:error, :quality_form_incomplete}
    end
  end

  defp answer(value) when value in [true, "yes", "true"], do: true
  defp answer(value) when value in [false, "no", "false"], do: false
  defp answer(_value), do: nil

  @doc "Whether a stored form is complete: every item answered, every question."
  def complete?(%{"version" => @version, "items" => [_ | _] = items}) do
    Enum.all?(items, fn item ->
      Enum.all?(@questions, &is_boolean(get_in(item, ["answers", &1])))
    end)
  end

  def complete?(_form), do: false

  @doc """
  Whether a proposal counts toward #253 §10's five: resolved with a complete
  form. Every written proposal is a non-abstained answer, since an
  abstention writes none (#264 R14.2).
  """
  def counts?(%Proposal{state: state, quality_form: form}) when state in [:taken, :dismissed],
    do: complete?(form)

  def counts?(_proposal), do: false

  @doc """
  One proposal's form as Markdown, for posting on #253: `context` names the
  page, the proposal version, the attempt, the model config, each item's
  label and the decision with its reason.
  """
  def markdown(%{} = context) do
    form = context.proposal.quality_form || %{}
    items = Map.new(form["items"] || [], &{&1["slot"], &1})

    rows =
      for item <- context.items do
        entry = items[slot(item)] || %{"answers" => %{}}

        cells =
          for q <- @questions do
            case get_in(entry, ["answers", q]) do
              true -> "yes"
              false -> "no"
              _ -> "—"
            end
          end

        "| #{slot(item)} | #{context.item_label.(item)} | " <> Enum.join(cells, " | ") <> " |"
      end

    header =
      "| Item | What | " <>
        Enum.map_join(@questions, " | ", &label/1) <>
        " |\n|---|---|" <> String.duplicate("---|", length(@questions))

    """
    ### #{context.page} · proposal version #{context.version.version}

    - Proposal ##{context.proposal.id}, version id #{context.version.id}, attempt ##{context.version.attempt_id}
    - Model config: #{context.model_config_label}
    - Decision: #{context.proposal.state}#{decision_reason(context)}
    - Form: #{if complete?(form), do: "complete (#{@version})", else: "not filled"}#{counts_note(context.proposal)}

    #{header}
    #{Enum.join(rows, "\n")}

    Note: #{form["note"] || "—"}
    """
  end

  defp decision_reason(%{decision_reason: reason}) when is_binary(reason) and reason != "",
    do: ": #{reason}"

  defp decision_reason(_context), do: ""

  defp counts_note(proposal),
    do: if(counts?(proposal), do: " · counts toward #253 §10's five", else: "")
end
