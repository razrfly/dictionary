defmodule DevilsDictionary.Curation.ManualFixture do
  @moduledoc """
  The Phase 1 opening reader (#156): hand-made selections from a committed
  file, for development only, until #196's approved compositions replace it.

  It reads `priv/curation/opening-fixtures.json`. Each composition there names
  its **scope** by lexical key (`en/love/noun`, the lexeme's lossless identity)
  and applies to a page whose resolved words include every one of them — never
  by slug or URL. Its lead and highlights name durable things by the sources'
  own identities and exact revisions (`DevilsDictionary.Curation.References`):
  a source record and its content hash, a verified Wikidata QID and the
  checksum of the committed catalog it came from, a quotation's fingerprint
  under a sense revision. No discovery result id appears anywhere, because a
  discovery result is disposable and a selection is not.

  Every item is checked when the page is read. One that no longer resolves,
  whose revision is no longer current, whose quoted words no longer match the
  words pinned for it, whose source is switched off or may not be displayed,
  whose catalog row no longer matches what the page would display, or that
  breaks `DevilsDictionary.Curation.LeadPolicy` is withheld and listed in
  `Opening.withheld` with its reason. Nothing is substituted for it and
  nothing is invented to fill its place: a composition whose items are all
  withheld renders no section at all. Relationships used as explanations are
  read under the public claim-review policy, so a rejected or withdrawn one
  explains nothing (`DevilsDictionary.Curation.References`).

  Gated twice, like `DevilsDictionary.Demo`: `Opening.reader/1` returns this
  module only when `:curated_opening_fixtures` is on (dev and test config
  only) **and** the request carries `?opening=fixture`. A public page never
  reaches it. It reads the database and the file; it makes no request and
  calls no model. The only files it reads are this one and the committed
  corpus manifests a work is pinned to.

  The selections are labelled as what they are. The file records who chose
  them (`selected_by`, with a `kind` of `human` or `model`), and whether a
  person has reviewed them; the component prints both, and a fixture is never
  shown as a published, approved composition.

  ## Exemplars (#212 Build 3)

  A highlight may also be an **exemplar**: a person, work or passage someone
  cited as an example of the meaning. The fixture names the subject (a
  verified Wikidata QID, or a passage's source record) and the meaning's
  sense, and the reader finds the `illustrates` claim of that pair
  (`References.exemplar_claim/2`). It then holds the claim to exactly the
  rules a saved composition's exemplar is held to, by asking
  `Curation.Eligibility.check/3` about the item a composition would store:
  the latest review accepted, the claim current and public, the meaning the
  claim's, the accepting review still describing what is shown, the subject
  active. A nomination nobody has accepted is withheld, whatever its subject,
  and nothing about it is drawn. The fixture adds no approval of its own.

  What it shows about the claim is `Examples.Provenance.of/2` for the public,
  the projection the examples card draws, with the fixture's selection in
  place of the card's ranking (`Provenance.in_fixture/2`).
  """

  @behaviour DevilsDictionary.Curation.OpeningReader

  alias DevilsDictionary.{Artworks, Examples}

  alias DevilsDictionary.Curation.{
    CompositionItem,
    Eligibility,
    Excerpt,
    LeadPolicy,
    Opening,
    References
  }

  alias DevilsDictionary.Curation.Opening.{
    Credit,
    Highlight,
    Lead,
    Meaning,
    Reason,
    Reference,
    Review
  }

  alias DevilsDictionary.Examples.Provenance
  alias DevilsDictionary.Lexicon.WordPage

  @path "curation/opening-fixtures.json"

  @doc """
  The committed fixture file, decoded. Read on every call rather than
  memoised: it is small, it is read only in development, and an edit should
  show on reload the way a template edit does.
  """
  def read do
    path = Path.join(:code.priv_dir(:devils_dictionary), @path)

    with {:ok, body} <- File.read(path),
         {:ok, %{} = json} <- Jason.decode(body) do
      json
    else
      _ -> %{}
    end
  end

  @impl true
  @doc """
  The opening for `page` from the fixture file (or `opts[:fixtures]`, a
  decoded map of the same shape), or `nil` when no composition's scope is on
  this page. Where several are, the one naming the most words wins.
  """
  def opening(page, opts \\ []) do
    compositions = opts |> Keyword.get_lazy(:fixtures, &read/0) |> Map.get("compositions", [])
    page_ids = MapSet.new(page.headword.lexemes, & &1.id)
    lexemes = compositions |> Enum.flat_map(&scope_keys/1) |> Enum.uniq() |> References.lexemes()

    compositions
    |> Enum.filter(&in_scope?(&1, lexemes, page_ids))
    |> Enum.max_by(&length(scope_keys(&1)), fn -> nil end)
    |> case do
      nil -> nil
      composition -> build(composition, %{page: page, page_ids: page_ids, lexemes: lexemes})
    end
  end

  defp scope_keys(composition), do: List.wrap(get_in(composition, ["scope", "lexemes"]))

  defp in_scope?(composition, lexemes, page_ids) do
    case scope_keys(composition) do
      [] ->
        false

      keys ->
        Enum.all?(keys, fn key ->
          match?(%{object_id: id} when is_integer(id), lexemes[key]) and
            MapSet.member?(page_ids, lexemes[key].object_id)
        end)
    end
  end

  defp build(composition, ctx) do
    ctx = Map.merge(ctx, %{author: author(composition), composition: composition})
    {lead, lead_withheld} = lead(composition["lead"], ctx)
    {highlights, highlight_withheld} = highlights(List.wrap(composition["highlights"]), ctx)

    %Opening{
      composition: %{id: "fixture:#{composition["key"]}", version: composition["version"] || 1},
      origin: :fixture,
      lead: lead,
      highlights: highlights,
      review: review(composition),
      withheld: lead_withheld ++ highlight_withheld
    }
  end

  # ── the lead ─────────────────────────────────────────────────────────────

  defp lead(nil, ctx) do
    case LeadPolicy.check_empty(ctx.page) do
      :ok -> {nil, []}
      {:error, reason} -> {nil, [withheld(:lead, nil, reason)]}
    end
  end

  defp lead(spec, ctx) do
    count = get_in(spec, ["excerpt", "sentences"]) || 1

    with {:ok, content} <- References.content(get_in(spec, ["item", "content"])),
         {:ok, policy} <- LeadPolicy.check(ctx.page, content.object_id),
         {:ok, excerpt} <- Excerpt.sentences(content.body, content.body_format, count),
         :ok <- pinned_words(excerpt, get_in(spec, ["excerpt", "sha256"])),
         {:ok, meaning} <- lexeme_meaning(spec["meaning"], ctx),
         :ok <- defines(content.object_id, meaning) do
      {card, entry} = LeadPolicy.page_entry(ctx.page, content.object_id)
      source = content.source

      lead = %Lead{
        reference: %Reference{
          object_id: content.object_id,
          object_kind: :content,
          content_revision_id: content.content_revision_id,
          source_record_revision_id: content.source_record_revision_id,
          locator: %{kind: :sentences, count: count}
        },
        policy: policy,
        register: LeadPolicy.register(policy),
        source: source_view(source),
        author: author_of(source),
        work: work_of(source),
        entry: %{
          headword: content.metadata["printed_headword"] || content.headword,
          marker: content.metadata["pos_marker"],
          year: content.year
        },
        # The entry's length as the Definitions row counts it, so the lead's
        # "Read the whole entry · N characters" and the card say one number.
        excerpt:
          excerpt
          |> Map.take([:text, :html, :clipped?, :chars])
          |> Map.put(:chars, Map.get(entry, :chars) || excerpt.chars),
        meaning: %{meaning | anchor: "#" <> card.id},
        links: %{card_id: card.id, source: content.canonical_url},
        credits:
          compact([
            credit(:source, "Source", source.attribution || source.name, source.homepage),
            credit(:entry, "Entry", entry_label(content), content.canonical_url, false),
            credit(:rights, "Rights", source.license, source.license_url)
          ]),
        reasons:
          compact([%Reason{kind: :policy, text: LeadPolicy.statement(policy)}, note(spec, ctx)])
      }

      {lead, []}
    else
      {:error, reason} -> {nil, [withheld(:lead, nil, reason)]}
    end
  end

  # The words a selection quoted, pinned as the SHA-256 of the excerpt's text.
  # The observation is pinned by its content hash; this pins what was read
  # from it, so a re-materialization that changes the words is withheld
  # rather than quoted under the old selection.
  defp pinned_words(%{text: text}, pin) when is_binary(pin) do
    if :crypto.hash(:sha256, text) |> Base.encode16(case: :lower) == pin,
      do: :ok,
      else: {:error, :excerpt_changed}
  end

  defp pinned_words(_excerpt, _pin), do: {:error, :excerpt_unpinned}

  defp entry_label(%{metadata: metadata, headword: headword}) do
    printed = metadata["printed_headword"] || headword

    case metadata["pos_marker"] do
      marker when is_binary(marker) and marker != "" -> "#{printed} (#{marker})"
      _none -> printed
    end
  end

  defp defines(content_id, %Meaning{kind: :lexeme, object_id: lexeme_id}) do
    if References.defines?(content_id, lexeme_id), do: :ok, else: {:error, :meaning_mismatch}
  end

  # ── highlights ───────────────────────────────────────────────────────────

  defp highlights(specs, ctx) do
    max = Opening.max_highlights()
    {kept, over} = Enum.split(specs, max)

    {items, {withheld, _seen}} =
      kept
      |> Enum.with_index(1)
      |> Enum.map_reduce({[], MapSet.new()}, fn {spec, position}, {withheld, seen} ->
        with {:ok, item} <- highlight(spec, position, ctx),
             false <- MapSet.member?(seen, identity(item.reference)) do
          {item, {withheld, MapSet.put(seen, identity(item.reference))}}
        else
          true -> {nil, {[withheld(:highlight, position, :duplicate) | withheld], seen}}
          {:error, reason} -> {nil, {[withheld(:highlight, position, reason) | withheld], seen}}
        end
      end)

    over =
      for {_spec, position} <- Enum.with_index(over, max + 1),
          do: withheld(:highlight, position, :over_limit)

    {Enum.reject(items, &is_nil/1), Enum.reverse(withheld) ++ over}
  end

  defp identity(%Reference{} = ref), do: {ref.object_kind, ref.object_id, ref.locator}

  defp highlight(%{"item" => %{"work" => ref}} = spec, position, ctx) do
    with {:ok, work} <- References.work(ref),
         {:ok, meaning} <- sense_meaning(spec["meaning"], ctx) do
      # Everything shown is the pinned manifest row's, which `References.work/1`
      # has just checked the displayed view against.
      pinned = work.pinned
      source = work.source
      catalog_url = pinned["source_url"]

      {:ok,
       %Highlight{
         position: position,
         kind: :artwork,
         register: nil,
         reference: %Reference{
           object_id: work.object_id,
           object_kind: :entity,
           catalog: %{manifest: work.manifest, checksum: work.checksum}
         },
         title: pinned["title"],
         creator: creator_of(pinned),
         date: pinned["date"],
         image: %{url: pinned["image_url"], alt: ""},
         meaning: meaning,
         source: source_view(source),
         credits:
           compact([
             credit(:image, "Image", pinned["credit_line"], commons_page(pinned)),
             credit(
               :catalog,
               "Catalog record",
               Enum.join(compact([source && source.attribution, work.qid]), " · "),
               catalog_url,
               false
             )
           ]),
         links: %{source: catalog_url},
         reasons: compact([depiction_reason(work, meaning), note(spec, ctx)])
       }}
    end
  end

  defp highlight(
         %{"item" => %{"quotation" => %{"sense" => ref, "fingerprint" => fp}}} = spec,
         position,
         ctx
       ) do
    with {:ok, sense} <- References.sense(ref),
         {:ok, line} <- line(sense, fp),
         {:ok, meaning} <- sense_meaning(spec["meaning"], ctx) do
      source = sense.source

      url =
        WordPage.link_out(%{url: sense.url, external_id: sense.external_key}, source, sense.lemma)

      filed_here =
        meaning.object_id == sense.object_id &&
          %Reason{
            kind: :source_match,
            text: "#{source.name} files this quotation under this meaning."
          }

      {:ok,
       %Highlight{
         position: position,
         kind: :quotation,
         register: :quotation,
         reference: %Reference{
           object_id: sense.object_id,
           object_kind: :sense,
           sense_revision_id: sense.sense_revision_id,
           source_record_revision_id: sense.source_record_revision_id,
           locator: %{kind: :quotation, fingerprint: fp}
         },
         quotation: %{text: line.text, citation: line.citation, provenance: line.provenance},
         meaning: meaning,
         source: source_view(source),
         # The citation is the quotation's own caption (`quotation.citation`),
         # so it is not repeated here.
         credits:
           compact([
             credit(:source, "Quoted in", source.attribution || source.name, url),
             credit(:rights, "Rights", source.license, source.license_url)
           ]),
         links: %{source: url},
         reasons: compact([filed_here, note(spec, ctx)])
       }}
    end
  end

  # An exemplar (#212): someone's accepted `illustrates` claim that the
  # subject is an example of the meaning. The fixture chooses it; whether it
  # may stand is the composition rules' (`Eligibility`), asked about the item
  # a saved composition would hold, which is built here and never stored.
  defp highlight(%{"item" => %{"exemplar" => ref}} = spec, position, ctx) when is_map(ref) do
    with {:ok, meaning} <- sense_meaning(spec["meaning"], ctx),
         {:ok, subject} <- References.subject(ref["subject"]),
         {:ok, claim} <- References.exemplar_claim(subject.object_id, meaning.object_id),
         :ok <-
           Eligibility.check(exemplar_item(claim, subject, meaning, position), scope_ids(ctx)),
         {:ok, item} <- examples_item(claim, meaning),
         {:ok, provenance} <- public_provenance(item) do
      {:ok,
       %Highlight{
         position: position,
         kind: :exemplar,
         register: nil,
         reference: %Reference{
           object_id: subject.object_id,
           object_kind: subject.kind,
           content_revision_id: subject.content_revision_id,
           assertion_revision_id: claim.id
         },
         title: item.subject.label,
         subject: %{
           kind: subject.kind,
           entity_kind: item.subject.entity_kind,
           qid: item.subject.qid,
           words: subject.words
         },
         claim: Map.take(item.claim, [:assertion_id, :rationale, :nominated_by]),
         meaning: meaning,
         source: source_view(nil),
         reasons: compact([note(spec, ctx)]),
         provenance:
           Provenance.in_fixture(provenance, %{
             composition: "fixture:#{ctx.composition["key"]}",
             version: ctx.composition["version"] || 1,
             selected_by: ctx.author
           })
       }}
    end
  end

  defp highlight(_spec, _position, _ctx), do: {:error, :unsupported_item}

  # The item a saved composition would hold for this exemplar (Build 1's
  # `Compositions.create_version/3`): the claim's subject, its pinned words
  # for a passage, and the meaning's exact sense revision.
  defp exemplar_item(claim, subject, meaning, position) do
    %CompositionItem{
      role: :highlight,
      position: position,
      item_kind: :exemplar,
      item_object_id: subject.object_id,
      content_revision_id: subject.content_revision_id,
      assertion_revision_id: claim.id,
      meaning_sense_revision_id: meaning.sense_revision_id,
      selection_origin: :manual
    }
  end

  # The composition's scope: the words its `scope` names, which a fixture's
  # items are checked against as a saved composition's are its members.
  defp scope_ids(ctx) do
    for key <- scope_keys(ctx.composition), lexeme = ctx.lexemes[key], do: lexeme.object_id
  end

  # The claim as the examples card on this page reads it for the public.
  defp examples_item(claim, %Meaning{lexeme_id: lexeme_id}) do
    case Enum.find(Examples.exemplars([lexeme_id], :public), &(&1.claim.revision_id == claim.id)) do
      nil -> {:error, :claim_not_visible}
      item -> {:ok, item}
    end
  end

  defp public_provenance(item) do
    case Provenance.of(item, :public) do
      nil -> {:error, :claim_not_visible}
      provenance -> {:ok, provenance}
    end
  end

  # The line by its fingerprint, found by the rule the sense row itself uses —
  # so the highlight and the row can never disagree about what the line says.
  defp line(sense, fingerprint) do
    quotations = WordPage.quotations(sense.examples)

    case Enum.find(quotations.shown ++ quotations.rest, &(&1.fingerprint == fingerprint)) do
      nil -> {:error, :quotation_not_found}
      line -> {:ok, line}
    end
  end

  # Why the work fits the meaning, when the registry says so: a QID the
  # meaning refers to is among the work's committed depictions. Worded by the
  # catalog's own match reason. A work with no such overlap has no source
  # reason — the selection's own note is then the only why, and it is marked
  # as the selector's.
  #
  # `refers_to_qids/1` reads only relationships the public may see, so a
  # `refers_to` a reviewer rejected or withdrew explains nothing here; the
  # work may still be shown on its own record, without a source match.
  defp depiction_reason(work, %Meaning{kind: :sense, object_id: sense_id}) do
    qids = References.refers_to_qids(sense_id)

    case Enum.find(References.pinned_depicts(work.pinned), &(&1["qid"] in qids)) do
      nil -> nil
      depicted -> %Reason{kind: :source_match, text: Artworks.depiction_note(work.view, depicted)}
    end
  end

  defp depiction_reason(_work, _meaning), do: nil

  # The creators the pinned row names, as the catalog committed them.
  defp creator_of(%{"creators" => [_ | _] = creators}) do
    creators |> Enum.map(& &1["term"]) |> Enum.reject(&is_nil/1) |> Enum.join(", ") |> presence()
  end

  defp creator_of(_pinned), do: nil

  defp presence(""), do: nil
  defp presence(value), do: value

  # The Commons file page, where an image's licence is stated, when the
  # catalog committed the file name.
  defp commons_page(%{"commons_file" => file}) when is_binary(file) and file != "" do
    "https://commons.wikimedia.org/wiki/File:" <>
      URI.encode(String.replace(file, " ", "_"), &URI.char_unreserved?/1)
  end

  defp commons_page(_metadata), do: nil

  # ── meanings ─────────────────────────────────────────────────────────────

  defp lexeme_meaning(%{"lexeme" => key}, ctx) when is_binary(key) do
    lexeme = ctx.lexemes[key] || References.lexemes([key])[key]

    cond do
      is_nil(lexeme) ->
        {:error, :meaning_not_found}

      not MapSet.member?(ctx.page_ids, lexeme.object_id) ->
        {:error, :meaning_off_page}

      true ->
        {:ok,
         %Meaning{
           kind: :lexeme,
           object_id: lexeme.object_id,
           lexeme_id: lexeme.object_id,
           label: lexeme.lemma,
           part_of_speech: lexeme.part_of_speech
         }}
    end
  end

  defp lexeme_meaning(_spec, _ctx), do: {:error, :meaning_not_found}

  defp sense_meaning(%{"sense" => ref}, ctx) do
    case References.sense(ref) do
      {:ok, sense} ->
        if MapSet.member?(ctx.page_ids, sense.lexeme_id) do
          {:ok,
           %Meaning{
             kind: :sense,
             object_id: sense.object_id,
             sense_revision_id: sense.sense_revision_id,
             lexeme_id: sense.lexeme_id,
             label: sense.gloss,
             part_of_speech: sense.part_of_speech,
             source: %{slug: sense.source.slug, name: sense.source.name},
             anchor: sense_anchor(ctx.page, sense.object_id)
           }}
        else
          {:error, :meaning_off_page}
        end

      {:error, _reason} ->
        {:error, :meaning_not_found}
    end
  end

  defp sense_meaning(_spec, _ctx), do: {:error, :meaning_not_found}

  # The card on this page whose rows hold the sense.
  defp sense_anchor(page, sense_id) do
    Enum.find_value(page.cards, fn card ->
      if Enum.any?(card.groups, fn group -> Enum.any?(group.senses, &(&1.id == sense_id)) end),
        do: "#" <> card.id
    end)
  end

  # ── attribution ──────────────────────────────────────────────────────────

  defp author(composition) do
    case composition["selected_by"] do
      %{"label" => label} = by when is_binary(label) ->
        %{kind: author_kind(by["kind"]), label: label}

      label when is_binary(label) ->
        %{kind: :fixture, label: label}

      _none ->
        nil
    end
  end

  defp author_kind("human"), do: :human
  defp author_kind("model"), do: :model
  defp author_kind(_kind), do: :fixture

  defp note(%{"note" => text}, ctx) when is_binary(text) and text != "" do
    %Reason{
      kind: :editorial,
      text: text,
      author: ctx.author,
      reviewed_by: ctx.composition["reviewed_by"],
      reviewed_on: date(ctx.composition["reviewed_on"])
    }
  end

  defp note(_spec, _ctx), do: nil

  defp review(composition) do
    reviewed_by = composition["reviewed_by"]

    %Review{
      state: if(is_binary(reviewed_by), do: :reviewed, else: :unreviewed),
      selected_by: author(composition),
      selected_on: date(composition["selected_on"]),
      reviewed_by: reviewed_by,
      reviewed_on: date(composition["reviewed_on"])
    }
  end

  defp date(value) when is_binary(value) do
    case Date.from_iso8601(value) do
      {:ok, date} -> date
      _ -> nil
    end
  end

  defp date(_value), do: nil

  # ── helpers ──────────────────────────────────────────────────────────────

  defp source_view(nil), do: %{slug: nil, name: nil, tier: nil, logo: nil}

  defp source_view(source) do
    %{
      slug: source.slug,
      name: source.name,
      tier: source.tier,
      logo: source.logo,
      attribution: source.attribution,
      license: source.license,
      license_url: source.license_url,
      homepage: source.homepage
    }
  end

  # "Ambrose Bierce, The Devil's Dictionary" is the author before the comma and
  # the work after it — the same reading `DevilsDictionaryWeb.Word` gives a
  # card's header.
  defp author_of(source), do: source.name |> String.split(",", parts: 2) |> hd() |> String.trim()

  defp work_of(source) do
    case String.split(source.name, ",", parts: 2) do
      [_author, work] -> String.trim(work)
      [_only] -> nil
    end
  end

  # A credit is required on the page unless said otherwise: only a locator
  # or a CC0 catalog record may move into the item's disclosure.
  defp credit(role, label, text, href, required? \\ true)
  defp credit(_role, _label, text, _href, _required?) when text in [nil, ""], do: nil

  defp credit(role, label, text, href, required?),
    do: %Credit{role: role, label: label, text: text, href: href, required?: required?}

  defp compact(list), do: Enum.reject(list, &(&1 in [nil, false]))

  defp withheld(role, position, reason), do: %{role: role, position: position, reason: reason}
end
