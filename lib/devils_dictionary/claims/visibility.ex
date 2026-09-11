defmodule DevilsDictionary.Claims.Visibility do
  @moduledoc """
  The single public-display policy for claim projections and revisioned text.

  Public relationship reads exclude withdrawn/rejected claim revisions and
  attachments whose current content or sense revision is withdrawn. Pending
  and disputed claims remain visible with their actual state: hiding a dispute
  would make the correction process invisible.

  Rights restrictions are a different axis. They redact bodies, excerpts and
  quoted evidence while retaining identity, source and revision provenance.
  A revision is metadata-only when any of these source-neutral declarations is
  present in `rights_metadata`:

    * `display` is `restricted`, `metadata_only`, `identity_only` or `none`
    * `allow_display` or `display_allowed` is false

  Internal readers may inspect retained text only through an explicitly
  authorized call site; callers never get internal visibility by adding a URL
  parameter.
  """

  @restricted_display ~w(restricted metadata_only identity_only none)

  @doc "Whether a content revision permits its body to be shown publicly."
  def body_displayable?(%{rights_metadata: metadata}) when is_map(metadata) do
    display = value(metadata, "display")
    allow = value(metadata, "allow_display")
    allowed = value(metadata, "display_allowed")

    to_string(display || "") not in @restricted_display and allow != false and allowed != false
  end

  def body_displayable?(_), do: true

  @doc "Redacts a public content projection without erasing its provenance."
  def restrict_content(view, visibility \\ :public)

  def restrict_content(view, :internal), do: Map.put(view, :display_restricted?, false)

  def restrict_content(view, :public) do
    if body_displayable?(view) do
      Map.put(view, :display_restricted?, false)
    else
      view
      |> Map.put(:body, nil)
      |> Map.put(:summary, nil)
      |> Map.put(:display_restricted?, true)
    end
  end

  @doc "A stable public label when restricted text cannot supply one."
  def content_label(headword, body, id, rights_metadata \\ %{}) do
    if body_displayable?(%{rights_metadata: rights_metadata}) do
      headword || truncate(body) || "Content ##{id}"
    else
      headword || "Restricted content ##{id}"
    end
  end

  defp truncate(nil), do: nil
  defp truncate(body), do: String.slice(body, 0, 80)

  defp value(metadata, "display"), do: fetch_string_or_atom(metadata, "display", :display)

  defp value(metadata, "allow_display"),
    do: fetch_string_or_atom(metadata, "allow_display", :allow_display)

  defp value(metadata, "display_allowed"),
    do: fetch_string_or_atom(metadata, "display_allowed", :display_allowed)

  defp fetch_string_or_atom(metadata, string, atom) do
    case Map.fetch(metadata, string) do
      {:ok, value} -> value
      :error -> Map.get(metadata, atom)
    end
  end
end
