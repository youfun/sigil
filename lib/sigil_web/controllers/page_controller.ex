defmodule SigilWeb.PageController do
  use SigilWeb, :controller

  def home(conn, _params) do
    render(conn, :home)
  end
end
