# Wi-Fi Pineapple Pager Display Image

![Demo](demo.png)

Convert PNG images to raw RGB565 framebuffer files for display on the Hak5 Wi-Fi Pineapple Pager.

## Why This Exists

The Wi-Fi Pineapple Pager display requires images in a specific raw framebuffer format (RGB565) that standard image files can't provide directly. You can't simply copy a PNG or JPEG to the device and display it. This tool bridges that gap by converting regular PNG images into the exact binary format the pager's framebuffer expects, handling the necessary rotation, resizing, and pixel format conversion automatically.

## Quick Start

1. **Install dependencies**

   ```bash
   pip install Pillow
   ```

2. **Prepare your image**

   - Place a PNG file named `pager.png` in the script directory
   - The script will automatically rotate and resize it to fit the display

3. **Convert the image**

   ```bash
   python convert.py
   ```

4. **Transfer to device**

   ```bash
   scp image.raw root@<pineapple-ip>:/tmp/
   ```

5. **Display on device**
   ```bash
   ssh root@<pineapple-ip>
   cat /tmp/image.raw > /dev/fb0
   ```

## How It Works

The script converts your image through these steps:

1. Opens `pager.png`
2. Rotates 90° clockwise to match pager orientation
3. Resizes to 222×480 pixels
4. Converts pixels to RGB565 format (5-6-5 bits, little-endian)
5. Outputs `image.raw` ready for the framebuffer

## Display Specifications

- **Resolution**: 222×480 pixels
- **Format**: RGB565, little-endian
- **Orientation**: Rotated 90° right from source image

## Customization

Edit `convert.py` to change:

- **Input file**: Replace `'pager.png'` with your filename
- **Resolution**: Update `img.resize((222, 480))` for different displays
- **Pixel format**: Modify the RGB565 packing logic and `struct.pack('<H', ...)` call

## Files

- `convert.py` – Conversion script
- `demo.png` – Example input image
- `README.md` – This file

## Disclaimer

This is example code for the Wi-Fi Pineapple Pager framebuffer. Verify the correct framebuffer device and format for your specific hardware before use.
