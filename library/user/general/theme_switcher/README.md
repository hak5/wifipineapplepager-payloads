# Theme Switcher

A WiFi Pineapple Pager payload for browsing, previewing and activating themes from the device itself.

- **Author:** h4d35x0
- **Version:** 1.3
- **Category:** general

## What it does

- Lists installed themes in `/mmc/root/themes`, either all of them or only framework 0.9 (firmware 2.0.0) themes.
- Shows each theme's preview, dashboard, boot and settings images on screen before you commit to it.
- Shows theme info: author, framework version and the first lines of its README.
- Activates a theme: sets it in UCI, plays a short chime and restarts the Pager UI.
- Browses themes in the firmware update cache (`/mmc/root/pager_update_cache/UpdateThemes/themes`) and installs them to `/mmc/root/themes`.
- Previews the images in a pull request on [hak5/wifipineapplepager-themes](https://github.com/hak5/wifipineapplepager-themes) by PR number. This needs internet access through the Pager's Wi-Fi client.

## Install

```sh
scp -r theme_switcher root@172.16.52.1:/mmc/root/payloads/user/general/
```

Then run **Theme Switcher** from the payloads menu under **general**.

## Behaviour worth knowing

- **Activating a theme may add files to it.** Before activating, the payload checks every component and asset the theme references. Any that are missing are copied in from the built-in wargames theme (`/rom/lib/pager/themes/wargames`). This stops an incomplete theme from failing to load, but it does modify the theme directory.
- **Activating restarts the Pager UI.** The payload waits about 10 seconds while the UI restarts.
- **Installing a PR's theme** hands off to the separate [PullThemePR](../PullThemePR) payload, which must be installed at `/mmc/root/payloads/user/general/PullThemePR/`. PullThemePR asks for the PR number again. This payload does not download themes itself.
- **Theme paths with a `..` segment are ignored** when filling in missing files, so a theme cannot make the payload write outside its own directory.

## Credits

- Missing theme files are restored from Hak5's built-in **wargames** theme.
- PR installs use [PullThemePR](../PullThemePR) by Austin.
