defmodule DealScoutWeb.PageController do
  use DealScoutWeb, :controller

  def home(conn, _params) do
    render(conn, :home)
  end
end
