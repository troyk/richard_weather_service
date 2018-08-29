defmodule WeatherPageWeb.WeatherController do
  use WeatherPageWeb, :controller
  require Logger   # Because Logger calls are macros.

  def index(conn, params) do
    # Logger.info "Query Received: params=#{inspect params}"    # Phoenix writes the call parameters to the log (debug level).

	if params == %{} do
      Logger.debug "Initialize Display: Set all fields to empty string."
      render conn, "index.html", empty_display_fields()   # Return empty strings for all display fields.
	else
  	  case WeatherServer.get_forecast(params["address"], params["city"], params["state"], params["zipcode"]) do
  	    {:ok, fetched_zipcode, forecast_data, cached?, when_fetched} ->
	      # Return user's original query filters plus query status and forecast data.
	      #   params + query_status, error_msg, cached, when_fetched, days_fetched, forecast_data
		  query_status = "Success"
          days_requested = String.to_integer(params["days_requested"])   # Phoenix converts this number into a string. :-(
		  days_fetched = length(forecast_data["forecast"]["forecastday"])
		  {days_requested, error_msg} = 
		    if days_requested > days_fetched do
		      {days_fetched, "NOTE: Requested days was reduced to match days available (days fetched)."}
			else
			  {days_requested, ""}
		    end
		  # NOTE: Phoenix requires that all keys for the "assigns" map be atoms.
		  assigns = %{ :address => params["address"], :city => params["city"], :state => params["state"], :zipcode => params["zipcode"],
		    :days_requested => days_requested, :temperature_scale => params["temperature_scale"], 
		    :query_status => "Success", :error_msg => error_msg, :fetched_zipcode => fetched_zipcode, :data => forecast_data,
			:cached? => cached?, :when_fetched => when_fetched, :days_fetched => days_fetched }
          render conn, "index.html", assigns
	    {:error, reason} ->
	      # Return user's original query filters plus an error message.  
          Logger.debug "  ERROR: Unable to get forecast for zipcode #{inspect params["zipcode"]}. Reason: #{inspect reason}"
		  query_status = "FAILED"
		  error_msg = reason
          days_requested = String.to_integer(params["days_requested"])   # Phoenix converts this number into a string. :-(
		  assigns = %{ :address => params["address"], :city => params["city"], :state => params["state"], :zipcode => params["zipcode"],
		    :days_requested => days_requested, :temperature_scale => params["temperature_scale"], 
		    :query_status => query_status, :error_msg => error_msg, :fetched_zipcode => "", :data => nil, 
			:cached? => "", :when_fetched => "", :days_fetched => 0 }
          render conn, "index.html", assigns
	    end
	end
  end

  # Helper functions

  def empty_display_fields() do   # Pseudo-constructor that returns a keyword list of all display fields initialized to empty strings.
    [ address: "", city: "", state: "", zipcode: "", temperature_scale: "fahrenheit", days_requested: 5,
	  query_status: "", error_msg: "", cached: "", when_fetched: "", fetched_days: 0, data: nil]
  end

end
