defmodule DealScoutWeb.LocaleController do
  use DealScoutWeb, :controller

  alias DealScout.Accounts

  @supported_locales ~w(de en)

  def update(conn, %{"locale" => locale} = params) do
    locale = if locale in @supported_locales, do: locale, else: "de"

    redirect_to =
      case params["redirect_to"] || get_req_header(conn, "referer") do
        [referer | _] when is_binary(referer) ->
          clean_path(referer)

        path when is_binary(path) and path != "" ->
          clean_path(path)

        _ ->
          ~p"/"
      end

    if user = conn.assigns[:current_scope] && conn.assigns.current_scope.user do
      Accounts.update_user_locale(user, locale)
    end

    Gettext.put_locale(DealScoutWeb.Gettext, locale)

    conn
    |> put_session(:locale, locale)
    |> put_resp_cookie("locale", locale, max_age: 365 * 24 * 60 * 60, path: "/")
    |> redirect(to: redirect_to)
  end

  def update(conn, _params) do
    redirect(conn, to: ~p"/")
  end

  defp clean_path(url_or_path) do
    uri = URI.parse(url_or_path)
    path = if uri.path && String.starts_with?(uri.path, "/"), do: uri.path, else: ~p"/"
    query = if uri.query, do: "?#{uri.query}", else: ""
    "#{path}#{query}"
  end
end
