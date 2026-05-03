defmodule AshScimDemoWeb.PageController do
  use AshScimDemoWeb, :controller

  def home(conn, _params) do
    render(conn, :home)
  end
end
