# wiglebluetooth

This payload allows you to scan BLE (Bluetooth Low Energy) devices and upload them to Wigle in a Wigle compatiable CSV file. Bluetooth classic is not supported at this time!

`wiglebluetooth` also allows you to combine a WiFi CSV produced by the pager and the CSV file produced by this payload to upload them in one go.

The way the payload works is by relying on a seperate executable running in the background to act as the CSV writer and device scanner.

This allows you to keep using other features of your pager. You can start and stop the background process by using the payload menu. 

The repo with the executable code is [here](https://github.com/craftzman7/wigle-bluetooth-pager) if you'd like to build it yourself. Otherwise, the payload will download the latest release from Github automatically. 