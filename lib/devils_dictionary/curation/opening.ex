defmodule DevilsDictionary.Curation.Opening do
  @moduledoc """
  The curated opening section of a word page (#156): one sourced lead
  definition and up to three highlights, above the Definitions, examples and
  discovery shelves, which it never changes.

  This struct is the **contract** between where a selection comes from and
  how it is shown. `DevilsDictionaryWeb.Opening` renders it and knows nothing
  else; a reader (`DevilsDictionary.Curation.OpeningReader`) produces it and
  knows nothing about markup. Phase 1 has one reader, the development-only
  `DevilsDictionary.Curation.ManualFixture`.

  What each field promises:

    * `composition` — `%{id, version}` when the selection has an identity:
      a fixture's key and version today. Never a URL, never a slug.
    * `origin` — `:fixture` (development, never public) or `:published`.
    * `configuration` — the resolved curation configuration (#201), a
      `Configuration`, or `nil`. **`nil` in Phase 1**: a fixture resolves
      none and no panel ran, and the component says so.
    * `lead` — a `Lead` or `nil`. An honest empty lead is `nil`, not a
      placeholder.
    * `highlights` — zero to three `Highlight`s in position order. Never
      padded: two highlights are two, not three with a gap.
    * `review` — who selected it and who, if anyone, reviewed it.
    * `withheld` — items the reader found ineligible at read time (a changed
      revision, a drifted catalog row, a disabled source, a Bierce entry the
      lead ignored). Each is `%{role, position, reason}`; the item itself is
      **not** substituted.

  Every item carries a `Reference` to the durable registry object and the
  exact revision it was read from. Nothing here is keyed by a discovery
  result id, and nothing is fetched to fill it.

  ## What later phases add, and where

  The persisted reader will return this struct, but the contract is not
  finished and the component will change with it. Deliberately absent now,
  because there is no real data behind them yet:

    * **#196 / #201** — the composition's persisted id and version, the
      configuration id and version frozen for it, the resolution reason and
      policy version (the typed `configuration` field is their place), and
      version provenance such as the originating run.
    * **#203** — structured decisions and history: the configured and actual
      panel, per-profile final-round ballots and counts, the human decision
      and any override with its reason, and links to authorized history,
      profile and version pages. Typed fields, not text, when they exist.
    * **#204** — a link to the editorial-method page, once that page exists.

  None of it is invented for a fixture: a fixture has no configuration, no
  panel and no approval, and the opening shows those absences plainly.
  """

  alias DevilsDictionary.Curation.ManualFixture
  alias DevilsDictionary.Curation.Opening.{Configuration, Highlight, Lead, Review}

  @max_highlights 3

  @enforce_keys [:origin, :review]
  defstruct composition: nil,
            origin: nil,
            configuration: nil,
            lead: nil,
            highlights: [],
            review: nil,
            withheld: []

  @type withheld :: %{
          role: :lead | :highlight,
          position: pos_integer() | nil,
          reason: atom()
        }

  @type t :: %__MODULE__{
          composition: %{id: term(), version: pos_integer()} | nil,
          origin: :fixture | :published,
          configuration: Configuration.t() | nil,
          lead: Lead.t() | nil,
          highlights: [Highlight.t()],
          review: Review.t(),
          withheld: [withheld()]
        }

  @doc "The most highlights an opening shows (#156's output contract)."
  def max_highlights, do: @max_highlights

  @doc """
  Whether there is anything to render. An opening with no lead and no
  highlights draws nothing at all — no heading, no skeleton, no empty slots.
  """
  def empty?(nil), do: true
  def empty?(%__MODULE__{lead: nil, highlights: []}), do: true
  def empty?(%__MODULE__{}), do: false

  @doc """
  Which reader, if any, may compose this request's opening.

  Phase 1 has only the manual fixture, and it answers only when the
  environment allows fixtures **and** the request asks with
  `?opening=fixture`. `:curated_opening_fixtures` is set by `config/dev.exs`
  and `config/test.exs` and by nothing that production reads, the same gate
  `DevilsDictionary.Demo` uses, so a public page never renders a fixture.
  `nil` — the answer everywhere else — means the page has no opening section.
  """
  def reader(params) when is_map(params) do
    if fixtures_enabled?() and params["opening"] == "fixture", do: ManualFixture
  end

  def reader(_params), do: nil

  @doc "Whether this environment may render development fixtures at all."
  def fixtures_enabled?,
    do: Application.get_env(:devils_dictionary, :curated_opening_fixtures, false) == true

  @doc """
  The opening for a built `WordPage`, asked of `reader`; `nil` when there is no
  reader, the page names no word, or the reader has nothing for it.

  Reads the database and the committed corpus manifests, nothing else. No
  provider is asked, no model is called and nothing is written.
  """
  def for_page(_page, nil), do: nil
  def for_page(%{headword: %{lexemes: []}}, _reader), do: nil

  def for_page(page, reader) when is_atom(reader) do
    case reader.opening(page, []) do
      %__MODULE__{} = opening -> if empty?(opening), do: nil, else: opening
      nil -> nil
    end
  end
end
