# Payload Search

**Payload Search** is a utility payload that allows you to quickly search and browse through all available payloads on your WiFi Pineapple Pager by name, title, description, or author.

- **Author:** tototo31
- **Version:** 1.0

---

## Features

* **Multi-field Search:** Search across payload names, titles, descriptions, and authors
* **Case-Insensitive Matching:** Find payloads regardless of capitalization
* **Detailed Results:** View title, name, description, author, version, and path for each match
* **Smart Filtering:** Automatically excludes disabled payloads from search results
* **Interactive Interface:** Easy-to-use prompts and confirmation dialogs
* **Result Limiting:** Warns when search returns more than 20 results to help refine queries

---

## Usage

### Basic Search

1. **Launch the payload** from the general category
2. **Press A** when prompted to start searching
3. **Enter your search query** - you can search by:
   - Payload name (directory name)
   - Title (from metadata)
   - Description
   - Author name
4. **View results** - matching payloads are displayed with:
   - Numbered list
   - Title and name
   - Description
   - Author
   - Version
   - Full path

### Search Tips

* **Empty search:** If you leave the search query empty, the payload will exit
* **Partial matches:** The search finds payloads containing your query text anywhere in the searchable fields
* **Too many results:** If more than 20 payloads match, you'll be prompted to refine your search

### Example Searches

* Search for "network" to find all network-related payloads
* Search for an author name to find all payloads by that author
* Search for "handshake" to find payloads dealing with handshakes
* Search for "update" to find update-related utilities

---

## How It Works

The payload:
1. Scans `/mmc/root/payloads` for all `payload.sh` files
2. Extracts metadata from comment headers in each payload file
3. Searches across multiple fields (name, title, description, author)
4. Filters out disabled payloads (those prefixed with `DISABLED.`)
5. Displays formatted results with all relevant information

---

## Technical Details

**Search Location:** `/mmc/root/payloads`

**Metadata Extraction:**
- Reads `# Title:` from payload.sh header
- Reads `# Description:` from payload.sh header
- Reads `# Author:` from payload.sh header
- Reads `# Version:` from payload.sh header

**Temporary Files:**
- Uses `/tmp/payload_search_results.txt` for storing search results (automatically cleaned up)

---

## Notes

* The payload searches through all payload categories (alerts, recon, user, etc.)
* Disabled payloads are automatically excluded from search results
* Search is case-insensitive for better usability
* Results are limited to 20 for better readability (you'll be warned if more matches exist)
