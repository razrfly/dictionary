defmodule DevilsDictionaryWeb.Provenance do
  @moduledoc """
  The ⓘ drawer (#71 §2.6 and W4, U2): where a card came from.

  Nothing appears on this site without the source it came from, a link out and
  a way to see the raw record — the third of those is this panel. It shows the
  source with its tier and license, every `source_records` row the card cites,
  the concept links with the method and confidence that made them, and the
  trimmed raw payload of the one record the reader opened.

  Two rules shape it:

    * **It is URL state.** The panel opens on `?provenance=…`, patched in, so a
      drawer can be pasted to someone else — the same argument #71 §10 makes
      for the trail — and so it renders in the dead view, before the socket
      connects, where `Phoenix.LiveView.JS` cannot help.
    * **The raw is interpolated, never `Phoenix.HTML.raw/1`.** It is somebody
      else's JSON. `Word.source_card/1` renders `body_html` with `raw/1` a few
      lines away, which is exactly why this sentence is here.

  Everything it renders was decided by `Lexicon.WordPage.provenance/2`; the
  paths are built by the caller, so the panel does not know what a route is.
  """

  use DevilsDictionaryWeb, :html

  @doc """
  The panel. `close` is the path that dismisses it; `record_path` is a
  one-argument function from a record's index to the path that opens it.
  """
  attr :provenance, :map, required: true
  attr :close, :string, required: true
  attr :record_path, :any, required: true

  def provenance(assigns) do
    ~H"""
    <div id="provenance" class="fixed inset-0 z-30 flex justify-end">
      <.link
        id="provenance-backdrop"
        patch={@close}
        aria-hidden="true"
        tabindex="-1"
        class="absolute inset-0 bg-mist-950/20 dark:bg-mist-950/60"
      >
        <span class="sr-only">Close provenance</span>
      </.link>

      <aside
        id="provenance-panel"
        aria-label="Provenance"
        class="relative flex w-full max-w-md flex-col gap-6 overflow-y-auto border-l border-mist-950/10 bg-mist-50 px-6 py-6 dark:border-white/10 dark:bg-mist-950"
      >
        <header class="flex items-start justify-between gap-4">
          <div>
            <.eyebrow>provenance</.eyebrow>
            <p
              id="provenance-title"
              class="mt-1 text-base/7 font-medium text-mist-950 dark:text-white"
            >
              {@provenance.title}
            </p>
            <p :if={@provenance.source} id="provenance-source" class="text-sm/6 text-mist-500">
              <span aria-hidden="true" class="mr-1">{tier_glyph(@provenance.source.tier)}</span>
              <span :if={@provenance.source.name != @provenance.title}>
                {@provenance.source.name}
              </span>
              <span :if={@provenance.source.license}>
                <.link
                  :if={@provenance.source.license_url}
                  href={@provenance.source.license_url}
                  target="_blank"
                  rel="noopener"
                  class="underline underline-offset-4"
                >
                  {@provenance.source.license}
                </.link>
                <span :if={!@provenance.source.license_url}>{@provenance.source.license}</span>
              </span>
            </p>
          </div>

          <.link
            id="provenance-close"
            patch={@close}
            class="shrink-0 rounded-full px-2 py-1 text-mist-500 hover:bg-mist-950/5 hover:text-mist-950 dark:hover:bg-white/10 dark:hover:text-white"
          >
            <span aria-hidden="true">✕</span>
            <span class="sr-only">Close provenance</span>
          </.link>
        </header>

        <p :if={@provenance.records == []} id="provenance-no-records" class="text-sm/7 text-mist-500">
          No record of its own. What is on the page was derived from another source's row.
        </p>

        <ol :if={@provenance.records != []} id="provenance-records" class="flex flex-col gap-4">
          <li
            :for={record <- @provenance.records}
            id={"provenance-record-#{record.index}"}
            class={[
              "rounded-lg border p-3 text-sm/6",
              record.index == @provenance.open && "border-mist-950/20 dark:border-white/20",
              record.index != @provenance.open && "border-mist-950/5 dark:border-white/5"
            ]}
          >
            <p class="flex flex-wrap items-baseline gap-x-2">
              <span class="text-mist-700 dark:text-mist-400">record</span>
              <code class="font-mono text-mist-950 dark:text-white">{record.external_id}</code>
              <span
                :if={record.source && @provenance.source && record.source.id != @provenance.source.id}
                class="text-mist-500"
              >
                · {record.source.name}
              </span>
            </p>

            <.link
              :if={record.url}
              id={"provenance-record-#{record.index}-url"}
              href={record.url}
              target="_blank"
              rel="noopener"
              class="mt-1 block truncate text-mist-500 underline underline-offset-4 hover:text-mist-950 dark:hover:text-white"
            >
              {record.url} <span aria-hidden="true">↗</span>
            </.link>

            <p class="mt-1 text-mist-500">
              fetched {stamp(record.fetched_at)} · changed {stamp(record.changed_at)} · materialized {stamp(
                record.materialized_at
              )}
            </p>

            <.link
              :if={record.index != @provenance.open}
              id={"provenance-record-#{record.index}-open"}
              patch={@record_path.(record.index)}
              class="mt-1 inline-block text-mist-500 underline underline-offset-4 hover:text-mist-950 dark:hover:text-white"
            >
              show this record
            </.link>
          </li>
        </ol>

        <div :if={@provenance.links != []} id="provenance-links" class="text-sm/6">
          <p class="text-mist-700 dark:text-mist-400">links</p>
          <p
            :for={link <- @provenance.links}
            id={"provenance-link-#{link.qid}-#{link.method}"}
            class="mt-1 text-mist-500"
          >
            <span class="text-mist-950 dark:text-white">{link.qid}</span>
            <span :if={link.label}>{link.label}</span>
            · {link.method} · {confidence(link.confidence)} · {link.status}
          </p>
        </div>

        <details :if={@provenance.raw} id="provenance-raw" class="text-sm/6">
          <summary class="cursor-pointer list-none text-mist-700 hover:text-mist-950 [&::-webkit-details-marker]:hidden dark:text-mist-400 dark:hover:text-white">
            raw record <span class="text-mist-500">({bytes(@provenance.raw.bytes)})</span>
          </summary>
          <p :if={@provenance.raw.truncated?} id="provenance-raw-truncated" class="mt-2 text-mist-500">
            showing the first {bytes(@provenance.raw.shown)} of {bytes(@provenance.raw.bytes)}; the
            whole record is what materialize reads.
          </p>
          <pre class="mt-2 max-h-96 overflow-auto rounded-lg bg-mist-950/5 p-3 font-mono text-xs/5 text-mist-700 dark:bg-white/5 dark:text-mist-400"><code>{@provenance.raw.json}</code></pre>
        </details>
      </aside>
    </div>
    """
  end

  defp stamp(nil), do: "—"

  defp stamp(%{} = at) do
    at |> NaiveDateTime.truncate(:second) |> to_string() |> String.replace("T", " ")
  end

  defp confidence(nil), do: "—"
  defp confidence(value), do: :erlang.float_to_binary(value * 1.0, decimals: 2)

  defp bytes(n) when n < 1024, do: "#{n} B"
  defp bytes(n), do: "#{Float.round(n / 1024, 1)} kB"
end
