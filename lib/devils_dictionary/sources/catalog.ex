defmodule DevilsDictionary.Sources.Catalog do
  @moduledoc """
  The registry of what we absorb from, as data.

  Five open sources for MVP-0 (issue #69 §2), the Animals test scope (§3), and
  Bierce as a person who authored a layer. Lives in `lib` rather than in
  `seeds.exs` because seeds do **not** run in `:test` — the test alias is
  `ecto.create, ecto.migrate, test` — so tests and seeds need one shared
  definition. `mix dd.score`'s A1 row checks reality against this list.

  Adding a source is a row here plus a module under `Absorb.Sources`
  (scorecard E1: zero migrations).
  """

  alias DevilsDictionary.Lexicon.Scope
  alias DevilsDictionary.Repo
  alias DevilsDictionary.Sources.{Person, Source}

  @doc """
  The five MVP-0 sources. Pinned snapshots live in `config`.
  """
  def sources do
    [
      %{
        slug: "wordnet",
        name: "Open English WordNet 2025",
        tier: :middle,
        kind: :lexical_db,
        access: :dump,
        era_year: 2025,
        license: "CC BY 4.0",
        license_url: "https://creativecommons.org/licenses/by/4.0/",
        homepage: "https://en-word.net/",
        url_template: "https://en-word.net/id/{external_id}",
        attribution: "Open English WordNet 2025 (CC BY 4.0)",
        config: %{
          # The PLUS edition, deliberately: the base edition holds 107,519
          # synsets / 135,969 (lemma, pos) pairs and fails scorecard A2, which
          # needs >= 120,000 / >= 155,000. See #70 S0b.
          "dump_url" =>
            "https://github.com/globalwordnet/english-wordnet/releases/download/2025-edition/english-wordnet-2025-plus-json.zip",
          "dump_file" => "data/english-wordnet-2025-plus-json.zip",
          "edition" => "2025-plus",
          "snapshot_date" => "2025-12-12",
          "synset_prefix" => "oewn-",
          "expected_synsets" => 120_564,
          "expected_lexemes" => 161_875
        }
      },
      %{
        slug: "wiktionary",
        name: "Wiktionary (English) via Kaikki",
        tier: :middle,
        kind: :dictionary,
        access: :dump,
        era_year: 2026,
        license: "CC BY-SA 4.0",
        license_url: "https://creativecommons.org/licenses/by-sa/4.0/",
        homepage: "https://en.wiktionary.org/",
        url_template: "https://en.wiktionary.org/wiki/{lemma}#English",
        attribution: "Wiktionary contributors (CC BY-SA 4.0), extracted by kaikki.org",
        config: %{
          "dump_url" => "https://kaikki.org/dictionary/raw-wiktextract-data.jsonl.gz",
          "dump_file" => "data/raw-wiktextract-data.jsonl.gz",
          "dump_date" => "2026-08-28",
          "dump_bytes" => 2_826_623_319,
          "lang_code" => "en",
          # Decision #11 / scorecard M4: drop what we never materialize before
          # storing. Measured at ~81% smaller on the fixtures.
          # One source of truth: the module decides what it throws away, and the
          # catalog reports it, so the two can never drift.
          "trim" => DevilsDictionary.Absorb.Sources.Wiktionary.trimmed_keys()
        }
      },
      %{
        slug: "wikidata",
        name: "Wikidata",
        tier: :middle,
        kind: :knowledge_graph,
        access: :api,
        era_year: 2026,
        license: "CC0 1.0",
        license_url: "https://creativecommons.org/publicdomain/zero/1.0/",
        homepage: "https://www.wikidata.org/",
        url_template: "https://www.wikidata.org/wiki/{external_id}",
        attribution: "Wikidata (CC0)",
        config: %{
          "entity_url" => "https://www.wikidata.org/wiki/Special:EntityData/{qid}.json",
          "rate_limit_ms" => 200
        }
      },
      %{
        slug: "wikipedia",
        name: "Wikipedia (English)",
        tier: :middle,
        kind: :encyclopedia,
        access: :api,
        era_year: 2026,
        license: "CC BY-SA 4.0",
        license_url: "https://creativecommons.org/licenses/by-sa/4.0/",
        homepage: "https://en.wikipedia.org/",
        url_template: "https://en.wikipedia.org/wiki/{title}",
        attribution: "Wikipedia contributors (CC BY-SA 4.0)",
        config: %{
          "summary_url" => "https://en.wikipedia.org/api/rest_v1/page/summary/{title}",
          "rate_limit_ms" => 200
        }
      },
      %{
        slug: "bierce",
        name: "Ambrose Bierce, The Devil's Dictionary",
        tier: :aristocracy,
        kind: :dictionary,
        access: :static,
        era_year: 1911,
        license: "Public domain",
        license_url: "https://www.gutenberg.org/policy/permission.html",
        homepage: "https://www.gutenberg.org/ebooks/972",
        url_template: "https://www.gutenberg.org/cache/epub/972/pg972-images.html\#{external_id}",
        attribution: "Ambrose Bierce, The Devil's Dictionary (1911), public domain",
        config: %{
          "file" => "priv/sources/bierce/pg972.txt",
          "gutenberg_id" => 972
        }
      }
    ]
  end

  @doc """
  People who authored a layer. Keyed by the source slug they wrote.
  """
  def people do
    [
      %{
        name: "Ambrose Bierce",
        slug: "ambrose-bierce",
        birth_date: ~D[1842-06-24],
        death_date: ~D[1914-01-01],
        bio: "American satirist; author of The Devil's Dictionary (1911).",
        wikidata_id: "Q310190",
        source_slug: "bierce"
      }
    ]
  end

  @doc """
  Scopes and their rules.

  `wiktionary_categories` is frozen on purpose. The Kaikki dump carries each
  entry's categories as flat strings with no hierarchy, so the tree was walked
  once from `Category:en:Animals` (`mix dd.scope.categories animals`) and
  pinned here — which keeps `mix dd.scope.build` offline and reproducible
  (scorecard O3). Regenerate only if Wiktionary reorganises the tree.
  """
  def scopes do
    [
      %{
        slug: "animals",
        name: "Animals",
        rules: %{
          "wordnet_roots" => ["oewn-00015568-n"],
          "wiktionary_category_root" => "en:Animals",
          "wiktionary_categories" => animal_categories(),
          "wikidata_root" => "Q729"
        }
      }
    ]
  end

  @doc """
  231 categories, walked to depth 4 from `Category:en:Animals` on 2026-09-05,
  minus the subtrees that are about animals without being animals
  (body parts, animal products, equestrian equipment and sport,
  bestiality, veterinary medicine, a toy franchise).
  """
  def animal_categories do
    [
      "en:Acanthuroid fish",
      "en:Acipenseriform fish",
      "en:Adephagan beetles",
      "en:African insectivores",
      "en:Ammonites",
      "en:Amphibians",
      "en:Amphipods",
      "en:Anglerfish",
      "en:Animals",
      "en:Annelids",
      "en:Anomurans",
      "en:Anteaters and sloths",
      "en:Ants",
      "en:Anurans",
      "en:Aphids",
      "en:Apodiforms",
      "en:Arachnids",
      "en:Araneoid spiders",
      "en:Argentiniform fish",
      "en:Armadillos",
      "en:Arthropods",
      "en:Aschizan flies",
      "en:Asilomorph flies",
      "en:Astacideans",
      "en:Atheriniform fish",
      "en:Aulopiform fish",
      "en:Baby animals",
      "en:Barklice",
      "en:Barnacles",
      "en:Bats",
      "en:Bees",
      "en:Beetles",
      "en:Beloniform fish",
      "en:Bibionomorphs",
      "en:Birds",
      "en:Birds of prey",
      "en:Bivalves",
      "en:Blennies",
      "en:Bostrichiform beetles",
      "en:Brachiopods",
      "en:Branchiopods",
      "en:Bryozoans",
      "en:Butterflies",
      "en:Caddis flies",
      "en:Caecilians",
      "en:Camelids",
      "en:Caprimulgiforms",
      "en:Caridean shrimp",
      "en:Carnivores",
      "en:Catfish",
      "en:Cattle",
      "en:Cephalopods",
      "en:Chalcidoid wasps",
      "en:Characins",
      "en:Chickens",
      "en:Chimaeras (fish)",
      "en:Chordates",
      "en:Chrysomeloid beetles",
      "en:Cicadas",
      "en:Cnidarians",
      "en:Cockroaches",
      "en:Colugos",
      "en:Columbids",
      "en:Copepods",
      "en:Coraciiforms",
      "en:Crabs",
      "en:Crickets and grasshoppers",
      "en:Crocodilians",
      "en:Crustaceans",
      "en:Ctenophores",
      "en:Culicomorphs",
      "en:Cyprinids",
      "en:Dabbling ducks",
      "en:Damselflies",
      "en:Decapods",
      "en:Dinosaurs",
      "en:Dionychan spiders",
      "en:Dipterans",
      "en:Dragonflies and damselflies",
      "en:Ducks",
      "en:Dugongs and manatees",
      "en:Earthworms",
      "en:Earwigs",
      "en:Echinoderms",
      "en:Elateroid beetles",
      "en:Elephants",
      "en:Elopomorph fish",
      "en:Erinaceids",
      "en:Even-toed ungulates",
      "en:Female animals",
      "en:Fish",
      "en:Flatfish",
      "en:Flatworms",
      "en:Fleas",
      "en:Fowls",
      "en:Freshwater birds",
      "en:Gadiforms",
      "en:Gasterosteiform fish",
      "en:Gastropods",
      "en:Geese",
      "en:Gelechioid moths",
      "en:Geometrid moths",
      "en:Goats",
      "en:Gobies",
      "en:Gossamer-winged butterflies",
      "en:Hemipterans",
      "en:Herrings",
      "en:Holostean fish",
      "en:Hoopoes and hornbills",
      "en:Horse breeds",
      "en:Horseflies",
      "en:Horses",
      "en:Hydrozoans",
      "en:Hymenopterans",
      "en:Hyraxes",
      "en:Ichthyosauromorphs",
      "en:Insects",
      "en:Isopods",
      "en:Jawless fish",
      "en:Labroid fish",
      "en:Labyrinth fish",
      "en:Lagomorphs",
      "en:Lampriform fish",
      "en:Libellulid dragonflies",
      "en:Lice",
      "en:Littorinimorphs",
      "en:Livestock",
      "en:Lizards",
      "en:Loaches",
      "en:Lobe-finned fishes",
      "en:Male animals",
      "en:Mammals",
      "en:Mantids",
      "en:Marsupials",
      "en:Mayflies",
      "en:Megalopterans",
      "en:Mergansers",
      "en:Mites and ticks",
      "en:Mollusks",
      "en:Monotremes",
      "en:Moths",
      "en:Muscoid flies",
      "en:Mygalomorph spiders",
      "en:Myriapods",
      "en:Nematodes",
      "en:Neogastropods",
      "en:Neuropterans",
      "en:Noctuoid moths",
      "en:Nudibranchs",
      "en:Nymphalid butterflies",
      "en:Octopuses",
      "en:Odd-toed ungulates",
      "en:Oestroid flies",
      "en:Osteoglossomorph fish",
      "en:Otidimorph birds",
      "en:Otocephalan fish",
      "en:Pangolins",
      "en:Parrots",
      "en:Penguins",
      "en:Perching birds",
      "en:Percoid fish",
      "en:Piciforms",
      "en:Pierid butterflies",
      "en:Pigs",
      "en:Pikes (fish)",
      "en:Placoderms",
      "en:Poultry",
      "en:Primates",
      "en:Pterosaurs",
      "en:Pyraloid moths",
      "en:Ratites",
      "en:Rays and skates",
      "en:Reptiles",
      "en:Rodents",
      "en:Salamanders",
      "en:Salmonids",
      "en:Saturniid moths",
      "en:Sauropterygians",
      "en:Sawflies and wood wasps",
      "en:Scale insects",
      "en:Scarabaeoids",
      "en:Scombroids",
      "en:Scorpaeniform fish",
      "en:Scorpions",
      "en:Screamers",
      "en:Sea anemones",
      "en:Sea cucumbers",
      "en:Sea urchins",
      "en:Seabirds",
      "en:Sharks",
      "en:Sheep",
      "en:Shorebirds",
      "en:Skippers",
      "en:Smelts",
      "en:Snails",
      "en:Snakes",
      "en:Soft corals",
      "en:Soricomorphs",
      "en:Sphinx moths",
      "en:Spiders",
      "en:Sponges",
      "en:Squid",
      "en:Staphylinoid beetles",
      "en:Stick insects",
      "en:Stoneflies",
      "en:Stony corals",
      "en:Stromateoid fish",
      "en:Suckers (fish)",
      "en:Swallowtails",
      "en:Syngnathiform fish",
      "en:Temnospondyls",
      "en:Tenebrionoid beetles",
      "en:Tephritoid flies",
      "en:Termites",
      "en:Tetraodontiforms",
      "en:Ticks",
      "en:Toothcarps",
      "en:Tortricid moths",
      "en:Trachinoid fish",
      "en:Trilobites",
      "en:True bugs",
      "en:True jellyfish",
      "en:Turtles",
      "en:Venerida order mollusks",
      "en:Vertebrates",
      "en:Vespids",
      "en:Vetigastropods",
      "en:Weevils",
      "en:Worms",
      "en:Zoarcoid fish",
      "en:Zygaenoid moths"
    ]
  end

  @doc """
  Upserts the whole catalog. Idempotent: re-running only refreshes config.
  """
  def seed! do
    sources = Map.new(sources(), fn attrs -> {attrs.slug, upsert!(Source, :slug, attrs)} end)

    for person <- people() do
      {slug, attrs} = Map.pop(person, :source_slug)
      upsert!(Person, :slug, Map.put(attrs, :source_id, sources[slug].id))
    end

    scopes = Map.new(scopes(), fn attrs -> {attrs.slug, upsert!(Scope, :slug, attrs)} end)

    %{sources: sources, scopes: scopes}
  end

  defp upsert!(schema, natural_key, attrs) do
    replace = attrs |> Map.keys() |> Enum.reject(&(&1 == natural_key))

    schema
    |> struct()
    |> schema.changeset(attrs)
    |> Repo.insert!(
      on_conflict: {:replace, replace},
      conflict_target: [natural_key],
      returning: true
    )
  end
end
