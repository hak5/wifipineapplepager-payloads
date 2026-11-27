# 🌤️ Weather CLI Tool (Bash)

A lightweight Bash script that fetches real-time weather data for a selected city using geolocation + weather APIs. It auto-detects your location, lets you choose or override the city, and prints current conditions + a 3-day forecast.

---

## ✨ Features

- 🌍 Auto-detects your current city using IP geolocation
- ✍️ Interactive city input selector
- 🌦️ Current weather conditions (temperature, humidity, wind, pressure, visibility)
- 📅 3-day forecast
- 🌅 Sunrise and sunset times
- ⚡ Uses free public APIs
- 🧠 Human-readable weather condition decoding

---

## 🧰 Requirements

Make sure you have:

- `bash`
- `curl`
- `jq`
- `ping`

---

## 📡 APIs Used

This script relies on free APIs:

- IP Geolocation:
  - ipapi.co
  - ipinfo.io
  - ip-api.com

- Weather + Geocoding:
  - Open-Meteo API (no API key required)
  - https://open-meteo.com

---

You will be prompted to enter a city (auto-filled with detected location).

---

## 🌦️ Weather Data Included

- Current temperature
- Feels-like temperature
- Relative humidity
- Wind speed
- Atmospheric pressure
- Visibility
- Weather condition
- 3-day forecast (high/low)
- Sunrise & sunset times

---

## 📊 Example Output

```text
Weather
--------------------------------
Location : Chicago
Region   : Illinois
Country  : United States

Current conditions
--------------------------------
Condition  : Rain
Temp       : 18°C
Feels Like : 16°C
Humidity   : 72%
Wind       : 14 km/h
Pressure   : 1012 mb
Visibility : 9000 m

3 Day Forecast
--------------------------------
2026-05-30 High:21°C Low:13°C
2026-05-31 High:19°C Low:12°C
2026-06-01 High:23°C Low:15°C
```

---

## 🧠 Weather Code Mapping

| Code | Meaning |
|------|--------|
| 0 | Clear sky |
| 1–3 | Partly cloudy |
| 45–48 | Fog |
| 51–55 | Drizzle |
| 61–65 | Rain |
| 71–75 | Snow |
| 80–82 | Rain showers |
| 95 | Thunderstorm |
| 96–99 | Thunderstorm with hail |

---

## ⚠️ Notes

- Requires internet connection
- No API keys required
- Designed for quick terminal weather checks

---
