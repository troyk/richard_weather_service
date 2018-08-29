defmodule WeatherPageWeb.PageController do
  use WeatherPageWeb, :controller

  def index(conn, _params) do
    render conn, "index.html"
  end
end
