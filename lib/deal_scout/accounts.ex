defmodule DealScout.Accounts do
  @moduledoc """
  The Accounts context.
  """

  import Ecto.Query, warn: false
  alias DealScout.Repo

  alias DealScout.Accounts.{User, UserToken, UserNotifier, Scope}

  ## Database getters

  @doc """
  Gets a user by email.

  ## Examples

      iex> get_user_by_email("foo@example.com")
      %User{}

      iex> get_user_by_email("unknown@example.com")
      nil

  """
  def get_user_by_email(email) when is_binary(email) do
    Repo.get_by(User, email: email)
  end

  @doc """
  Gets a user by email and password.

  ## Examples

      iex> get_user_by_email_and_password("foo@example.com", "correct_password")
      %User{}

      iex> get_user_by_email_and_password("foo@example.com", "invalid_password")
      nil

  """
  def get_user_by_email_and_password(email, password)
      when is_binary(email) and is_binary(password) do
    user = Repo.get_by(User, email: email)
    if User.valid_password?(user, password), do: user
  end

  @doc """
  Gets a single user.

  Raises `Ecto.NoResultsError` if the User does not exist.

  ## Examples

      iex> get_user!(123)
      %User{}

      iex> get_user!(456)
      ** (Ecto.NoResultsError)

  """
  def get_user!(id), do: Repo.get!(User, id)

  ## User registration

  @doc """
  Registers a user with email and password, auto-confirming their account.

  ## Examples

      iex> register_user(%{field: value})
      {:ok, %User{}}

      iex> register_user(%{field: bad_value})
      {:error, %Ecto.Changeset{}}

  """
  def register_user(attrs) do
    %User{}
    |> User.registration_changeset(attrs)
    |> User.confirm_changeset()
    |> Repo.insert()
  end

  @doc """
  Returns an `%Ecto.Changeset{}` for tracking user registration changes.
  """
  def change_user_registration(user, attrs \\ %{}, opts \\ []) do
    opts = Keyword.put_new(opts, :hash_password, false)
    User.registration_changeset(user, attrs, opts)
  end

  ## Settings

  @doc """
  Checks whether the user is in sudo mode.

  The user is in sudo mode when the last authentication was done no further
  than 20 minutes ago. The limit can be given as second argument in minutes.
  """
  def sudo_mode?(user, minutes \\ -20)

  def sudo_mode?(%User{authenticated_at: ts}, minutes) when is_struct(ts, DateTime) do
    DateTime.after?(ts, DateTime.utc_now() |> DateTime.add(minutes, :minute))
  end

  def sudo_mode?(_user, _minutes), do: false

  @doc """
  Returns an `%Ecto.Changeset{}` for changing the user email.

  See `DealScout.Accounts.User.email_changeset/3` for a list of supported options.

  ## Examples

      iex> change_user_email(user)
      %Ecto.Changeset{data: %User{}}

  """
  def change_user_email(user, attrs \\ %{}, opts \\ []) do
    User.email_changeset(user, attrs, opts)
  end

  @doc """
  Updates the user email using the given token.

  If the token matches, the user email is updated and the token is deleted.
  """
  def update_user_email(user, token) do
    context = "change:#{user.email}"

    Repo.transact(fn ->
      with {:ok, query} <- UserToken.verify_change_email_token_query(token, context),
           %UserToken{sent_to: email} <- Repo.one(query),
           {:ok, user} <- Repo.update(User.email_changeset(user, %{email: email})),
           {_count, _result} <-
             Repo.delete_all(from(UserToken, where: [user_id: ^user.id, context: ^context])) do
        {:ok, user}
      else
        _ -> {:error, :transaction_aborted}
      end
    end)
  end

  @doc """
  Returns an `%Ecto.Changeset{}` for changing the user password.

  See `DealScout.Accounts.User.password_changeset/3` for a list of supported options.

  ## Examples

      iex> change_user_password(user)
      %Ecto.Changeset{data: %User{}}

  """
  def change_user_password(user, attrs \\ %{}, opts \\ []) do
    User.password_changeset(user, attrs, opts)
  end

  @doc """
  Updates the user password.

  Returns a tuple with the updated user, as well as a list of expired tokens.

  ## Examples

      iex> update_user_password(user, %{password: ...})
      {:ok, {%User{}, [...]}}

      iex> update_user_password(user, %{password: "too short"})
      {:error, %Ecto.Changeset{}}

  """
  def update_user_password(user, attrs) do
    user
    |> User.password_changeset(attrs)
    |> update_user_and_delete_all_tokens()
  end

  ## Session

  @doc """
  Generates a session token.
  """
  def generate_user_session_token(user) do
    {token, user_token} = UserToken.build_session_token(user)
    Repo.insert!(user_token)
    token
  end

  @doc """
  Gets the user with the given signed token.

  If the token is valid `{user, token_inserted_at}` is returned, otherwise `nil` is returned.
  """
  def get_user_by_session_token(token) do
    {:ok, query} = UserToken.verify_session_token_query(token)
    Repo.one(query)
  end

  @doc """
  Gets the user with the given magic link token.
  """
  def get_user_by_magic_link_token(token) do
    with {:ok, query} <- UserToken.verify_magic_link_token_query(token),
         {user, _token} <- Repo.one(query) do
      user
    else
      _ -> nil
    end
  end

  @doc """
  Logs the user in by magic link.

  There are three cases to consider:

  1. The user has already confirmed their email. They are logged in
     and the magic link is expired.

  2. The user has not confirmed their email and no password is set.
     In this case, the user gets confirmed, logged in, and all tokens -
     including session ones - are expired. In theory, no other tokens
     exist but we delete all of them for best security practices.

  3. The user has not confirmed their email but a password is set.
     This cannot happen in the default implementation but may be the
     source of security pitfalls. See the "Mixing magic link and password registration" section of
     `mix help phx.gen.auth`.
  """
  def login_user_by_magic_link(token) do
    {:ok, query} = UserToken.verify_magic_link_token_query(token)

    case Repo.one(query) do
      # Prevent session fixation attacks by disallowing magic links for unconfirmed users with password
      {%User{confirmed_at: nil, hashed_password: hash}, _token} when not is_nil(hash) ->
        raise """
        magic link log in is not allowed for unconfirmed users with a password set!

        This cannot happen with the default implementation, which indicates that you
        might have adapted the code to a different use case. Please make sure to read the
        "Mixing magic link and password registration" section of `mix help phx.gen.auth`.
        """

      {%User{confirmed_at: nil} = user, _token} ->
        user
        |> User.confirm_changeset()
        |> update_user_and_delete_all_tokens()

      {user, token} ->
        Repo.delete!(token)
        {:ok, {user, []}}

      nil ->
        {:error, :not_found}
    end
  end

  @doc ~S"""
  Delivers the update email instructions to the given user.

  ## Examples

      iex> deliver_user_update_email_instructions(user, current_email, &url(~p"/users/settings/confirm-email/#{&1}"))
      {:ok, %{to: ..., body: ...}}

  """
  def deliver_user_update_email_instructions(%User{} = user, current_email, update_email_url_fun)
      when is_function(update_email_url_fun, 1) do
    {encoded_token, user_token} = UserToken.build_email_token(user, "change:#{current_email}")

    Repo.insert!(user_token)
    UserNotifier.deliver_update_email_instructions(user, update_email_url_fun.(encoded_token))
  end

  @doc """
  Delivers the magic link login instructions to the given user.
  """
  def deliver_login_instructions(%User{} = user, magic_link_url_fun)
      when is_function(magic_link_url_fun, 1) do
    {encoded_token, user_token} = UserToken.build_email_token(user, "login")
    Repo.insert!(user_token)
    UserNotifier.deliver_login_instructions(user, magic_link_url_fun.(encoded_token))
  end

  @doc """
  Verifies the password.
  """
  defdelegate valid_password?(user, password), to: User

  @doc """
  Deletes the signed token with the given context.
  """
  def delete_user_session_token(token) do
    Repo.delete_all(from(UserToken, where: [token: ^token, context: "session"]))
    :ok
  end

  @doc """
  Deletes a user account and returns `{:ok, {deleted_user, tokens_to_disconnect}}`.

  All associated alert rules, deal matches, push subscriptions, and tokens
  are deleted via database foreign key cascading. Feedback records are nilified.
  """
  def delete_user(%User{} = user) do
    tokens_to_disconnect = Repo.all_by(UserToken, user_id: user.id)

    case Repo.delete(user) do
      {:ok, deleted_user} ->
        {:ok, {deleted_user, tokens_to_disconnect}}

      {:error, changeset} ->
        {:error, changeset}
    end
  end

  @doc """
  Exports all personal and configuration data for a user in accordance with Art. 15 and Art. 20 GDPR.
  """
  def export_user_data(%Scope{user: %User{} = user}), do: export_user_data(user)

  def export_user_data(%User{} = user) do
    alert_rules =
      DealScout.Alerts.list_alert_rules_for_user(user.id)
      |> Enum.map(fn rule ->
        %{
          id: rule.id,
          name: rule.name,
          keywords: rule.keywords,
          negative_keywords: rule.negative_keywords,
          max_price: (rule.max_price && Decimal.to_string(rule.max_price)) || nil,
          min_temperature: rule.min_temperature,
          delivery_mode: rule.delivery_mode,
          source_filter: rule.source_filter,
          country_filter: rule.country_filter,
          merchant_filter: rule.merchant_filter,
          exclude_dropshippers: rule.exclude_dropshippers,
          exclude_foreign_keyboards: rule.exclude_foreign_keyboards,
          notify_push: rule.notify_push,
          notify_email: rule.notify_email,
          cooldown_minutes: rule.cooldown_minutes,
          is_active: rule.is_active,
          inserted_at: DateTime.to_iso8601(rule.inserted_at),
          updated_at: DateTime.to_iso8601(rule.updated_at)
        }
      end)

    push_subscriptions =
      DealScout.Notifications.list_push_subscriptions_for_user(user.id)
      |> Enum.map(fn sub ->
        %{
          id: sub.id,
          device_name: sub.device_name,
          endpoint: sub.endpoint,
          user_agent: sub.user_agent,
          last_used_at: (sub.last_used_at && DateTime.to_iso8601(sub.last_used_at)) || nil,
          inserted_at: DateTime.to_iso8601(sub.inserted_at)
        }
      end)

    matches =
      Repo.all(
        from m in DealScout.Alerts.UserMatch,
          where: m.user_id == ^user.id,
          preload: [[deal: :merchant], :alert_rule],
          order_by: [desc: m.inserted_at]
      )
      |> Enum.map(fn match ->
        %{
          id: match.id,
          is_read: match.is_read,
          notified_via_push: match.notified_via_push,
          notified_via_email: match.notified_via_email,
          matched_at: DateTime.to_iso8601(match.inserted_at),
          alert_rule_name: (match.alert_rule && match.alert_rule.name) || nil,
          deal:
            if match.deal do
              merchant_name =
                case match.deal.merchant do
                  %DealScout.Deals.Merchant{name: name} -> name
                  _ -> match.deal.raw_merchant
                end

              %{
                title: match.deal.title,
                url: match.deal.url,
                price: (match.deal.price && Decimal.to_string(match.deal.price)) || nil,
                merchant: merchant_name
              }
            else
              nil
            end
        }
      end)

    %{
      version: "1.0",
      service: "DealScout",
      exported_at: DateTime.to_iso8601(DateTime.utc_now()),
      gdpr_notice:
        "This export contains all personal and configuration data associated with your account in accordance with Art. 15 and Art. 20 GDPR.",
      account: %{
        id: user.id,
        email: user.email,
        confirmed_at: (user.confirmed_at && DateTime.to_iso8601(user.confirmed_at)) || nil,
        is_admin: user.is_admin,
        inserted_at: DateTime.to_iso8601(user.inserted_at)
      },
      alert_rules: alert_rules,
      push_subscriptions: push_subscriptions,
      matched_deals: matches
    }
  end

  ## Token helper

  defp update_user_and_delete_all_tokens(changeset) do
    Repo.transact(fn ->
      with {:ok, user} <- Repo.update(changeset) do
        tokens_to_expire = Repo.all_by(UserToken, user_id: user.id)

        Repo.delete_all(from(t in UserToken, where: t.id in ^Enum.map(tokens_to_expire, & &1.id)))

        {:ok, {user, tokens_to_expire}}
      end
    end)
  end
end
