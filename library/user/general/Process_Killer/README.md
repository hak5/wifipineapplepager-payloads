# Process_Killer 

---

## Description

`Process_Killer` is a Bash script designed to monitor and manage system processes. It lists the top CPU-consuming processes and allows you to safely terminate unwanted processes by specifying their PID (Process ID).  

This script is particularly useful for developers, system administrators, or anyone who needs a quick way to identify and stop resource-hogging processes on pager.

---

## Features

- Displays top CPU-consuming processes with their PID, CPU usage, RAM usage, and name.  
- Skips kernel threads automatically.  
- Provides a simple interface to select and confirm the PID to kill.  
- Retries killing a process up to 5 times if it does not terminate immediately.  
- Provides user feedback on success or failure of process termination.

---

## Usage

1. Follow on-screen instructions:

* Wait for the script to list the top processes.
* Note the PID of the process you want to terminate.
* Press **Button A** to continue.
* Enter the PID using the number picker.
* Confirm the action in the confirmation dialog.
* The script will attempt to kill the process and retry if necessary.

---

## Example Output

```
----- Top CPU Processes -----
[PID]   [CPU]   [RAM]   [NAME]
1234    15%     120MB   firefox
5678    12%     50MB    chrome
4321    10%     30MB    gnome-terminal
```

After selecting a PID and confirming, the script will attempt to terminate the process and display success or failure messages.

---

## Notes

* Compatible Payload/DuckyScript environment
* The script is designed for pager that expose process information in `/proc`.
* Kernel threads (e.g., `kworker*`) are automatically skipped to prevent accidental system instability.
* Killing critical system processes may destabilize your system. Use with caution.

---

## License

This script is provided as-is under the MIT License. Use responsibly.

---

## Author

**spywill** – Creator of `Process_Killer`

---
