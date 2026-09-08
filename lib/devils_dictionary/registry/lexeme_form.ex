defmodule DevilsDictionary.Registry.LexemeForm do
  @moduledoc """
  A written variant of a word — a plural, an inflection, an alternative
  spelling — with the source revision that attested it.

  In MVP-0 these were a JSONB array on `lexemes`, filled by whichever import ran
  first and merged fill-empty afterwards. That made "which source says *oysters*
  is the plural" unanswerable, and it is the shape the audit's finding #9 calls
  import-order-sensitive. A row per form, each carrying its evidence, answers it.
  """
  use Ecto.Schema

  import Ecto.Changeset

  alias DevilsDictionary.Corpus.SourceRecordRevision
  alias DevilsDictionary.Registry.Lexeme

  schema "lexeme_forms" do
    belongs_to :lexeme, Lexeme, references: :object_id
    field :written_form, :string
    field :form_kind, :string
    field :language_tag, :string, default: "en"
    field :tags, {:array, :string}, default: []
    belongs_to :source_record_revision, SourceRecordRevision

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(form, attrs) do
    form
    |> cast(attrs, [
      :lexeme_id,
      :written_form,
      :form_kind,
      :language_tag,
      :tags,
      :source_record_revision_id
    ])
    |> validate_required([:lexeme_id, :written_form])
    |> unique_constraint([:lexeme_id, :written_form, :form_kind])
  end
end
