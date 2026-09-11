defmodule DevilsDictionaryWeb.UserLive.Login do
  use DevilsDictionaryWeb, :live_view

  alias DevilsDictionary.Accounts

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <section
        id="login-page"
        class="min-h-[calc(100dvh-var(--scroll-padding-top))] bg-white py-12 sm:py-20 dark:bg-mist-950"
      >
        <.container>
          <div class="mx-auto flex max-w-xs flex-col gap-8">
            <header class="flex flex-col gap-3 text-center">
              <p class="text-base/7 font-semibold text-mist-600 sm:text-sm/6 dark:text-mist-400">
                Reader account
              </p>
              <h1 class="font-display text-4xl tracking-tight text-balance text-mist-950 sm:text-5xl dark:text-white">
                Log in
              </h1>
              <p class="text-pretty text-base/7 text-mist-600 sm:text-sm/6 dark:text-mist-400">
                <%= if @current_scope do %>
                  You need to reauthenticate before changing sensitive account details.
                <% else %>
                  New to wordhoard? <.a navigate={~p"/users/register"}>Sign up for an account</.a>.
                <% end %>
              </p>
            </header>

            <div
              :if={local_mail_adapter?()}
              id="local-mail-notice"
              class="flex items-start gap-3 rounded-xl bg-mist-950/5 p-4 dark:bg-white/5"
            >
              <.icon
                name="hero-information-circle"
                class="size-4 h-lh shrink-0 stroke-mist-600 dark:stroke-mist-400"
              />
              <p class="text-pretty text-base/7 text-mist-600 sm:text-sm/6 dark:text-mist-400">
                Local email is enabled. Open
                <.a href="/dev/mailbox">the mailbox</.a>
                to retrieve a login link.
              </p>
            </div>

            <.form
              for={@form}
              id="login_form_magic"
              action={~p"/users/log-in"}
              phx-submit="submit_magic"
              class="flex flex-col gap-2"
            >
              <.input
                id="login_form_magic_email"
                readonly={!!@current_scope}
                field={@form[:email]}
                type="email"
                label="Email"
                autocomplete="username"
                spellcheck="false"
                required
                phx-mounted={JS.focus()}
              />
              <.button type="submit" size="lg" class="w-full" phx-disable-with="Sending login link…">
                Log in with email
              </.button>
            </.form>

            <div class="flex items-center gap-4" aria-hidden="true">
              <div class="h-px grow bg-mist-950/10 dark:bg-white/10"></div>
              <span class="text-mist-500">or use a password</span>
              <div class="h-px grow bg-mist-950/10 dark:bg-white/10"></div>
            </div>

            <.form
              for={@form}
              id="login_form_password"
              action={~p"/users/log-in"}
              phx-submit="submit_password"
              phx-trigger-action={@trigger_submit}
              class="flex flex-col gap-2"
            >
              <.input
                id="login_form_password_email"
                readonly={!!@current_scope}
                field={@form[:email]}
                type="email"
                label="Email"
                autocomplete="username"
                spellcheck="false"
                required
              />
              <.input
                id="login_form_password_password"
                field={@form[:password]}
                type="password"
                label="Password"
                autocomplete="current-password"
                spellcheck="false"
              />
              <div class="flex flex-col gap-2 pt-1">
                <.button
                  type="submit"
                  variant="soft"
                  size="lg"
                  class="w-full"
                  name={@form[:remember_me].name}
                  value="true"
                >
                  Log in and stay logged in
                </.button>
                <.button type="submit" variant="plain" size="md" class="w-full">
                  Log in only this time
                </.button>
              </div>
            </.form>
          </div>
        </.container>
      </section>
    </Layouts.app>
    """
  end

  @impl true
  def mount(_params, _session, socket) do
    email =
      Phoenix.Flash.get(socket.assigns.flash, :email) ||
        get_in(socket.assigns, [:current_scope, Access.key(:user), Access.key(:email)])

    form = to_form(%{"email" => email}, as: "user")

    {:ok, assign(socket, form: form, trigger_submit: false)}
  end

  @impl true
  def handle_event("submit_password", _params, socket) do
    {:noreply, assign(socket, :trigger_submit, true)}
  end

  def handle_event("submit_magic", %{"user" => %{"email" => email}}, socket) do
    if user = Accounts.get_user_by_email(email) do
      Accounts.deliver_login_instructions(
        user,
        &url(~p"/users/log-in/#{&1}")
      )
    end

    info =
      "If your email is in our system, you will receive instructions for logging in shortly."

    {:noreply,
     socket
     |> put_flash(:info, info)
     |> push_navigate(to: ~p"/users/log-in")}
  end

  defp local_mail_adapter? do
    Application.get_env(:devils_dictionary, DevilsDictionary.Mailer)[:adapter] ==
      Swoosh.Adapters.Local
  end
end
