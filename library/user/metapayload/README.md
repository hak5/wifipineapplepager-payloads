![MetaPayload Logo](logo.png)

# The Swiss Army Knife of Payloads for the Wifi Pineapple Pager! 🍍

👉**Includes more than 20 payloads out of the box!** See the [Included Payload Packs](#included-payload-packs-📦) section below for details.

Run payloads, keep track of results, export logs to Discord and more - all from the Pager interface!

## Video Review

[![Watch the video](https://i.ytimg.com/an_webp/45Wbnfh4HXc/mqdefault_6s.webp?du=3000&sqp=CJPBissG&rs=AOn4CLDxPLvPQ4tKHUSEZS-_4ZE2TRZ38g)](https://www.youtube.com/live/45Wbnfh4HXc?si=1Txkxtf60HLsgV7v&t=10148)

Watch Hak5's Darren Kitchen review MetaPayload and demonstrate its features on the Wifi Pineapple Pager: https://www.youtube.com/live/45Wbnfh4HXc?si=1Txkxtf60HLsgV7v&t=10148


## Get Started Easily 🚀
1. Install the metapayload directory as /root/payloads/user/metapayload
2. On the pager, Payloads > metapayload > Generate Payloads
3. Find generated payloads under Payloads > metapayload_recon

## Included Payload Packs

### 🔭 MetaPayload Recon 
metapayload_recon.json includes a variety of reconnaissance-focused payloads powered by nmap and arp-scan.  These payloads provide everything from quick network discovery to comprehensive port scanning and service detection.

- **Quick Hosts Scan**: [TARGET_SUBNET]
- **ARP Network Scan**: [TARGET_SUBNET]
- **Top Ports Scan**: [TARGET_IP]
- **Full Port Scan**: [TARGET_IP]
- **UDP Port Scan**: [TARGET_IP]
- **Network Port Sweep**: [TARGET_SUBNET]
- **Network Web Sweep**: [TARGET_SUBNET]
- **Service Version Detection**: [TARGET_IP]
- **OS Detection**: [TARGET_IP]

###  🛠 MetaPayload Sys Utils
metapayload_sysutils.json includes a set of essential system utility payloads for gathering system information, monitoring processes, managing files, etc

- **System Information**
- **Disk Usage (df)**
- **Process List (ps)**
- **Top Processes (top)**
- **Process Grep (pgrep)**
- **Network Connections (netstat)**
- **Find Files by Name (find)**
- **Find File Content (grep -r)**
- **Install Package (opkg)**


#
#  🍍MetaPayload Framework For Advanced Users:

MetaPayload is a comprehensive payload framework for the Wifi Pineapple Pager that provides many powerfull features for creating, managing, and executing dynamic payloads.  It is designed to simplify the process of building complex command line tool chains into easy-to-use payloads that can be executed directly from the Pager interface.

Want to create fully functional payloads from command line tools?  MetaPayload makes it easy.

Do you have a long running payload that you'd like to background so you can continue using the Pager?  MetaPayload has you covered.

Need to track and manage multiple payload logs as part of your engagement workflow?  MetaPayload provides built-in task management features - so you can easily monitor, view, and export logs.

Already included are many powerful payload definitions, making MetaPayload a versatile reconnaissance toolkit out of the box.  You can also easily extend its capabilities by adding your own payload configurations in JSON format.  See below for details on included payload packs.

## Features
- ✨ **Dynamic Payload Generation**: Create custom reconnaissance payloads by adding your own commands and variables in JSON configuration files.
- ⚙️ **Task Management**: Long-running payloads can be backgrounded, allowing users to continue using the Pager while tasks execute. Users can reattach to running tasks to monitor progress or export logs for later review.
- 📦 **Package Management**: Automatically prompts users to install required packages for individual payloads. Each payload can specify dependencies in its configuration, and the system will check and offer to install missing packages before execution.
- 🌐 **Global and Local Variable Management**: Define global variables for all payloads and payload-specific variables, with automatic prompting for missing values.  Manage global variables directly on the Pager.
- 🎨 **User-Friendly UI Integration**: Automatically selects appropriate UI pickers (IP, MAC, Text, Number) based on variable names and default values.
- 🗒️ **Log Management**: Payloads run as 'tasks' and produce log output that you choose to export to loot or Discord webhook, during task execution or afterwards.  The task stays visible until you choose to delete it.
- 🧩 **Modular Structure**: Easily add new payloads by creating configuration files in the config/ directory.
- 🚀 **Beyond Reconnaissance**: While focused on reconnaissance, MetaPayload's flexible design allows for adaptation to other use cases.  Any command line tool chain can be integrated, with customizable payload destination (including the 'client' and 'access_point' targeted payload categories.)



## 🔨Core Payloads 

- **Generate_Payloads**: Generates custom payloads based on user-defined configurations in config/.
- **List_Payloads**: Lists all available payloads defined in configuration files.
- **Remove_Payloads**: Cleans up and removes previously created reconnaissance payloads.
- **Tasks_CLEAR_ALL**: Stop any running backgrounded tasks and clear all task logs and metadata.

## 🪄Dynamic Payloads
The following payloads are dynamically generated based on the configurations defined in config/.
- **Set_{varname}**: Sets global variables used across payloads (only generated for variables defined in metapayload/.env).
- **View_Task_{taskid}**: Monitor or manage individual background tasks (auto-generated when tasks are created).
- **{path/category/payload_name}**: Custom payloads as defined in the configuration files.

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
7. LOG output while task is running in foreground
8. IF user presses LEFT: background the task; create management payload View_Task_{taskid}; exit the running payload
8. Exit with command return code

## Future Enhancements
- Existing payload wrapper - to allow other payloads to be run within the metapayload framework
- YAML configuration support
- Refactoring for maintainability

## Known Issues (planned to fix)
- Backgrounded tasks may produce log output into other payloads' UI logs if multiple tasks are running simultaneously. 
- Directional button responsiveness when trying to background a running task can be inconsistent; multiple presses may be required.
- Killing running tasks via the task management payloads is a bit slow; please be patient for now. 
