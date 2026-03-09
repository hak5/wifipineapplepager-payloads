#!/bin/bash
# Title: Payload Search
# Description: Search for payloads by name, title, description, or author. Browse and view payload details.
# Author: tototo31
# Version: 1.0

PAYLOAD_DIR="/mmc/root/payloads"
TEMP_RESULTS="/tmp/payload_search_results.txt"

# Extract metadata from payload.sh file
get_payload_meta() {
    local pfile="$1"
    local title=""
    local description=""
    local author=""
    local version=""
    
    if [ -f "$pfile" ]; then
        title=$(grep -m 1 "^# *Title:" "$pfile" | cut -d: -f2- | sed 's/^[ \t]*//;s/[ \t]*$//')
        description=$(grep -m 1 "^# *Description:" "$pfile" | cut -d: -f2- | sed 's/^[ \t]*//;s/[ \t]*$//')
        author=$(grep -m 1 "^# *Author:" "$pfile" | cut -d: -f2- | sed 's/^[ \t]*//;s/[ \t]*$//')
        version=$(grep -m 1 "^# *Version:" "$pfile" | cut -d: -f2- | sed 's/^[ \t]*//;s/[ \t]*$//')
    fi
    
    echo "$title|$description|$author|$version"
}

# Search for payloads
search_payloads() {
    local query="$1"
    
    # Clear previous results
    > "$TEMP_RESULTS"
    
    LOG "Searching for: $query"
    LED SPECIAL
    
    # Find all payload.sh files
    if [ ! -d "$PAYLOAD_DIR" ]; then
        LED FAIL
        ERROR_DIALOG "Payload directory not found: $PAYLOAD_DIR"
        exit 1
    fi
    
    find "$PAYLOAD_DIR" -name "payload.sh" -type f | while read -r pfile; do
        local dir=$(dirname "$pfile")
        local name=$(basename "$dir")
        local rel_path="${dir#$PAYLOAD_DIR/}"
        
        # Skip disabled payloads
        if [[ "$name" =~ ^DISABLED\. ]]; then
            continue
        fi
        
        # Get metadata
        local meta=$(get_payload_meta "$pfile")
        local title=$(echo "$meta" | cut -d'|' -f1)
        local description=$(echo "$meta" | cut -d'|' -f2)
        local author=$(echo "$meta" | cut -d'|' -f3)
        local version=$(echo "$meta" | cut -d'|' -f4)
        
        # Use name as fallback for title
        [ -z "$title" ] && title="$name"
        
        # Search in name, title, description, and author (case-insensitive)
        local search_text="$name $title $description $author"
        if echo "$search_text" | grep -qi "$query"; then
            echo "$rel_path|$name|$title|$description|$author|$version" >> "$TEMP_RESULTS"
        fi
    done
    
    # Count results (need to read file since subshell)
    local result_count=$(wc -l < "$TEMP_RESULTS" 2>/dev/null || echo "0")
    echo "$result_count"
}

# Display search results
display_results() {
    local count="$1"
    
    if [ "$count" -eq 0 ]; then
        LOG "No payloads found matching your search."
        LED FAIL
        return 1
    fi
    
    LOG "Found $count matching payload(s):"
    LOG "================================"
    
    local idx=1
    while IFS='|' read -r rel_path name title description author version; do
        LOG ""
        LOG "[$idx] $title"
        [ -n "$name" ] && [ "$name" != "$title" ] && LOG "    Name: $name"
        [ -n "$description" ] && LOG "    Desc: $description"
        [ -n "$author" ] && LOG "    Author: $author"
        [ -n "$version" ] && LOG "    Version: $version"
        LOG "    Path: $rel_path"
        idx=$((idx + 1))
    done < "$TEMP_RESULTS"
    
    LOG ""
    LOG "================================"
    return 0
}

# View details of a specific payload
view_payload_details() {
    local selection="$1"
    local line=$(sed -n "${selection}p" "$TEMP_RESULTS")
    
    if [ -z "$line" ]; then
        ERROR_DIALOG "Invalid selection"
        return 1
    fi
    
    IFS='|' read -r rel_path name title description author version <<< "$line"
    local full_path="$PAYLOAD_DIR/$rel_path/payload.sh"
    
    if [ ! -f "$full_path" ]; then
        ERROR_DIALOG "Payload file not found: $full_path"
        return 1
    fi
    
    LOG ""
    LOG "=== Payload Details ==="
    LOG "Title: $title"
    LOG "Name: $name"
    [ -n "$description" ] && LOG "Description: $description"
    [ -n "$author" ] && LOG "Author: $author"
    [ -n "$version" ] && LOG "Version: $version"
    LOG "Path: $rel_path"
    LOG ""
    LOG "=== Payload File Location ==="
    LOG "$full_path"
}

# Main search loop
main() {
    LED SETUP

    LOG "Payload Search"
    LOG "================================"
    LOG "Search for payloads by name, title, description, or author."
    LOG ""
    LOG "Press A to enter a search query and find payloads."
    LOG "================================"

    WAIT_FOR_INPUT A

    while true; do
        # Get search query
        local query=$(TEXT_PICKER "Enter search query" "")
        
        
        # Check if query is empty
        if [ -z "$query" ]; then
            if [ "$(CONFIRMATION_DIALOG "Empty search. Exit?")" != "$DUCKYSCRIPT_USER_CONFIRMED" ]; then
                continue
            fi

            LOG "Exiting..."
            LED FINISH
            exit 0
            
        fi
        
        # Perform search
        local result_count=$(search_payloads "$query")
        
        # Display results
        if display_results "$result_count"; then
            if [ "$result_count" -gt 20 ]; then
                LOG "Too many results ($result_count). Please refine your search."
            fi
            
            break

        else
            # No results, ask to search again
            if [ "$(CONFIRMATION_DIALOG "No results found. Search again?")" != "$DUCKYSCRIPT_USER_CONFIRMED" ]; then
                break
            fi
        fi
    done
    
    # Cleanup
    rm -f "$TEMP_RESULTS"
    LED FINISH
    LOG "Search complete!"
}

# Run main function
main
