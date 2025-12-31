# DuckyScript Commands Used in Tailscale Installer

This document lists all DuckyScript™ commands used in the Tailscale installer payload.

## Commands Used

### LOG
Writes messages to the payload log (visible in Pager UI).

```bash
LOG "Message text"
LOG red "Error message"
LOG green "Success message"
LOG blue "Info message"
```

**Usage in payload:**
- Installation progress updates
- Configuration steps
- Error messages
- Status information

### ALERT
Displays a popup alert message on the Pager screen.

```bash
ALERT "Message to display"
```

**Usage in payload:**
- Installation complete notifications
- Authentication success/failure
- Important status updates
- User-facing confirmations

### ERROR_DIALOG
Displays an error dialog on the Pager screen.

```bash
ERROR_DIALOG "Error message"
```

**Usage in payload:**
- Download failures
- Installation errors
- Authentication failures
- Configuration errors

### CONFIRMATION_DIALOG
Prompts user with Yes/No question.

```bash
resp=$(CONFIRMATION_DIALOG "Question?")
case $? in
    $DUCKYSCRIPT_REJECTED)
        # Dialog was rejected/cancelled
        ;;
    $DUCKYSCRIPT_ERROR)
        # An error occurred
        ;;
esac

case "$resp" in
    $DUCKYSCRIPT_USER_CONFIRMED)
        # User selected Yes
        ;;
    $DUCKYSCRIPT_USER_DENIED)
        # User selected No
        ;;
esac
```

**Usage in payload:**
- Reinstall confirmation
- Auto-start preference
- Authentication method selection
- Uninstall confirmation

### TEXT_PICKER
Prompts user to enter text input.

```bash
resp=$(TEXT_PICKER "Prompt text" "default_value")
case $? in
    $DUCKYSCRIPT_CANCELLED)
        # User cancelled
        ;;
    $DUCKYSCRIPT_REJECTED)
        # Dialog rejected
        ;;
    $DUCKYSCRIPT_ERROR)
        # An error occurred
        ;;
esac

# $resp contains the entered text
```

**Usage in payload:**
- Auth key entry
- Configuration values

### START_SPINNER / STOP_SPINNER
Shows a loading spinner with message.

```bash
spinner_id=$(START_SPINNER "Loading message")
# Do work...
STOP_SPINNER $spinner_id
```

**Usage in payload:**
- Download progress
- Installation progress
- Authentication waiting
- Network operations

### PROMPT
Displays a message and waits for button press.

```bash
PROMPT "Press any button to continue"
```

**Usage in payload:**
- Displaying authentication URL
- Pausing for user to read information

## Response Code Constants

All DuckyScript input commands use these standard response codes:

- `$DUCKYSCRIPT_CANCELLED` - User cancelled the operation
- `$DUCKYSCRIPT_REJECTED` - Dialog was rejected
- `$DUCKYSCRIPT_ERROR` - An error occurred
- `$DUCKYSCRIPT_USER_CONFIRMED` - User selected Yes (CONFIRMATION_DIALOG)
- `$DUCKYSCRIPT_USER_DENIED` - User selected No (CONFIRMATION_DIALOG)

## Best Practices

### Always Check Return Codes

```bash
resp=$(CONFIRMATION_DIALOG "Continue?")
case $? in
    $DUCKYSCRIPT_REJECTED|$DUCKYSCRIPT_ERROR)
        LOG "Operation cancelled"
        exit 1
        ;;
esac
```

### Handle All Response Cases

```bash
case "$resp" in
    $DUCKYSCRIPT_USER_CONFIRMED)
        # Handle Yes
        ;;
    $DUCKYSCRIPT_USER_DENIED)
        # Handle No
        ;;
    *)
        # Handle unexpected response
        LOG "ERROR: Unknown response: $resp"
        ;;
esac
```

### Provide User Feedback

Always use LOG and ALERT to keep users informed:

```bash
LOG "Starting operation..."
spinner_id=$(START_SPINNER "Processing")
# Do work
STOP_SPINNER $spinner_id
ALERT "Operation complete!"
LOG "Operation completed successfully"
```

### Validate Input

```bash
value=$(TEXT_PICKER "Enter value:" "")
case $? in
    $DUCKYSCRIPT_CANCELLED|$DUCKYSCRIPT_REJECTED|$DUCKYSCRIPT_ERROR)
        LOG "Input cancelled"
        exit 1
        ;;
esac

if [ -z "$value" ]; then
    ERROR_DIALOG "Value cannot be empty"
    LOG "ERROR: Empty value provided"
    exit 1
fi
```

## Command Flow in Tailscale Installer

### payload.sh
1. `LOG` - Installation start
2. `CONFIRMATION_DIALOG` - Check if reinstall needed
3. `START_SPINNER` - Download progress
4. `STOP_SPINNER` - Download complete
5. `ALERT` - Installation success

### configure.sh
1. `LOG` - Configuration start
2. `CONFIRMATION_DIALOG` - Reconfigure check
3. `CONFIRMATION_DIALOG` - Auto-start preference
4. `CONFIRMATION_DIALOG` - Auth method selection
5. `TEXT_PICKER` - Auth key entry (if selected)
6. `START_SPINNER` - Authentication progress
7. `PROMPT` - Display auth URL
8. `ALERT` - Configuration complete

### manage.sh
1. `LOG` - Management operation start
2. `CONFIRMATION_DIALOG` - Operation confirmation
3. `ALERT` - Operation result
4. `ERROR_DIALOG` - Error conditions

## Additional Resources

- Full DuckyScript documentation: See payloads/README.md
- Example payloads: payloads/library/user/examples/
- Hak5 Payload Studio: https://payloadstudio.hak5.org

