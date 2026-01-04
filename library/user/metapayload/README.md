![MetaPayload Logo](logo.png)

# MetaPayload Framework

MetaPayload is a comprehensive payload framework for the Wifi Pineapple Pager that transforms how you create and manage reconnaissance tools. Define commands, variables, and dependencies in external configuration files, then generate fully-functional payloads with intelligent package management, task backgrounding, and context-aware UI integration—all without touching the core payload scripts.

## Features
- ✨ **Dynamic Payload Generation**: Create custom reconnaissance payloads by adding your own commands and variables in JSON configuration files.
- ⚙️ **Task Management**: Long-running payloads can be backgrounded, allowing users to continue using the Pager while tasks execute. Users can reattach to running tasks to monitor progress or export logs for later review.
- 📦 **Package Management**: Automatically prompts users to install required packages for individual payloads. Each payload can specify dependencies in its configuration, and the system will check and offer to install missing packages before execution.
- 🌐 **Global and Local Variable Management**: Define global variables for all payloads and payload-specific variables, with automatic prompting for missing values.  Manage global variables directly on the Pager.
- 🎨 **User-Friendly UI Integration**: Automatically selects appropriate UI pickers (IP, MAC, Text, Number) based on variable names and default values.
- 🧩 **Modular Structure**: Easily add new payloads by creating configuration files in the config/ directory.
- 🚀 **Beyond Reconnaissance**: While focused on reconnaissance, MetaPayload's flexible design allows for adaptation to other use cases.  Any command line tool chain can be integrated, with customizable payload destination (including the 'client' and 'access_point' targeted payload categories.)


## Core Payloads

- **Generate_Payloads**: Generates custom payloads based on user-defined configurations in config/.
- **List_Payloads**: Lists all available payloads defined in configuration files.
- **Remove_Payloads**: Cleans up and removes previously created reconnaissance payloads.
- **Task_Manager**: Displays all task status and provides task management operations (Stop all, Delete all, Export logs, Delete completed).

## Dynamic Payloads
The following payloads are dynamically generated based on the configurations defined in config/.
- **Set_{varname}**: Sets global variables used across payloads (only generated for variables defined in metapayload/.env).
- **View_Task_{taskid}**: Monitor or manage individual background tasks (auto-generated when tasks are created).
- **{path/category/payload_name}**: Custom payloads as defined in the configuration files.

## Directory Structure
```
metapayload/
├── README.md
├── logo.png
├── example.env               # Example global variables template
├── .env                      # Global variables (generated from example.env)
├── .tasks/                   # Task metadata and logs
├── Generate_Payloads/
│   └── payload.sh
├── List_Payloads/
│   └── payload.sh
├── Remove_Payloads/
│   └── payload.sh
├── Task_Manager/             # Work in progress
│   └── payload.sh
└── config/
    └── *.json                # Payload configuration files
```

## How It Works
1. **Configuration**: Define commands, variables, and settings in config/config.json or add custom JSON files in config/.
2. **Payload Generation**: The Generate_Payloads script reads all configuration files and generates payload scripts in their defined directory structure. Each payload includes a payload.sh with proper metadata. Generates global .env from examples.env if it doesn't exist.
3. **Execution**: Generated payloads can be executed on the Pager by selecting them from Payloads menu (exact location based on defined path). During execution, the system checks for required and optional variables, prompting the user as needed.
4. **Complex Functionality**: Use scripts in the scripts/ directory for advanced functionality that generated payloads can source or call.

## Variable Management

### Global Variables (metapayload/.env)
- User-defined list of variable keys that should be available across all payloads
- Managed via Set_{VAR_NAME} dynamic payloads
- To add a global variable, manually add it to metapayload/.env

### Payload-Specific Variables (e.g., network/ping_host/.env)
- Variables specific to individual payloads
- Can override global variables for payload-specific values
- Automatically created when user sets values during payload execution

### Variable Resolution Hierarchy
1. Load global variables from metapayload/.env
2. Load payload-specific .env (overrides globals)
3. Missing required variable? Prompt user → save to:
   - metapayload/.env if variable key exists there (global)
   - {payload}/.env if not in global list (local)
4. Missing optional variable? Ask user to customize (pre-filled with default) → save to {payload}/.env

### UI Picker Auto-Detection
The system automatically selects the appropriate UI picker based on variable naming and default values:

**For Required Variables (no default):**
- Variable name contains "IP", "HOST", or "GATEWAY" → IP_PICKER
- Variable name contains "MAC" → MAC_PICKER
- All others → TEXT_PICKER

**For Optional Variables (with default value):**
- Default matches IP pattern (e.g., "192.168.1.1") → IP_PICKER
- Default matches MAC pattern (e.g., "aa:bb:cc:dd:ee:ff") → MAC_PICKER
- Default is purely numeric (e.g., "4", "100") → NUMBER_PICKER
- All others → TEXT_PICKER

**Examples:**
- `TARGET_IP` (required) → IP_PICKER
- `GATEWAY` (required) → IP_PICKER
- `SOURCE_MAC` (required) → MAC_PICKER
- `"COUNT": "4"` (optional) → NUMBER_PICKER
- `"TARGET": "192.168.1.1"` (optional) → IP_PICKER
- `"INTERFACE": "eth0"` (optional) → TEXT_PICKER

## Payload Configuration Schema
```json
{
  "payloads": [
    {
      "name": "Ping Host",
      "path": "network/ping_host",
      "command": "ping -c $COUNT -W $TIMEOUT $TARGET_IP",
      "required_vars": ["TARGET_IP"],
      "optional_vars": {
        "COUNT": "4",
        "TIMEOUT": "10"
      },
      "required_packages": ["iputils-ping"],
      "description": "Ping a target host",
      "author": "username"
    }
  ]
}
```

### Configuration Fields
- **name**: Payload display name
- **path**: Directory structure (creates subdirectories as categories)
- **command**: Shell command to execute (use $VAR_NAME for variable substitution)
- **required_vars**: Array of variables that must be set (will prompt if missing)
- **optional_vars**: Object with variable names and default values
- **required_packages**: Array of package names needed for the payload to function
- **description**: Brief description of the payload's purpose
- **author**: Creator of the payload

## Generated Payload Execution Flow
1. Display CONFIRMATION_DIALOG with metadata (description, author, required/optional vars with current values)
2. Load metapayload/.env (global variables)
3. Load {payload}/.env if exists (local variables)
4. Check required_vars:
   - If missing: prompt with IP_PICKER, TEXT_PICKER, or MAC_PICKER
   - Prompt saving to appropriate .env based on global/local status
5. Check optional_vars:
   - If missing: ask "Set {VAR}? (default: {value})"
   - If yes: prompt with default pre-filled → save to {payload}/.env
   - If no: use default from config
6. Execute command with variable substitution
7. LOG output:
   - Success: LOG green {stdout}
   - Error: LOG red {stderr + stdout}
8. Exit with command return code

## Known Issues
- Backgrounded tasks may produce log output into other payloads' logs if multiple tasks are running simultaneously.
- Directional button responsiveness when trying to background a running task can be inconsistent; multiple presses may be required.
- Exiting the payload execution screen while a task is running will orphan the task, making it unmanageable via Task Manager. Use the BACKGROUND (LEFT button) instead of B button to exit running payloads.
- Killing running tasks via the task management payloads is a bit slow; please be patient for now. 
