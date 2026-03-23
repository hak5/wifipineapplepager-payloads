# GPS Checker

**GPS Checker** looks, if gpsd if receiving data from your GPS device.

- **Author:** mik
- **Version:** 1.0

## Why?

I already had a couple occasions where GPS did not work.
When you turn on the pager indoors, you would never get a Lat and Lon reading, so you can't check if GPS is working properly.
This payload checks, if gpsd is receiving GPS data, which is a prerequisite to be able to get a location fix.

## Usage

Run the payload on the Pineapple Pager it will tell you if GPS data is flowing, if not it tries to restart gpsd and looks again.

If it fails, you should check gpsd config or your hardware.
