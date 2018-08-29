defmodule WeatherServerTest do
  use ExUnit.Case
  doctest WeatherServer

  test "greets the world" do
    assert WeatherServer.hello() == :world
  end
end
