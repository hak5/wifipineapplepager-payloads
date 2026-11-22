/*
 * demo.c - pagerctl Hardware Demo in C
 *
 * Demonstrates all hardware features using pagerctl:
 * - Display with double-buffering
 * - Button input (including POWER button)
 * - LED control
 * - Audio (buzzer) and vibration
 * - Brightness control
 * - TTF font rendering
 * - Image loading (JPG, PNG, BMP, GIF)
 *
 * Build:
 *   make demo
 *
 * Run on Pager:
 *   ./demo
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <sys/time.h>
#include "pagerctl.h"

/* Font paths */
#define FONT_DIR "/root/payloads/user/utilities/PAGERCTL/fonts"
#define ROBOTO FONT_DIR "/Roboto-Regular.ttf"
#define ROBOTO_BOLD FONT_DIR "/Roboto-Bold.ttf"
#define PRESS_START FONT_DIR "/PressStart2P.ttf"

/* Helper colors (for backgrounds not in header) */
#define COLOR_BG       RGB565(0, 0, 51)
#define COLOR_BG_GREEN RGB565(0, 17, 0)
#define COLOR_BG_RED   RGB565(34, 0, 17)
#define COLOR_BG_BLUE  RGB565(0, 0, 32)

/* Get current time in milliseconds */
static long get_time_ms(void) {
    struct timeval tv;
    gettimeofday(&tv, NULL);
    return tv.tv_sec * 1000 + tv.tv_usec / 1000;
}

/* Skippable delay - returns 1 if GREEN pressed, 0 otherwise */
static int skippable_delay(int ms) {
    long start = get_time_ms();
    pager_input_t input;

    while (get_time_ms() - start < ms) {
        pager_poll_input(&input);
        if (input.pressed & BTN_A) {
            return 1;
        }
        usleep(50000);  /* 50ms */
    }
    return 0;
}

/* Wait for green (A) button */
static void wait_for_green(const char *message) {
    pager_draw_text_centered(200, message ? message : "Press GREEN to continue...",
                             COLOR_GREEN, 1);
    pager_flip();

    while (1) {
        pager_button_t btn = pager_wait_button();
        if (btn & BTN_A) break;
    }
}

/* File exists check */
static int file_exists(const char *path) {
    return access(path, F_OK) == 0;
}

int main(int argc, char *argv[]) {
    printf("=== pagerctl C Demo ===\n");

    /* Initialize */
    if (pager_init() != 0) {
        fprintf(stderr, "Failed to initialize pager\n");
        return 1;
    }

    pager_set_rotation(270);  /* Landscape mode */

    int width = pager_get_width();
    int height = pager_get_height();

    /* ----------------------------------------
     * 1. Display basics
     * ---------------------------------------- */
    printf("[1/8] Display basics...\n");

    pager_clear(COLOR_BG);
    pager_draw_text_centered(20, "PAGERCTL C DEMO", COLOR_YELLOW, 2);
    pager_draw_text(10, 60, "Left aligned", COLOR_RED, 1);
    pager_draw_text_centered(80, "Centered text", COLOR_GREEN, 1);

    /* Right-aligned: 6 pixels per char at scale 1 */
    const char *right_text = "Right aligned";
    int right_x = width - (strlen(right_text) * 6) - 10;
    pager_draw_text(right_x, 100, right_text, COLOR_BLUE, 1);

    /* Filled rectangle with text */
    pager_fill_rect(150, 130, 180, 40, COLOR_ORANGE);
    pager_draw_text(170, 145, "Graphics!", COLOR_BLACK, 1);

    wait_for_green(NULL);

    /* ----------------------------------------
     * 2. Screen properties and colors
     * ---------------------------------------- */
    printf("[2/8] Screen properties...\n");

    pager_clear(COLOR_BLACK);
    char screen_info[64];
    snprintf(screen_info, sizeof(screen_info), "Screen: %dx%d", width, height);
    pager_draw_text_centered(30, screen_info, COLOR_WHITE, 1);

    /* Rainbow color bars (blue in position 2 to test optical illusion) */
    int bar_width = width / 6;
    uint16_t colors[] = {COLOR_RED, COLOR_BLUE, COLOR_YELLOW, COLOR_GREEN, COLOR_ORANGE, COLOR_MAGENTA};
    for (int i = 0; i < 6; i++) {
        pager_fill_rect(i * bar_width, 60, bar_width, 60, colors[i]);
    }

    pager_draw_text_centered(140, "Rainbow!", COLOR_WHITE, 2);

    wait_for_green(NULL);

    /* ----------------------------------------
     * 3. LED control
     * ---------------------------------------- */
    printf("[3/8] LED control...\n");

    int run_led_test = 1;
    while (run_led_test) {
        pager_clear(COLOR_BG_GREEN);
        pager_draw_text_centered(30, "LED Demo", COLOR_WHITE, 2);
        pager_draw_text_centered(70, "Watch D-pad + A/B buttons!", COLOR_GRAY, 1);
        pager_draw_text(100, 200, "GREEN=skip/continue", COLOR_GREEN, 1);
        pager_draw_text(300, 200, "RED=repeat", COLOR_RED, 1);
        pager_flip();

        int skipped = 0;

        /* Cycle through colors on D-pad LEDs */
        uint32_t led_colors[] = {0xFF0000, 0x00FF00, 0x0000FF, 0xFFFF00, 0xFF00FF, 0x00FFFF};
        const char *dpad_leds[] = {"up", "right", "down", "left"};

        for (int c = 0; c < 6 && !skipped; c++) {
            for (int l = 0; l < 4; l++) {
                pager_led_dpad(dpad_leds[l], led_colors[c]);
            }
            if (skippable_delay(800)) {
                skipped = 1;
            }
        }

        if (!skipped) {
            pager_led_all_off();
            if (skippable_delay(300)) {
                skipped = 1;
            }
        }

        /* Test A button LED (green) - sysfs swapped */
        if (!skipped) {
            pager_fill_rect(0, 60, width, 30, COLOR_BG_GREEN);
            pager_draw_text_centered(70, "A button LED (Green)", COLOR_GREEN, 1);
            pager_flip();
            for (int i = 0; i < 3 && !skipped; i++) {
                pager_led_set("b-button-led", 255);
                if (skippable_delay(500)) { skipped = 1; break; }
                pager_led_set("b-button-led", 0);
                if (skippable_delay(300)) { skipped = 1; break; }
            }
        }

        /* Test B button LED (red) - sysfs swapped */
        if (!skipped) {
            pager_fill_rect(0, 60, width, 30, COLOR_BG_GREEN);
            pager_draw_text_centered(70, "B button LED (Red)", COLOR_RED, 1);
            pager_flip();
            for (int i = 0; i < 3 && !skipped; i++) {
                pager_led_set("a-button-led", 255);
                if (skippable_delay(500)) { skipped = 1; break; }
                pager_led_set("a-button-led", 0);
                if (skippable_delay(300)) { skipped = 1; break; }
            }
        }

        pager_led_all_off();

        if (skipped) {
            run_led_test = 0;
        } else {
            /* Wait for user choice */
            pager_fill_rect(0, 60, width, 30, COLOR_BG_GREEN);
            pager_draw_text_centered(70, "LED test complete!", COLOR_WHITE, 1);
            pager_flip();

            while (1) {
                pager_button_t btn = pager_wait_button();
                if (btn & BTN_A) {
                    run_led_test = 0;
                    break;
                } else if (btn & BTN_B) {
                    break;  /* Repeat */
                }
            }
        }
    }

    /* ----------------------------------------
     * 4. Audio and vibration
     * ---------------------------------------- */
    printf("[4/8] Audio and vibration...\n");

    pager_clear(COLOR_BG_RED);
    pager_draw_text_centered(30, "Audio Demo", COLOR_WHITE, 2);
    pager_draw_text_centered(80, "Playing scale...", COLOR_GRAY, 1);
    pager_draw_text_centered(200, "GREEN=skip", COLOR_GREEN, 1);
    pager_flip();

    int skipped = 0;

    /* Play scale C4 to C5 */
    int notes[] = {262, 294, 330, 349, 392, 440, 494, 523};
    for (int i = 0; i < 8 && !skipped; i++) {
        pager_beep(notes[i], 150);
        if (skippable_delay(50)) {
            skipped = 1;
        }
    }

    if (!skipped) {
        skipped = skippable_delay(300);
    }

    /* Vibration */
    if (!skipped) {
        pager_fill_rect(0, 70, width, 30, COLOR_BG_RED);
        pager_draw_text_centered(80, "Vibrating...", COLOR_GRAY, 1);
        pager_flip();

        pager_vibrate(100);
        if (!skippable_delay(100)) {
            pager_vibrate(100);
            if (!skippable_delay(100)) {
                pager_vibrate(200);
                skippable_delay(300);
            }
        }
    }

    if (!skipped) {
        /* RTTTL modes demo */
        const char *melody = "Demo:d=4,o=5,b=140:8c,8e,8g,c6";

        /* Mode 1: Sound only */
        pager_fill_rect(0, 70, width, 30, COLOR_BG_RED);
        pager_draw_text_centered(80, "RTTTL: Sound only", COLOR_GRAY, 1);
        pager_flip();
        pager_play_rtttl(melody);
        while (pager_audio_playing() && !skipped) {
            if (skippable_delay(100)) skipped = 1;
        }

        if (!skipped && !skippable_delay(300)) {
            /* Mode 2: Sound + Vibration */
            pager_fill_rect(0, 70, width, 30, COLOR_BG_RED);
            pager_draw_text_centered(80, "RTTTL: Sound + Vibrate", COLOR_CYAN, 1);
            pager_flip();
            pager_play_rtttl_ex(melody, RTTTL_SOUND_VIBRATE);
            while (pager_audio_playing() && !skipped) {
                if (skippable_delay(100)) skipped = 1;
            }

            if (!skipped && !skippable_delay(300)) {
                /* Mode 3: Vibration only (silent) */
                pager_fill_rect(0, 70, width, 30, COLOR_BG_RED);
                pager_draw_text_centered(80, "RTTTL: Vibrate only (silent)", COLOR_YELLOW, 1);
                pager_flip();
                pager_play_rtttl_ex(melody, RTTTL_VIBRATE_ONLY);
                while (pager_audio_playing() && !skipped) {
                    if (skippable_delay(100)) skipped = 1;
                }
            }
        }
    }

    /* Always stop audio/vibration when leaving this section */
    pager_stop_audio();

    pager_fill_rect(0, 70, width, 150, COLOR_BG_RED);
    pager_draw_text_centered(80, "Audio test complete!", COLOR_WHITE, 1);
    wait_for_green(NULL);

    /* ----------------------------------------
     * 5. Brightness control
     * ---------------------------------------- */
    printf("[5/8] Brightness control...\n");

    pager_clear(COLOR_BG);
    pager_draw_text_centered(30, "Brightness Demo", COLOR_WHITE, 2);
    pager_draw_text_centered(200, "GREEN=skip", COLOR_GREEN, 1);
    pager_flip();

    skipped = 0;

    /* Get current brightness to restore later */
    int original_brightness = pager_get_brightness();

    /* Dim down */
    pager_fill_rect(0, 70, width, 50, COLOR_BG);
    pager_draw_text_centered(80, "Dimming down...", COLOR_GRAY, 1);
    pager_flip();

    for (int level = 100; level >= 20 && !skipped; level -= 10) {
        pager_set_brightness(level);
        pager_fill_rect(0, 110, width, 30, COLOR_BG);
        char brightness_text[32];
        snprintf(brightness_text, sizeof(brightness_text), "Brightness: %d%%", level);
        pager_draw_text_centered(120, brightness_text, COLOR_YELLOW, 1);
        pager_flip();
        if (skippable_delay(300)) {
            skipped = 1;
        }
    }

    if (!skipped) {
        /* Brighten up */
        pager_fill_rect(0, 70, width, 50, COLOR_BG);
        pager_draw_text_centered(80, "Brightening up...", COLOR_GRAY, 1);
        pager_flip();

        for (int level = 20; level <= 100 && !skipped; level += 10) {
            pager_set_brightness(level);
            pager_fill_rect(0, 110, width, 30, COLOR_BG);
            char brightness_text[32];
            snprintf(brightness_text, sizeof(brightness_text), "Brightness: %d%%", level);
            pager_draw_text_centered(120, brightness_text, COLOR_YELLOW, 1);
            pager_flip();
            if (skippable_delay(300)) {
                skipped = 1;
            }
        }
    }

    if (!skipped) {
        /* Screen off/on test */
        pager_fill_rect(0, 70, width, 80, COLOR_BG);
        pager_draw_text_centered(80, "Screen off in 2 seconds...", COLOR_RED, 1);
        pager_flip();
        if (!skippable_delay(2000)) {
            pager_screen_off();
            sleep(2);  /* Non-skippable 2 second delay */
            pager_screen_on();
            pager_fill_rect(0, 70, width, 80, COLOR_BG);
            pager_draw_text_centered(80, "Screen back on!", COLOR_GREEN, 1);
            pager_flip();
            skippable_delay(500);
        }
    }

    /* Restore original brightness */
    pager_set_brightness(original_brightness > 0 ? original_brightness : 80);

    pager_fill_rect(0, 70, width, 150, COLOR_BG);
    pager_draw_text_centered(80, "Brightness test complete!", COLOR_WHITE, 1);
    wait_for_green(NULL);

    /* ----------------------------------------
     * 6. TTF Font rendering
     * ---------------------------------------- */
    printf("[6/8] TTF Font rendering...\n");

    pager_clear(COLOR_BG_BLUE);
    pager_draw_text_centered(10, "TTF Font Demo", COLOR_YELLOW, 2);

    if (file_exists(ROBOTO)) {
        int y = 40;
        pager_draw_ttf(10, y, "Roboto 16px", COLOR_WHITE, ROBOTO, 16.0);
        y += 18;
        pager_draw_ttf(10, y, "Roboto 24px", COLOR_WHITE, ROBOTO, 24.0);
        y += 26;
        pager_draw_ttf(10, y, "Roboto 32px", COLOR_CYAN, ROBOTO, 32.0);

        if (file_exists(ROBOTO_BOLD)) {
            y += 34;
            pager_draw_ttf(10, y, "Roboto Bold", COLOR_GREEN, ROBOTO_BOLD, 28.0);
        }

        if (file_exists(PRESS_START)) {
            y += 30;
            pager_draw_ttf(10, y, "RETRO!", COLOR_MAGENTA, PRESS_START, 16.0);
        }

        /* Centered TTF */
        pager_draw_ttf_centered(168, "Centered TTF", COLOR_ORANGE, ROBOTO, 20.0);
    } else {
        pager_draw_text_centered(100, "No TTF fonts found!", COLOR_RED, 1);
        pager_draw_text_centered(130, "Run: make fonts", COLOR_GRAY, 1);
    }

    wait_for_green(NULL);

    /* ----------------------------------------
     * 7. Image loading (JPG, PNG, BMP)
     * ---------------------------------------- */
    printf("[7/8] Image loading...\n");

    pager_clear(COLOR_BLACK);
    pager_draw_text_centered(10, "Image Demo", COLOR_YELLOW, 2);

    /* Check if test image exists */
    #define TEST_IMAGE "/root/payloads/user/utilities/PAGERCTL/images/test_image.jpg"

    if (file_exists(TEST_IMAGE)) {
        int img_w, img_h;
        if (pager_get_image_info(TEST_IMAGE, &img_w, &img_h) == 0) {
            char info[64];
            snprintf(info, sizeof(info), "Image: %dx%d", img_w, img_h);
            pager_draw_text_centered(35, info, COLOR_GRAY, 1);

            /* Calculate scaling to fit (max 400x180 to leave room for text) */
            int max_w = 400;
            int max_h = 160;
            float scale_w = (float)max_w / img_w;
            float scale_h = (float)max_h / img_h;
            float scale = (scale_w < scale_h) ? scale_w : scale_h;
            if (scale > 1.0f) scale = 1.0f;  /* Don't upscale */

            int dst_w = (int)(img_w * scale);
            int dst_h = (int)(img_h * scale);
            int x = (width - dst_w) / 2;
            int y = 50;

            /* Load and draw scaled */
            if (pager_draw_image_file_scaled(x, y, dst_w, dst_h, TEST_IMAGE) == 0) {
                snprintf(info, sizeof(info), "Scaled: %dx%d", dst_w, dst_h);
                pager_draw_text(x, y + dst_h + 5, info, COLOR_WHITE, 1);
            } else {
                pager_draw_text_centered(100, "Failed to load image!", COLOR_RED, 1);
            }
        } else {
            pager_draw_text_centered(100, "Failed to get image info!", COLOR_RED, 1);
        }
    } else {
        pager_draw_text_centered(80, "No test image found!", COLOR_RED, 1);
        pager_draw_text_centered(110, "Copy test_image.jpg to:", COLOR_GRAY, 1);
        pager_draw_text_centered(130, TEST_IMAGE, COLOR_GRAY, 1);
    }

    wait_for_green(NULL);

    /* ----------------------------------------
     * 8. Button input - wait for ALL buttons
     * ---------------------------------------- */
    printf("[8/8] Button input...\n");

    /* Track which buttons have been pressed */
    int btn_up = 0, btn_down = 0, btn_left = 0, btn_right = 0;
    int btn_a = 0, btn_b = 0, btn_power = 0;

    pager_led_all_off();

    while (1) {
        /* Draw status */
        pager_clear(COLOR_BG);
        pager_draw_text_centered(20, "Button Test", COLOR_WHITE, 2);
        pager_draw_text_centered(50, "Press ALL buttons!", COLOR_YELLOW, 1);

        int y = 80;
        pager_draw_text(100, y, btn_up ? "[X] UP" : "[ ] UP",
                        btn_up ? COLOR_GREEN : COLOR_DARK_GRAY, 1);
        y += 18;
        pager_draw_text(100, y, btn_down ? "[X] DOWN" : "[ ] DOWN",
                        btn_down ? COLOR_GREEN : COLOR_DARK_GRAY, 1);
        y += 18;
        pager_draw_text(100, y, btn_left ? "[X] LEFT" : "[ ] LEFT",
                        btn_left ? COLOR_GREEN : COLOR_DARK_GRAY, 1);
        y += 18;
        pager_draw_text(100, y, btn_right ? "[X] RIGHT" : "[ ] RIGHT",
                        btn_right ? COLOR_GREEN : COLOR_DARK_GRAY, 1);
        y += 18;
        pager_draw_text(100, y, btn_a ? "[X] A" : "[ ] A",
                        btn_a ? COLOR_GREEN : COLOR_DARK_GRAY, 1);
        y += 18;
        pager_draw_text(100, y, btn_b ? "[X] B" : "[ ] B",
                        btn_b ? COLOR_GREEN : COLOR_DARK_GRAY, 1);
        y += 18;
        pager_draw_text(100, y, btn_power ? "[X] POWER" : "[ ] POWER",
                        btn_power ? COLOR_GREEN : COLOR_DARK_GRAY, 1);

        int remaining = !btn_up + !btn_down + !btn_left + !btn_right +
                        !btn_a + !btn_b + !btn_power;

        if (remaining > 0) {
            char msg[32];
            snprintf(msg, sizeof(msg), "%d buttons remaining", remaining);
            pager_draw_text_centered(200, msg, COLOR_GRAY, 1);
        } else {
            pager_draw_text_centered(200, "All pressed! GREEN to exit", COLOR_GREEN, 1);
        }

        pager_flip();

        /* Check if all done */
        if (remaining == 0) {
            while (1) {
                pager_button_t btn = pager_wait_button();
                if (btn & BTN_A) {
                    goto button_test_done;
                }
                pager_beep(400, 50);
            }
        }

        /* Wait for button */
        pager_button_t btn = pager_wait_button();

        if (btn & BTN_UP) {
            btn_up = 1;
            pager_led_dpad("up", 0x00FF00);
        }
        if (btn & BTN_DOWN) {
            btn_down = 1;
            pager_led_dpad("down", 0x00FF00);
        }
        if (btn & BTN_LEFT) {
            btn_left = 1;
            pager_led_dpad("left", 0x00FF00);
        }
        if (btn & BTN_RIGHT) {
            btn_right = 1;
            pager_led_dpad("right", 0x00FF00);
        }
        if (btn & BTN_A) {
            btn_a = 1;
            pager_led_set("b-button-led", 255);
        }
        if (btn & BTN_B) {
            btn_b = 1;
            pager_led_set("a-button-led", 255);
        }
        if (btn & BTN_POWER) {
            btn_power = 1;
        }

        pager_beep(600, 50);
    }

button_test_done:
    pager_led_all_off();

    /* ----------------------------------------
     * Goodbye
     * ---------------------------------------- */
    printf("Exiting...\n");

    pager_beep(523, 100);
    pager_beep(392, 100);
    pager_beep(262, 200);

    pager_clear(COLOR_BLACK);
    pager_draw_text_centered(100, "Goodbye!", COLOR_GREEN, 2);
    pager_flip();
    pager_delay(1000);

    pager_clear(COLOR_BLACK);
    pager_flip();

    pager_cleanup();

    printf("Done!\n");
    return 0;
}
