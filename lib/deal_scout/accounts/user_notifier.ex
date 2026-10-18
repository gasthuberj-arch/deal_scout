defmodule DealScout.Accounts.UserNotifier do
  import Swoosh.Email

  alias DealScout.Mailer
  alias DealScout.Accounts.User

  # Delivers the email using the application mailer.
  defp deliver(recipient, subject, body) do
    email =
      new()
      |> to(recipient)
      |> from({"DealScout", "contact@example.com"})
      |> subject(subject)
      |> text_body(body)

    with {:ok, _metadata} <- Mailer.deliver(email) do
      {:ok, email}
    end
  end

  @doc """
  Deliver instructions to update a user email.
  """
  def deliver_update_email_instructions(user, url) do
    deliver(user.email, "Update email instructions", """

    ==============================

    Hi #{user.email},

    You can change your email by visiting the URL below:

    #{url}

    If you didn't request this change, please ignore this.

    ==============================
    """)
  end

  @doc """
  Deliver instructions to log in with a magic link.
  """
  def deliver_login_instructions(user, url) do
    case user do
      %User{confirmed_at: nil} -> deliver_confirmation_instructions(user, url)
      _ -> deliver_magic_link_instructions(user, url)
    end
  end

  defp deliver_magic_link_instructions(user, url) do
    deliver(user.email, "Log in instructions", """

    ==============================

    Hi #{user.email},

    You can log into your account by visiting the URL below:

    #{url}

    If you didn't request this email, please ignore this.

    ==============================
    """)
  end

  defp deliver_confirmation_instructions(user, url) do
    deliver(user.email, "Confirmation instructions", """

    ==============================

    Hi #{user.email},

    You can confirm your account by visiting the URL below:

    #{url}

    If you didn't create an account with us, please ignore this.

    ==============================
    """)
  end

  @doc """
  Deliver notification when an alert rule matches a new deal.
  """
  def deliver_deal_alert(user, deal, alert_rule) do
    price_str = if deal.price, do: "#{deal.price} €", else: "Price not listed"
    merchant_str = if deal.merchant, do: "at #{deal.merchant}", else: ""

    deliver(user.email, "[DealScout] Deal Match: #{deal.title}", """

    ==============================

    Hi #{user.email},

    A new deal matched your alert rule "#{alert_rule.name}" (#{alert_rule.keywords}):

    Deal: #{deal.title}
    Price: #{price_str} #{merchant_str}
    Source: #{if deal.feed, do: deal.feed.name, else: "Deal Feed"}

    View Deal:
    #{deal.url}

    ==============================
    """)
  end
end
