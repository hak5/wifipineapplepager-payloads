# ⏰ Pager Alarm Clock

A simple alarm clock for the **Hak5 WiFi Pineapple Pager**. Set an alarm, choose and preview your favorite RTTTL ringtone, and let your Pager wake you up!

---

## ✨ Features

- ⏰ Set an alarm using a date and time.
- 📅 Supports `YYYY-MM-DD HH:MM AM/PM` format.
- 🔔 Select your favorite ringtone from the ringtone menu.
- 🎵 Preview RTTTL ringtones before selecting one.
- 🎶 Automatically creates a default ringtone if one doesn't exist.
- 🔁 Plays the selected ringtone continuously when the alarm activates.
- 🛑 Press any button to stop the alarm.
- ⚡ Runs the alarm monitoring process in the background.
- 📂 Supports custom RTTTL ringtone files.

## 📋 Requirements

- Hak5 WiFi Pineapple Pager
- RTTTL ringtone support
- Pager payload environment
- Writable `/mmc/root/ringtones` directory

## 🚀 Usage

### 1. Start Pager Alarm Clock

Launch the payload from your WiFi Pineapple Pager.

### 2. Select a ringtone

The ringtone selection menu displays all available `.rtttl` files.

- Select a ringtone to preview it.
- Listen to the ringtone.
- Confirm if you want to use it as your alarm.
- Choose another ringtone if you want to preview a different one.

### 3. Set your alarm

Enter your desired alarm date and time.

Example:

```text
2026-11-18 07:30 AM
```

Supported format:

```text
YYYY-MM-DD HH:MM AM/PM
```

### 4. Wait for your alarm

Once configured, the Pager monitors the time in the background.

When the alarm time is reached:
- The selected ringtone starts playing continuously.
- The Pager displays the current time.
- The alarm continues until stopped.

### 5. Stop the alarm

Press **any button** on your Pager to stop the ringtone and exit the alarm process.

## 🎵 Custom Ringtones

Ringtone files are stored in:

```text
/mmc/root/ringtones/
```

The payload automatically creates this directory if it doesn't exist.

You can add your own RTTTL ringtone files to this directory.

Example:

```text
/mmc/root/ringtones/
├── Alert1.rtttl
├── Alarm.rtttl
├── Classic.rtttl
└── Custom.rtttl
```

### Default Ringtone

If `Alert1.rtttl` does not exist, the payload automatically creates it.

```text
Alert1:d=4,o=5,b=285:8d5,8e5,8f5,8e5,8d5
```

All `.rtttl` files found in the ringtone directory are automatically added to the selection menu.

---

**Enjoy your Pager Alarm Clock!** ⏰
