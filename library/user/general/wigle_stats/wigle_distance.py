#!/usr/bin/env python3

import csv
import math
import sys
from datetime import datetime

if len(sys.argv) != 2:
    sys.exit("Usage: wigle_distance.py <wigle.csv>")

filename = sys.argv[1]

EARTH_RADIUS_KM = 6371.0
MAX_SPEED_KMH = 160        # generous driving cap
MIN_MOVE_KM = 0.005        # 5 meters

def haversine(lat1, lon1, lat2, lon2):
    lat1, lon1, lat2, lon2 = map(math.radians, [lat1, lon1, lat2, lon2])
    dlat = lat2 - lat1
    dlon = lon2 - lon1
    a = math.sin(dlat/2)**2 + math.cos(lat1) * math.cos(lat2) * math.sin(dlon/2)**2
    return EARTH_RADIUS_KM * 2 * math.atan2(math.sqrt(a), math.sqrt(1-a))

def parse_time(ts):
    return datetime.fromisoformat(ts.replace("Z", "+00:00")).timestamp()

total = 0.0
prev = None

with open(filename, newline='') as f:
    reader = csv.reader(f)
    next(reader)
    next(reader)

    for row in reader:
        try:
            lat = float(row[7])
            lon = float(row[8])
            t = parse_time(row[3])
        except Exception:
            continue

        if lat == 0 or lon == 0:
            continue

        if prev:
            d = haversine(prev["lat"], prev["lon"], lat, lon)
            dt = t - prev["time"]

            if dt <= 0:
                prev = {"lat": lat, "lon": lon, "time": t}
                continue

            speed = (d / dt) * 3600  # km/h

            if d >= MIN_MOVE_KM and speed <= MAX_SPEED_KMH:
                total += d

        prev = {"lat": lat, "lon": lon, "time": t}

print(f"{total:.2f}")