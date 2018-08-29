defmodule WeatherServer do
  @name "WeatherServer"   # Suppresses the leading "Elixir." in log messages.
  @vsn "1.0.0 (2018-08-27 2357)"
  @max_days 7
  @cached_forecast_timetolive 120   # 1800 seconds = 30 minutes
  require Logger   # Because Logger calls are macros.

  # ---------------------------------------------------------------------------------
  # Sample iex commands to start and test the WeatherServer as a standalone service:  
  #   {:ok, pid} = WeatherServer.start_link([])
  #   Process.registered() |> Enum.sort()
  #   Process.whereis(WeatherServer)
  #   WeatherServer.get_status()
  #   WeatherServer.get_forecast()                   # Defaults to Rocklin, CA.
  #   WeatherServer.get_forecast("","","","12345")   # Schenectady, NY :-)
  # ---------------------------------------------------------------------------------

  use GenServer
  
  alias WeatherServer.State      # Defines the state record used by the WeatherServer worker processes.
  alias WeatherServer.Forecast   # Defines the data record stored in the server state's dictionary of cached_forecasts.
  
  def start_link(_args) do
    Logger.info("#{@name}: Start command was received.")
    GenServer.start_link(__MODULE__, nil, name: __MODULE__)
  end

  # Perform server initialization:

  def init(_args) do
    Logger.info("#{@name}: Started. Version=#{@vsn} Pid=#{inspect self()}")
    Process.flag(:trap_exit, true)    # Required to receive shutdown notifications.
    initial_state = %State{when_started: DateTime.utc_now()}
	# Application.ensure_all_started(:inets)   # Starts Erlang :httpc service.
    # Application.ensure_all_started(:ssl)     # To use https for requests.
    {:ok, initial_state}
  end
 
  # Perform server shutdown:

  def terminate(reason, state, data) do
    Logger.info("#{@name}: Terminating... Reason=#{reason} State=#{state} Data=#{inspect data}")
    :void
  end
  
  # ---------------------------------------------------
  # Client API
  # ---------------------------------------------------

  def max_days() do   # Called by WeatherController to validate that user's "requested_days" can be provided by this source.
    @max_days
    # This function returns a "static" "global" configuration constant. Hence it doesn't need to be implemented as GenServer callback.
  end
  
  def get_forecast(address \\"", city \\ "", state \\ "", zipcode \\ "95765") do
    GenServer.call(__MODULE__, {:get_forecast, address, city, state, zipcode})   
	# Returns {:ok, fetched_zipcode, new_forecast.data, cached?, when_fetched} or {:error, reason}.
  end

  def get_status() do
    GenServer.call(__MODULE__, :get_status)   # Returns {:ok, status_string}.
  end

  # ---------------------------------------------------
  # Genserver callbacks to implement client API
  # ---------------------------------------------------

  # :get_status shows that the server is alive and tells you which zipcodes are in the cache.
  
  def handle_call(:get_status, _from, %State{}=state) do
    status_string = "#{@name}: WhenStarted: #{format_with_tz_offset(state.when_started)}, " <> 
	  "CachedForecasts: n=#{map_size(state.cached_forecasts)} #{inspect Map.keys(state.cached_forecasts)}"  # Map keys are already sorted.
	Logger.info status_string
    {:reply, {:ok, status_string}, state}
  end

  # :get_forecast gets the weather forecast from apixu.com for the specified zipcode.
  # If a zipcode wasn't supplied, it will look it up the zipcode based on either (full) address or the city and state.
  # If the forecast is already in the cache and is less than 30 minutes old (configurable), it will be reused.
  # Otherwise, we will fetch a new forecast and either replace the existing cache entry or add a new one.
  
  def handle_call({:get_forecast, address, city, state, zipcode}, _from, %State{}=server_state) do
    # If necessary, remove the hyphen and "Plus4" part of the zipcode.
	# NOTE: This routine assumes that the base zipcode is a well-formed numeric string: 5 digits in length with leading zeros if needed.
    zipcode = 
	  if String.length(zipcode) > 5 do
	    Logger.info "#{@name}: Incoming zipcode is too long: #{inspect zipcode}. Trimming it to 5 digits..."
	    String.slice(zipcode, 0..4)
	  else
	    zipcode
	  end
    Logger.info "#{@name}: :get_forecast for zipcode #{inspect zipcode} OR address #{inspect address}, city #{inspect city}, state #{inspect state}."

	# The weather forecasts are retrieved and cached by zipcode. 
	# If the user didn't give us a zipcode, then we need to look it up based on either {address,city,state} or {city,state}.
	{zipcode, zipcode_status, zipcode_error_msg} =
	  if zipcode != "" do
	    # The user supplied a zipcode. Just use it.
	    {zipcode, :ok, ""}
	  else 
	    if address != "" do
	      # Search usps.com by {address,city,state}.
	      case get_zipcode_from_usps(address,city,state,zipcode) do
            {:ok, new_data} ->
              # Logger.debug "#{@name}:  Received new data for zipcode search: #{inspect new_data}"
	      	  usps_zipcode = Exml.get(new_data, "/ZipCodeLookupResponse/Address/Zip5")   # Returns nil if not found.
              usps_error_msg = Exml.get(new_data, "/ZipCodeLookupResponse/Address/Error/Description")   # Returns nil if not found.
			  # NOTE: If the address is not found, USPS still returns a "successful" search (HTTP return code 200),
			  # but packs the error message into a different structured XML document. Sigh! 
              if usps_zipcode != nil do
			    trimmed_usps_zipcode = String.trim(usps_zipcode)
                Logger.debug "#{@name}:  Success! usps_zipcode = #{inspect trimmed_usps_zipcode}"
			    {trimmed_usps_zipcode, :ok, ""}
			  else
			    trimmed_usps_error_msg = String.trim(usps_error_msg)
                Logger.debug "#{@name}:  Error! usps_error_msg = #{inspect trimmed_usps_error_msg}"
			    {"", :error, trimmed_usps_error_msg}
			  end
  	        {:error, reason} ->
			  usps_error_msg = "USPS search request failed. Reason=#{inspect reason}"
              Logger.info usps_error_msg
			  {"", :error, usps_error_msg}
	      end
	    else
		  # Search zippotam.us by {city,state}.
	      case get_zipcode_from_zippopotamus(city, state) do
            {:ok, new_data} ->
              # Logger.debug "#{@name}:  Received new data from zippotam.us search: #{inspect new_data}"
			  # NOTE: zippopotam.us returns other attributes that might be useful in the future, including latatude and longitude.
		      # place_info = Enum.at(new_data["places"], 0)   # Accesses the first full place info record returned by zippopotam.us
		      zippo_zipcode = Enum.at(new_data["places"], 0)["post code"]
              Logger.debug "#{@name}:  Success! zippopotam.us zipcode = #{inspect zippo_zipcode}"
			  {zippo_zipcode, :ok, ""}
  	        {:error, reason} ->
			  zippo_error_msg = "Zippotam.us search request failed. Reason=#{inspect reason}" 
              Logger.info zippo_error_msg
			  {"", :error, zippo_error_msg}
	      end
	    end
	  end

	if zipcode_status == :ok do
      # Get the weather forecast for this zipcode.
	  # First, check to see if it's already in the cache and is fresh enough to use.
	  if Map.has_key?(server_state.cached_forecasts, zipcode) do
	    forecast = server_state.cached_forecasts[zipcode]
	    forecast_age = DateTime.diff(DateTime.utc_now(), forecast.when_fetched)   # Returns the time difference in seconds.
	    if forecast_age < @cached_forecast_timetolive do
          Logger.info "#{@name}: Forecast for zipcode #{inspect zipcode} is not yet stale. It was fetched #{forecast_age} seconds ago. " <>
		    "(Max=#{@cached_forecast_timetolive} secs)"
          {:reply, {:ok, zipcode, forecast.data, true, forecast.when_fetched}, server_state}
	    else
          Logger.info "#{@name}: Forecast for zipcode #{inspect zipcode} needs to be refreshed. It was fetched #{forecast_age} seconds ago. " <>
		    "(Max=#{@cached_forecast_timetolive} secs)"
          case get_forecast_from_apixu(zipcode) do   # Get the forecast (it's stale).
		    {:ok, new_data} ->
              Logger.info "#{@name}:   Received new data for zipcode #{inspect zipcode} from get_forecast_from_apixu."
    	      new_forecast = %Forecast{zipcode: zipcode, when_fetched: DateTime.utc_now(), data: new_data}
              new_forecasts = Map.put(server_state.cached_forecasts, zipcode, new_forecast)  # NOTE: Map.put (to update the existing record)
              new_server_state = %{server_state | cached_forecasts: new_forecasts}
              {:reply, {:ok, zipcode, new_forecast.data, false, forecast.when_fetched}, new_server_state}
		    {:error, reason} ->
              Logger.info "#{@name}:   Request failed! Reason=#{inspect reason}"
              {:reply, {:error, reason}, server_state}
		  end
	    end
	  else
        Logger.info "#{@name}: Forecast for zipcode #{inspect zipcode} not found in cache. Fetching it now..."
        case get_forecast_from_apixu(zipcode) do   # Get the forecast (it's a new zipcode).
          {:ok, new_data} ->
            Logger.info "#{@name}:   Received new data for zipcode #{inspect zipcode} from get_forecast_from_apixu."
            new_forecast = %Forecast{zipcode: zipcode, when_fetched: DateTime.utc_now(), data: new_data}
	        new_forecasts = Map.put_new(server_state.cached_forecasts, zipcode, new_forecast)  # NOTE: Map.put_new (to create a new record)
            new_server_state = %{server_state | cached_forecasts: new_forecasts}
            {:reply, {:ok, zipcode, new_forecast.data, false, new_forecast.when_fetched}, new_server_state}
		  {:error, reason} ->
            Logger.info "#{@name}:   Request failed! Reason=#{inspect reason}"
            {:reply, {:error, reason}, server_state}
   	    end
	  end
	else
      {:reply, {:error, zipcode_error_msg}, server_state}
	end
  end

  def handle_call(msg, from, state) do
    Logger.error "#{@name}: GenServer received unknown call #{inspect msg} from process: #{inspect elem(from, 0)}"
    {:reply, :unknown_call, state}
  end
  
  def handle_cast(msg, from, state) do
    Logger.error "#{@name}: GenServer received unknown cast #{inspect msg} from process: #{inspect elem(from, 0)}"
    {:reply, :unknown_call, state}
  end
  
  # ---------------------------------------------------
  # Timestamp Helpers (now exposed for use by the web server)
  # ---------------------------------------------------  
 
  def set_microsecond_precision(dt, p) do 
    %{dt | microsecond: {elem(dt.microsecond, 0), p}}
  end
  
  def format_with_tz_offset(datetime) do  # Adding "\\ DateTime.utc_now()" gives a compiler warning that "default arguments are never used". Sheesh!
    # My preferred timestamp display format is a "datetime with offset" showing tenths of a second: "YYYY-MM-DD HHmmss.s+hhmm"
	Timex.Timezone.convert(datetime, Timex.Timezone.local)
	  |> set_microsecond_precision(1)                             # Reduce the fractional seconds display from 6 digits to 1.
	  |> Timex.format!("{YYYY}-{0M}-{0D} {h24}{0m}{0s}{ss}{Z}")   # Format it. Note: {ss} supplies its own leading decimal point.
  end

  # ---------------------------------------------------
  # Internal Helpers (private)
  # ---------------------------------------------------  

  defp get_forecast_from_apixu(zipcode) do   # Using hackney for HTTP requests.
    try do
      # Search apixu.com based on zipcode. 
	  # NOTE: apixu.com also allows searches based on "city,state,country" but there are very erratic because
	  #   they treat it as one long string ("place name") rather than as elements in a geographical hierarchy.
	  #   Hence, we will NOT use apixu for searches by "city,state,country". Instead get the first zipcode for
	  #   this US city and state from zippotam.us, then get the forecast for that zipcode from apixu.com.
      Logger.info "#{@name}: Getting forecast for zipcode #{inspect zipcode} from apixu.com..."
	  base_url = "https://api.apixu.com/v1/forecast.json?key=1b517f7d9a074cbfa7044000182308"
	  target_url = "#{base_url}&q=#{zipcode}&days=#{max_days()}"
      # Logger.info "#{@name}:   Target URL = #{inspect target_url}"
	  case :hackney.get(target_url, [], "", [follow_redirect: true]) do
        {:ok, 200, _headers, client_ref} ->
          {:ok, body} = :hackney.body(client_ref)
          Logger.debug "#{@name}:  HTTP Request Success! body size is #{byte_size(body)} bytes."
          # Logger.debug "#{@name}:  body contents = #{inspect body}"
		  {:ok, Poison.decode!(body)}   # Return the decoded data as a nested Elixir map.
        {:ok, http_return_code, _headers,_client_ref} ->
	      {:error, "HTTP Return Code: #{http_return_code}"}
        {:error, reason} ->
          Logger.info "#{@name}: ERROR! reason=#{inspect reason}"
	      {:error, reason}
      end
	rescue
	  e -> {:error, "EXCEPTION in get_forecast_from_apixu: #{inspect e}"}
	end
  end
  
  defp get_zipcode_from_zippopotamus(city, state) do   # Using hackney for HTTP requests.
    try do
      Logger.info "#{@name}: Getting zipcode for city #{inspect city}, state #{inspect state} from zippopotam.us..."
	  base_url = "http://api.zippopotam.us/us"
	  target_url = URI.encode("#{base_url}/#{state}/#{city}")   # City may have embedded spaces.
      # Logger.info "#{@name}:   Target URL = #{inspect target_url}"
	  case :hackney.get(target_url, [], "", [follow_redirect: true]) do
        {:ok, 200, _headers, client_ref} ->
          {:ok, body} = :hackney.body(client_ref)
          Logger.debug "#{@name}:  HTTP Request Success! body size is #{byte_size(body)} bytes."
          # Logger.debug "#{@name}:  body contents = #{inspect body}"
		  {:ok, Poison.decode!(body)}   # Return the decoded data as a nested Elixir map.
        {:ok, http_return_code, _headers,_client_ref} ->
	      {:error, "HTTP Return Code: #{http_return_code}"}
        {:error, reason} ->
          Logger.info "#{@name}: ERROR! reason=#{inspect reason}"
	      {:error, reason}
      end
	rescue
	  e -> {:error, "EXCEPTION in get_zipcode_from_zippopotamus: #{inspect e}"}
	end
  end
  
  defp get_zipcode_from_usps(address, city, state, zipcode) do   # Using hackney for HTTP requests.
    try do
      Logger.info "#{@name}: Getting zipcode for address #{inspect address}, city #{inspect city}, state #{inspect state} from usps.com..."
	  base_url = "https://secure.shippingapis.com/ShippingAPI.dll?API=ZipCodeLookup&XML="
	  usps_userid = "449SELF00178"
	  xml_text = "<ZipCodeLookupRequest USERID=\"#{usps_userid}\"><Address ID=\"1\"><Address1>#{address}</Address1><Address2></Address2>" <>
	    "<City>#{city}</City><State>#{state}</State><Zip5>#{zipcode}</Zip5><Zip4></Zip4></Address></ZipCodeLookupRequest>"
	  target_url = URI.encode("#{base_url}#{xml_text}")
      # Logger.info "#{@name}:   Target URL = #{inspect target_url}"
	  case :hackney.get(target_url, [], "", [follow_redirect: true]) do
        {:ok, 200, _headers, client_ref} ->
          {:ok, body} = :hackney.body(client_ref)
          Logger.debug "#{@name}:  HTTP Request Success! body size is #{byte_size(body)} bytes."
          # Logger.debug "#{@name}:   body contents = #{inspect body}"
          doc = Exml.parse(body)
		  {:ok, doc}
        {:ok, http_return_code, _headers,_client_ref} ->
	      {:error, "HTTP Return Code: #{http_return_code}"}
        {:error, reason} ->
          Logger.info "#{@name}: ERROR! reason=#{inspect reason}"
	      {:error, reason}
      end
	rescue
	  e -> {:error, "EXCEPTION in get_zipcode_from_usps: #{inspect e}"}
	end
  end
  
end
