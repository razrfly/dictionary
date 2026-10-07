defmodule DevilsDictionary.Routing.Resolution do
  @moduledoc """
  What the resolver found, explicitly (ADR 0004 §6). Never a guessed page.

  | `outcome` | Meaning | HTTP |
  |---|---|---|
  | `:canonical` | the request is a published page's canonical, spelled exactly | 200 |
  | `:redirect` | an alias, a merged page or an equivalent spelling; `location` is the canonical | 301 |
  | `:choice` | a published split page; `successors` are its named successors | 200 |
  | `:missing` | no such address or page — never a name-based substitute | 404 |
  | `:gone` | a tombstone: deliberately removed, still reserved | 410 |
  | `:unavailable` | a real page not visible in the reading mode (a draft read publicly, or anything withdrawn); indistinguishable from missing to the public | 404 |
  | `:invalid` | a malformed request: bad encoding, encoded separator, NUL, dot segment | 400 |
  | `:corrupt` | inconsistent routing state; `diagnostics` says what | 500 |

  `location` is a stored path; `Routing.Address.encode/1` makes it a header or
  link. `DevilsDictionaryWeb.ReadingStatus` serves these statuses (#219).
  """

  @enforce_keys [:outcome]
  defstruct [
    :outcome,
    :request,
    :path,
    :page,
    :location,
    :reason,
    successors: [],
    diagnostics: %{}
  ]

  @type outcome ::
          :canonical
          | :redirect
          | :choice
          | :missing
          | :gone
          | :unavailable
          | :invalid
          | :corrupt

  @type t :: %__MODULE__{outcome: outcome()}

  @statuses %{
    canonical: 200,
    redirect: 301,
    choice: 200,
    missing: 404,
    gone: 410,
    unavailable: 404,
    invalid: 400,
    corrupt: 500
  }

  @doc "The HTTP status ADR 0004 §6 assigns to an outcome."
  def http_status(%__MODULE__{outcome: outcome}), do: Map.fetch!(@statuses, outcome)
end
