# pagerctl

Hardware control library for the WiFi Pineapple Pager. Provides smooth, flicker-free graphics and complete hardware access through a shared library.

## Features

- **Display** - Double-buffered framebuffer rendering (480x222 RGB565)
- **Text** - Built-in bitmap font with multiple sizes
- **TTF Fonts** - TrueType font rendering via stb_truetype
- **Images** - Load and draw JPG, PNG, BMP, GIF images via stb_image
- **Input** - Button handling (D-pad, A, B, Power) with thread-safe event queue
- **LEDs** - RGB D-pad LEDs and A/B button LEDs
- **Audio** - Buzzer control with RTTTL ringtone support
- **Vibration** - Haptic feedback
- **Brightness** - Screen backlight control via sysfs

## Building

The Pager uses a MIPS processor, so C code must be cross-compiled. Docker handles this automatically on Linux, Mac, and Windows.

**Note:** Hak5 does not accept pull requests with binaries included. You must compile the binaries yourself using the included source code, or download precompiled binaries from: https://github.com/pineapple-pager-projects/pineapple_pager_pagerctl

### Requirements

- Docker installed on your machine

### Build and Deploy

```bash
# Pull the OpenWrt SDK image (first time only)
docker pull openwrt/sdk:mipsel_24kc-22.03.5

# Build the library and demo
make

# Copy to your Pager (from this directory)
scp -r . root@172.16.52.1:/mmc/root/payloads/user/utilities/PAGERCTL
```

### Running

On the Pager, navigate to: **Payloads > Utilities > PAGERCTL Demo**

Or run directly via SSH:
```bash
ssh root@172.16.52.1
cd /mmc/root/payloads/user/utilities/PAGERCTL
/etc/init.d/pineapplepager stop
python3 examples/demo.py   # Python demo
/etc/init.d/pineapplepager start
```

## Usage

### Python

```python
from pagerctl import Pager

with Pager() as p:
    p.set_rotation(270)  # Landscape mode
    p.clear(p.rgb(0, 0, 32))
    p.draw_text_centered(100, "Hello Pager!", p.WHITE, 2)
    p.flip()
    p.wait_button()
```

### C

```c
#include "pagerctl.h"

int main() {
    pager_init();
    pager_set_rotation(270);
    pager_clear(RGB565(0, 0, 32));
    pager_draw_text_centered(100, "Hello Pager!", COLOR_WHITE, 2);
    pager_flip();
    pager_wait_button();
    pager_cleanup();
    return 0;
}
```

## API Reference

### Display

| Function | Description |
|----------|-------------|
| `pager_init()` | Initialize display and input |
| `pager_cleanup()` | Clean up resources |
| `pager_set_rotation(deg)` | Set rotation (0, 90, 180, 270) |
| `pager_clear(color)` | Clear screen with color |
| `pager_flip()` | Swap buffers (show drawn content) |
| `pager_get_width()` | Get screen width |
| `pager_get_height()` | Get screen height |

### Timing

| Function | Description |
|----------|-------------|
| `pager_get_ticks()` | Get milliseconds since init |
| `pager_delay(ms)` | Sleep for milliseconds |
| `pager_frame_sync()` | Sync to ~30 FPS, returns frame time |

### Drawing

| Function | Description |
|----------|-------------|
| `pager_set_pixel(x, y, color)` | Draw single pixel |
| `pager_fill_rect(x, y, w, h, color)` | Draw filled rectangle |
| `pager_draw_rect(x, y, w, h, color)` | Draw rectangle outline |
| `pager_draw_line(x0, y0, x1, y1, color)` | Draw line |
| `pager_hline(x, y, w, color)` | Draw horizontal line |
| `pager_vline(x, y, h, color)` | Draw vertical line |
| `pager_fill_circle(cx, cy, r, color)` | Draw filled circle |
| `pager_draw_circle(cx, cy, r, color)` | Draw circle outline |

### Text (Bitmap Font)

| Function | Description |
|----------|-------------|
| `pager_draw_text(x, y, text, color, scale)` | Draw text at position |
| `pager_draw_text_centered(y, text, color, scale)` | Draw horizontally centered text |
| `pager_text_width(text, scale)` | Get text width in pixels |
| `pager_draw_number(x, y, num, color, scale)` | Draw integer number |

### Text (TTF Fonts)

| Function | Description |
|----------|-------------|
| `pager_draw_ttf(x, y, text, color, font, size)` | Draw TTF text |
| `pager_draw_ttf_centered(y, text, color, font, size)` | Draw centered TTF text |
| `pager_draw_ttf_right(y, text, color, font, size, padding)` | Draw right-aligned TTF text |
| `pager_ttf_width(text, font, size)` | Get TTF text width |
| `pager_ttf_height(font, size)` | Get TTF font height |

### Images

| Function | Description |
|----------|-------------|
| `pager_load_image(filepath)` | Load image file, returns handle (caller must free) |
| `pager_free_image(handle)` | Free a loaded image |
| `pager_draw_image(x, y, handle)` | Draw loaded image at position |
| `pager_draw_image_scaled(x, y, w, h, handle)` | Draw loaded image scaled to w×h |
| `pager_draw_image_file(x, y, filepath)` | Load and draw in one call |
| `pager_draw_image_file_scaled(x, y, w, h, filepath)` | Load and draw scaled in one call |
| `pager_get_image_info(filepath, &w, &h)` | Get image dimensions without loading |

Supported formats: JPEG, PNG, BMP, GIF (first frame only)

**Python example:**
```python
# One-shot draw (loads, draws, frees)
p.draw_image_file_scaled(0, 0, 200, 100, "/path/to/image.jpg")

# For repeated drawing, load once
img = p.load_image("/path/to/image.png")
p.draw_image(10, 10, img)
p.draw_image_scaled(100, 10, 50, 50, img)
p.free_image(img)

# Get dimensions without loading
w, h = p.get_image_info("/path/to/image.jpg")
```

### Input

| Function | Description |
|----------|-------------|
| `pager_wait_button()` | Wait for button press (blocking) |
| `pager_poll_input(input)` | Poll input state (non-blocking) |
| `pager_get_input_event(event)` | Get next event from thread-safe queue |
| `pager_has_input_events()` | Check if events are pending in queue |
| `pager_peek_buttons()` | Get current button state without consuming events |
| `pager_clear_input_events()` | Clear all pending events from queue |

Button constants: `BTN_UP`, `BTN_DOWN`, `BTN_LEFT`, `BTN_RIGHT`, `BTN_A`, `BTN_B`, `BTN_POWER`

Event types: `EVENT_NONE` (0), `EVENT_PRESS` (1), `EVENT_RELEASE` (2)

**Python example - Single-threaded (games):**
```python
# Blocking wait
button = p.wait_button()
if button & Pager.BTN_A:
    print("A pressed")

# Non-blocking poll (for game loops)
current, pressed, released = p.poll_input()
if pressed & Pager.BTN_A:      # Just pressed this frame
    p.beep(800, 50)
if current & Pager.BTN_UP:      # Currently held down
    player_y -= 1
if released & Pager.BTN_B:      # Just released
    print("B released")
```

**Python example - Multi-threaded (background button monitoring):**
```python
# Thread-safe event queue for apps with multiple threads
# Each event is only consumed once, preventing race conditions

def button_thread(pager):
    while running:
        pager.poll_input()  # Read hardware, populate queue
        event = pager.get_input_event()
        if event:
            button, event_type, timestamp = event
            if button == Pager.BTN_B and event_type == Pager.EVENT_PRESS:
                show_menu()

# Check button state without consuming events
if pager.peek_buttons() & Pager.BTN_A:
    print("A is currently held")

# Clear queue when transitioning between screens
pager.clear_input_events()
```

### LEDs

| Function | Description |
|----------|-------------|
| `pager_led_dpad(dir, color)` | Set D-pad LED color (dir: "up", "down", "left", "right") |
| `pager_led_set(name, brightness)` | Set LED brightness (name: "a-button-led", "b-button-led") |
| `pager_led_all_off()` | Turn off all LEDs |

Note: A/B button LED sysfs names are swapped - "b-button-led" controls green/A, "a-button-led" controls red/B.

### Audio

| Function | Description |
|----------|-------------|
| `pager_beep(freq, duration_ms)` | Play tone |
| `pager_play_rtttl(melody)` | Play RTTTL in background (sound only) |
| `pager_play_rtttl_ex(melody, mode)` | Play RTTTL with mode (see below) |
| `pager_play_rtttl_sync(melody, vibrate)` | Play RTTTL blocking (0=sound, 1=sound+vibrate) |
| `pager_stop_audio()` | Stop audio/vibration playback |
| `pager_audio_playing()` | Check if audio is still playing (returns 1/0) |

**RTTTL Playback Modes** (for `pager_play_rtttl_ex`):
- `RTTTL_SOUND_ONLY` (0) - Sound only (default)
- `RTTTL_SOUND_VIBRATE` (1) - Sound + vibration synced to notes
- `RTTTL_VIBRATE_ONLY` (2) - Silent vibration pattern (no sound)

### Vibration

| Function | Description |
|----------|-------------|
| `pager_vibrate(duration_ms)` | Vibrate for duration |
| `pager_vibrate_pattern(pattern)` | Play pattern "on,off,on,off,..." |

### Brightness / Screen Power

| Function | Description |
|----------|-------------|
| `pager_set_brightness(percent)` | Set screen brightness (0-100%), returns 0 on success |
| `pager_get_brightness()` | Get current brightness as percentage (0-100) |
| `pager_get_max_brightness()` | Get hardware max brightness value |
| `pager_screen_off()` | Turn screen off (brightness 0%) |
| `pager_screen_on()` | Turn screen on (brightness 80%) |

**Note:** On Pager hardware, setting brightness below ~10% turns off the backlight completely.

**Python example:**
```python
# Set brightness to 50%
p.set_brightness(50)

# Get current brightness
current = p.get_brightness()
print(f"Brightness: {current}%")

# Turn screen off/on
p.screen_off()
p.delay(2000)
p.screen_on()

# Dim the screen gradually
for level in range(100, 20, -10):
    p.set_brightness(level)
    p.delay(100)
```

Note: Returns -1 if backlight control is not available on the device.

### Utilities

| Function | Description |
|----------|-------------|
| `pager_random(max)` | Get random integer from 0 to max-1 |
| `pager_seed_random(seed)` | Seed the random number generator |

## Colors

Predefined colors (RGB565):
- `COLOR_BLACK`, `COLOR_WHITE`
- `COLOR_RED`, `COLOR_GREEN`, `COLOR_BLUE`
- `COLOR_YELLOW`, `COLOR_CYAN`, `COLOR_MAGENTA`
- `COLOR_ORANGE`, `COLOR_GRAY`, `COLOR_DARK_GRAY`

Create custom colors: `RGB565(r, g, b)`

## File Structure

```
PAGERCTL/
├── src/
│   ├── pagerctl.c          # Main library source
│   ├── pagerctl.h          # Header file
│   ├── stb_truetype.h      # TTF rendering (stb library)
│   ├── stb_image.h         # Image loading (stb library)
│   └── demo.c              # C demo source
├── pagerctl.py             # Python wrapper
├── payload.sh              # Pager payload entry point
├── examples/
│   └── demo.py             # Python demo
├── fonts/                  # TTF fonts (Roboto, PressStart2P)
├── images/                 # Test images
└── Makefile                # Build targets
```

## Creating Your Own Payload

### Using pagerctl in Your Project

Copy both files to your project (keep them together in the same directory):
- `pagerctl.py` - Python wrapper
- `libpagerctl.so` - Compiled library

These files are portable - `pagerctl.py` automatically finds `libpagerctl.so` in the same directory.

```python
# In your script, import from where you placed the files
import sys
sys.path.insert(0, "/path/to/your/lib")
from pagerctl import Pager

with Pager() as p:
    p.set_rotation(270)
    p.draw_text(10, 10, "My App!", p.WHITE, 2)
    p.flip()
```

### As a Pager Payload

1. Copy `payload.sh` and `examples/demo.py` to your payload directory
2. Copy `pagerctl.py` and `libpagerctl.so` to your payload's lib folder
3. Update paths in `payload.sh` to point to your payload location
4. Deploy and run via Payloads menu

## Requirements

- WiFi Pineapple Pager
- Python3 + python3-ctypes (auto-installed by payload)

## License

MIT License

## Author

**brAinphreAk**

www.brainphreak.net

https://ko-fi.com/brainphreak
