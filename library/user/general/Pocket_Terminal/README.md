Payload inspired from the live stream done on 12/31/2025, about 2hours and 13 min into the stream

Use the Up and Down arrow keys to scroll; press B to exit the terminal.

Updates History
---------------

Version 1.0
 - Successfully implemented user input for commands; however, output was only viewable within the "Loot" file.

Version 1.1
 - Users can now view command output in real-time as it executes.

Version 1.2
 - Attempted to add an option to toggle saving output, but encountered issues with file deletion.

Version 1.3
 - Resolved file handling issues; the temporary output file is now successfully removed upon user request.

Version 2.0
 - Implemented a persistent loop, allowing multiple commands to be executed without restarting the payload.
 - Added color-coded logging to improve readability.
 - Added code comments for easier navigation and maintenance.

Version 2.1
- Bug fix when running a command with no output it would say "green".
- Changed where commands are ran to the root directory.