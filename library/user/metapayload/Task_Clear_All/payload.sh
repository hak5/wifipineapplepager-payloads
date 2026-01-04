#!/bin/bash
# Title: Task CLEAR ALL
# Description: Deletes all tasks, kills processes, and removes task management payloads
# Author: spencershepard (GRIMM)
# Version: 1.0

TASK_DIR="/root/payloads/user/metapayload/.tasks"
MGMT_DIR="/root/payloads/user/metapayload"

# Function to recursively find all descendant PIDs
get_descendants() {
    local parent_pid="$1"
    local descendants=""
    
    # Find direct children from /proc
    for proc in /proc/[0-9]*; do
        [ -f "$proc/stat" ] || continue
        # Parse PPID - skip past command name in parentheses to avoid spaces in comm field
        local stat_line=$(cat "$proc/stat" 2>/dev/null)
        [ -z "$stat_line" ] && continue
        # Remove everything up to and including the last ) to get past comm field
        local after_comm="${stat_line##*) }"
        # PPID is the second field after state (state ppid ...)
        local ppid=$(echo "$after_comm" | awk '{print $2}')
        if [ "$ppid" = "$parent_pid" ]; then
            local child_pid=$(basename "$proc")
            descendants="$descendants $child_pid"
            # Recursively get this child's descendants
            local child_descendants=$(get_descendants "$child_pid")
            [ -n "$child_descendants" ] && descendants="$descendants$child_descendants"
        fi
    done
    
    echo "$descendants"
}

# Function to kill a process and all its descendants
kill_process_tree() {
    local pid="$1"
    local signal="${2:-TERM}"
    
    [ -z "$pid" ] && return
    
    # Check if process exists before doing anything
    [ ! -d "/proc/$pid" ] && return
    
    # Get all descendants
    local descendants=$(get_descendants "$pid")
    
    # Kill descendants first (deepest first)
    for desc_pid in $descendants; do
        [ -d "/proc/$desc_pid" ] || continue
        kill -$signal "$desc_pid" 2>/dev/null
    done
    
    # Kill the parent last
    if [ -d "/proc/$pid" ]; then
        kill -$signal "$pid" 2>/dev/null
    fi
}

# Check if task directory exists
if [ ! -d "$TASK_DIR" ]; then
    LOG yellow "No task directory found. Nothing to clear."
    exit 0
fi

# Count existing tasks
TASK_COUNT=$(find "$TASK_DIR" -name "*.meta" 2>/dev/null | wc -l)

if [ "$TASK_COUNT" -eq 0 ]; then
    LOG cyan "No tasks found. Nothing to clear."
    exit 0
fi

# Confirm with user
resp=$(CONFIRMATION_DIALOG "Clear All Tasks?

This will:
• Kill all running task processes
• Delete all task data (.meta and .log files)
• Remove all task management payloads

Found: $TASK_COUNT task(s)")

case $? in
    $DUCKYSCRIPT_REJECTED|$DUCKYSCRIPT_ERROR)
        LOG red "Error in dialog"
        exit 1
        ;;
esac

case "$resp" in
    $DUCKYSCRIPT_USER_DENIED)
        LOG yellow "Operation cancelled by user"
        exit 0
        ;;
esac


LOG purple "CLEARING ALL TASKS"


# Track statistics
PROCESSES_KILLED=0
TASKS_DELETED=0
MGMT_PAYLOADS_REMOVED=0
FAILED_OPERATIONS=0

# Step 1: Kill all running task processes
LOG yellow "Step 1: Terminating running task processes..."

shopt -s nullglob
for meta_file in "$TASK_DIR"/*.meta; do
    [ -f "$meta_file" ] || continue
    
    # Source the metadata file to get task info
    source "$meta_file"
    
    # Check if task has a PID and if it's still running
    if [ -n "$TASK_PID" ] && kill -0 "$TASK_PID" 2>/dev/null; then
        LOG "  Killing task $TASK_ID (PID: $TASK_PID)..."
        
        # Use kill_process_tree to terminate entire process tree
        kill_process_tree "$TASK_PID" TERM
        sleep 0.5
        
        # Force kill if still running
        kill_process_tree "$TASK_PID" KILL
        sleep 0.2
        
        # Verify the process is dead
        if ! kill -0 "$TASK_PID" 2>/dev/null; then
            LOG green "Process terminated successfully"
            ((PROCESSES_KILLED++))
        else
            LOG red "Failed to kill process"
            ((FAILED_OPERATIONS++))
        fi
    fi
done

if [ $PROCESSES_KILLED -gt 0 ]; then
    LOG green "Terminated $PROCESSES_KILLED process(es)"
else
    LOG cyan "No running processes found"
fi
LOG ""

# Step 2: Delete all task data files
LOG yellow "Step 2: Deleting task data files..."

for meta_file in "$TASK_DIR"/*.meta; do
    [ -f "$meta_file" ] || continue
    
    # Get task ID from filename
    task_id=$(basename "$meta_file" .meta)
    
    # Delete log file if it exists
    log_file="$TASK_DIR/${task_id}.log"
    if [ -f "$log_file" ]; then
        if rm -f "$log_file" 2>/dev/null; then
            LOG "Deleted log: ${task_id}.log"
        else
            LOG red "Failed to delete log: ${task_id}.log"
            ((FAILED_OPERATIONS++))
        fi
    fi
    
    # Delete meta file
    if rm -f "$meta_file" 2>/dev/null; then
        LOG "Deleted meta: ${task_id}.meta"
        ((TASKS_DELETED++))
    else
        LOG red "Failed to delete meta: ${task_id}.meta"
        ((FAILED_OPERATIONS++))
    fi
done

if [ $TASKS_DELETED -gt 0 ]; then
    LOG green "Deleted $TASKS_DELETED task data file(s)"
else
    LOG cyan "No task data files found"
fi
LOG ""

# Step 3: Remove all task management payloads
LOG yellow "Step 3: Removing task management payloads..."

for mgmt_payload in "$MGMT_DIR"/View_Task_*; do
    [ -d "$mgmt_payload" ] || continue
    
    payload_name=$(basename "$mgmt_payload")
    
    if rm -rf "$mgmt_payload" 2>/dev/null; then
        LOG "Removed: $payload_name"
        ((MGMT_PAYLOADS_REMOVED++))
    else
        LOG red "Failed to remove: $payload_name"
        ((FAILED_OPERATIONS++))
    fi
done

if [ $MGMT_PAYLOADS_REMOVED -gt 0 ]; then
    LOG green "Removed $MGMT_PAYLOADS_REMOVED management payload(s)"
else
    LOG cyan "No management payloads found"
fi
LOG ""

# Display final summary

if [ $FAILED_OPERATIONS -eq 0 ]; then
    LOG green "All tasks cleared successfully!"
else
    LOG yellow "Tasks cleared with some errors."
fi
