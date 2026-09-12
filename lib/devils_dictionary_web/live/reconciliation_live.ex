defmodule DevilsDictionaryWeb.ReconciliationLive do
  @moduledoc """
  The reviewer-only queue for attachments made ambiguous by an identity split.

  A reviewer can map the attachment to one declared split output, explicitly
  leave it unresolved, or decline a mapping. Mapping creates a new assertion
  revision; the original endpoint and its review/evidence history are never
  rewritten.
  """

  use DevilsDictionaryWeb, :live_view

  alias DevilsDictionary.Claims.{Connection, Contributions}

  @impl true
  def mount(_params, _session, socket) do
    {:ok, load_cases(socket)}
  end

  @impl true
  def handle_event("decide", %{"_case_id" => id, "decision" => decision} = params, socket) do
    case Integer.parse(id) do
      {case_id, ""} -> decide(case_id, decision, params, socket)
      _ -> {:noreply, put_flash(socket, :error, "Decision not saved: invalid case.")}
    end
  end

  defp decide(case_id, decision, params, socket) do
    result =
      Contributions.reconcile(
        socket.assigns.current_scope,
        case_id,
        decision,
        params["replacement_object_id"],
        params["reason"]
      )

    case result do
      {:ok, _} ->
        {:noreply,
         socket
         |> put_flash(:info, "Reconciliation decision recorded.")
         |> load_cases()}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Decision not saved: #{error_label(reason)}.")}
    end
  end

  defp load_cases(socket) do
    cases =
      socket.assigns.current_scope
      |> Contributions.list_reconciliation_cases()
      |> Enum.map(&decorate/1)

    forms = Map.new(cases, &{&1.id, to_form(%{"reason" => "", "replacement_object_id" => ""})})

    socket
    |> assign(:page_title, "reconciliation")
    |> assign(:case_forms, forms)
    |> stream(:cases, cases, reset: true)
  end

  defp decorate(kase) do
    candidates =
      kase.payload
      |> Map.get("candidate_output_ids", [])
      |> Enum.map(&Connection.endpoint/1)

    %{
      id: kase.id,
      input: Connection.endpoint(kase.object_id),
      assertion_id: kase.assertion_id,
      revision_id: kase.payload["assertion_revision_id"],
      roles: kase.payload["attachment_roles"] || List.wrap(kase.payload["endpoint_role"]),
      candidates: candidates,
      options: Enum.map(candidates, &{&1.label, &1.object_id})
    }
  end

  defp error_label(reason) when is_atom(reason) or is_binary(reason),
    do: reason |> to_string() |> String.replace("_", " ")

  defp error_label(%Ecto.Changeset{}), do: "the change was rejected"
  defp error_label(_reason), do: "the change could not be completed"

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <.container class="py-10">
        <header id="reconciliation-header">
          <.eyebrow>reviewer queue</.eyebrow>
          <.heading>Resolve split attachments</.heading>
          <.text class="mt-2 max-w-3xl">
            A split makes every affected attachment ambiguous. Choose only when the evidence supports a
            replacement; otherwise keep the ambiguity visible or decline the mapping.
          </.text>
        </header>

        <div id="reconciliation-cases" phx-update="stream" class="mt-10">
          <section
            id="reconciliation-empty"
            class="hidden only:block border-y border-mist-950/10 py-8 dark:border-white/10"
          >
            <p class="text-base/7 text-mist-500 sm:text-sm/6">No split attachments need review.</p>
          </section>

          <section
            :for={{dom_id, kase} <- @streams.cases}
            id={dom_id}
            class="border-t border-mist-950/10 py-8 first:border-t-0 dark:border-white/10"
          >
            <div class="grid gap-2 sm:grid-cols-[minmax(0,1fr)_auto] sm:items-start sm:gap-6">
              <div class="min-w-0">
                <p class="font-medium">{kase.input.label}</p>
                <p class="text-base/7 text-mist-500 text-pretty sm:text-sm/6">
                  Claim {kase.assertion_id}, revision {kase.revision_id}; affected attachments: {Enum.join(
                    kase.roles,
                    ", "
                  )}.
                </p>
              </div>
              <.a navigate={~p"/connections/#{kase.assertion_id}"}>Inspect connection</.a>
            </div>

            <.form
              for={Map.fetch!(@case_forms, kase.id)}
              id={"reconciliation-form-#{kase.id}"}
              phx-submit="decide"
              class="mt-5 grid gap-4 sm:grid-cols-2"
            >
              <input type="hidden" name="_case_id" value={kase.id} />
              <.input
                field={Map.fetch!(@case_forms, kase.id)[:replacement_object_id]}
                type="select"
                label="Replacement"
                prompt="Choose a declared output"
                options={kase.options}
              />
              <.input
                field={Map.fetch!(@case_forms, kase.id)[:reason]}
                type="textarea"
                label="Evidence and reason"
                required
              />
              <div class="flex flex-wrap gap-2 sm:col-span-2">
                <.button variant="soft" name="decision" value="map" type="submit">
                  Save mapping
                </.button>
                <.button variant="soft" name="decision" value="unresolved" type="submit">
                  Keep unresolved
                </.button>
                <.button variant="soft" name="decision" value="decline" type="submit">
                  Decline mapping
                </.button>
              </div>
            </.form>
          </section>
        </div>
      </.container>
    </Layouts.app>
    """
  end
end
