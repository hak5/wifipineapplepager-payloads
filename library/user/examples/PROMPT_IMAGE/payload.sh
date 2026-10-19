#!/bin/bash
# Title: PROMPT_IMAGE
# Author: RootJunky
# Description: Displays the rootjunky.png image
# Version: 1.0

IMAGE_PATH="${_PAYLOAD_HOME}/rootjunky.png"

if [ ! -f "$IMAGE_PATH" ]; then
    LOG "Image not found: $IMAGE_PATH"
    exit 1
fi

LOG "Displaying image: $IMAGE_PATH"
PROMPT_IMAGE "$IMAGE_PATH"
LOG "Prompt Image Completed"
