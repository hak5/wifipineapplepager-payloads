import json
import os
import re
from datetime import date

# CONFIG
LIBRARY_DIR = 'library'
REGISTRY_FILE = 'site/payloads.json'

def parse_front_matter(file_path):
    """
    Extracts YAML front matter from a markdown file.
    Returns a dictionary of metadata or None if invalid.
    """
    try:
        with open(file_path, 'r', encoding='utf-8') as f:
            content = f.read()
            
        # Regex to find the block between the first two '---' lines
        match = re.search(r'^---\s+(.*?)\s+---', content, re.DOTALL)
        
        if not match:
            return None
            
        yaml_block = match.group(1)
        metadata = {}
        
        # Simple parsing of "key: value" lines
        for line in yaml_block.split('\n'):
            if ':' in line:
                key, value = line.split(':', 1)
                key = key.strip()
                value = value.strip()
                
                # Handle Arrays (e.g., tags: [a, b, c])
                if value.startswith('[') and value.endswith(']'):
                    # Strip brackets and split by comma
                    clean_list = value[1:-1].split(',')
                    metadata[key] = [item.strip() for item in clean_list if item.strip()]
                else:
                    metadata[key] = value
                    
        # Validate required fields
        if 'title' in metadata and 'description' in metadata:
            return metadata
        return None
        
    except Exception as e:
        print(f"[WARN] Could not parse {file_path}: {e}")
        return None

def scan_and_sync():
    # 1. Load existing registry
    if os.path.exists(REGISTRY_FILE):
        with open(REGISTRY_FILE, 'r') as f:
            registry = json.load(f)
    else:
        registry = []

    registry_map = {item['id']: item for item in registry}
    changes_made = False
    
    # 2. Walk through library
    for root, dirs, files in os.walk(LIBRARY_DIR):
        # We look for README.md (case insensitive)
        readme_file = next((f for f in files if f.lower() == 'readme.md'), None)
        
        if readme_file:
            full_path = os.path.join(root, readme_file)
            meta = parse_front_matter(full_path)
            
            if meta:
                # Generate ID from folder structure
                rel_path = os.path.relpath(root, LIBRARY_DIR)
                payload_id = rel_path.replace(os.sep, '-')
                
                # Logic: If ID exists, update metadata; if new, create entry
                if payload_id not in registry_map:
                    print(f"[NEW] Discovered {meta['title']} ({payload_id})")
                    new_entry = {
                        "id": payload_id,
                        "title": meta['title'],
                        "description": meta['description'],
                        "author": meta.get('author', 'Community'),
                        "category": meta.get('category', 'General'),
                        "tags": meta.get('tags', []),
                        "readme_path": f"/{rel_path}", 
                        "last_updated": str(date.today()),
                        "votes": 0,
                        "visible": True,
                        "issue_number": None # Triggers the Issue Creator!
                    }
                    registry.append(new_entry)
                    registry_map[payload_id] = new_entry
                    changes_made = True
                else:
                    # Update Title/Desc/Tags if changed
                    existing = registry_map[payload_id]
                    if existing['title'] != meta['title'] or existing['description'] != meta['description']:
                        existing['title'] = meta['title']
                        existing['description'] = meta['description']
                        existing['tags'] = meta.get('tags', existing['tags'])
                        existing['last_updated'] = str(date.today())
                        print(f"[UPDATED] Refreshed metadata for {payload_id}")
                        changes_made = True
            else:
                print(f"[SKIP] {root} has a README but no valid Front Matter.")

    # 3. Save
    if changes_made:
        with open(REGISTRY_FILE, 'w') as f:
            json.dump(registry, f, indent=4)
        print("::set-output name=updated::true")
    else:
        print("::set-output name=updated::false")

if __name__ == "__main__":
    scan_and_sync()