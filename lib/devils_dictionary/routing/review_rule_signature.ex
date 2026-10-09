defmodule DevilsDictionary.Routing.ReviewRuleSignature do
  @moduledoc """
  The database attestation of a standing review rule's signature (#237
  Part A′): one row per signed rule digest, written by
  `Routing.ReviewRule.sign/3` after the signer's password is checked, and
  required by `Routing.ReviewRule.load/1` beside the signature in the file.
  Append-only; only an account holding the reviewer role can be its signer.
  """
  use Ecto.Schema

  alias DevilsDictionary.Accounts.User

  schema "review_rule_signatures" do
    field :rule_sha256, :string
    belongs_to :user, User
    field :signed_at, :utc_datetime
    field :method, :string
    field :attestation, :string
    field :inserted_at, :utc_datetime_usec, read_after_writes: true
  end
end
