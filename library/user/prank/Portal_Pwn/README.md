<div align="center">

# Portal Pwn
![f2](https://github.com/user-attachments/assets/3baa6c7a-23cf-48de-9840-2f03bfe45d07)
![marauderskull](https://github.com/user-attachments/assets/55eeedb7-a1b0-43ce-ae0f-b657973ea16a)

</div>

Portal Pwn is a Hak5 Wifi Pineapple Pager payload designed to distrupt malicious actors utilizing ESP32 Marauder Evil Portals (EP) for credenetial phishing campaigns.
It works by throwing random data via `cURL` requests at the Evil Portal, overwhelming it, and crashing it. If you choose not to crash the portal, but have a laugh, a secondary attack can be utilized to spam requests at the portal filling the screen with whatever text you choose to input.
The payload prompts the user for the EP SSID, will then connect, and finally prompt the user for the desired attack preference `Spam (1) Crash (2)`.

![crash](https://github.com/user-attachments/assets/f1494636-0a50-48c2-adf5-61fb3c01bd58)

This payload has succesfully been tested on (and crashed):
```
JustCallMeKoko ESP32 Marauder v6.1 - Firmware v1.10.12
JustCallMeKoko ESP32 Marauder Mini - Firmware v1.10.12
Cheap Yellow Display - Marauder Firmware
Flipper Zero - Momentum Firmware - Evil Portal app
```
