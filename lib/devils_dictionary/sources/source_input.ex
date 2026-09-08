defmodule DevilsDictionary.Sources.SourceInput do
  @moduledoc """
  The archived file an import actually read, pinned by SHA-256.

  The database half of `priv/sources/MANIFEST.json`: the file says what should
  be there, this says what a given run used, and `import_runs.source_input_id`
  ties a corpus back to its bytes.

  `url_is_rolling` is the field that earns its place. `kaikki.org` serves the
  latest extract at a fixed path, so `acquisition_url` alone would imply the
  2.6 GB dump is re-fetchable when it is not, and the digest is the only thing
  identifying which extract every measured number was taken on.
  """
  use Ecto.Schema

  import Ecto.Changeset

  alias DevilsDictionary.Sources.Source

  schema "source_inputs" do
    belongs_to :source, Source
    field :edition, :string
    field :archive_locator, :string
    field :acquisition_url, :string
    field :acquired_on, :date
    field :byte_count, :integer
    field :sha256, :string
    field :parser_version, :string
    field :license, :string
    field :url_is_rolling, :boolean, default: false
    field :metadata, :map, default: %{}

    timestamps(type: :utc_datetime_usec)
  end

  @castable ~w(source_id edition archive_locator acquisition_url acquired_on byte_count
               sha256 parser_version license url_is_rolling metadata)a

  def changeset(input, attrs) do
    input
    |> cast(attrs, @castable)
    |> validate_required([:source_id, :archive_locator])
    |> validate_format(:sha256, ~r/\A[0-9a-f]{64}\z/, message: "must be 64 lowercase hex digits")
    |> unique_constraint([:source_id, :archive_locator, :sha256])
  end
end
