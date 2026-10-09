defmodule DevilsDictionary.Routing.PublicRouting do
  @moduledoc """
  The launch switch for public subject addresses (#237 D5, ADR 0004 §8 step
  6), and the published host (#237 D2).

  `config :devils_dictionary, :public_routing` is `false` everywhere unless a
  published host turns it on. **Off**, nothing is served publicly at a
  ledger address: `Routing.Resolver` withholds every page in public mode, so
  the eight family routes answer 404 to the public, public links fall back to
  `/entities/:id/:slug`, and the sitemap is empty. Internal mode is
  unaffected, and nothing in the ledger changes: reservations, aliases and
  tombstones stay as they are, so turning it on again restores every answer.
  **On**, the resolver serves published pages publicly as ADR 0004 §6 says.

  The published host is the server the public reaches (D2): `config
  :devils_dictionary, :published_host` names it (`wordhoard.eu.ngrok.io`),
  set only by `config/runtime.exs`'s development block from
  `DD_PUBLISHED_HOST`. A server that is the published host reads publicly
  even where the development configuration turns internal reading on
  (`DevilsDictionaryWeb.ReadingMode`); only an authenticated reviewer or
  contributor reads internally there. Its pages name it in their canonical
  URLs.

  Both come only from configuration. Nothing in a request — no parameter,
  header, cookie or path — can turn the switch on or name a host
  (`PublicRoutingTest`). Production's configuration pins the switch off.
  """

  @doc "Whether published pages are served publicly at their addresses."
  def enabled?, do: Application.get_env(:devils_dictionary, :public_routing, false) == true

  @doc "The host the public reaches, when this server is it; otherwise nil."
  def published_host do
    case Application.get_env(:devils_dictionary, :published_host) do
      host when is_binary(host) and host != "" -> host
      _ -> nil
    end
  end

  @doc "Whether this server is the published host."
  def published_host?, do: not is_nil(published_host())

  @doc """
  The absolute origin canonical URLs are written with: the published host's,
  over https, or the endpoint's own URL where there is none.
  """
  def origin do
    case published_host() do
      nil -> DevilsDictionaryWeb.Endpoint.url()
      host -> "https://" <> host
    end
  end
end
