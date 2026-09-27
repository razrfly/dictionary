defmodule DevilsDictionary.CurationFixtures do
  @moduledoc """
  A small curation world for #196/#201 integrity tests, built through the
  registry and the curation services themselves.

  Every text is a placeholder. No words are attributed to Bierce or anyone
  else, and no profile gets a dossier about a real person: an admission test
  uses a test profile with test references. That rule is the task's (never
  invent quotations or biography evidence), and it applies to fixtures too.
  """

  import Ecto.Query

  alias DevilsDictionary.Accounts.{Scope, User}
  alias DevilsDictionary.AccountsFixtures
  alias DevilsDictionary.Curation.{Configurations, Digest}
  alias DevilsDictionary.{Fixtures, Registry, Repo, WordFixtures}
  alias DevilsDictionary.Sources.Actor

  @doc "An account with the given roles, and its scope."
  def account(roles \\ []) do
    user =
      AccountsFixtures.user_fixture()
      |> Ecto.Changeset.change(
        reviewer: :reviewer in roles,
        internal_contributor: :contributor in roles
      )
      |> Repo.update!()

    Scope.for_user(user)
  end

  @doc "Revokes an account's roles."
  def revoke!(%Scope{user: user}) do
    Repo.update_all(from(u in User, where: u.id == ^user.id),
      set: [reviewer: false, internal_contributor: false]
    )
  end

  @doc "A `bot` actor, for proving a bot can do none of this."
  def bot_actor!(source) do
    Repo.insert!(%Actor{actor_kind: :bot, bot_source_id: source.id, label: "fixture bot"})
  end

  @doc "The account's own `user` actor."
  def actor!(%Scope{user: user}) do
    {:ok, actor} =
      Repo.transaction(fn -> DevilsDictionary.Claims.Contributions.account_actor!(user) end)

    actor
  end

  @doc """
  The world: the source catalog, a reviewer and a contributor, and words.

    * `love` carries a Bierce entry, a Wiktionary definition, and a Wiktionary
      sense with a quotation;
    * `oats` carries only a Wiktionary definition (no Bierce entry);
    * `amor` is another English word, for scope changes.
  """
  def world! do
    ctx = Fixtures.seed_catalog!()
    reviewer = account([:reviewer])
    contributor = account([:contributor])

    love = WordFixtures.word!(ctx, "love", ["bierce", "wiktionary"], scope: nil)
    oats = WordFixtures.word!(ctx, "oats", ["wiktionary"], scope: nil)
    amor = WordFixtures.word!(ctx, "amor", ["wiktionary"], scope: nil)

    bierce = WordFixtures.entry!(ctx, love, "bierce", body: "fixture bierce entry body")
    definition = WordFixtures.entry!(ctx, love, "wiktionary", body: "fixture definition body")
    oats_definition = WordFixtures.entry!(ctx, oats, "wiktionary", body: "fixture oats body")

    sense =
      WordFixtures.sense!(ctx, love, "wiktionary",
        examples: [
          %{"type" => "example", "text" => "fixture example"},
          %{"type" => "quotation", "text" => "fixture quotation words", "ref" => "fixture ref"}
        ]
      )

    Map.merge(ctx, %{
      reviewer: reviewer,
      contributor: contributor,
      love: love,
      oats: oats,
      amor: amor,
      bierce: bierce,
      definition: definition,
      oats_definition: oats_definition,
      sense: sense
    })
  end

  @doc "Seeds and activates the global default, returning `{configuration, version}`."
  def enabled_default!(reviewer) do
    %{configuration: c, version: v} = Configurations.seed!()

    {:ok, _} =
      Configurations.activate(reviewer, c.id, v.id,
        reason: "fixture activation",
        idempotency_key: "fixture-activate-#{c.id}-#{v.id}",
        expected: nil
      )

    {Repo.reload!(c), v}
  end

  @doc "An internal test configuration with one activated version, returning `{configuration, version}`."
  def enabled_test_configuration!(reviewer, slug, attrs \\ %{}) do
    {:ok, c} = Configurations.create_test_configuration(reviewer, slug, "Test #{slug}")

    {:ok, v} =
      Configurations.create_version(
        reviewer,
        c.id,
        Map.merge(%{reason: "fixture version"}, attrs)
      )

    {:ok, _} =
      Configurations.activate(reviewer, c.id, v.id,
        reason: "fixture activation",
        idempotency_key: "fixture-activate-#{slug}",
        expected: nil
      )

    {Repo.reload!(c), v}
  end

  @doc "A content item spec for its current revision, meaning a lexeme."
  def content_spec(content, lexeme) do
    %{
      kind: :content,
      object_id: content.object_id,
      content_revision_id: Registry.current_content_revision(content.object_id).id,
      meaning: {:lexeme, lexeme.object_id}
    }
  end

  @doc "A quotation spec for example `index` of a sense's current revision, meaning that sense."
  def quotation_spec(sense, index) do
    revision = Registry.current_sense_revision(sense.object_id)
    %{"text" => text} = Enum.at(revision.examples, index)

    %{
      kind: :sense_quotation,
      object_id: sense.object_id,
      sense_revision_id: revision.id,
      locator: "quotation:#{index}",
      words_sha256: Digest.sha256(text),
      meaning: {:sense_revision, revision.id}
    }
  end

  @catalog "wikidata-famous-v1"
  @catalog_row "Q8777422"

  @doc "A work spec pinned to a committed catalog manifest row."
  def catalog_spec(lexeme, overrides \\ %{}) do
    path = Application.app_dir(:devils_dictionary, "priv/artworks/manifests/#{@catalog}.json")
    checksum = path |> File.read!() |> Jason.decode!() |> Map.fetch!("checksum")

    %{
      kind: :work,
      catalog:
        Map.merge(%{manifest: @catalog, checksum: checksum, identity: @catalog_row}, overrides),
      meaning: {:lexeme, lexeme.object_id}
    }
  end

  @doc """
  A registry work that *is* the committed catalog row: an entity carrying the
  row's QID as a verified Wikidata identifier.
  """
  def catalog_work!(label \\ "Cupid and Psyche (fixture)") do
    WordFixtures.concept!(@catalog_row, label)
  end

  @doc """
  A source record that materialized `object`, and its revision id: the
  evidence a source-record work item names.
  """
  def owned_record!(ctx, object, source_slug \\ "wikidata") do
    record = WordFixtures.record!(ctx, source_slug, raw: %{"fixture" => "record payload"})
    now = DateTime.utc_now()

    Repo.insert_all("source_materialized_outputs", [
      %{
        source_record_id: record.id,
        output_role: "work",
        output_key: "fixture:#{object.object_id}",
        output_object_id: object.object_id,
        inserted_at: now,
        updated_at: now
      }
    ])

    revision_id =
      Repo.one!(
        from r in "source_record_revisions",
          where: r.source_record_id == ^record.id,
          select: r.id
      )

    {record, revision_id}
  end

  @doc "A work spec backed by a source-record revision."
  def record_work_spec(object, revision_id, lexeme) do
    %{
      kind: :work,
      object_id: object.object_id,
      source_record_revision_id: revision_id,
      meaning: {:lexeme, lexeme.object_id}
    }
  end

  @doc "The current `defines` claim revision from a content item to a lexeme."
  def defines_claim!(content, lexeme) do
    Repo.one!(
      from r in DevilsDictionary.Claims.AssertionRevision,
        join: p in assoc(r, :predicate),
        where:
          r.subject_object_id == ^content.object_id and r.object_object_id == ^lexeme.object_id and
            r.is_current and p.key == "defines"
    )
  end

  @doc "Takes down the source record behind a content item's current revision."
  def disallow_record!(content) do
    revision = Registry.current_content_revision(content.object_id)

    Repo.update_all(
      from(rec in "source_records",
        join: rev in "source_record_revisions",
        on: rev.source_record_id == rec.id,
        where: rev.id == ^revision.source_record_revision_id
      ),
      set: [display_allowed: false]
    )
  end

  @doc "Unique idempotency keys."
  def key(prefix \\ "key"), do: "#{prefix}-#{System.unique_integer([:positive])}"

  @doc """
  Runs every pending deferred check now, as COMMIT would, then defers them
  again. A sandboxed test never commits, so without this it would never see
  what the database checks at COMMIT. No constraint in the schema is
  `DEFERRABLE INITIALLY IMMEDIATE`, so `ALL DEFERRED` restores the initial
  state exactly.
  """
  def settle! do
    Repo.query!("SET CONSTRAINTS ALL IMMEDIATE")
    Repo.query!("SET CONSTRAINTS ALL DEFERRED")
    :ok
  end

  @doc """
  What the database answers to `fun`, run in a (sub)transaction whose
  deferred checks run before it ends: `:accepted`, or `{:refused, code,
  detail}`.
  """
  def refused(fun) do
    result =
      try do
        Repo.transaction(fn ->
          fun.()
          Repo.query!("SET CONSTRAINTS ALL IMMEDIATE")
        end)

        :accepted
      rescue
        e in Postgrex.Error -> {:refused, e.postgres.code, e.postgres.message}
        e in Ecto.ConstraintError -> {:refused, e.type, e.constraint}
      end

    # A savepoint that commits keeps its SET CONSTRAINTS; one that rolls back
    # does not. Defer again either way, so the rest of the test is unchanged.
    Repo.query!("SET CONSTRAINTS ALL DEFERRED")
    result
  end
end
