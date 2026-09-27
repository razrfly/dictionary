defmodule DevilsDictionary.Routing.Address do
  @moduledoc """
  The syntax of a public address, and nothing else (ADR 0004 §5, "Slug and
  locale decisions").

  Namespaces come only from `priv/routing/namespaces.json`. An English page is
  `/<namespace>/<slug>`; a future translation is `/l/<bcp47>/<namespace>/<slug>`.
  A stored path is decoded and normalized: NFC, Unicode lowercase, letters,
  marks, numbers and single hyphens, at most 120 UTF-8 bytes per segment.
  `Routing.Policy.slug/1` *proposes* segments from labels; this module only
  validates them, so an approved readable slug is never re-slugified.

  A request path is decoded exactly once, then NFC-normalized and lowercased —
  never re-slugified. Malformed encodings, encoded separators, NUL and dot
  segments are refused. A spelling that differs from the canonical encoding
  (case, Unicode form, a trailing slash, percent-encoding case) is reported as
  inexact, so the resolver can answer it with one 301.
  """

  @registry Path.expand("../../../priv/routing/namespaces.json", __DIR__)
  @external_resource @registry
  @namespaces @registry |> File.read!() |> Jason.decode!()

  @families Enum.map(@namespaces["public_families"], & &1["prefix"])
  @editorial @namespaces["editorial_prefix"]
  @locale_prefix @namespaces["future_locale_prefix"]
  @default_locale @namespaces["policy"]["default_locale"]
  @max_bytes @namespaces["policy"]["max_slug_utf8_bytes"]
  @editions "works"

  if @editions not in @families, do: raise("namespace registry lost the works family")

  @segment ~r/\A[\p{L}\p{M}\p{N}]+(?:-[\p{L}\p{M}\p{N}]+)*\z/u
  @locale ~r/\A[a-z]{2,3}(?:-[a-z0-9]{2,8})*\z/

  @doc "The eight subject-family prefixes, in registry order."
  def families, do: @families

  @doc "The launch locale, whose paths carry no locale prefix."
  def default_locale, do: @default_locale

  @doc """
  The namespaces a page role may be allocated under.

  Subjects take their approved family; editions are Works pages; On overviews
  are `/on`. Lexeme pages keep `/words/:id/:slug` and `/define/:slug`, which the
  ledger does not allocate. The registry does not yet give collections or
  choice pages a namespace, so allocating one is refused rather than guessed.
  """
  def namespaces_for(:subject), do: {:ok, @families}
  def namespaces_for(:edition), do: {:ok, [@editions]}
  def namespaces_for(:overview), do: {:ok, [@editorial]}
  def namespaces_for(:lexeme), do: {:error, :not_ledger_addressed}
  def namespaces_for(role) when role in [:collection, :choice], do: {:error, :namespace_undefined}

  @doc """
  Parses a stored-form path into its locale, namespace and slug.

      iex> DevilsDictionary.Routing.Address.parse("/concepts/c-plus-plus")
      {:ok, %{path: "/concepts/c-plus-plus", locale: "en", namespace: "concepts", slug: "c-plus-plus"}}

      iex> DevilsDictionary.Routing.Address.parse("/users/settings")
      {:error, :unknown_namespace}
  """
  def parse(path) when is_binary(path) do
    with true <- String.valid?(path) || {:error, :invalid_encoding},
         "/" <> rest <- path,
         {:ok, locale, namespace, slug} <- split(String.split(rest, "/")),
         :ok <- namespace(namespace),
         :ok <- segment(slug) do
      {:ok, %{path: path, locale: locale, namespace: namespace, slug: slug}}
    else
      {:error, reason} -> {:error, reason}
      _ -> {:error, :not_absolute}
    end
  end

  def parse(_), do: {:error, :not_absolute}

  defp split([@locale_prefix, locale, namespace, slug]) do
    if Regex.match?(@locale, locale) and locale != @default_locale,
      do: {:ok, locale, namespace, slug},
      else: {:error, :invalid_locale}
  end

  defp split([namespace, slug]), do: {:ok, @default_locale, namespace, slug}
  defp split(_segments), do: {:error, :invalid_shape}

  defp namespace(namespace) when namespace in @families or namespace == @editorial, do: :ok
  defp namespace(_namespace), do: {:error, :unknown_namespace}

  defp segment(slug) do
    cond do
      byte_size(slug) > @max_bytes -> {:error, :segment_too_long}
      String.normalize(slug, :nfc) != slug -> {:error, :not_normalized}
      String.downcase(slug) != slug -> {:error, :not_normalized}
      not Regex.match?(@segment, slug) -> {:error, :invalid_segment}
      true -> :ok
    end
  end

  @doc "Builds and validates a stored-form path for a locale."
  def build(namespace, slug, locale \\ @default_locale)

  def build(namespace, slug, @default_locale), do: checked("/#{namespace}/#{slug}")

  def build(namespace, slug, locale),
    do: checked("/#{@locale_prefix}/#{locale}/#{namespace}/#{slug}")

  defp checked(path) do
    with {:ok, _parsed} <- parse(path), do: {:ok, path}
  end

  @doc """
  Normalizes a raw request path (as received, percent-encoded) to stored form.

  Returns `{:ok, path, exact?}`, where `exact?` is false for an equivalent
  spelling that should be answered with a 301, or `{:error, reason}`.
  """
  def normalize_request(raw) when is_binary(raw) do
    with :ok <- refuse_encoded(raw),
         {:ok, decoded} <- decode_once(raw),
         {:ok, segments} <- segments(decoded),
         path = "/" <> Enum.map_join(segments, "/", &fold/1),
         {:ok, _parsed} <- parse(path) do
      {:ok, path, encode(path) == raw}
    end
  end

  def normalize_request(_raw), do: {:error, :not_absolute}

  defp refuse_encoded(raw) do
    cond do
      String.contains?(raw, <<0>>) or Regex.match?(~r/%00/, raw) -> {:error, :nul}
      Regex.match?(~r/%(?:2f|5c)/i, raw) -> {:error, :encoded_separator}
      String.contains?(raw, ["?", "#"]) -> {:error, :not_a_path}
      true -> :ok
    end
  end

  # `URI.decode/1` passes a truncated escape (`%A`) through untouched, so the
  # escapes are checked first: every `%` starts two hex digits.
  defp decode_once(raw) do
    cond do
      Regex.match?(~r/%(?![0-9A-Fa-f]{2})/, raw) ->
        {:error, :malformed_encoding}

      String.valid?(decoded = URI.decode(raw)) ->
        {:ok, decoded}

      true ->
        {:error, :invalid_utf8}
    end
  end

  # One trailing slash is an equivalent spelling; an empty or dot segment is
  # not a path we will interpret. The slash is removed as one byte: grapheme
  # slicing would take a prepended letter (U+0D4E, U+0600) with it.
  defp segments("/" <> rest) do
    rest =
      if String.ends_with?(rest, "/"),
        do: binary_part(rest, 0, byte_size(rest) - 1),
        else: rest

    segments = String.split(rest, "/")

    cond do
      Enum.any?(segments, &(&1 in [".", ".."])) -> {:error, :dot_segment}
      Enum.any?(segments, &(&1 == "")) -> {:error, :empty_segment}
      true -> {:ok, segments}
    end
  end

  defp segments(_decoded), do: {:error, :not_absolute}

  defp fold(segment),
    do: segment |> String.normalize(:nfc) |> String.downcase() |> String.normalize(:nfc)

  @doc """
  Percent-encodes each segment of a stored path for a link or `Location`
  header. Normalizing the result gives back the same path, exactly.

      iex> DevilsDictionary.Routing.Address.encode("/people/чехов")
      "/people/%D1%87%D0%B5%D1%85%D0%BE%D0%B2"
  """
  def encode(path) do
    path
    |> String.split("/")
    |> Enum.map_join("/", &URI.encode(&1, fn char -> URI.char_unreserved?(char) end))
  end
end
