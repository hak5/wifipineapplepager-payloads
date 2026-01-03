import json
import os
import requests

# Config
REPO = os.getenv("GITHUB_REPOSITORY") # e.g. "username/repo"
TOKEN = os.getenv("GITHUB_TOKEN")
JSON_FILE = "site/payloads.json" # Verify this path matches your folder structure

def get_reaction_count(issue_number):
    url = f"https://api.github.com/repos/{REPO}/issues/{issue_number}"
    headers = {"Authorization": f"token {TOKEN}", "Accept": "application/vnd.github.v3+json"}
    resp = requests.get(url, headers=headers)
    if resp.status_code == 200:
        data = resp.json()
        # Count the '+1' reactions
        return data.get("reactions", {}).get("+1", 0)
    return 0

# Read JSON
with open(JSON_FILE, "r") as f:
    payloads = json.load(f)

# Update Votes
changes_made = False
for p in payloads:
    if "issue_number" in p:
        current_votes = get_reaction_count(p["issue_number"])
        if p.get("votes") != current_votes:
            p["votes"] = current_votes
            changes_made = True
            print(f"Updated {p['title']}: {current_votes} votes")

# Write JSON back if changed
if changes_made:
    with open(JSON_FILE, "w") as f:
        json.dump(payloads, f, indent=4)
    print("::set-output name=updated::true")
else:
    print("::set-output name=updated::false")