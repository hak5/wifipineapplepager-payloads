#!/bin/bash

# Title: Weather
# Author: spywill
# Description:  A simple weather app to check local or enter city name 
# Version: 1.0

# Check internet connection
if ping -c 1 -W 2 8.8.8.8 >/dev/null 2>&1; then
	LOG green "Online"
else
	LOG red "Offline internet connection is required exiting"
	exit 1
fi

my_city=$(curl -s ipinfo.io/city | sed 's/ /+/g')
CITY=$(TEXT_PICKER "Enter cities name" "$my_city")
DATA=$(curl -s "https://wttr.in/${CITY}?format=j1")

spinnerid=$(START_SPINNER "Weather info")

# Functions
cond() { echo "$DATA" | jq -r ".weather[$1].hourly[4].weatherDesc[0].value"; }
max() { echo "$DATA" | jq -r ".weather[$1].maxtempC"; }
min() { echo "$DATA" | jq -r ".weather[$1].mintempC"; }
feels_like() { echo "$DATA" | jq -r ".weather[$1].hourly[4].FeelsLikeC"; }
wind() { speed=$(echo "$DATA" | jq -r ".weather[$1].hourly[4].windspeedKmph"); dir=$(echo "$DATA" | jq -r ".weather[$1].hourly[4].winddir16Point"); echo "${speed}${dir}"; }
humidity() { echo "$DATA" | jq -r ".weather[$1].hourly[4].humidity"; }
sunrise() { echo "$DATA" | jq -r ".weather[$1].astronomy[0].sunrise"; }
sunset() { echo "$DATA" | jq -r ".weather[$1].astronomy[0].sunset"; }

# Table header
LOG ""
LOG yellow "Weather: $CITY"
LOG ""
LOG blue "+------+------+------+------+-------+------+"
LOG green "Day   | Cond | TEMP | FELL | Wind  | HUM   "
LOG blue "+------+------+------+------+-------+------+"
LOG ""

for i in 0 1 2; do
	case $i in
		0) DAY="Today";;
		1) DAY="Tmrw";;
		2) DAY="Day+2";;
	esac
	W="$(cond $i)"
	T="$(max $i)→$(min $i)"
	F="$(feels_like $i)"
	WN="$(wind $i)"
	H="$(humidity $i)"
	# Shorten condition to 3 chars
	SHORTCOND="$(echo $W | cut -c1-3)"
	LOG "$(printf "%-5s| %-3s | %-4s | %-4s | %-5s | %-2s" "$DAY" "$SHORTCOND" "$T" "$F" "$WN" "$H")"
done

sleep 1
STOP_SPINNER ${spinnerid}

# Sunrise / Sunset
LOG ""
LOG yellow "Sunrise / Sunset:"
LOG ""
for i in 0 1 2; do
	case $i in
		0) DAY="Today";;
		1) DAY="Tomorrow";;
		2) DAY="DayAfter";;
	esac
	LOG "$(printf "%-7s : %s / %s" "$DAY" "$(sunrise $i)" "$(sunset $i)")"
done
