# PageCord

**Control WiFi Pineapple Pager Through Discord**

## Overview

This payload allows the user to control WiFi Pineapple Pager using a Discord bot/app.

Designed as a simple reverse shell along with extras such as file transfer, on-device setup and basic security features.

## Features

* Upload and download files
* Restart as background task
* Basic session security
* Single user ID access
* Changeable working directory
* Use all Linux and Duckyscript commands
* Batched messages for large outputs
* On-device setup

## Setup

1. make a discord bot at https://discord.com/developers/applications/
2. Turn on ALL intents in the 'Bot' tab.

<img width="1597" height="686" alt="intents" src="https://github.com/user-attachments/assets/1b31dfed-e85c-41d9-adb0-1514937835d4" />

3. Give these permissions in Oauth2 tab (Send-Messages, Read-messages/view-channels, Attach files)

<img width="1522" height="966" alt="perms" src="https://github.com/user-attachments/assets/81fc2d44-5831-4ccf-ad9e-06a36cfbd871" />

4. Copy the link/URL at the bottom of the page into a browser url bar
5. This Add the bot to your Discord server (A private server is recommended)
6. Click 'Reset Token' in "Bot" tab for your token and copy it
7. Run the payload ONCE to create setup files OR create a `.env` file yourself inside the pagecord directory, and add these feilds below..

```
token="YOUR_BOT_TOKEN_HERE"
chan="CHANNEL_ID_HERE"
pass="password"
```

8. You can either use the setup prompts on device, or edit the newly created .env file.
* Change YOUR_BOT_TOKEN_HERE with your bot token.
* Change CHANNEL_ID_HERE to the channel ID of your channel you intend to use for this.
* Change 'password' to something unique.. bear in mind it will be viewable by anyone in the channel selected (used for background sessions only.)

*Once this is done you can run the payload again and you should get a 'session waiting' message in discord. Only your user ID will be able to interact with the session.*

*The bot will NOT appear online - this is because the payload simply queries the Discord API and is expected behaviour..*

## Commands

**These commands are case sensitive!**

```
options  - Show the options list

pause    - Pause this session (re-authenticate to resume)

background  - Restart the payload in the background

sysinfo    - Show basic system information

close    - Close this session permanently

download   - Send a file to Discord [download path/to/file.txt]

upload     - Upload file to Pager [attach to 'upload' command]

readme     - Show a readme file in markdown format [readme path/to/README.md]

payloads   - List all user payloads along with their descriptions
```

**OR You can just use the channel as a basic shell**

## Road Map
- Pager specific commands
- Pager navigation with screenshots





