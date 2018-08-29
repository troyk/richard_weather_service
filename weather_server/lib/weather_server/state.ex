defmodule WeatherServer.State do
  @moduledoc false
  
  # State record used by the WeatherServer worker processes.

  defstruct(       # Space is not allowed between defstruct and (.
    when_started: "",       # DateTime UTC when the WeatherServer was started.
    cached_forecasts: %{}   # Dictionary of WeatherServer.Forecast structs keyed by zipcode.
	)
  
end
