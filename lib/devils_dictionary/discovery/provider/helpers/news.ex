defmodule DevilsDictionary.Discovery.Provider.Helpers.News do
  @moduledoc """
  What every news provider needs, and what none of them should own (#144 Phase 1).

  Bing News (#135) is the first `:news` provider and the Guardian (#142) is the
  second. Both publish articles, neither publishes an article **id**, and both
  write to the same `news_article` namespace so that `Shelf.dedup/2` can fold
  the same story reported twice into one card. That fold only works if the two
  providers compute the same identity for the same article — which means the
  URL normalisation is not Bing's, it is the shelf's.

  `BingNews.normalize/1` and `BingNews.article_id/1` were public and `@doc`'d
  and called by nobody else, and #142's plan was for the Guardian to call them.
  A provider depending on a sibling for a rule that belongs to the kit is the
  shape this phase exists to remove, so they moved here before the second
  caller arrived rather than after.
  """

  # Click ids, campaign ids and the referrer breadcrumbs a syndicator staples
  # on. None of them name a different article, and two feeds carrying the same
  # story rarely staple the same ones.
  @tracking_parameters ~w(
    fbclid gclid gbraid wbraid msclkid dclid yclid
    mc_cid mc_eid igshid twclid ttclid
    ocid cmp icid ito smid srnd taid partner
    guccounter guce_referrer guce_referrer_sig
    ref referrer source amp __twitter_impression
  )

  @doc "The query parameters stripped before an article URL becomes an identity."
  def tracking_parameters, do: @tracking_parameters

  @doc """
  One publisher URL, normalised so that the same article twice is one item.

  Scheme and host lowercased, the fragment dropped, tracking parameters
  stripped and what is left **sorted**. Sorting is part of it because two feeds
  on the same `news_article` namespace can name the same article with the same
  parameters in a different order, and an identity that depended on their order
  would not merge.

  A `userinfo` in a news URL is not a thing, and carrying one into an `href`
  would be.
  """
  def normalize(%URI{} = uri) do
    %URI{
      uri
      | scheme: uri.scheme && String.downcase(uri.scheme),
        host: uri.host && String.downcase(uri.host),
        fragment: nil,
        query: normalize_query(uri.query),
        userinfo: nil
    }
    |> URI.to_string()
  end

  defp normalize_query(nil), do: nil

  defp normalize_query(query) do
    query
    |> URI.decode_query()
    |> Enum.reject(fn {key, _value} ->
      downcased = String.downcase(key)
      downcased in @tracking_parameters or String.starts_with?(downcased, "utm_")
    end)
    |> Enum.sort()
    |> case do
      [] -> nil
      pairs -> URI.encode_query(pairs)
    end
  end

  @doc """
  The stable identity of one article: the digest of its normalised URL.

  The URL is the only identity a news feed publishes — there is no article id
  in either envelope — and it is the one a keyed provider can also compute for
  the same article, which is what lets `Shelf.dedup/2` fold the two.
  """
  def article_id(url) when is_binary(url) do
    :crypto.hash(:sha256, url) |> Base.encode16(case: :lower) |> binary_part(0, 32)
  end
end
