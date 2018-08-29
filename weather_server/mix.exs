defmodule WeatherServer.MixProject do
  use Mix.Project

  def project do
    [
      app: :weather_server,
      version: "0.1.0",
      elixir: "~> 1.6",
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:logger],
      mod: {WeatherServer.Application, []}
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
	  {:timex, "~> 3.1"},     # For time zones and local-time timestamps.
      {:poison, "~> 3.1"},    # For parsing JSON.
	  {:exml, "~> 0.1.1"},    # For parsing XML.
    ]
  end
end
