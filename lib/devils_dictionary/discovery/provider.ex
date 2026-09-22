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

  "Optional" here means *optional to a registry-only module*, and nothing
  weaker. `retrieve/4`, `automatic_mapping/1`, `request_options/1` and
  `validate_mapping/2` are the four the pipeline drives, and
  `DevilsDictionary.Discovery.Providers.retrievable?/1` requires **all four or
  none**: a module that claims `background: true, transport: :server` and
  exports three of them is refused at the gate, and at boot
  (`Providers.validate!/0`). `validate_mapping/2` is in that set since #144
  Phase 0 — it was documented as optional while `Discovery` called it
  unconditionally, on every render as well as mid-run.
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
      *successful* requests. `Discovery.Transport` reserves every attempt a
      slot that far after the provider's latest one, across every run on every
      node, so a run of `1 + n` requests holds the rate however many stages it
      runs and two concurrent runs share the rate instead of doubling it.
      Absent means unpaced.
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
  Decodes a response body the shared transport could not, into a map or a list.

  Not defining this — the default — means this provider answers JSON, which Req
  decodes and `DevilsDictionary.Discovery.Transport` hands straight to
  `retrieve/4`'s `request_fun`. A provider that also declares `body: :xml` in
  `capabilities/0` is handed the **binary** 200 instead and returns `{:ok,
  decoded}`, or `:error` for a body it cannot read, which the transport reports
  as the same `"malformed_response"` a bad JSON envelope gets.

  It exists so that the format a source speaks is the provider's knowledge and
  not a branch per format in the shared transport. Bing's news feed is RSS 2.0
  (#135) and is the only one so far; `parse/1` inside such a provider therefore
  sees the decoded map and never the document twice.
  """
  @callback parse_body(binary()) :: {:ok, map() | list()} | :error

  @doc """
  One short qualifier shown beside the provider name on a shelf, or `nil`.

  It exists so the reader can say "CineGraph · keywords: TMDb" without any
  component knowing that CineGraph exists. It is not persisted: `source_attrs/0`
  is upserted into `sources` column by column, so a key that is not a column
  breaks the catalog seed.
  """
  @callback shelf_detail() :: String.t() | nil

  @doc """
  A mark this source's licence *requires* the shelf to carry, or `nil`.

  Not a logo a source would like shown — one its terms make a condition of
  using it at all. The Guardian's Open Platform terms, clause 6(b)(vi), are
  the first: a "Powered by The Guardian" logo on the same page as any
  republished content, reproduced from the file the Guardian publishes, linked
  back to theguardian.com and placed adjacent to the content.

  It is the same shape of answer as `shelf_detail/0` and for the same reason:
  the reader renders whatever is here and knows no provider by name. A source
  with nothing to declare does not export it and no shelf gains a mark.

  The map is:

    * `:src` — the image, a path under `priv/static`
    * `:dark_src` — the variant for dark mode, or `nil` to use `:src` for both
    * `:alt` — the text, which is also what a screen reader is owed
    * `:href` — where the mark links, which the licence usually dictates
    * `:width` — the intrinsic width in CSS pixels the mark is drawn at

  A required *credit* is a different obligation and is already served by the
  content type's `attribution` column and `preview_metadata["attribution"]`:
  that is per item, this is per shelf.
  """
  @callback attribution_mark() ::
              %{
                required(:src) => String.t(),
                required(:alt) => String.t(),
                required(:href) => String.t(),
                required(:width) => pos_integer(),
                optional(:dark_src) => String.t() | nil
              }
              | nil

  @doc """
  What a browser-transport provider's shelf needs to run itself, or `nil`.

  A provider whose `capabilities/0` says `transport: :browser` is never driven
  by the shared pipeline: its requests leave the **reader's** browser, nothing
  is persisted, and the ledger gains nothing it could (K10). What the server
  does is decide whether the shelf appears at all — the provider is enabled,
  its key is present, its source row is active, and there is a target — and
  hand the page the parameters.

  Returning a map puts one browser shelf on the page. The keys the shared
  renderer reads:

    * `content_type` — which row of `DevilsDictionary.Discovery.ContentTypes`
      the shelf is, and therefore its heading, its card width and its title
      clamp, exactly as for a server provider
    * `hook` — the `phx-hook` name whose JavaScript makes the requests
    * `term`, `language` — the target, as `data-query` and `data-language`
    * `api_key` — optional, as `data-api-key`; absent for a keyless one
    * `note` — the sentence under the rail, which is the provider's to write
      because what its results *are* is the provider's knowledge
    * `badge` — optional `%{src:, alt:, href:}` for a licence that requires a
      mark shown, as GIPHY's terms do

  It became a callback in #144 Phase 3. Before that `WordLive` called
  `Giphy.browser_config/1` by name and `Culture` rendered `GiphyShelf` by
  name, so a second browser provider was three edits in shared files — and
  promise 9 of the README, *the reader knows no provider by name*, carried an
  exception for the one provider that had one.
  """
  @callback browser_config(target :: map()) :: map() | nil

  @optional_callbacks automatic_mapping: 1,
                      browser_config: 1,
                      covers?: 1,
                      parse_body: 1,
                      mapping_identity: 1,
                      request_options: 1,
                      validate_mapping: 2,
                      retrieve: 4,
                      shelf_detail: 0,
                      attribution_mark: 0,
                      retryable_status?: 1
end
