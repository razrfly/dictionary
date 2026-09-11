defmodule DevilsDictionaryWeb.UserLive.Registration do
  use DevilsDictionaryWeb, :live_view

  alias DevilsDictionary.Accounts
  alias DevilsDictionary.Accounts.User

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <section
        id="registration-page"
        class="min-h-[calc(100dvh-var(--scroll-padding-top))] bg-white py-12 sm:py-20 dark:bg-mist-950"
      >
        <.container>
          <div class="mx-auto flex max-w-xs flex-col gap-8">
            <header class="flex flex-col gap-3 text-center">
              <p class="text-base/7 font-semibold text-mist-600 sm:text-sm/6 dark:text-mist-400">
                Reader account
              </p>
              <h1 class="font-display text-4xl tracking-tight text-balance text-mist-950 sm:text-5xl dark:text-white">
                Register
              </h1>
              <p class="text-pretty text-base/7 text-mist-600 sm:text-sm/6 dark:text-mist-400">
                Already registered? <.a navigate={~p"/users/log-in"}>Log in</.a>.
              </p>
            </header>

            <.form
              for={@form}
              id="registration_form"
              phx-submit="save"
              phx-change="validate"
              class="flex flex-col gap-2"
            >
              <.input
                id="registration_form_email"
                field={@form[:email]}
                type="email"
                label="Email"
                autocomplete="username"
                spellcheck="false"
                required
                phx-mounted={JS.focus()}
              />

              <.button type="submit" size="lg" class="w-full" phx-disable-with="Creating account…">
                Create account
              </.button>
            </.form>

            <p class="text-pretty text-center text-base/7 text-mist-500 sm:text-sm/6">
              Accounts are available for reading and account settings. Contributions remain in internal testing.
            </p>
          </div>
        </.container>
      </section>
    </Layouts.app>
    """
  end

  @impl true
  def mount(_params, _session, %{assigns: %{current_scope: %{user: user}}} = socket)
      when not is_nil(user) do
    {:ok, redirect(socket, to: DevilsDictionaryWeb.UserAuth.signed_in_path(socket))}
  end

  def mount(_params, _session, socket) do
    changeset = Accounts.change_user_email(%User{}, %{}, validate_unique: false)

    {:ok, assign_form(socket, changeset), temporary_assigns: [form: nil]}
  end

  @impl true
  def handle_event("save", %{"user" => user_params}, socket) do
    case Accounts.register_user(user_params) do
      {:ok, user} ->
        {:ok, _} =
          Accounts.deliver_login_instructions(
            user,
            &url(~p"/users/log-in/#{&1}")
          )

        {:noreply,
         socket
         |> put_flash(
           :info,
           "An email was sent to #{user.email}, please access it to confirm your account."
         )
         |> push_navigate(to: ~p"/users/log-in")}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign_form(socket, changeset)}
    end
  end

  def handle_event("validate", %{"user" => user_params}, socket) do
    changeset = Accounts.change_user_email(%User{}, user_params, validate_unique: false)
    {:noreply, assign_form(socket, Map.put(changeset, :action, :validate))}
  end

  defp assign_form(socket, %Ecto.Changeset{} = changeset) do
    form = to_form(changeset, as: "user")
    assign(socket, form: form)
  end
end
