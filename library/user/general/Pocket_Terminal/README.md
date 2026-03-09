Payload inspired from the live stream done on 12/31/2025, about 2hours and 13 min into the stream

The payload will have a use input 3 times per command that is sent
1.
 - User inputs the command they want ran.
2.
 - Asking to save the output if the user want to review for a later time.
3.
 - Asking if the user want to run another command if not ending the payload.

Use the Up and Down arrow keys to scroll.

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

Version 2.2
 - Expanded the README.md file.
 - Changed from using a number selector to use "CONFIRMATION_DIALOG" for a better experience.