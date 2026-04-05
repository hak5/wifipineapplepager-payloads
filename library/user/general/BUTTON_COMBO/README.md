# 🔐 Button Combination Payload (Duckyscript)

An interactive **button-triggered payload system** that runs a
user-defined command only after the correct button combination is
entered.

This version adds more control, feedback, and stealth options including:

-   Background execution
-   LED toggling for A/B buttons
-   Display disable/enable for stealth mode
-   Countdown before activation

------------------------------------------------------------------------

# 📌 Features

### 🎛 Custom Button Combination

Users can choose any button sequence such as:

A UP UP DOWN

The payload waits until the exact sequence is entered.

------------------------------------------------------------------------

### 💻 Custom Command Execution

Users can enter any shell command through a `TEXT_PICKER`.\
The command runs only after the correct combination is entered.

Example default command:

ip -o -4 addr show \| awk '{print \$2,$4}' | while read i p; do
  echo "$i IP:$p MAC:$(\</sys/class/net/\$i/address)" done

This displays:

-   Network interface
-   IPv4 address
-   MAC address

------------------------------------------------------------------------

# ⚙️ Execution Flow

## 1️⃣ Startup

The payload:

-   Turns the LED cyan
-   Displays a title prompt
-   Turns LED off

------------------------------------------------------------------------

## 2️⃣ User Setup

User selects:

1.  A button combination
2.  A custom command
3.  Confirmation to start the payload

------------------------------------------------------------------------

## 3️⃣ Background Mode Selection

User chooses whether to run the combo:

-   Foreground Mode
-   Background Mode

If background mode is selected, the combo listener runs using:

run_combo &

------------------------------------------------------------------------

# ⏳ Activation Countdown

Before starting the combo detection, the script runs a **10‑second
countdown**.

This gives time to prepare the device before it enters listening mode.

------------------------------------------------------------------------

# 🕶 Stealth Mode

When combo detection starts:

-   Device display is disabled
-   A and B button LEDs are turned off

This reduces visual indicators that the device is active.

------------------------------------------------------------------------

# 🎛 LED Toggle System

The script includes a reusable function:

toggle_led()

This function:

-   Reads LED brightness state
-   Turns LED on if off
-   Turns LED off if on
-   Logs the change

Example paths used:

/sys/devices/platform/leds/leds/a-button-led/brightness
/sys/devices/platform/leds/leds/b-button-led/brightness

------------------------------------------------------------------------

# 🎮 Combination Detection

The script continuously waits for input using WAIT_FOR_INPUT.

If the button does **not match the expected input**:

-   LED turns red
-   Combo resets

If the full sequence is entered correctly:

-   LED turns green
-   Display is re-enabled
-   Button LEDs are restored

------------------------------------------------------------------------

# 🟢 Successful Execution

Once the combo is correct:

1.  Display is enabled
2.  LEDs restored
3.  Command is executed

Results are:

-   Logged to console
-   Displayed in a prompt window

------------------------------------------------------------------------

# 🚦 LED Indicators

  LED Color   Meaning
  ----------- ------------------
  
-   Cyan        Script start
-   Red         Incorrect button
-   Green       Correct combo
-   Off         Idle/reset

------------------------------------------------------------------------

# 📦 Requirements

Duckyscript features including:

-   TEXT_PICKER
-   CONFIRMATION_DIALOG
-   WAIT_FOR_INPUT
-   LED
-   LOG
-   PROMPT
-   ENABLE_DISPLAY
-   DISABLE_DISPLAY

------------------------------------------------------------------------

# 🧠 Use Cases

This payload can be used for:

-   Hidden command triggers
-   Physical unlock systems
-   Security lab experiments
-   Red team device triggers
-   Interactive payload demonstrations

------------------------------------------------------------------------

# ⚠️ Security Notice

The script executes commands using:

eval "\$user_command"

Only use in **trusted environments or controlled labs**.

------------------------------------------------------------------------

