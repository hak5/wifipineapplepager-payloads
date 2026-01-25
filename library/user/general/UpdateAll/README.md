# Update All Payload

## Overview
This payload allows you to update **Payloads**, **Themes**, and **Ringtones** for the WiFi Pineapple Pager from a single interface. It replaces the need to have three separate update scripts.

## Why use this?
1.  **Unified Experience**: Manage all your Pager resources in one place.
2.  **Persistent Caching**: This payload uses `git` to maintain a local cache of the repositories in `/mmc/root/pager_update_cache`.
    *   **Faster Updates**: Subsequent updates only pull changes (`git pull`) rather than re-downloading the entire repository zip every time.
    *   **Bandwidth Efficient**: Saves data by only downloading what has changed.
3.  **Flexible**: Choose to update "Everything" at once, or select specific categories interactively.

## Credits
*   Based on the original update scripts by **cococode**.
*   Unified and enhanced by **Z3r0L1nk**.
