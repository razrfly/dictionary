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
  @doc """
  What this provider can do, as data the shared pipeline branches on.

  Required keys: `background`, `transport`, `persistence`, `pagination`,
  `operations`, `content_types`. Two optional keys are read by the shared
  transport, and both are pacing the provider knows and the pipeline does not:

    * `min_retry_interval_ms` — the shortest gap this provider's API tolerates
      between a failed attempt and the next one. `Discovery.Transport` waits the
      longer of this and the shared `:retry_delay_ms`, so a provider that
      answers a burst with a throttle does not retry straight back into it.
    * `request_interval_ms` — the sustained gap between this provider's
      *successful* requests. `Discovery.Transport` waits it before every
      attempt, so a run of `1 + n` requests holds the rate however many stages
      it runs. Absent means unpaced.
  """
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
  Whether this provider has anything to work with for a target, before any run.

  The default, applied when a provider does not define this, is `true` — a
  keyword search can be run for any word, so CineGraph and GIPHY never decline.
  The Met can not: its match key is a Wikidata QID the target's senses already
  refer to, and for a target with no such link there is no query to make and no
  result that could pass the identity gate. Declining is how that provider
  avoids admitting a run whose only possible outcome is empty, and how the page
  avoids showing a shelf that was never going to hold anything.

  This is not eligibility — the provider is enabled, configured and permitted.
  It is the provider reading the target and saying *not this one*.
  """
  @callback covers?(map()) :: boolean()

  @doc """
  A fingerprint of the evidence a recipe from `automatic_mapping/1` rests on.

  Not defining this — the default — means the mapping for a target is
  identified by provider, target and adapter version alone, which is right for
  a provider whose recipe is just the word.

  A provider whose recipe freezes data that can change out from under it
  returns a short, stable digest of that data instead. It is appended to the
  automatic mapping key, so evidence moving produces a *new mapping version*
  rather than a reused row still carrying the old parameters, and it is
  recomputed before a run publishes, so a run cannot outlive the claim that
  justified it.

  The Met needs this: its mapping parameters freeze the QIDs the target's
  senses refer to, and a `refers_to` claim can be withdrawn or replaced while
  coverage stays non-empty. Without the fingerprint a mapping created for QID A
  would keep querying A after the encyclopedia had moved to B.

  It takes the parameters and not the target so that it is a pure function of
  the recipe: the pipeline builds the recipe once and derives the key from it,
  rather than reading the same evidence a second time to name it.
  """
  @callback mapping_identity(parameters :: map()) :: String.t() | nil

  @doc """
  Whether an HTTP status is worth another bounded attempt.

  The default, applied when a provider does not define this, is `429` or any
  `5xx` — a throttle or a server fault. A provider overrides it when its API
  reports backpressure some other way, and must keep the default cases
  retryable; `Discovery.Transport.default_retryable_status?/1` is public so an
  implementation can delegate to it rather than restate it.

  This exists because a status code is a provider's dialect, not a fact. The Met
  answers a keyless, throttled request with `403` and no `Retry-After`, so for
  that provider a `403` is a backoff signal and treating it as an
  authentication verdict is both wrong and unrecoverable.
  """
  @callback retryable_status?(non_neg_integer()) :: boolean()

  @doc """
  One short qualifier shown beside the provider name on a shelf, or `nil`.

  It exists so the reader can say "CineGraph · keywords: TMDb" without any
  component knowing that CineGraph exists. It is not persisted: `source_attrs/0`
  is upserted into `sources` column by column, so a key that is not a column
  breaks the catalog seed.
  """
  @callback shelf_detail() :: String.t() | nil

  @optional_callbacks automatic_mapping: 1,
                      covers?: 1,
                      mapping_identity: 1,
                      request_options: 1,
                      validate_mapping: 2,
                      retrieve: 4,
                      shelf_detail: 0,
                      retryable_status?: 1
end
