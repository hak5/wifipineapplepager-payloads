# WiFi Pineapple Pager Payload Repository - System Design & Operations Manual

**Project:** GitHub-Native Payload Repository Platform  
**Status:** Operational / Maintenance Mode

## 1. Executive Summary

This platform serves as a community-driven "App Store" for repository artifacts (specifically WiFi Pineapple Pager payloads). Unlike traditional web applications that require database servers (SQL) and backend hosting (AWS/Azure), this system is built entirely on **GitHub's Serverless Ecosystem**.

* **Zero Cost:** Hosting, database, and backend logic are handled by GitHub Free Tier.
* **Transparency:** All logic, votes, and code are open-source.
* **Automation:** The system is self-healing and self-updating.

---

## 2. Architecture Overview

The system is composed of three distinct layers:

### A. The Frontend (The "Storefront")
* **Technology:** HTML5, CSS3, Vanilla JavaScript.
* **Hosting:** GitHub Pages.
* **Function:** It is a static site. It does not calculate anything server-side. Instead, it fetches pre-computed data from a JSON registry file (`site/payloads.json`) to render the UI cards.

### B. The Database (The "Registry")
* **Static Data:** `site/payloads.json`. This is the "Master Record." It contains the title, description, author, and path for every payload.
* **Dynamic Data:** **GitHub Issues**. We utilize the GitHub Issues API as a NoSQL database to store user votes (Reactions) and comments. This delegates authentication and spam protection to GitHub.

### C. The Backend (The "Robots")
* **Technology:** Python 3.9 + GitHub Actions (YAML).
* **Function:** A set of autonomous "Watchdogs" that trigger on specific events (Code Pushes, Pull Requests, Schedule) to synchronize the static registry with the dynamic data.

---

## 3. Operational Workflow

This is the lifecycle of a payload from "User Idea" to "Live on Website."

### Phase 1: Submission
1.  **User** forks the repository.
2.  **User** creates a folder in `library/category/MyPayload`.
3.  **User** adds a `README.md` containing **YAML Front Matter** (Metadata) and the code.
4.  **User** submits a Pull Request (PR) to the `master` branch.

### Phase 2: Ingestion (The Librarian)
1.  **Admin** reviews the code and clicks "Merge."
2.  **Action Triggered:** `Sync Library Manifests`.
3.  **Bot Task:** Scans the `library/` folder for `README.md` files.
4.  **Bot Task:** Parses the YAML Front Matter (Title, Author, Tags).
5.  **Bot Task:** Updates `site/payloads.json` with the new entry.

### Phase 3: Voting Initialization (The Watchdog)
1.  **Action Triggered:** `Watchdog - Ensure Voting Issues` (runs immediately after Phase 2).
2.  **Bot Task:** Detects the new payload has no "Issue Number."
3.  **Bot Task:** Creates a new GitHub Issue titled "OFFICIAL VOTE: [Payload Name]."
4.  **Bot Task:** Adds the initial 👍 reaction to initialize the voting button.
5.  **Bot Task:** Writes the new Issue Number back to `site/payloads.json`.

### Phase 4: The Loop (Vote Sync)
1.  **Action Triggered:** `Sync Vote Counts` (Runs hourly via CRON).
2.  **Bot Task:** Queries the GitHub API for reaction counts on all official issues.
3.  **Bot Task:** Updates the "votes" integer in `site/payloads.json`.
4.  **Bot Task:** Rebuilds the website to display the new scores.

---

## 4. Configuration Guide

To maintain or alter the system, stakeholders need to know where the logic lives.

### Key Directory Structure
* **`.github/workflows/`**: The Triggers (When to run).
    * `library_sync.yml`: Runs on PR Merge. Adds new files to DB.
    * `watchdog_issues.yml`: Runs on JSON change. Creates voting threads.
    * `vote_sync.yml`: Runs Hourly. Updates vote counts.
* **`.github/scripts/`**: The Logic (What to run).
    * `scan_library.py`: The regex parser for reading READMEs.
    * `ensure_issues.py`: The API bridge that talks to GitHub Issues.
    * `update_votes.py`: The calculator that tallies votes.
* **`library/`**: The Content.
    * All user submissions live here. Organized by category folders.
* **`site/`**: The Website.
    * Contains the `index.html`, `style.css`, and `app.js`.

### The Metadata Standard (YAML Front Matter)
To ensure the automated "Librarian" picks up a payload, the `README.md` **must** start with this header:

```
---
title: Payload Name
description: One sentence summary.
author: GitHubUsername
category: General
tags: [Tag1, Tag2]
---
```

## 5. Maintenance & Troubleshooting

### Scenario A: A Payload isn't appearing on the site.
1.  **Check:** Did the PR merge successfully?
2.  **Check:** Does the `README.md` have valid YAML Front Matter? (Are the `---` dashes correct? Is indentation correct?)
3.  **Fix:** Edit the README to fix the YAML, then push. The `Sync Library Manifests` action will run again automatically.

### Scenario B: The "Vote" button link is broken.
1.  **Check:** Go to `site/payloads.json`. Does the payload have `"issue_number": null`?
2.  **Fix:** Go to the **Actions** tab in GitHub. Run the `Watchdog - Ensure Voting Issues` workflow manually. This will generate the missing issue.

### Scenario C: Votes aren't updating.
1.  **Note:** Votes only update once per hour to save API limits.
2.  **Check:** Go to **Actions** -> **Sync Vote Counts**. Ensure the last run was Green.
3.  **Fix:** If the run failed, check the logs. It is usually a temporary GitHub API timeout. It will likely succeed the next hour.

---

## 6. Reconfiguration / Forking Guide

If you wish to clone this platform for a completely different project (e.g., "Awesome Flipper Zero Scripts" or "My Company Tools"), follow these steps to decouple it from the original repository.

### Step 1: Clean the Slate
1.  **Clear the Library:** Delete all folders inside `library/` except for a placeholder or README.
2.  **Reset the Registry:** Open `site/payloads.json` and replace the content with an empty array: `[]`.
3.  **Reset Issues:** Delete or close all existing Issues in your new repo (or they won't match your new content).

### Step 2: Update Hardcoded Variables
The automation scripts use environment variables (dynamic), but the frontend (static) requires manual updates.

* **`site/app.js`**: Search for `repoBase` or `libraryBase`.
    * *Change:* `https://github.com/StarkweatherNow/...` → `https://github.com/YOUR_USERNAME/YOUR_REPO`.
* **`.github/scripts/ensure_issues.py`**:
    * *Check:* Ensure `readme_link` variable points to your new repository's `library/` folder URL.
* **`site/index.html`**:
    * *Change:* Update `<title>`, `<h1>`, and branding text to match your new project name.

### Step 3: Enable Permissions
GitHub defaults to strict security for new forks. You must explicitly grant "Write" access to the bots.
1.  Go to **Settings** → **Actions** → **General**.
2.  Scroll to **Workflow permissions**.
3.  Select **"Read and write permissions"**.
4.  Click **Save**.

### Step 4: Activate "Issues" Feature
If your new repo is a Fork, "Issues" might be disabled by default.
1.  Go to **Settings** → **General**.
2.  Scroll to **Features**.
3.  Check the box for **Issues**.

### Step 5: First Run
1.  Add a new payload (folder + README with Front Matter) to `library/`.
2.  Push to `master`.
3.  Watch the **Actions** tab. The `Sync Library Manifests` workflow should trigger, followed by the `Watchdog`.
4.  Once green, enable **GitHub Pages** in Settings (Deploy from branch: `master`, folder: `/root` or `/docs` depending on your config).
