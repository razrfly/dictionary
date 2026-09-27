defmodule DevilsDictionary.Routing.PublicPath do
  @moduledoc """
  A reserved public address, decoded and normalized (`/people/voltaire`).

  One uniqueness domain covers every kind, so an address used once — as a
  canonical, an alias after a move or merge, or a tombstone after retirement —
  can never be allocated to an unrelated page. `path` and `original_page_id`
  never change. `destination_page_id` is the original owner or, after an
  approved merge, its successor; aliases name a destination *page*, whose
  current canonical is resolved directly, so a redirect is always one hop.

    * `canonical` — the destination page's one current address;
    * `alias` — a permanent 301 to the destination's canonical;
    * `tombstone` — reserved and gone: 410.

  Rows change only through `Routing.Ledger`, each change naming the
  `route_changes` row that records it (`last_route_change_id`).
  """
  use Ecto.Schema

  alias DevilsDictionary.Routing.{Page, RouteChange}

  @kinds [:canonical, :alias, :tombstone]

  schema "public_paths" do
    field :path, :string
    field :kind, Ecto.Enum, values: @kinds
    belongs_to :original_page, Page
    belongs_to :destination_page, Page
    belongs_to :last_route_change, RouteChange

    timestamps(type: :utc_datetime_usec)
  end

  def kinds, do: @kinds
end
