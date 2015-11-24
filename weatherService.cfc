<cfcomponent displayname="Weather Service" hint="Used looking up weather forecasts via Weather.gov's XML web service" output="false">
	<cfscript>
		INSTANCE = structNew();
		
		weatherParameters = structNew();
		weatherParameters['maxt']  = true;
		weatherParameters['mint']  = true;
		weatherParameters['temp']  = false;
		weatherParameters['dew']   = false;
		weatherParameters['pop12'] = true;
		weatherParameters['qpf']   = false;
		weatherParameters['sky']   = true;
		weatherParameters['snow']  = false;
		weatherParameters['wspd']  = true;
		weatherParameters['wdir']  = false;
		weatherParameters['wx']    = true;
		weatherParameters['waveh'] = false;
		weatherParameters['icons'] = true;

		variables.weatherParameters = weatherParameters;
		
		// create an object that references the weather.gov service		
		variables.ws = createObject("webservice", "http://weather.gov/forecasts/xml/SOAP_server/ndfdXMLserver.php?wsdl");
		
		// create a cache for the weather data
		// weather.gov asks that we don't ask for the same point more than once per hour
		variables.cache = structNew();
	</cfscript>


	<cffunction name="init" output="false" access="public" returntype="any">
		<cfargument name="zipcodeService" type="any" required="true" />
		<cfset variables.zipcodeService = arguments.zipcodeService />

		<cfreturn this />
	</cffunction>


	<!--- public method to get weather data (checks cache, then goes to weather.gov) --->
	<cffunction name="getWeather" output="false" access="public" returntype="any">
		<cfargument name="zip" type="string" required="true" />
		<cfargument name="startDate" type="date" default="#dateFormat(now(), 'yyyy-mm-dd')#" />
		<cfargument name="numDays" type="numeric" default="5" />
		<cfargument name="flush" type="boolean" default="false" />

		<!--- is the data in the cache? --->
		<cfif isDataCurrent(argumentCollection = arguments) AND NOT arguments.flush>
			<cfreturn getData(arguments.zip) />
		</cfif>
		
		<!--- if not, get it and ship it back --->
		<cfreturn getWeatherData(argumentCollection = arguments) />
	</cffunction>


	<!--- private worker method to transform a zip into long/lat and get data from NWS --->
	<cffunction name="getWeatherData" output="false" access="private" returntype="struct">
		<cfargument name="zip" type="string" required="true" />
		<cfargument name="startDate" type="date" required="true" />
		<cfargument name="numDays" type="numeric" required="true" />
		
		<!--- localize some variables to ensure we're not clobbering each other --->
		<cfset var loc = "" />
		<cfset var strTemp = structNew() />
		<cfset var xmlWeather = "" />
		<cfset var min = "" />
		<cfset var max = "" />
		<cfset var parse = "" />
		<cfset var ii = "" />

		<!--- get the long/lat to ship to NWS --->
		<cfset loc = variables.zipcodeService.getLocation(arguments.zip) />
		
		<!--- check to make sure this is a known zip --->
		<cfif NOT loc.getIsPersisted()>
			<cfthrow type="api.ZipCodeNotFound" message="Zip Code data not found" detail="There was no data found for the zip code ""#arguments.zip#"" in the Zip Code Lookup Service" />
		</cfif>
		
		<!--- parse and compartmentalize the data --->
		<cfset strTemp.arrTemperature = arrayNew(1) />
		<cfset strTemp.arrPrecipitation = arrayNew(1) />
		<cfset strTemp.arrWeather = arrayNew(1) />
		<cfset strTemp.arrImage = arrayNew(1) />
		
		<!--- to prevent a bad zip or something from slowing down the app on each page reload, we 
			  build some fault tolerance in so we don't continue to hit the same bump over and over --->
		<cftry>
		
			<!--- get it, save it and return it --->
			<cfset xmlWeather = getWeatherForecast(longitude = loc.getDecLongitude()
													,latitude = loc.getDecLatitude()
													,startDate = arguments.startDate
													,numDays = arguments.numDays) />
	
			<!--- get the first 5 which are maximums only --->
			<cfset max = xmlSearch(xmlWeather, "/dwml/data/parameters/temperature[@type = 'maximum']/value") />
			
			<!--- get the second 5 which are minimums only --->
			<cfset min = xmlSearch(xmlWeather, "/dwml/data/parameters/temperature[@type = 'minimum']/value") />
			
			<!--- based on the arrays being the same length - always 2 per day --->
			<cfloop from="1" to="#arrayLen(max)#" index="ii">
				<cfset arrayAppend(strTemp.arrTemperature, max[ii].xmlText) />
				<cfset arrayAppend(strTemp.arrTemperature, min[ii].xmlText) />
			</cfloop>
			
			<!--- get the chance of rain, all 10 zones --->
			<cfset parse = xmlSearch(xmlWeather, "/dwml/data/parameters/probability-of-precipitation/value") />
			<cfloop from="1" to="#arrayLen(parse)#" index="ii">
				<cfset arrayAppend(strTemp.arrPrecipitation, parse[ii].xmlText) />
			</cfloop>
	
			<!--- get the weather conditions, all 10 zones --->
			<cfset parse = xmlSearch(xmlWeather, "/dwml/data/parameters/weather/weather-conditions") />
			<cfloop from="1" to="#arrayLen(parse)#" index="ii">
				<!--- throws errors when an odd number of conditions are returned; exists check prevents that --->
				<cfif structKeyExists(parse[ii].xmlAttributes, "weather-summary")>
					<cfset arrayAppend(strTemp.arrWeather, parse[ii].xmlAttributes["weather-summary"]) />
				<cfelse>
					<cfset arrayAppend(strTemp.arrWeather, "") />
				</cfif>
			</cfloop>
	
			<!--- get the image URLs, all 10 zones --->
			<cfset parse = xmlSearch(xmlWeather, "/dwml/data/parameters/conditions-icon/icon-link") />
			<cfloop from="1" to="#arrayLen(parse)#" index="ii">
				<cfset arrayAppend(strTemp.arrImage, parse[ii].xmlText) />
			</cfloop>
			
			<!--- save the data to cache (do we need to parse and make sensible first?) --->
			<cfset setData(argumentCollection = arguments, data = duplicate(strTemp), city = loc.getVchCity(), state = loc.getChrRegion()) />

			<cfcatch type="any">
			
				<!--- reset data structures --->
				<cfset strTemp = structNew() />
				<cfset strTemp.arrTemperature = arrayNew(1) />
				<cfset strTemp.arrPrecipitation = arrayNew(1) />
				<cfset strTemp.arrWeather = arrayNew(1) />
				<cfset strTemp.arrImage = arrayNew(1) />
			
				<!--- something broke so we're going to create a dummy entry in cache to prevent checking for some time --->
				<cfset setData(argumentCollection = arguments, data = duplicate(strTemp), city = loc.getVchCity(), state = loc.getChrRegion()) />

			</cfcatch> 
		</cftry>
		
		<!--- ship it back --->
		<cfreturn getData(arguments.zip) />
	</cffunction>


	<cffunction name="getWeatherForecast" output="false" access="private" returntype="any">
		<cfargument name="longitude" required="true" type="numeric" />
		<cfargument name="latitude" required="true" type="numeric" />
		<cfargument name="startDate" required="true" type="date" />
		<cfargument name="numDays" required="true" type="numeric" />

		<cfset var xmlPacket = "" />
		<cfset var rtnPacket = "" />

		<cfinvoke method="NDFDgenByDay" returnvariable="rtnPacket" webservice="#variables.ws#" timeout="25">
			<cfinvokeargument name="latitude" value="#arguments.latitude#" />
			<cfinvokeargument name="longitude" value="#arguments.longitude#" />
			<cfinvokeargument name="format" value="12 hourly" />
			<cfinvokeargument name="startDate" value="#dateFormat(arguments.startDate, 'yyyy-mm-dd')#" />
			<cfinvokeargument name="numDays" value="#val(arguments.numDays)#" />
		</cfinvoke>
		
		<!--- we get xsi:nil for empty elements as well as just no data in certain slots --->
		<cfset xmlPacket = xmlParse(rtnPacket) />
		
		<cfreturn xmlPacket.dwml.data />
	</cffunction>


	<!--- check if currently cached data is valid for this request --->
	<cffunction name="isDataCurrent" output="false" access="private" returntype="boolean">
		<cfargument name="zip" type="string" required="true">
		<cfargument name="startDate" type="date" required="true">
		<cfargument name="numDays" type="numeric" required="true">

		<cfset var loc = "" />
		
		<!--- if the data exists and it's less than 6 hours old we're ok --->	
		<cfif structKeyExists(variables.cache, arguments.zip)>
				<cfset loc = getData(arguments.zip)>
				<cfif dateDiff('h', loc.timestamp, now()) LTE 6
						AND loc.startDate EQ arguments.startDate
						AND loc.numDays GTE arguments.numDays>
					<cfreturn true />
				<cfelse>
					<cfreturn false />
				</cfif>
		<cfelse> 
			<cfreturn false />
		</cfif>
	</cffunction>


	<cffunction name="getData" output="false" access="private" returntype="struct">
		<cfargument name="zip" type="string" required="true" />

		<!--- to avoid throwing an error --->	
		<cfif structKeyExists(variables.cache, arguments.zip)>
			<cfreturn variables.cache[arguments.zip] />
		<cfelse> 
			<!--- it should never get here ... --->
			<cfthrow message="Data not in cache" detail="Weather data for zip code ""#arguments.zip#"" was not found in variables.cache." />
		</cfif>
	</cffunction>


	<cffunction name="setData" output="false" access="private" returntype="void">
		<cfargument name="zip" type="string" required="true" />
		<cfargument name="startDate" type="date" required="true" />
		<cfargument name="numDays" type="numeric" required="true" />
		<cfargument name="data" type="struct" required="true" />
		<!--- optional info --->
		<cfargument name="city" type="string" required="false" default="" />
		<cfargument name="state" type="string" required="false" default="" />

		<cfset var strTemp = structNew() />

		<!--- create a struct with the timestamp and the data --->
		<cfscript>
			strTemp.timestamp = now();
			strTemp.startDate = dateFormat(arguments.startDate, 'yyyy-mm-dd');
			strTemp.numDays = arguments.numDays;
			strTemp.data = arguments.data;
			strTemp.zipCode = arguments.zip;
			strTemp.city = arguments.city;
			strTemp.state = arguments.state;
		
			structInsert(variables.cache, arguments.zip, strTemp, true);
		</cfscript>
	</cffunction>
	
</cfcomponent>