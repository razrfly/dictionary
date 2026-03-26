# Script for populating the database. You can run it as:
#
#     mix run priv/repo/seeds.exs
#
# We recommend using the bang functions (`insert!`, `update!`
# and so on) as they will fail if something goes wrong.

alias DevilsDictionary.Repo
alias DevilsDictionary.Dictionary.{Topic, Person, Definition, TopicRelationship}

IO.puts("🎩 Seeding Devil's Dictionary...")

# ============================================================================
# PEOPLE - The Aristocracy of the Dead
# ============================================================================

IO.puts("  Creating authors...")

bierce =
  Repo.insert!(
    %Person{
      name: "Ambrose Bierce",
      slug: "ambrose-bierce",
      birth_date: ~D[1842-06-24],
      death_date: ~D[1914-01-01],
      bio: "American journalist, short story writer, and satirist. Best known for his sardonic lexicon, The Devil's Dictionary.",
      tier: :aristocracy,
      wikidata_id: "Q103846"
    },
    on_conflict: :nothing
  )

wilde =
  Repo.insert!(
    %Person{
      name: "Oscar Wilde",
      slug: "oscar-wilde",
      birth_date: ~D[1854-10-16],
      death_date: ~D[1900-11-30],
      bio: "Irish poet and playwright. Known for his wit, flamboyance, and tragic downfall.",
      tier: :aristocracy,
      wikidata_id: "Q30875"
    },
    on_conflict: :nothing
  )

twain =
  Repo.insert!(
    %Person{
      name: "Mark Twain",
      slug: "mark-twain",
      birth_date: ~D[1835-11-30],
      death_date: ~D[1910-04-21],
      bio: "American writer, humorist, and lecturer. The father of American literature.",
      tier: :aristocracy,
      wikidata_id: "Q7245"
    },
    on_conflict: :nothing
  )

IO.puts("    ✓ Created #{bierce.name}, #{wilde.name}, #{twain.name}")

# ============================================================================
# TOPICS - Sample Dictionary Entries
# ============================================================================

IO.puts("  Creating topics...")

# Topic: TRUTH
truth =
  Repo.insert!(
    %Topic{
      title: "Truth",
      slug: "truth",
      type: :concept,
      part_of_speech: "noun",
      pronunciation: "/truːθ/"
    },
    on_conflict: :nothing
  )

# Topic: FRIENDSHIP
friendship =
  Repo.insert!(
    %Topic{
      title: "Friendship",
      slug: "friendship",
      type: :concept,
      part_of_speech: "noun",
      pronunciation: "/ˈfrend.ʃɪp/"
    },
    on_conflict: :nothing
  )

# Topic: POLITICS
politics =
  Repo.insert!(
    %Topic{
      title: "Politics",
      slug: "politics",
      type: :concept,
      part_of_speech: "noun",
      pronunciation: "/ˈpɒl.ɪ.tɪks/"
    },
    on_conflict: :nothing
  )

# Topic: CYNIC
cynic =
  Repo.insert!(
    %Topic{
      title: "Cynic",
      slug: "cynic",
      type: :concept,
      part_of_speech: "noun",
      pronunciation: "/ˈsɪn.ɪk/"
    },
    on_conflict: :nothing
  )

# Topic: LOVE
love =
  Repo.insert!(
    %Topic{
      title: "Love",
      slug: "love",
      type: :concept,
      part_of_speech: "noun",
      pronunciation: "/lʌv/"
    },
    on_conflict: :nothing
  )

IO.puts("    ✓ Created topics: Truth, Friendship, Politics, Cynic, Love")

# ============================================================================
# DEFINITIONS - The Three Tiers
# ============================================================================

IO.puts("  Creating definitions...")

# --- TRUTH ---

# Aristocracy: Bierce's definition
Repo.insert!(
  %Definition{
    topic_id: truth.id,
    author_id: bierce.id,
    content: "An ingenious compound of desirability and appearance.",
    source_name: "The Devil's Dictionary",
    source_year: 1911,
    tier: :aristocracy,
    position: 0
  },
  on_conflict: :nothing
)

# Aristocracy: Wilde's definition
Repo.insert!(
  %Definition{
    topic_id: truth.id,
    author_id: wilde.id,
    content: "Rarely pure and never simple.",
    source_name: "The Importance of Being Earnest",
    source_year: 1895,
    tier: :aristocracy,
    position: 1
  },
  on_conflict: :nothing
)

# Middle Class: Dictionary definition
Repo.insert!(
  %Definition{
    topic_id: truth.id,
    content: "The quality or state of being true; that which is true or in accordance with fact or reality.",
    source_name: "Merriam-Webster",
    source_url: "https://www.merriam-webster.com/dictionary/truth",
    source_year: 2024,
    tier: :middle,
    position: 0
  },
  on_conflict: :nothing
)

# Plebs: Urban Dictionary style
Repo.insert!(
  %Definition{
    topic_id: truth.id,
    content: "That thing politicians accidentally say when they forget the cameras are rolling.",
    source_name: "Urban Dictionary",
    source_url: "https://www.urbandictionary.com/define.php?term=truth",
    source_year: 2023,
    tier: :plebs,
    position: 0
  },
  on_conflict: :nothing
)

# --- FRIENDSHIP ---

Repo.insert!(
  %Definition{
    topic_id: friendship.id,
    author_id: bierce.id,
    content: "A ship big enough to carry two in fair weather, but only one in foul.",
    source_name: "The Devil's Dictionary",
    source_year: 1911,
    tier: :aristocracy,
    position: 0
  },
  on_conflict: :nothing
)

Repo.insert!(
  %Definition{
    topic_id: friendship.id,
    content: "The state of being friends; the relationship between friends.",
    source_name: "Oxford English Dictionary",
    source_year: 2024,
    tier: :middle,
    position: 0
  },
  on_conflict: :nothing
)

Repo.insert!(
  %Definition{
    topic_id: friendship.id,
    content: "When you share your Netflix password but they never use your Hulu.",
    source_name: "Twitter",
    source_year: 2024,
    tier: :plebs,
    position: 0
  },
  on_conflict: :nothing
)

# --- POLITICS ---

Repo.insert!(
  %Definition{
    topic_id: politics.id,
    author_id: bierce.id,
    content: "A strife of interests masquerading as a contest of principles. The conduct of public affairs for private advantage.",
    source_name: "The Devil's Dictionary",
    source_year: 1911,
    tier: :aristocracy,
    position: 0
  },
  on_conflict: :nothing
)

Repo.insert!(
  %Definition{
    topic_id: politics.id,
    author_id: twain.id,
    content: "The only criminal class in America.",
    source_name: "Letter to Henry Rogers",
    source_year: 1906,
    tier: :aristocracy,
    position: 1
  },
  on_conflict: :nothing
)

Repo.insert!(
  %Definition{
    topic_id: politics.id,
    content: "The activities associated with the governance of a country or area.",
    source_name: "Cambridge Dictionary",
    source_year: 2024,
    tier: :middle,
    position: 0
  },
  on_conflict: :nothing
)

Repo.insert!(
  %Definition{
    topic_id: politics.id,
    content: "Thanksgiving dinner speedrun any% (family destroyed)",
    source_name: "Reddit",
    source_year: 2024,
    tier: :plebs,
    position: 0
  },
  on_conflict: :nothing
)

# --- CYNIC ---

Repo.insert!(
  %Definition{
    topic_id: cynic.id,
    author_id: bierce.id,
    content: "A blackguard whose faulty vision sees things as they are, not as they ought to be.",
    source_name: "The Devil's Dictionary",
    source_year: 1911,
    tier: :aristocracy,
    position: 0
  },
  on_conflict: :nothing
)

Repo.insert!(
  %Definition{
    topic_id: cynic.id,
    author_id: wilde.id,
    content: "A man who knows the price of everything and the value of nothing.",
    source_name: "Lady Windermere's Fan",
    source_year: 1892,
    tier: :aristocracy,
    position: 1
  },
  on_conflict: :nothing
)

Repo.insert!(
  %Definition{
    topic_id: cynic.id,
    content: "A person who believes that people are motivated purely by self-interest.",
    source_name: "Merriam-Webster",
    source_year: 2024,
    tier: :middle,
    position: 0
  },
  on_conflict: :nothing
)

# --- LOVE ---

Repo.insert!(
  %Definition{
    topic_id: love.id,
    author_id: bierce.id,
    content: "A temporary insanity curable by marriage.",
    source_name: "The Devil's Dictionary",
    source_year: 1911,
    tier: :aristocracy,
    position: 0
  },
  on_conflict: :nothing
)

Repo.insert!(
  %Definition{
    topic_id: love.id,
    content: "A strong feeling of affection and concern toward another person.",
    source_name: "American Heritage Dictionary",
    source_year: 2024,
    tier: :middle,
    position: 0
  },
  on_conflict: :nothing
)

Repo.insert!(
  %Definition{
    topic_id: love.id,
    content: "When you let them have the last slice of pizza even though you're still hungry.",
    source_name: "TikTok",
    source_year: 2024,
    tier: :plebs,
    position: 0
  },
  on_conflict: :nothing
)

IO.puts("    ✓ Created definitions across all three tiers")

# ============================================================================
# TOPIC RELATIONSHIPS
# ============================================================================

IO.puts("  Creating topic relationships...")

# Truth <-> Related -> Politics
Repo.insert!(
  %TopicRelationship{
    topic_id: truth.id,
    related_topic_id: politics.id,
    relationship_type: :related,
    bidirectional: true,
    weight: 0.8
  },
  on_conflict: :nothing
)

# Love <-> Related -> Friendship
Repo.insert!(
  %TopicRelationship{
    topic_id: love.id,
    related_topic_id: friendship.id,
    relationship_type: :related,
    bidirectional: true,
    weight: 0.9
  },
  on_conflict: :nothing
)

# Cynic <-> See Also -> Truth
Repo.insert!(
  %TopicRelationship{
    topic_id: cynic.id,
    related_topic_id: truth.id,
    relationship_type: :see_also,
    bidirectional: true,
    weight: 0.7
  },
  on_conflict: :nothing
)

IO.puts("    ✓ Created topic relationships")

IO.puts("✨ Seeding complete!")
IO.puts("")
IO.puts("Summary:")
IO.puts("  • 3 authors (Bierce, Wilde, Twain)")
IO.puts("  • 5 topics (Truth, Friendship, Politics, Cynic, Love)")
IO.puts("  • 15 definitions across all three tiers")
IO.puts("  • 3 topic relationships")
