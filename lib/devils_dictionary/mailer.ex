defmodule DevilsDictionary.Mailer do
  @moduledoc """
  Transactional mail for `phx.gen.auth`: confirmation, password reset, magic
  link. Nothing else sends mail.

  Local adapter in dev (`/dev/mailbox`) and test; production is deliberately
  unconfigured — #74 needs an authenticated submit/review flow, not a mail
  pipeline, and a half-configured production sender is worse than an absent one.
  """
  use Swoosh.Mailer, otp_app: :devils_dictionary
end
