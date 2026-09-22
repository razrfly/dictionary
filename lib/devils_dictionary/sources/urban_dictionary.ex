defmodule DevilsDictionary.Sources.UrbanDictionary do
  @moduledoc """
  Urban Dictionary as one 📱 definition per word page, fetched by the reader.

  The first **on-demand definition source** (#136, from #134 Finding 3). It is
  neither an absorb adapter nor a discovery provider, and the reason is the
  same both times: a registry is a promise about what a module can be asked
  for.

    * Not in `DevilsDictionary.Sources.Catalog.sources/0` — scorecard A1 asks
      every catalog source for a finished absorb and a snapshot pin, and this
      one will never have either. Registering it there turns A1 red on the day
      it ships and keeps it red.
    * Not in `:discovery_providers` — the conformance suite asks every
      registered provider for a fixture and a *presentable content type*, and
      a definition is not a shelf. There is no `ContentTypes` row for it and
      there should not be one.

  So it is registered in `DevilsDictionary.Sources.OnDemand`, whose whole
  contract is `source_attrs/0`, `enabled?/0` and `browser_config/1`, and whose
  row is written by the same `on_conflict: :nothing` upsert the providers use.

  ## The transport

  `GET https://api.urbandictionary.com/v0/define?term=<word>`, keyless and
  CORS-open (`access-control-allow-origin: *`, measured 2026-09-21). The
  **reader's browser** makes that request; this server never does. Nothing
  comes back into a `source_records` row, a `senses` row, an Oban job or the
  replay archive, which is what `access: :api` with
  `"ingestion" => "none; nothing is stored"` says on the row itself.

  The terms (`https://urbandictionary.help/tos/`, read 2026-09-21) reserve API
  access to those with Urban Dictionary's express permission. The owner's email
  asking for it is step one and the date sits in `config` below; this module is
  the stopgap #134 Phase 3 describes, and `active: false` on the row retires it
  the day they answer no. See `docs/integrations/urban-dictionary.md`.

  ## The kill switches

  Two, and either one alone is enough, because `browser_config/1` returns `nil`
  unless **both** pass: `URBAN_DICTIONARY_ENABLED=false` in the environment and
  `active: false` on the row. `nil` means `WordLive` renders no shell — not a
  hidden one, not an empty one.
  """

  alias DevilsDictionary.Sources

  @slug "urban-dictionary"

  @doc "The source row's slug."
  def slug, do: @slug

  @doc """
  The `sources` row, as data.

  `era_year: 1999` is the site's founding year, which is what the tier diagram
  and `/sources` sort by. `license` names the terms rather than a licence
  because there is no licence: the content is the authors', licensed to Urban
  Dictionary and sublicensable by them, which is precisely why permission is
  asked for rather than assumed.
  """
  def source_attrs do
    %{
      slug: @slug,
      name: "Urban Dictionary",
      tier: :plebs,
      kind: :dictionary,
      access: :api,
      era_year: 1999,
      license: "Urban Dictionary Terms of Service; API access by permission",
      license_url: "https://urbandictionary.help/tos/",
      homepage: "https://www.urbandictionary.com/",
      logo: "/images/sources/urban-dictionary.png",
      url_template: "https://www.urbandictionary.com/define.php?term={term}",
      attribution: "Urban Dictionary",
      active: true,
      config: %{
        "transport" => "browser only",
        "ingestion" => "none; nothing is stored",
        "permission_requested_on" => permission_requested_on(),
        "permission_status" => "requested"
      }
    }
  end

  @doc """
  Whether the environment allows the card at all.

  Keyless, so — unlike GIPHY's — this reads nothing but the switch.
  """
  def enabled? do
    Application.get_env(:devils_dictionary, :urban_dictionary, [])[:enabled] != false
  end

  @doc """
  What the browser hook needs, or `nil` when there is to be no shell.

  `nil` on any of: no discovery target (a miss page, a page with no lexemes,
  or `?demo=1`), the environment switch off, no source row, or `active: false`.
  The shape is deliberately three strings — there is no key to hand out and
  nothing here is a secret, which is the difference between this and every
  server-side source on the page.
  """
  def browser_config(target) do
    source = Sources.get_source_by_slug(@slug)

    if target && enabled?() && source && source.active do
      %{
        term: target.term,
        endpoint: endpoint(),
        permalink_host: "www.urbandictionary.com",
        # Who the card is, from the row and not from the component (#152):
        # the header's badge and name, and the rail's stack, read these.
        source: %{slug: source.slug, name: source.name, tier: source.tier, logo: source.logo}
      }
    end
  end

  @doc "The date the owner's permission email went, or `\"pending\"` until it has."
  def permission_requested_on do
    Application.get_env(:devils_dictionary, :urban_dictionary, [])[:permission_requested_on] ||
      "pending"
  end

  defp endpoint do
    Application.get_env(:devils_dictionary, :urban_dictionary, [])[:endpoint] ||
      "https://api.urbandictionary.com/v0/define"
  end
end
