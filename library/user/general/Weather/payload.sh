#!/bin/bash

# Title: Weather
# Author: spywill
# Description:  A Bash script that checks internet access, gets a city name, uses Open-Meteo APIs to fetch weather data, and prints current conditions plus a 3-day forecast. 
# Version: 1.3

set -euo pipefail

# Check internet connection
if ! ping -c 1 -W 2 8.8.8.8 >/dev/null 2>&1; then
	LOG red "Internet connection required"
	exit 0
fi

LOG green "Online"

# City input
my_city=$( (curl -fs https://ipapi.co/city || curl -fs https://ipinfo.io/city || curl -fs http://ip-api.com/line?fields=city) | tr ' ' '+' )
CITY=$(TEXT_PICKER "Enter city" "$my_city")
CITY_ENC="${CITY// /%20}"

# Geocode city
GEO=$(curl -fsS "https://geocoding-api.open-meteo.com/v1/search?name=${CITY_ENC}&count=1")

if [[ -z "$GEO" ]] || [[ "$(echo "$GEO" | jq '.results | length // 0')" -eq 0 ]]; then
	LOG red "City not found"
	exit 0
fi

LAT=$(echo "$GEO" | jq -r '.results[0].latitude')
LON=$(echo "$GEO" | jq -r '.results[0].longitude')

REGION=$(echo "$GEO" | jq -r '.results[0].admin1 // "Unknown"')
COUNTRY=$(echo "$GEO" | jq -r '.results[0].country // "Unknown"')

# Fetch weather data
DATA=$(curl -fsS "https://api.open-meteo.com/v1/forecast?latitude=${LAT}&longitude=${LON}&current=temperature_2m,relative_humidity_2m,apparent_temperature,wind_speed_10m,pressure_msl,visibility,weather_code&daily=temperature_2m_max,temperature_2m_min,sunrise,sunset&forecast_days=3&timezone=auto")

if [[ -z "$DATA" ]]; then
	LOG red "Weather request failed"
	exit 0
fi

# Current conditions
TEMP=$(echo "$DATA" | jq -r '.current.temperature_2m // "N/A"')
FEELS=$(echo "$DATA" | jq -r '.current.apparent_temperature // "N/A"')
HUM=$(echo "$DATA" | jq -r '.current.relative_humidity_2m // "N/A"')
WINDSPD=$(echo "$DATA" | jq -r '.current.wind_speed_10m // "N/A"')
PRESSURE=$(echo "$DATA" | jq -r '.current.pressure_msl // "N/A"')
VISIBILITY=$(echo "$DATA" | jq -r '.current.visibility // "N/A"')
WEATHER_CODE=$(echo "$DATA" | jq -r '.current.weather_code // -1')

WEATHER_DESC() {
	case "$1" in
		0) echo "Clear sky" ;;
		1|2|3) echo "Partly cloudy" ;;
		45|48) echo "Fog" ;;
		51|53|55) echo "Drizzle" ;;
		61|63|65) echo "Rain" ;;
		71|73|75) echo "Snow" ;;
		80|81|82) echo "Rain showers" ;;
		95) echo "Thunderstorm" ;;
		96|99) echo "Thunderstorm (hail)" ;;
		*) echo "Unknown" ;;
	esac
}

# Output
LOG ""
LOG yellow "Weather"
LOG blue "--------------------------------"

LOG "Location : $CITY"
LOG "Region   : $REGION"
LOG "Country  : $COUNTRY"

LOG ""
LOG yellow "Current conditions"
LOG blue "--------------------------------"

LOG "Condition  : $(WEATHER_DESC "$WEATHER_CODE")"
LOG "Temp       : ${TEMP}°C"
LOG "Feels Like : ${FEELS}°C"
LOG "Humidity   : ${HUM}%"
LOG "Wind       : ${WINDSPD} km/h"
LOG "Pressure   : ${PRESSURE} mb"
LOG "Visibility : ${VISIBILITY} m"

# 3-day forecast
LOG ""
LOG yellow "3 Day Forecast"
LOG blue "--------------------------------"

for i in 0 1 2; do
	DATE=$(echo "$DATA" | jq -r ".daily.time[$i] // \"N/A\"")
	MAX=$(echo "$DATA" | jq -r ".daily.temperature_2m_max[$i] // \"N/A\"")
	MIN=$(echo "$DATA" | jq -r ".daily.temperature_2m_min[$i] // \"N/A\"")

	LOG "$DATE High:${MAX}°C Low:${MIN}°C"
done

# Sunrise / Sunset
LOG ""
LOG yellow "Sunrise / Sunset"
LOG blue "--------------------------------"

for i in 0 1 2; do
	DATE=$(echo "$DATA" | jq -r ".daily.time[$i] // \"N/A\"")
	SUNRISE=$(echo "$DATA" | jq -r ".daily.sunrise[$i] // \"\"")
	SUNSET=$(echo "$DATA" | jq -r ".daily.sunset[$i] // \"\"")

	LOG "$DATE ${SUNRISE#*T} / ${SUNSET#*T}"
done
