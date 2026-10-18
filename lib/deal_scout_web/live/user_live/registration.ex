defmodule DealScoutWeb.UserLive.Registration do
  use DealScoutWeb, :live_view

  alias DealScout.Accounts
  alias DealScout.Accounts.User

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <div class="mx-auto max-w-sm">
        <div class="text-center">
          <.header>
            Register for an account
            <:subtitle>
              Already registered?
              <.link navigate={~p"/users/log-in"} class="font-semibold text-brand hover:underline">
                Log in
              </.link>
              to your account now.
            </:subtitle>
          </.header>
        </div>

        <.form for={@form} id="registration_form" phx-submit="save" phx-change="validate">
          <.input
            field={@form[:email]}
            type="email"
            label="Email"
            autocomplete="username"
            spellcheck="false"
            required
            phx-mounted={JS.focus()}
          />

          <.input
            name="invite_code"
            value={@invite_code}
            type="text"
            label="Invite Code"
            placeholder="Enter invite code"
            required
          />

          <.button phx-disable-with="Creating account..." class="btn btn-primary w-full">
            Create an account
          </.button>
        </.form>
      </div>
    </Layouts.app>
    """
  end

  @impl true
  def mount(_params, _session, %{assigns: %{current_scope: %{user: user}}} = socket)
      when not is_nil(user) do
    {:ok, redirect(socket, to: DealScoutWeb.UserAuth.signed_in_path(socket))}
  end

  def mount(_params, _session, socket) do
    changeset = Accounts.change_user_email(%User{}, %{}, validate_unique: false)

    {:ok,
     socket
     |> assign_form(changeset)
     |> assign(:invite_code, ""), temporary_assigns: [form: nil]}
  end

  @impl true
  def handle_event("save", %{"user" => user_params, "invite_code" => invite_code}, socket) do
    expected_code = System.get_env("INVITE_CODE", "dealscout2026")

    if String.trim(invite_code) != expected_code do
      {:noreply,
       socket
       |> assign(:invite_code, invite_code)
       |> put_flash(:error, "Invalid invite code. DealScout is currently invite-only.")}
    else
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
  end

  def handle_event("validate", %{"user" => user_params} = params, socket) do
    invite_code = Map.get(params, "invite_code", socket.assigns.invite_code)
    changeset = Accounts.change_user_email(%User{}, user_params, validate_unique: false)

    {:noreply,
     socket
     |> assign(:invite_code, invite_code)
     |> assign_form(Map.put(changeset, :action, :validate))}
  end

  defp assign_form(socket, %Ecto.Changeset{} = changeset) do
    form = to_form(changeset, as: "user")
    assign(socket, form: form)
  end
end
