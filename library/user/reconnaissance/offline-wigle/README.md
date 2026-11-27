# Offline WiGLE

- Author:       TW-D
- Version:      1.0

## Description

Offline WiGLE reconnaissance with conversion of WiGLE log file to KML format for visualization (Google Earth).

## Configuration

From the file "payload.sh" change the value of the following constants :

```

#
# USER CONSTANTS
#

# GPS serial communication speed
#
GPS_BAUDRATE=4800

# Acceptable battery percentage threshold
#
BATTERYPERCENT_LIMIT=25

# Maximum WiGLE log file size threshold (MB)
#
WIGLESTART_LIMIT=50

```
