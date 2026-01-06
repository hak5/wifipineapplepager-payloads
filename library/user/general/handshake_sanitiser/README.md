# Handshake Sanitiser

**Author:** PanicAcid  
**Version:** 1.0  
**Target:** Handshake Loot Management (`~/loot/handshakes`)

---

## The Problem
If you leave a Pineapple running for any decent amount of time, your handshake folder becomes a nightmare. You end up with hundreds of duplicate captures for the same network, and because the filenames contain colons (`:`), Windows refuses to touch them. It makes managing your loot a total chore.

## The Solution
**Handshake Sanitiser** is a straightforward utility to get your loot folder under control. It handles the heavy lifting of sorting through your captures and making sure you only keep the stuff that actually matters.

### Features
* **Smart Deduplication**: Scans your MAC address pairings and keeps only the absolute newest capture for each target. 
* **Quality Control**: Got a full handshake? The script can automatically nuke the partial ones for that same network, so you aren't wasting time on inferior captures.
* **Windows Normalisation**: Swaps those illegal colons (`:`) for hyphens (`-`). You can finally drag-and-drop your loot folder straight onto a Windows machine without it throwing a fit.
* **Non-Destructive**: It always keeps the best available version of a handshake. If you only have a partial, it stays safe until you manage to snag a full one.

## Usage
1. Run **Handshake Sanitiser** from the User Payloads menu.
2. Follow the prompts on the screen to choose your cleaning method:
   - **Deduplicate?** (Removes older identical captures).
   - **Purge Partials?** (Removes partials if you've already got a full one).
   - **Rename for Windows?** (Fixes the colon character issue).
3. Check the system log for a summary of how much junk was cleared out.

---
*Surgical loot organisation for the WiFi Pineapple Pager.*