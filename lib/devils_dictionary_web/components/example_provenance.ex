defmodule DevilsDictionaryWeb.ExampleProvenance do
  @moduledoc """
  "Why this example is here" (#212): an example's provenance, one row per
  stage, in plain words.

  It draws `DevilsDictionary.Examples.Provenance` and decides nothing. So
  the exemplar card, and later the opening (#156), say the same thing about
  one claim. Where the record is silent a row says *unknown*. No model, run,
  person or date is ever filled in for it.

  Closed, it adds one line to a card. Open, each row is a label over its
  sentence on a phone and beside it from `sm` up.
  """

  use DevilsDictionaryWeb, :html

  alias DevilsDictionary.Examples.Provenance

  attr :id, :string, required: true
  attr :provenance, Provenance, required: true
  attr :summary, :string, default: "Why this example is here"

  def why(assigns) do
    assigns = assign(assigns, :rows, rows(assigns.provenance))

    ~H"""
    <details id={@id} class="group/why min-w-0">
      <summary class="flex min-h-11 cursor-pointer list-none items-center gap-1 text-base/7 text-mist-700 hover:text-mist-950 sm:min-h-0 sm:text-sm/6 dark:text-mist-300 dark:hover:text-white [&::-webkit-details-marker]:hidden">
        <.icon
          name="hero-chevron-right-mini"
          class="size-4 shrink-0 text-mist-500 group-open/why:rotate-90"
        />
        {@summary}
      </summary>
      <dl class="mt-1 flex flex-col gap-2 rounded-lg bg-mist-950/2.5 p-3 sm:gap-1 dark:bg-white/2.5">
        <div
          :for={{key, label, text} <- @rows}
          id={"#{@id}-#{key}"}
          class="min-w-0 sm:grid sm:grid-cols-[7rem_minmax(0,1fr)] sm:gap-3"
        >
          <dt class="text-base/7 font-medium text-mist-950 sm:text-sm/6 dark:text-white">
            {label}
          </dt>
          <dd class="text-base/7 text-pretty text-mist-700 sm:text-sm/6 dark:text-mist-300">
            {text}
          </dd>
        </div>
      </dl>
    </details>
    """
  end

  @doc """
  The rows, `{key, label, sentence}`, one per stage, in reading order:
  source, nomination, model, review, selection, publication.
  """
  def rows(%Provenance{} = p) do
    [
      {"source", "Source", source(p.source)},
      {"nominated", "Nominated", nomination(p.nomination)},
      {"model", "Model", agent(p.agent)},
      {"reviewed", "Reviewed", review(p.review)},
      {"shown", "Shown here", selection(p.selection)},
      {"opening", "Opening", opening(p)}
    ]
  end

  defp source(:none), do: "Not listed by a source."

  defp source(sources) when is_list(sources),
    do: "Listed by #{sources |> Enum.map(& &1.name) |> Enum.uniq() |> sentence_list()}."

  defp nomination(:none), do: "None."
  defp nomination(:unknown), do: "Unknown. The record names no nominator."

  defp nomination(n) do
    [
      "By #{n.by.label || "someone the record does not name"}",
      claimant(n.claimant),
      origin(n),
      n.at && "on #{date(n.at)}",
      meaning(n.meaning)
    ]
    |> Enum.reject(&(&1 in [nil, false, ""]))
    |> Enum.join(", ")
    |> Kernel.<>(".")
  end

  defp origin(%{origin: :manifest, manifest: %{slug: slug, row: row}}) when not is_nil(row),
    do: "from manifest #{slug} row #{row}"

  defp origin(%{origin: :manifest, manifest: %{slug: slug}}), do: "from manifest #{slug}"

  defp origin(%{origin: :form, shelf: %{name: name, result_id: id}}) when not is_nil(id),
    do: "through the connect form, prefilled from a result by #{name} on the page"

  defp origin(%{origin: :form, shelf: %{name: name}}),
    do: "through the connect form, prefilled from #{name}'s catalog on the page"

  defp origin(%{origin: :form}), do: "through the connect form"
  defp origin(%{origin: :agent}), do: "by an agent"
  defp origin(_nomination), do: nil

  # The claim's own claimant, when it cites someone other than its nominator.
  defp claimant(%{kind: :unknown}), do: "citing an unknown claimant"
  defp claimant(%{label: label}) when is_binary(label), do: "citing #{label}"
  defp claimant(_claimant), do: nil

  defp meaning(%{gloss: gloss, lemma: lemma}) when is_binary(gloss) and is_binary(lemma),
    do: "under “#{gloss}” (#{lemma})"

  defp meaning(%{gloss: gloss}) when is_binary(gloss), do: "under “#{gloss}”"
  defp meaning(_meaning), do: nil

  defp agent(:none), do: "None involved."
  defp agent(:unknown), do: "Unknown. The record does not say."

  defp review(:none), do: "Not yet reviewed."

  defp review(r) do
    by = if r.by.label, do: " by #{r.by.label}", else: ""
    changed = if r.context_changed?, do: " It has changed since.", else: ""
    "#{decision(r.state)}#{by} on #{date(r.decided_at)}.#{changed}"
  end

  defp decision(:accepted), do: "Accepted"
  defp decision(:disputed), do: "Disputed"
  defp decision(:rejected), do: "Rejected"
  defp decision(:withdrawn), do: "Withdrawn"
  defp decision(_needs_review), do: "Sent back for review"

  defp selection(%{kind: :ranked, signals: s}) do
    up = s[:human_up] || 0
    down = s[:human_down] || 0
    cited = s[:evidence_count] || 0

    "Ranked by votes (#{up} for, #{down} against) and " <>
      "#{cited} supporting #{if cited == 1, do: "citation", else: "citations"}."
  end

  defp selection(%{kind: :composed} = s),
    do: "Selected by #{s.selected_by.label || "an unnamed author"} (version #{s.version})."

  defp opening(%Provenance{publication: %{committed_at: at} = pub, selection: %{kind: :composed}}) do
    state =
      cond do
        pub.withdrawn_at -> " It was withdrawn on #{date(pub.withdrawn_at)}."
        pub.superseded_at -> " A later version replaced it on #{date(pub.superseded_at)}."
        true -> ""
      end

    "Published on #{date(at)}.#{state}"
  end

  defp opening(%Provenance{featured: []}), do: "Not selected for a published opening."

  # Selected and published, but no page shows a composition yet (#194's
  # binding, #156's reader): the row says so rather than place it on a page.
  defp opening(%Provenance{featured: featured}) do
    Enum.map_join(featured, " ", fn f ->
      "Selected for the opening of #{words(f.scope)} by " <>
        "#{f.selected_by.label || "an unnamed author"} (version #{f.version}), " <>
        "published on #{date(f.published_at)}." <>
        if(f.shown_on_page, do: "", else: " The page does not show openings yet.")
    end)
  end

  defp words([]), do: "a word"
  defp words(scope), do: scope |> Enum.map(& &1.lemma) |> sentence_list()

  @doc "A date as the site writes one: *27 Sep 2026*."
  def date(%DateTime{} = at), do: Calendar.strftime(at, "%-d %b %Y")
  def date(%NaiveDateTime{} = at), do: Calendar.strftime(at, "%-d %b %Y")

  defp sentence_list([one]), do: one

  defp sentence_list(names),
    do: Enum.join(Enum.drop(names, -1), ", ") <> " and " <> List.last(names)
end
