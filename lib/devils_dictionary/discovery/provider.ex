defmodule DevilsDictionary.Discovery.Provider do
  @moduledoc """
  The deliberately small contract shared by cultural discovery providers.

  Providers may differ in transport, operations, persistence, pagination and
  attribution. The shared boundary is identity, factual match provenance and a
  normalized card; it is not a promise that every provider supports the same
  search operation.
  """

  @type request_fun ::
          (map() -> {:ok, map()} | {:error, String.t()} | {:deferred, String.t(), pos_integer()})

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
end
