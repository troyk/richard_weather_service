defmodule WeatherServer.Forecast do
  @moduledoc false

  # Forecast record used by the WeatherServer process.

  defstruct(       # Space is not allowed between defstruct and (.
    zipcode: nil,         # Key
	when_fetched: nil,    # DateTime UTC when this forecast was fetched from apixu.com
	data: nil             # The decoded JSON response received from apixu.com
	)
	
end
