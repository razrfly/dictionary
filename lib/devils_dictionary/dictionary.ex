defmodule DevilsDictionary.Dictionary do
  @moduledoc """
  The Dictionary context.

  Manages topics (words/terms) and their definitions across the three-tier
  hierarchy: Aristocracy (dead intellectuals), Middle Class (institutional),
  and Plebs (social/crowdsourced).
  """

  import Ecto.Query, warn: false
  alias DevilsDictionary.Repo
  alias DevilsDictionary.Dictionary.{Topic, Definition, Person, TopicRelationship}

  # ============================================================================
  # Topics
  # ============================================================================

  @doc """
  Returns the list of topics.
  """
  def list_topics do
    Repo.all(Topic)
  end

  @doc """
  Gets a single topic by ID.
  """
  def get_topic(id), do: Repo.get(Topic, id)

  @doc """
  Gets a single topic by ID, raises if not found.
  """
  def get_topic!(id), do: Repo.get!(Topic, id)

  @doc """
  Gets a topic by slug.
  """
  def get_topic_by_slug(slug) do
    Repo.get_by(Topic, slug: slug)
  end

  @doc """
  Gets a topic by slug with definitions preloaded and ordered by tier.
  """
  def get_topic_with_definitions(slug) do
    definitions_query =
      from d in Definition,
        order_by: [
          asc: fragment("CASE ? WHEN 'aristocracy' THEN 0 WHEN 'middle' THEN 1 WHEN 'plebs' THEN 2 END", d.tier),
          asc: d.position
        ],
        preload: [:author]

    Topic
    |> Repo.get_by(slug: slug)
    |> Repo.preload(definitions: definitions_query)
  end

  @doc """
  Creates a topic.
  """
  def create_topic(attrs \\ %{}) do
    %Topic{}
    |> Topic.changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  Updates a topic.
  """
  def update_topic(%Topic{} = topic, attrs) do
    topic
    |> Topic.changeset(attrs)
    |> Repo.update()
  end

  @doc """
  Deletes a topic.
  """
  def delete_topic(%Topic{} = topic) do
    Repo.delete(topic)
  end

  @doc """
  Searches topics by title using fuzzy matching.
  """
  def search_topics(query, limit \\ 10) do
    search_term = "%#{query}%"

    from(t in Topic,
      where: ilike(t.title, ^search_term),
      order_by: [asc: t.title],
      limit: ^limit
    )
    |> Repo.all()
  end

  # ============================================================================
  # Definitions
  # ============================================================================

  @doc """
  Gets a single definition.
  """
  def get_definition!(id), do: Repo.get!(Definition, id)

  @doc """
  Creates a definition for a topic.
  """
  def create_definition(attrs \\ %{}) do
    %Definition{}
    |> Definition.changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  Updates a definition.
  """
  def update_definition(%Definition{} = definition, attrs) do
    definition
    |> Definition.changeset(attrs)
    |> Repo.update()
  end

  @doc """
  Deletes a definition.
  """
  def delete_definition(%Definition{} = definition) do
    Repo.delete(definition)
  end

  @doc """
  Lists definitions for a topic, ordered by tier and position.
  """
  def list_definitions_for_topic(topic_id) do
    from(d in Definition,
      where: d.topic_id == ^topic_id,
      order_by: [
        asc: fragment("CASE ? WHEN 'aristocracy' THEN 0 WHEN 'middle' THEN 1 WHEN 'plebs' THEN 2 END", d.tier),
        asc: d.position
      ],
      preload: [:author]
    )
    |> Repo.all()
  end

  @doc """
  Groups definitions by tier.
  """
  def group_definitions_by_tier(definitions) do
    Enum.group_by(definitions, & &1.tier)
  end

  # ============================================================================
  # People
  # ============================================================================

  @doc """
  Gets a person by ID.
  """
  def get_person!(id), do: Repo.get!(Person, id)

  @doc """
  Gets a person by slug.
  """
  def get_person_by_slug(slug) do
    Repo.get_by(Person, slug: slug)
  end

  @doc """
  Creates a person.
  """
  def create_person(attrs \\ %{}) do
    %Person{}
    |> Person.changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  Lists people in the Aristocracy tier (dead intellectuals).
  """
  def list_aristocracy do
    from(p in Person,
      where: not is_nil(p.death_date) or p.tier == :aristocracy,
      order_by: [asc: p.name]
    )
    |> Repo.all()
  end

  # ============================================================================
  # Topic Relationships
  # ============================================================================

  @doc """
  Creates a relationship between two topics.
  """
  def create_topic_relationship(attrs \\ %{}) do
    %TopicRelationship{}
    |> TopicRelationship.changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  Gets all relationships for a topic.
  """
  def get_topic_relationships(topic_id) do
    from(r in TopicRelationship,
      where: r.topic_id == ^topic_id,
      preload: [:related_topic]
    )
    |> Repo.all()
  end

  @doc """
  Gets word forms for a topic.
  """
  def get_word_forms(topic_id) do
    from(r in TopicRelationship,
      where: r.topic_id == ^topic_id and r.relationship_type == :word_form,
      preload: [:related_topic]
    )
    |> Repo.all()
  end
end
