defmodule DevilsDictionary.Routing.PageMetadata do
  @moduledoc """
  What a subject page says about itself (#237, ADR 0004 §7): its title, its
  canonical address and its description — the "complete metadata" a page
  must be able to derive before it may be published (`Routing.Publications`,
  gate 7).

  The description is the page's first displayable sentence: the subject's
  own description as the page shows it, otherwise the first sentence of its
  first biography paragraph whose rights permit display, otherwise of its
  first displayable definition. Never text the page withholds.
  """

  alias DevilsDictionary.Encyclopedia.EntityPage
  alias DevilsDictionary.Routing.{Address, Policy}

  @limit 160

  @family_labels Policy.root()
                 |> Path.join("namespaces.json")
                 |> File.read!()
                 |> Jason.decode!()
                 |> Map.fetch!("public_families")
                 |> Map.new(&{&1["prefix"], &1["label"]})

  @doc "The label a family's prefix carries in the namespace registry."
  def family_label(prefix), do: Map.get(@family_labels, prefix)

  @doc """
  A subject or edition page's metadata from its built `EntityPage` and its
  canonical path: `%{title:, family:, family_label:, canonical_path:,
  description:}`; any of them nil when the page cannot supply it.
  """
  def subject(%EntityPage{} = page, canonical_path) when is_binary(canonical_path) do
    family =
      case Address.parse(canonical_path) do
        {:ok, %{namespace: namespace}} -> namespace
        _ -> nil
      end

    %{
      title: present(page.entity && page.entity.label),
      family: family,
      family_label: family && family_label(family),
      canonical_path: canonical_path,
      description: description(page)
    }
  end

  @doc "The page's first displayable sentence, or nil."
  def description(%EntityPage{} = page) do
    biography = for b <- page.biography, not b[:display_restricted?], do: b[:body]
    definitions = for d <- page.definitions, not d[:display_restricted?], do: d[:body]

    Enum.find_value([page.entity && page.entity.description | biography ++ definitions], fn
      text when is_binary(text) -> first_sentence(text)
      _ -> nil
    end)
  end

  @doc """
  The first sentence of a text, as plain text: tags and Markdown marks
  removed, whitespace collapsed, at most #{@limit} characters, cut at a word.
  """
  def first_sentence(text) when is_binary(text) do
    plain =
      text
      |> String.replace(~r/<[^>]*>/u, " ")
      |> String.replace(~r/\[([^\]]*)\]\([^)]*\)/u, "\\1")
      |> String.replace(~r/[*_`#>]+/u, "")
      |> String.replace(~r/\s+/u, " ")
      |> String.trim()

    sentence =
      case Regex.run(~r/\A.+?[.!?](?=\s|\z)/u, plain) do
        [match] -> match
        nil -> plain
      end

    present(cut(sentence))
  end

  def first_sentence(_text), do: nil

  defp cut(text) do
    if String.length(text) <= @limit do
      text
    else
      head = String.slice(text, 0, @limit - 1)

      case Regex.run(~r/\A(.+)\s\S*\z/u, head) do
        [_, words] -> String.trim_trailing(words, " ,;:") <> "…"
        nil -> head <> "…"
      end
    end
  end

  defp present(nil), do: nil

  defp present(text) when is_binary(text) do
    case String.trim(text) do
      "" -> nil
      trimmed -> trimmed
    end
  end
end
