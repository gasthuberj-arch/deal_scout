defmodule DealScout.AccountsFixtures do
  @moduledoc """
  This module defines test helpers for creating
  entities via the `DealScout.Accounts` context.
  """

  import Ecto.Query

  alias DealScout.Accounts
  alias DealScout.Accounts.Scope

  def unique_user_email, do: "user#{System.unique_integer()}@example.com"
  def valid_user_password, do: "hello world!"

  def valid_user_attributes(attrs \\ %{}) do
    Enum.into(attrs, %{
      email: unique_user_email(),
      password: valid_user_password()
    })
  end

  def unconfirmed_user_fixture(attrs \\ %{}) do
    {:ok, user} =
      attrs
      |> valid_user_attributes()
      |> Map.delete(:password)
      |> Map.delete("password")
      |> then(fn attrs ->
        %DealScout.Accounts.User{}
        |> DealScout.Accounts.User.email_changeset(attrs)
        |> DealScout.Repo.insert()
      end)

    user
  end

  def user_fixture(attrs \\ %{}) do
    {:ok, user} =
      attrs
      |> valid_user_attributes()
      |> Accounts.register_user()

    user
  end

  def passwordless_user_fixture(attrs \\ %{}) do
    email = Map.get(attrs, :email) || unique_user_email()

    {:ok, user} =
      %DealScout.Accounts.User{}
      |> DealScout.Accounts.User.email_changeset(%{email: email})
      |> DealScout.Accounts.User.confirm_changeset()
      |> DealScout.Repo.insert()

    user
  end

  def admin_fixture(attrs \\ %{}) do
    user = user_fixture(attrs)
    user |> Ecto.Changeset.change(%{is_admin: true}) |> DealScout.Repo.update!()
  end

  def user_scope_fixture do
    user = user_fixture()
    user_scope_fixture(user)
  end

  def user_scope_fixture(user) do
    Scope.for_user(user)
  end

  def set_password(user) do
    {:ok, {user, _expired_tokens}} =
      Accounts.update_user_password(user, %{password: valid_user_password()})

    user
  end

  def extract_user_token(fun) do
    {:ok, captured_email} = fun.(&"[TOKEN]#{&1}[TOKEN]")
    [_, token | _] = String.split(captured_email.text_body, "[TOKEN]")
    token
  end

  def override_token_authenticated_at(token, authenticated_at) when is_binary(token) do
    DealScout.Repo.update_all(
      from(t in Accounts.UserToken,
        where: t.token == ^token
      ),
      set: [authenticated_at: authenticated_at]
    )
  end

  def generate_user_magic_link_token(user) do
    {encoded_token, user_token} = Accounts.UserToken.build_email_token(user, "login")
    DealScout.Repo.insert!(user_token)
    {encoded_token, user_token.token}
  end

  def offset_user_token(token, amount_to_add, unit) do
    dt = DateTime.add(DateTime.utc_now(:second), amount_to_add, unit)

    DealScout.Repo.update_all(
      from(ut in Accounts.UserToken, where: ut.token == ^token),
      set: [inserted_at: dt, authenticated_at: dt]
    )
  end
end
