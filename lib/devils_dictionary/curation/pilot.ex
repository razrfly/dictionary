defmodule DevilsDictionary.Curation.Pilot do
  @moduledoc """
  The pilot allowlist (#253 D2): the only pages curation runs on during the
  MVP. "Pilot allowlist only during MVP; later expansion disabled" (#253 D7,
  #259 §4): there is no candidate threshold and no widening to every
  published composition.

  Configuration may name other pages
  (`config :devils_dictionary, :curation_pilot_pages, [...]`); nothing here is
  a table. The list is a default in code rather than a line in
  `config/config.exs` because the published host goes live without a restart
  (#250), and Phoenix's code reloader refuses to compile once a configuration
  file has changed since boot (#257).
  """

  @pages ~w(nepotism greed war love coward patience justice truth hope bestiality)

  @doc "The pilot pages' slugs: `:curation_pilot_pages`, by default #253 D2's ten."
  def pages, do: Application.get_env(:devils_dictionary, :curation_pilot_pages, @pages)

  @doc "Whether `slug` is a pilot page."
  def page?(slug) when is_binary(slug), do: slug in pages()
  def page?(_slug), do: false
end
