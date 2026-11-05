# #309 D2: the content the curated-page sketches show, captured once.
#
# Reads a database, writes `content.json` beside this file, and nothing else.
# It was run against a private copy of `devils_dictionary_v2` taken read-only
# on 4 November 2026 at 17:27:48 UTC, never against v2 itself:
#
#     MIX_ENV=test MIX_TEST_PARTITION=_ux1 DD_NO_OBAN=1 \
#       mix run --no-start docs/sketches/curated-page/capture.exs
#
# It loads the serving checkout's discovery policies (`config.exs` +
# `dev.exs`) before it starts, so shelf retention is the published host's
# seven days and not the suite's two hours, and it reads as the public does.
#
# A published version is mapped by the page's own reader
# (`PublishedReader.arrangement/3`), including a version that is withheld as
# a whole today: the sketch draws what that version holds, and the state it is
# in now separately.
#
# Provider payloads are not copied. A shelf item (an image, film, album, book,
# poem or headline found by discovery) is held for seven days under its
# provider's terms, so its title, creator, image and credit text stay out of
# the repository; the sketch draws a labelled placeholder with the provider's
# name, the dates and the editor's stored reason. The records the site holds
# itself (Bierce, Johnson, WordNet, Wiktionary) are quoted as the page quotes
# them, with the credits their terms require.

dev = Config.Reader.read!("config/config.exs", env: :dev, target: :host)
Application.put_env(:devils_dictionary, :discovery, dev[:devils_dictionary][:discovery])
Application.put_env(:devils_dictionary, :internal_reading, false)
Logger.configure(level: :warning)
{:ok, _} = Application.ensure_all_started(:devils_dictionary)

import Ecto.Query

alias DevilsDictionary.{Lexicon, Repo}
alias DevilsDictionary.Lexicon.WordPage

alias DevilsDictionary.Curation.{
  Composition,
  CompositionPublication,
  CompositionVersion,
  Compositions,
  Configuration,
  ConfigurationVersion,
  Published,
  PublishedReader,
  RefreshState,
  ShelfCitations,
  Standing
}

alias DevilsDictionary.Curation.Opening.Review
alias DevilsDictionary.Curation.WholeEntry

out = Path.join(__DIR__, "content.json")

page_of = fn slug -> slug |> Lexicon.lookup() |> WordPage.build(trail: [], viewer: :public) end

time = fn
  nil -> nil
  %NaiveDateTime{} = t -> t |> NaiveDateTime.truncate(:second) |> NaiveDateTime.to_iso8601()
  %DateTime{} = t -> t |> DateTime.truncate(:second) |> DateTime.to_iso8601()
end

reason_of = fn reasons ->
  Enum.find_value(reasons || [], fn
    %{kind: :editorial, text: text} -> text
    _ -> nil
  end)
end

credits_of = fn credits ->
  for c <- credits || [], c.required?, do: %{label: c.label, text: c.text, href: c.href}
end

holdings = fn page ->
  sources = page.cards |> Enum.map(& &1.source.name) |> Enum.uniq()
  %{dictionaries: length(sources), senses: Enum.reduce(page.cards, 0, &(&2 + &1.senses))}
end

headword = fn page ->
  %{
    lemma: page.headword.lemma,
    pronunciation: page.headword.pronunciations |> List.first() |> then(&(&1 && &1.ipa)),
    parts: page.headword.parts |> Enum.map(& &1.pos) |> Enum.uniq()
  }
end

related = fn page ->
  case page.related do
    %{groups: groups} ->
      groups
      |> Map.values()
      |> Enum.flat_map(&(&1[:shown] || []))
      |> Enum.map(&(&1[:lemma] || &1[:label] || &1[:text]))
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()
      |> Enum.take(8)

    _ ->
      []
  end
end

citation_of = fn id ->
  c = ShelfCitations.get(id)
  %{observed_at: time.(c.observed_at), expires_at: time.(c.expires_at)}
end

item_json = fn tile, item ->
  section = WholeEntry.section(tile)

  base = %{
    position: tile.position,
    section: section,
    kind: tile.kind,
    source: tile.source && tile.source[:name],
    reason: reason_of.(tile.reasons),
    reason_chars: String.length(reason_of.(tile.reasons) || "")
  }

  case tile.kind do
    :shelf ->
      Map.merge(base, %{placeholder: true, shelf_kind: section})
      |> Map.merge(citation_of.(item.shelf_citation_id))

    :definition ->
      Map.merge(base, %{
        text: tile.excerpt.text,
        creator: tile.creator,
        title: tile.title,
        date: tile.date,
        credits: credits_of.(tile.credits)
      })

    :quotation ->
      Map.merge(base, %{
        text: tile.quotation.text,
        citation: tile.quotation.citation,
        credits: credits_of.(tile.credits)
      })

    :exemplar ->
      Map.merge(base, %{title: tile.title, credits: credits_of.(tile.credits)})

    kind when kind in [:poem, :book, :artwork] ->
      Map.merge(base, %{title: tile.title, creator: tile.creator, date: tile.date, credits: credits_of.(tile.credits)})

    _ ->
      base
  end
end

published = fn slug, version_id ->
  page = page_of.(slug)
  version = Repo.get!(CompositionVersion, version_id)
  composition = Repo.get!(Composition, version.composition_id)
  configuration = Repo.get!(Configuration, version.curation_configuration_id)
  configuration_version = Repo.get!(ConfigurationVersion, version.configuration_version_id)
  items = Compositions.items(version.id)
  arrangement = Published.arrangement_of(items, Standing.evaluate(version, composition))
  receipt = Repo.one!(from p in CompositionPublication, where: p.published_version_id == ^version.id, order_by: [desc: p.id], limit: 1)
  label = items |> Enum.find_value(& &1.note_author_label)
  [persona, instruction, model] = String.split(label, " · ")

  record = %{
    composition: %{id: composition.id, version: version.version},
    configuration: configuration,
    configuration_version: configuration_version,
    review: %Review{state: :published, selected_by: %{kind: :model, label: label}, published_on: NaiveDateTime.to_date(receipt.committed_at)}
  }

  opening = PublishedReader.arrangement(page, arrangement, record)
  lead_item = Enum.find(items, &(&1.role == :lead))

  earlier =
    Repo.all(
      from p in CompositionPublication,
        join: v in CompositionVersion,
        on: v.id == p.published_version_id,
        where: p.composition_id == ^composition.id and p.action == :publish and v.version < ^version.version,
        distinct: true,
        select: v.version
    )
    |> Enum.sort(:desc)

  state =
    case Published.current(composition.id) do
      {:ok, _} -> %{kind: :published}
      {:withheld, reasons} -> %{kind: :withheld_whole, reasons: reasons}
      other -> %{kind: other}
    end

  %{
    slug: slug,
    headword: headword.(page),
    holdings: holdings.(page),
    related: related.(page),
    state: state,
    version: %{
      number: version.version,
      record: version.id,
      published_at: time.(receipt.committed_at),
      authority: receipt.authority_kind,
      configuration_version: configuration_version.version,
      persona: persona,
      instruction: instruction,
      model: model,
      earlier: earlier
    },
    lead:
      opening.lead &&
        %{
          text: opening.lead.excerpt.text,
          author: opening.lead.author,
          work: opening.lead.work,
          year: opening.lead.entry[:year],
          register: opening.lead.register,
          credits: credits_of.(opening.lead.credits),
          reason: reason_of.(opening.lead.reasons) || lead_item.note
        },
    items:
      for tile <- opening.highlights do
        item = Enum.find(items, &(&1.role == :highlight and &1.position == tile.position))
        item_json.(tile, item)
      end,
    withheld: opening.withheld
  }
end

assessed = fn slug, composition_id ->
  page = page_of.(slug)

  row =
    Repo.one(
      from r in RefreshState,
        where: r.composition_id == ^composition_id,
        order_by: [desc: r.last_completed_at],
        limit: 1
    )

  key = "proposal:#{composition_id}:#{row.configuration_version_id}:#{row.refresh_generation}"

  {attempt_id, chars} =
    Repo.one(
      from a in "inference_attempts",
        where: a.request_key == ^key,
        select: {a.id, fragment("length(?->>'abstain_reason')", a.result)}
    )

  %{
    slug: slug,
    headword: headword.(page),
    holdings: holdings.(page),
    related: related.(page),
    state: %{
      kind: row.last_outcome,
      assessed_at: time.(row.last_completed_at),
      attempt: attempt_id,
      # The stored abstain reason is the model's text; the sketch says how
      # long it is and draws the line it would fill, and the built page shows
      # the text itself.
      reason_chars: chars
    }
  }
end

content = %{
  captured_from: "private copy of devils_dictionary_v2, taken read-only 2026-11-04T17:27:48Z",
  pages: [
    published.("nepotism", 39),
    published.("truth", 45),
    published.("love", 55),
    published.("greed", 40) |> Map.put(:assessment, assessed.("greed", 7).state),
    assessed.("bestiality", 10)
  ]
}

File.write!(out, Jason.encode!(content, pretty: true))
IO.puts("wrote #{out}")
