#!/usr/bin/env python3
"""
demo.py - Full Demo for pagerctl

Demonstrates all hardware features:
- Display with double-buffering
- Button input (including POWER button)
- LED control
- Audio (buzzer) and vibration
- Brightness control

Run with: python3 demo.py
"""

import os
import sys
import time

# Add parent directory to path for pagerctl import
sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from pagerctl import Pager

# Font paths for TTF demo
FONT_DIR = "/root/payloads/user/utilities/PAGERCTL/fonts"
ROBOTO = f"{FONT_DIR}/Roboto-Regular.ttf"
ROBOTO_BOLD = f"{FONT_DIR}/Roboto-Bold.ttf"
PRESS_START = f"{FONT_DIR}/PressStart2P.ttf"


def wait_for_green(p, message="Press GREEN to continue..."):
    """Wait for the green (A) button to be pressed."""
    p.draw_text_centered(200, message, p.GREEN, 1)
    p.flip()
    while True:
        button = p.wait_button()
        if button & Pager.BTN_A:
            break


def skippable_delay(p, ms):
    """Delay that can be skipped with GREEN button. Returns True if skipped."""
    start = time.time()
    while (time.time() - start) * 1000 < ms:
        current, pressed, _ = p.poll_input()
        if pressed & Pager.BTN_A:
            return True
        time.sleep(0.05)
    return False


def main():
    with Pager() as p:
        p.set_rotation(270)  # Landscape mode

        print("=== pagerctl Full Demo ===")

        # ------------------------------------
        # 1. Display basics
        # ------------------------------------
        print("[1/8] Display basics...")

        p.clear(p.rgb(0, 0, 51))
        p.draw_text_centered(20, "PAGERCTL DEMO", p.YELLOW, 2)
        p.draw_text(10, 60, "Left aligned", p.RED, 1)
        p.draw_text_centered(80, "Centered text", p.GREEN, 1)
        # Right-align: 6 pixels per char at scale 1, plus padding
        right_text = "Right aligned"
        right_x = p.width - (len(right_text) * 6) - 10
        p.draw_text(right_x, 100, right_text, p.BLUE, 1)

        # Draw a filled rectangle with text
        p.fill_rect(150, 130, 180, 40, p.ORANGE)
        p.draw_text(170, 145, "Graphics!", p.BLACK, 1)

        wait_for_green(p)

        # ------------------------------------
        # 2. Screen properties and colors
        # ------------------------------------
        print("[2/8] Screen properties...")

        p.clear(p.BLACK)
        p.draw_text_centered(30, f"Screen: {p.width}x{p.height}", p.WHITE, 1)

        # Draw color bars (blue moved to position 2 to test optical illusion)
        bar_width = p.width // 6
        colors = [p.RED, p.BLUE, p.YELLOW, p.GREEN, p.ORANGE, p.MAGENTA]
        for i, color in enumerate(colors):
            p.fill_rect(i * bar_width, 60, bar_width, 60, color)

        p.draw_text_centered(140, "Rainbow!", p.WHITE, 2)

        wait_for_green(p)

        # ------------------------------------
        # 3. LED control
        # ------------------------------------
        print("[3/8] LED control...")

        run_led_test = True
        while run_led_test:
            p.clear(p.rgb(0, 17, 0))
            p.draw_text_centered(30, "LED Demo", p.WHITE, 2)
            p.draw_text_centered(70, "Watch D-pad + A/B buttons!", p.GRAY, 1)
            p.draw_text(100, 200, "GREEN=skip/continue", p.GREEN, 1)
            p.draw_text(300, 200, "RED=repeat", p.RED, 1)
            p.flip()

            skipped = False

            # Cycle through colors on D-pad LEDs
            led_colors = [0xFF0000, 0x00FF00, 0x0000FF, 0xFFFF00, 0xFF00FF, 0x00FFFF]
            dpad_leds = ["up", "right", "down", "left"]

            for color in led_colors:
                if skipped:
                    break
                for led in dpad_leds:
                    p.led_dpad(led, color)
                if skippable_delay(p, 800):
                    skipped = True
                    break

            if not skipped:
                p.led_all_off()
                if skippable_delay(p, 300):
                    skipped = True

            # Test A button LED (Green button - right side)
            if not skipped:
                p.fill_rect(0, 60, p.width, 30, p.rgb(0, 17, 0))
                p.draw_text_centered(70, "A button LED (Green)", p.GREEN, 1)
                p.flip()
                for _ in range(3):
                    if skipped:
                        break
                    p.led_set("b-button-led", 255)
                    if skippable_delay(p, 500):
                        skipped = True
                        break
                    p.led_set("b-button-led", 0)
                    if skippable_delay(p, 300):
                        skipped = True
                        break

            # Test B button LED (Red button - left side)
            if not skipped:
                p.fill_rect(0, 60, p.width, 30, p.rgb(0, 17, 0))
                p.draw_text_centered(70, "B button LED (Red)", p.RED, 1)
                p.flip()
                for _ in range(3):
                    if skipped:
                        break
                    p.led_set("a-button-led", 255)
                    if skippable_delay(p, 500):
                        skipped = True
                        break
                    p.led_set("a-button-led", 0)
                    if skippable_delay(p, 300):
                        skipped = True
                        break

            p.led_all_off()

            if skipped:
                run_led_test = False
            else:
                # Wait for user choice
                p.fill_rect(0, 60, p.width, 30, p.rgb(0, 17, 0))
                p.draw_text_centered(70, "LED test complete!", p.WHITE, 1)
                p.flip()

                while True:
                    button = p.wait_button()
                    if button & Pager.BTN_A:
                        run_led_test = False
                        break
                    elif button & Pager.BTN_B:
                        break

        # ------------------------------------
        # 4. Audio and vibration
        # ------------------------------------
        print("[4/8] Audio and vibration...")

        p.clear(p.rgb(34, 0, 17))
        p.draw_text_centered(30, "Audio Demo", p.WHITE, 2)
        p.draw_text_centered(80, "Playing scale...", p.GRAY, 1)
        p.draw_text_centered(200, "GREEN=skip", p.GREEN, 1)
        p.flip()

        skipped = False
        notes = [262, 294, 330, 349, 392, 440, 494, 523]  # C4 to C5
        for freq in notes:
            if skipped:
                break
            p.beep(freq, 150)
            if skippable_delay(p, 50):
                skipped = True
                break

        if not skipped:
            skipped = skippable_delay(p, 300)

        # Vibration
        if not skipped:
            p.fill_rect(0, 70, p.width, 30, p.rgb(34, 0, 17))
            p.draw_text_centered(80, "Vibrating...", p.GRAY, 1)
            p.flip()

            p.vibrate(100)
            if not skippable_delay(p, 100):
                p.vibrate(100)
                if not skippable_delay(p, 100):
                    p.vibrate(200)
                    skippable_delay(p, 300)

        if not skipped:
            # RTTTL modes demo
            melody = "Demo:d=4,o=5,b=140:8c,8e,8g,c6"

            # Mode 1: Sound only
            p.fill_rect(0, 70, p.width, 30, p.rgb(34, 0, 17))
            p.draw_text_centered(80, "RTTTL: Sound only", p.GRAY, 1)
            p.flip()
            p.play_rtttl(melody, mode=Pager.RTTTL_SOUND_ONLY)
            while p.audio_playing() and not skipped:
                if skippable_delay(p, 100):
                    skipped = True
            if not skipped and not skippable_delay(p, 300):
                # Mode 2: Sound + Vibration
                p.fill_rect(0, 70, p.width, 30, p.rgb(34, 0, 17))
                p.draw_text_centered(80, "RTTTL: Sound + Vibrate", p.CYAN, 1)
                p.flip()
                p.play_rtttl(melody, mode=Pager.RTTTL_SOUND_VIBRATE)
                while p.audio_playing() and not skipped:
                    if skippable_delay(p, 100):
                        skipped = True
                if not skipped and not skippable_delay(p, 300):
                    # Mode 3: Vibration only (silent)
                    p.fill_rect(0, 70, p.width, 30, p.rgb(34, 0, 17))
                    p.draw_text_centered(80, "RTTTL: Vibrate only (silent)", p.YELLOW, 1)
                    p.flip()
                    p.play_rtttl(melody, mode=Pager.RTTTL_VIBRATE_ONLY)
                    while p.audio_playing() and not skipped:
                        if skippable_delay(p, 100):
                            skipped = True

        # Always stop audio/vibration when leaving this section
        p.stop_audio()

        p.fill_rect(0, 70, p.width, 150, p.rgb(34, 0, 17))
        p.draw_text_centered(80, "Audio test complete!", p.WHITE, 1)
        wait_for_green(p)

        # ------------------------------------
        # 5. Brightness control
        # ------------------------------------
        print("[5/8] Brightness control...")

        p.clear(p.rgb(0, 0, 51))
        p.draw_text_centered(30, "Brightness Demo", p.WHITE, 2)
        p.draw_text_centered(200, "GREEN=skip", p.GREEN, 1)
        p.flip()

        skipped = False

        # Get current brightness to restore later
        original_brightness = p.get_brightness()

        # Dim down
        p.fill_rect(0, 70, p.width, 50, p.rgb(0, 0, 51))
        p.draw_text_centered(80, "Dimming down...", p.GRAY, 1)
        p.flip()

        for level in range(100, 19, -10):
            if skipped:
                break
            p.set_brightness(level)
            p.fill_rect(0, 110, p.width, 30, p.rgb(0, 0, 51))
            p.draw_text_centered(120, f"Brightness: {level}%", p.YELLOW, 1)
            p.flip()
            if skippable_delay(p, 300):
                skipped = True

        if not skipped:
            # Brighten up
            p.fill_rect(0, 70, p.width, 50, p.rgb(0, 0, 51))
            p.draw_text_centered(80, "Brightening up...", p.GRAY, 1)
            p.flip()

            for level in range(20, 101, 10):
                if skipped:
                    break
                p.set_brightness(level)
                p.fill_rect(0, 110, p.width, 30, p.rgb(0, 0, 51))
                p.draw_text_centered(120, f"Brightness: {level}%", p.YELLOW, 1)
                p.flip()
                if skippable_delay(p, 300):
                    skipped = True

        if not skipped:
            # Screen off/on test
            p.fill_rect(0, 70, p.width, 80, p.rgb(0, 0, 51))
            p.draw_text_centered(80, "Screen off in 2 seconds...", p.RED, 1)
            p.flip()
            if not skippable_delay(p, 2000):
                p.screen_off()
                time.sleep(2)  # Non-skippable 2 second delay
                p.screen_on()
                p.fill_rect(0, 70, p.width, 80, p.rgb(0, 0, 51))
                p.draw_text_centered(80, "Screen back on!", p.GREEN, 1)
                p.flip()
                skippable_delay(p, 500)

        # Restore original brightness
        p.set_brightness(original_brightness if original_brightness > 0 else 80)

        p.fill_rect(0, 70, p.width, 150, p.rgb(0, 0, 51))
        p.draw_text_centered(80, "Brightness test complete!", p.WHITE, 1)
        wait_for_green(p)

        # ------------------------------------
        # 6. TTF Font rendering
        # ------------------------------------
        print("[6/8] TTF Font rendering...")

        p.clear(p.rgb(0, 0, 32))
        p.draw_text_centered(10, "TTF Font Demo", p.YELLOW, 2)

        # Check if fonts exist
        if os.path.exists(ROBOTO):
            y = 40
            p.draw_ttf(10, y, "Roboto 16px", p.WHITE, ROBOTO, 16.0)
            y += 18
            p.draw_ttf(10, y, "Roboto 24px", p.WHITE, ROBOTO, 24.0)
            y += 26
            p.draw_ttf(10, y, "Roboto 32px", p.CYAN, ROBOTO, 32.0)

            if os.path.exists(ROBOTO_BOLD):
                y += 34
                p.draw_ttf(10, y, "Roboto Bold", p.GREEN, ROBOTO_BOLD, 28.0)

            if os.path.exists(PRESS_START):
                y += 30
                p.draw_ttf(10, y, "RETRO!", p.MAGENTA, PRESS_START, 16.0)

            # Centered TTF - vertically centered (screen height 222, so ~100)
            p.draw_ttf_centered(168, "Centered TTF", p.ORANGE, ROBOTO, 20.0)
        else:
            p.draw_text_centered(100, "No TTF fonts found!", p.RED, 1)
            p.draw_text_centered(130, "Run: make fonts", p.GRAY, 1)

        wait_for_green(p)

        # ------------------------------------
        # 7. Image loading (JPG, PNG, BMP)
        # ------------------------------------
        print("[7/8] Image loading...")

        p.clear(p.BLACK)
        p.draw_text_centered(10, "Image Demo", p.YELLOW, 2)

        TEST_IMAGE = "/root/payloads/user/utilities/PAGERCTL/images/test_image.jpg"

        if os.path.exists(TEST_IMAGE):
            img_info = p.get_image_info(TEST_IMAGE)
            if img_info:
                img_w, img_h = img_info
                p.draw_text_centered(35, f"Image: {img_w}x{img_h}", p.GRAY, 1)

                # Calculate scaling to fit (max 400x160 to leave room for text)
                max_w, max_h = 400, 160
                scale_w = max_w / img_w
                scale_h = max_h / img_h
                scale = min(scale_w, scale_h, 1.0)  # Don't upscale

                dst_w = int(img_w * scale)
                dst_h = int(img_h * scale)
                x = (p.width - dst_w) // 2
                y = 50

                # Load and draw scaled
                if p.draw_image_file_scaled(x, y, dst_w, dst_h, TEST_IMAGE) == 0:
                    p.draw_text(x, y + dst_h + 5, f"Scaled: {dst_w}x{dst_h}", p.WHITE, 1)
                else:
                    p.draw_text_centered(100, "Failed to load image!", p.RED, 1)
            else:
                p.draw_text_centered(100, "Failed to get image info!", p.RED, 1)
        else:
            p.draw_text_centered(80, "No test image found!", p.RED, 1)
            p.draw_text_centered(110, "Copy test_image.jpg to:", p.GRAY, 1)
            p.draw_text_centered(130, TEST_IMAGE, p.GRAY, 1)

        wait_for_green(p)

        # ------------------------------------
        # 8. Button input - wait for ALL buttons
        # ------------------------------------
        print("[8/8] Button input...")

        # Track which buttons have been pressed
        buttons_pressed = {
            'UP': False,
            'DOWN': False,
            'LEFT': False,
            'RIGHT': False,
            'A': False,
            'B': False,
            'POWER': False,
        }

        def draw_button_status():
            p.clear(p.rgb(0, 0, 51))
            p.draw_text_centered(20, "Button Test", p.WHITE, 2)
            p.draw_text_centered(50, "Press ALL buttons!", p.YELLOW, 1)

            # Draw button status grid
            y = 80
            for name, pressed in buttons_pressed.items():
                color = p.GREEN if pressed else p.rgb(80, 80, 80)
                symbol = "[X]" if pressed else "[ ]"
                p.draw_text(100, y, f"{symbol} {name}", color, 1)
                y += 18

            # Count remaining
            remaining = sum(1 for v in buttons_pressed.values() if not v)
            if remaining > 0:
                p.draw_text_centered(200, f"{remaining} buttons remaining", p.GRAY, 1)
            else:
                p.draw_text_centered(200, "All pressed! GREEN to exit", p.GREEN, 1)

            p.flip()

        draw_button_status()

        # Wait for all buttons to be pressed
        all_done = False
        while not all_done:
            button = p.wait_button()

            # Check each button and light up corresponding LED
            if button & Pager.BTN_UP:
                buttons_pressed['UP'] = True
                p.led_dpad("up", 0x00FF00)
            if button & Pager.BTN_DOWN:
                buttons_pressed['DOWN'] = True
                p.led_dpad("down", 0x00FF00)
            if button & Pager.BTN_LEFT:
                buttons_pressed['LEFT'] = True
                p.led_dpad("left", 0x00FF00)
            if button & Pager.BTN_RIGHT:
                buttons_pressed['RIGHT'] = True
                p.led_dpad("right", 0x00FF00)
            if button & Pager.BTN_A:
                buttons_pressed['A'] = True
                p.led_set("b-button-led", 255)  # sysfs swapped: b-led = green/A
            if button & Pager.BTN_B:
                buttons_pressed['B'] = True
                p.led_set("a-button-led", 255)  # sysfs swapped: a-led = red/B
            if button & Pager.BTN_POWER:
                buttons_pressed['POWER'] = True

            # Play beep on any button
            p.beep(600, 50)

            draw_button_status()

            # Check if all buttons have been pressed
            if all(buttons_pressed.values()):
                # Wait for GREEN to exit
                while True:
                    button = p.wait_button()
                    if button & Pager.BTN_A:
                        all_done = True
                        break
                    p.beep(400, 50)  # Wrong button sound

        # Turn off LEDs
        p.led_all_off()

        # ------------------------------------
        # Goodbye
        # ------------------------------------
        print("Exiting...")

        # Exit sound
        p.beep(523, 100)
        p.beep(392, 100)
        p.beep(262, 200)

        # Show goodbye
        p.clear(p.BLACK)
        p.draw_text_centered(100, "Goodbye!", p.GREEN, 2)
        p.flip()
        p.delay(1000)

        # Clear screen before exit
        p.clear(p.BLACK)
        p.flip()

    print("Done!")


if __name__ == "__main__":
    main()
