import json
import os
import requests

# CONFIG
JSON_FILE = 'site/payloads.json'
TOKEN = os.environ.get('GITHUB_TOKEN')
REPO = os.environ.get('GITHUB_REPOSITORY') # e.g. "StarkweatherNow/repo"
HEADERS = {
    "Authorization": f"token {TOKEN}", 
    "Accept": "application/vnd.github.v3+json"
}

def create_issue(payload_data):
    # 1. Construct a nice body for the issue
    # Handle readme_url vs readme_path safely
    path = payload_data.get('readme_url') or payload_data.get('readme_path') or ""
    
    # Construct a link to the Readme (assuming standard folder structure)
    # Adjust 'main' or 'master' depending on your branch name
    readme_link = f"https://github.com/hak5/wifipineapplepager-payloads/tree/master/library{path}"
    
    title = f"OFFICIAL VOTE: {payload_data['title']}"
    body = (
        f"### 🗳️ Official Voting Thread: {payload_data['title']}\n\n"
        f"{payload_data['description']}\n\n"
        f"**[View ReadMe & Source Code]({readme_link})**\n\n"
        f"---\n"
        f"*Click the Thumbs Up (👍) reaction below to vote for this payload.*\n"
        f"*Votes are synced to the Community Hub hourly.*"
    )

    # 2. Send to GitHub
    url = f"https://api.github.com/repos/{REPO}/issues"
    resp = requests.post(url, json={"title": title, "body": body}, headers=HEADERS)
    resp.raise_for_status()
    
    issue_data = resp.json()
    issue_number = issue_data['number']

    # --- NEW: Add the Initial Thumbs Up (+1) ---
    print(f" -> Adding initial reaction to Issue #{issue_number}...")
    reaction_url = f"https://api.github.com/repos/{REPO}/issues/{issue_number}/reactions"
    # Content must be "+1" for thumbs up
    requests.post(reaction_url, json={"content": "+1"}, headers=HEADERS)
    # -------------------------------------------
    
    return issue_number

# MAIN EXECUTION
if __name__ == "__main__":
    with open(JSON_FILE, 'r') as f:
        payloads = json.load(f)

    changes_made = False

    for p in payloads:
        # Check if issue_number is missing, 0, or null
        if not p.get('issue_number'):
            print(f"Found new payload without issue: {p['title']}")
            try:
                new_id = create_issue(p)
                p['issue_number'] = new_id
                # Ensure vote count is init at 0
                if 'votes' not in p: p['votes'] = 0
                
                print(f" -> Created Issue #{new_id}")
                changes_made = True
            except Exception as e:
                print(f" -> Failed to create issue: {e}")

    if changes_made:
        with open(JSON_FILE, 'w') as f:
            json.dump(payloads, f, indent=4)
        print("UPDATED=true")
        # Write to GITHUB_ENV so the next step knows to commit
        with open(os.environ['GITHUB_ENV'], 'a') as env_file:
            env_file.write("UPDATED=true\n")
    else:
        print("No new payloads found.")
        with open(os.environ['GITHUB_ENV'], 'a') as env_file:
            env_file.write("UPDATED=false\n")