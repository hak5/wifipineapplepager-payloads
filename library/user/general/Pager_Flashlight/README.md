# Pager Flashlight

A full-screen flashlight payload for the **Hak5 WiFi Pineapple Pager**. Choose from multiple solid-color screens to use the Pager as a simple flashlight or colored light.

## Features

- **Flashlight** — Full-screen white light.
- **Red** — Full-screen red light.
- **Blue** — Full-screen blue light.
- **Orange** — Full-screen orange light.
- **Green** — Full-screen green light.
- **Yellow** — Full-screen yellow light.
- **Black** — Full-screen black screen.
- **Exit** — Return from the payload.


## Requirements

- Hak5 WiFi Pineapple Pager
- PNG images for each color
- Pager payload environment supporting `LIST_PICKER`, `PROMPT`, and `PROMPT_IMAGE`

## Installation

1. Download or clone this repository.
2. Copy the payload script and all required PNG files into the same payload directory.
3. Ensure the image filenames match the names expected by the script.

Required files:

```text
Flashlight/
├── payload.sh
├── white.png
├── red.png
├── blue.png
├── orange.png
├── green.png
├── yellow.png
└── black.png
```

The payload uses `${_PAYLOAD_HOME}` to locate the PNG files automatically.

## Usage

1. Run the Flashlight payload on your WiFi Pineapple Pager.
2. Read the introductory prompt.
3. Select a color from the menu.
4. The selected image opens in full-screen mode.
5. Dismiss the image using the Pager controls to return to the menu.
6. Select another color or choose **Exit** to leave the payload.

**Note:** The payload uses `PROMPT_IMAGE`, which waits for the user to dismiss the image before the script continues.

## Configuration

The color images are loaded using these variables:

```bash
WHITE="${_PAYLOAD_HOME}/white.png"
ORANGE="${_PAYLOAD_HOME}/orange.png"
RED="${_PAYLOAD_HOME}/red.png"
BLUE="${_PAYLOAD_HOME}/blue.png"
GREEN="${_PAYLOAD_HOME}/green.png"
YELLOW="${_PAYLOAD_HOME}/yellow.png"
BLACK="${_PAYLOAD_HOME}/black.png"
```

To customize the appearance, replace the PNG files with your own images while keeping the filenames unchanged.

## Troubleshooting

- **Image does not appear:** Verify that the PNG exists in the payload directory.
- **Image fails to load:** Check that the file is a valid PNG and is accessible to the Pager.
- **Missing color option:** Confirm that the corresponding image file exists and that the payload script references it correctly.
- **Cannot return to the menu:** Dismiss the full-screen image using the Pager controls.


## Disclaimer

This payload is intended for personal lighting and color-screen use on the Hak5 WiFi Pineapple Pager. The brightness and usability of each color depend on the display and the image files used.

