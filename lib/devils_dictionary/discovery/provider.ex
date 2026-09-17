defmodule DevilsDictionary.Discovery.Provider do
  @moduledoc """
  The deliberately small contract shared by cultural discovery providers.

  Providers may differ in transport, operations, persistence, pagination and
  attribution. The shared boundary is identity and capability declaration; it
  is not a promise that every provider supports the same search operation.

  Server callback implementations are optional so a provider can remain in the
  source catalog while legal or transport prerequisites are unresolved. Callers
  must select providers by their declared capabilities before invoking a
  transport-specific callback.
  """

  @type request_fun ::
          (String.t(), map() ->
             {:ok, map()} | {:error, String.t()} | {:deferred, String.t(), pos_integer()})

  @callback slug() :: String.t()
  @callback source_attrs() :: map()
  @callback adapter_version() :: String.t()
  @callback capabilities() :: map()
  @callback enabled?() :: boolean()
  @callback automatic_mapping(map()) :: {String.t(), map()}
  @callback request_options(map()) :: keyword()
  @callback validate_mapping(String.t(), map()) :: :ok | {:error, atom()}
  @callback retrieve(String.t(), map(), map(), request_fun()) ::
              {:ok, map()}
              | {:error, String.t()}
              | {:deferred, String.t(), pos_integer(), map()}

  @doc """
  One short qualifier shown beside the provider name on a shelf, or `nil`.

  It exists so the reader can say "CineGraph · keywords: TMDb" without any
  component knowing that CineGraph exists. It is not persisted: `source_attrs/0`
  is upserted into `sources` column by column, so a key that is not a column
  breaks the catalog seed.
  """
  @callback shelf_detail() :: String.t() | nil

  @optional_callbacks automatic_mapping: 1,
                      request_options: 1,
                      validate_mapping: 2,
                      retrieve: 4,
                      shelf_detail: 0
end
