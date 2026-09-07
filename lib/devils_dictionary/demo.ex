defmodule DevilsDictionary.Demo do
  @moduledoc """
  Fake-data mode (#71 §2.8, §5 W6, U3): `?demo=1`, dev and test only.

  Most of what this project plans to be is not absorbed yet. Webster 1913 and
  EB1911 are 👑 sources nobody has written a module for; Urban Dictionary is
  the 📱 tier, which has no rows at all; and the culture layer — community
  examples, the evidence wall of #67 — is three tables in `docs/sketches/` that
  were rolled back on purpose. A layout argument about them cannot be had
  against an empty page, so this module invents one card per missing layer and
  hands it to the **real** components. What is being checked is the real
  layout; only the content is fiction.

  Three rules hold it in place:

    * **Nothing invented reaches the query module.** `WordPage.build/2` is
      untouched and `Health.Pages` builds its pages by calling it directly, so
      no scorecard row can ever grade a sample. Samples are merged in
      `WordLive.load/3`, downstream of everything the scorecard sees.
    * **Never a real source.** The sample slugs are disjoint from the six
      absorbed sources — Johnson especially, who was a sample in the wireframe
      and has been real since S5. A test asserts the disjointness rather than
      trusting the JSON.
    * **Off by default, and absent in production.** `enabled?/0` reads
      `:demo_mode`, which `config/dev.exs` and `config/test.exs` set and
      `config/prod.exs` and `config/runtime.exs` never mention — the same gate
      `:dev_routes` uses for `/kit`. A test reads `config/prod.exs` back and
      fails if it ever grows the key.

  Every sample body ends in *(invented for layout)*, and every card carries a
  dashed border and a SAMPLE badge, because a demo that can be mistaken for
  data is worse than no demo.
  """

  alias DevilsDictionary.Markdown

  @tier_rank %{aristocracy: 0, middle: 1, plebs: 2}
  @default_key "_default"

  @doc "Whether fake-data mode may be turned on at all in this environment."
  def enabled?, do: Application.get_env(:devils_dictionary, :demo_mode, false) == true

  @doc """
  Whether the request asked for it *and* is allowed to have it.

  The parameter alone is never enough: `?demo=1` in production reaches a
  function that has already returned `false`.
  """
  def on?(params) when is_map(params), do: enabled?() and params["demo"] == "1"
  def on?(_params), do: false

  @doc """
  The invented cards and evidence tiles for one word.

  A word with a set of its own gets it; every other word in the index — all
  1.5 million — gets the default set with its own lemma interpolated, so the
  mode works on any page rather than on three.
  """
  def samples(lemma) do
    file = read()
    words = Map.get(file, "words", %{})
    key = String.downcase(to_string(lemma || ""))
    word = Map.get(words, key) || Map.get(words, @default_key) || %{}
    sources = Map.new(Map.get(file, "sources", []), &{&1["slug"], &1})

    %{
      cards: Enum.map(Map.get(word, "cards", []), &card(&1, sources, lemma)),
      evidence: Enum.map(Map.get(word, "evidence", []), &evidence_tile(&1, lemma))
    }
  end

  @doc """
  Merges the sample cards into a built page: a 👑 sample belongs among the dead
  and a 📱 one at the bottom, not in a heap wherever they were appended.

  Sorted by tier and year *only*, and `Enum.sort_by/2` is stable, so the real
  cards keep the order `WordPage.build/2` gave them — re-deciding it here with
  a second, nearly-identical comparator is how the two would drift apart.
  """
  def decorate(%{headword: %{lexemes: []}} = page, _samples), do: page

  def decorate(page, %{cards: cards}) do
    %{page | cards: Enum.sort_by(page.cards ++ cards, &{@tier_rank[&1.tier] || 3, &1.year || 0})}
  end

  @doc """
  The ⓘ drawer for a sample card.

  Returns `nil` for anything else, so the caller falls through to
  `WordPage.provenance/2`. A sample's drawer is invented too — showing the
  page's real concept links under a card that does not exist would be the one
  dishonest thing in the mode.
  """
  def provenance(page, "card:card-sample-" <> _ = ref) do
    id = String.replace_prefix(ref, "card:", "")

    case Enum.find(page.cards, &(&1.id == id)) do
      nil -> nil
      card -> sample_drawer(ref, card)
    end
  end

  def provenance(_page, _ref), do: nil

  @doc "The sample source slugs, so a test can prove none of them is a real one."
  def source_slugs, do: read() |> Map.get("sources", []) |> Enum.map(& &1["slug"])

  # ── building ─────────────────────────────────────────────────────────────

  defp card(spec, sources, lemma) do
    source = Map.get(sources, spec["source"], %{})
    tier = tier(source["tier"])
    entry = spec["entry"]

    %{
      id: "card-sample-#{source["slug"]}",
      source: %{
        id: nil,
        slug: source["slug"],
        name: source["name"],
        tier: tier,
        license: source["license"],
        license_url: source["license_url"]
      },
      tier: tier,
      year: source["year"],
      pos: spec["pos"],
      kind: if(entry, do: :entry, else: :senses),
      entries: entries(entry, source, lemma),
      groups: groups(spec["senses"], lemma),
      thumbnail_url: entry && fill(entry["thumbnail_url"], lemma),
      url: fill(source["url"], lemma),
      sample?: true
    }
  end

  defp entries(nil, _source, _lemma), do: []

  defp entries(entry, source, lemma) do
    [
      %{
        headword: fill(entry["headword"], lemma),
        marker: fill(entry["marker"], lemma),
        body_html: entry["body"] |> fill(lemma) |> Markdown.to_html(:markdown),
        year: source["year"],
        url: fill(source["url"], lemma),
        record_id: nil
      }
    ]
  end

  defp groups(nil, _lemma), do: []
  defp groups([], _lemma), do: []

  defp groups(senses, lemma) do
    [
      %{
        group_key: nil,
        gloss: nil,
        chain: [],
        senses:
          Enum.with_index(senses, fn sense, i ->
            %{
              id: "sample-#{i}",
              gloss: fill(sense["gloss"], lemma),
              tags: sense["tags"] || [],
              url: nil,
              record_id: nil,
              relations: %{}
            }
          end)
      }
    ]
  end

  defp evidence_tile(tile, lemma) do
    %{
      kind: tile["kind"],
      label: tile["label"],
      duration: tile["duration"],
      body: fill(tile["body"], lemma),
      meta: fill(tile["meta"], lemma),
      handle: tile["handle"],
      metric: tile["metric"]
    }
  end

  # The invented record behind an invented card. It exists so the drawer's own
  # layout can be looked at for a layer that has no rows yet — the same reason
  # the cards exist.
  defp sample_drawer(ref, card) do
    now = DateTime.utc_now() |> DateTime.to_naive() |> NaiveDateTime.truncate(:second)

    record = %{
      index: 0,
      source: card.source,
      external_id: "SAMPLE/#{card.source.slug}/1",
      url: card.url,
      fetched_at: now,
      changed_at: nil,
      materialized_at: now
    }

    json =
      Jason.encode!(
        %{
          "sample" => true,
          "source" => card.source.slug,
          "note" => "invented for layout; no such record exists"
        },
        pretty: true
      )

    %{
      ref: ref,
      title: "SAMPLE · #{card.source.name}",
      source: card.source,
      records: [record],
      open: 0,
      raw: %{
        record_id: nil,
        json: json,
        bytes: byte_size(json),
        shown: byte_size(json),
        truncated?: false
      },
      links: []
    }
  end

  # ── helpers ──────────────────────────────────────────────────────────────

  defp tier("aristocracy"), do: :aristocracy
  defp tier("middle"), do: :middle
  defp tier("plebs"), do: :plebs
  defp tier(_other), do: nil

  # `{{word}}`, `{{Word}}` and `{{WORD}}` are the whole template language. A
  # sample that reads "OYSTER. n.s." on the oyster page and "GRIEF. n.s." on
  # grief's is a better layout check than one that reads "WORD" on both.
  defp fill(nil, _lemma), do: nil

  defp fill(text, lemma) when is_binary(text) do
    word = to_string(lemma || "word")

    text
    |> String.replace("{{word}}", word)
    |> String.replace("{{Word}}", String.capitalize(word))
    |> String.replace("{{WORD}}", String.upcase(word))
  end

  defp fill(other, _lemma), do: other

  # Read on every call rather than memoised: the file is a few kilobytes, this
  # runs in dev only, and editing a sample should show up on reload the way
  # editing a template does.
  defp read do
    path = Path.join(:code.priv_dir(:devils_dictionary), "demo/samples.json")

    with {:ok, body} <- File.read(path),
         {:ok, json} <- Jason.decode(body) do
      json
    else
      _ -> %{}
    end
  end
end
