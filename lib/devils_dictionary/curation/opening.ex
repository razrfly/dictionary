defmodule DevilsDictionary.Curation.Opening do
  @moduledoc """
  The curated opening section of a word page (#156): one sourced lead
  definition and up to three highlights, above the Definitions, examples and
  discovery shelves, which it never changes.

  This struct is the **contract**. `DevilsDictionaryWeb.Opening` renders it and
  knows nothing else; a reader (`DevilsDictionary.Curation.OpeningReader`)
  produces it and knows nothing about markup. Phase 1 has one reader, the
  development-only `DevilsDictionary.Curation.ManualFixture`. Phase 2 adds the
  reader of #196's approved `editorial_composition_versions`, which returns
  this same struct with `origin: :published`, and the fixture goes away. The
  component does not change.

  What each field promises:

    * `composition` — `%{id, version}` when the selection has an identity:
      a fixture's key and version today, #196's `editorial_compositions.id` and
      version number later. Never a URL, never a slug.
    * `origin` — `:fixture` (development, never public) or `:published`.
    * `lead` — a `Lead` or `nil`. An honest empty lead is `nil`, not a
      placeholder.
    * `highlights` — zero to three `Highlight`s in position order. Never
      padded: two highlights are two, not three with a gap.
    * `review` — who selected it, who (if anyone) reviewed it, and what panel
      took part: a `Review`, whose empty lists mean *nothing recorded*, not
      *unanimous*.
    * `withheld` — items the reader found ineligible at read time (a changed
      revision, a withdrawn source, a Bierce entry the lead ignored). Each is
      `%{role, position, reason}`; the item itself is **not** substituted.

  Every item carries a `Reference` to the durable registry object and the
  exact revision it was read from, which is what #196 stores. Nothing here is
  keyed by a discovery result id, and nothing is fetched to fill it.
  """

  alias DevilsDictionary.Curation.ManualFixture
  alias DevilsDictionary.Curation.Opening.{Highlight, Lead, Review}

  @max_highlights 3

  @enforce_keys [:origin, :review]
  defstruct composition: nil,
            origin: nil,
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

  Reads the database and nothing else. No provider is asked, no model is
  called and nothing is written.
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
