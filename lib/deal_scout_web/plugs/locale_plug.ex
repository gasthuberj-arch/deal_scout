defmodule DealScoutWeb.Plugs.LocalePlug do
  @moduledoc """
  Plug for determining and setting the locale (de/en) for HTTP requests.
  """
  @behaviour Plug

  import Plug.Conn

  @supported_locales ~w(de en)

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(conn, _opts) do
    conn = fetch_cookies(conn)

    locale =
      determine_locale(conn)
      |> validate_locale()

    Gettext.put_locale(DealScoutWeb.Gettext, locale)

    conn
    |> maybe_put_session(:locale, locale)
    |> assign(:locale, locale)
  end

  defp determine_locale(conn) do
    cond do
      user_locale = get_user_locale(conn) ->
        user_locale

      session_locale = get_session_locale(conn) ->
        session_locale

      cookie_locale = get_cookie_locale(conn) ->
        cookie_locale

      true ->
        locale_from_header(conn)
    end
  end

  defp get_user_locale(conn) do
    case conn.assigns[:current_scope] do
      %{user: %{locale: locale}} when is_binary(locale) and locale != "" -> locale
      _ -> nil
    end
  end

  defp get_session_locale(conn) do
    if conn.private[:plug_session] do
      get_session(conn, :locale) || get_session(conn, "locale")
    end
  end

  defp get_cookie_locale(conn) do
    conn.cookies["locale"] || conn.req_cookies["locale"]
  end

  defp locale_from_header(conn) do
    case get_req_header(conn, "accept-language") do
      [header | _] when is_binary(header) ->
        first =
          header
          |> String.split(",")
          |> List.first("")
          |> String.trim()
          |> String.downcase()

        cond do
          String.starts_with?(first, "en") -> "en"
          String.starts_with?(first, "de") -> "de"
          header =~ ~r/\ben\b/i -> "en"
          true -> "de"
        end

      _ ->
        "de"
    end
  end

  defp validate_locale(locale) when locale in @supported_locales, do: locale
  defp validate_locale(_), do: "de"

  defp maybe_put_session(conn, key, val) do
    if conn.private[:plug_session] do
      put_session(conn, key, val)
    else
      conn
    end
  end
end
