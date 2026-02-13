/*
 * pagerctl.h - WiFi Pineapple Pager Hardware Control Library
 *
 * Shared library for hardware access on the Pager's framebuffer display.
 *
 * Hardware Specs:
 *   Display: 222x480 pixels, RGB565 (16-bit color)
 *   Framebuffer: /dev/fb0 (direct write, no mmap needed)
 *   Refresh: ~20 FPS max (SPI bottleneck)
 *   Input: /dev/input/event0 (Linux evdev)
 *   CPU: MIPS 24KEc @ 580MHz, 64MB RAM
 *
 * Usage:
 *   1. Call pager_init() at startup
 *   2. Draw using pager_fill_rect(), pager_draw_text(), etc.
 *   3. Call pager_flip() to display the frame
 *   4. Call pager_poll_input() for button state
 *   5. Call pager_cleanup() on exit
 */

#ifndef PAGERCTL_H
#define PAGERCTL_H

#include <stdint.h>
#include <stdbool.h>

/* Display dimensions (framebuffer is always 222x480) */
#define PAGER_FB_WIDTH   222
#define PAGER_FB_HEIGHT  480
#define PAGER_BPP        16      /* Bits per pixel (RGB565) */
#define PAGER_STRIDE     (PAGER_FB_WIDTH * 2)  /* Bytes per row */

/* Logical dimensions (depend on orientation) */
#define PAGER_WIDTH      222    /* Portrait width (default) */
#define PAGER_HEIGHT     480    /* Portrait height (default) */
#define PAGER_LANDSCAPE_WIDTH   480   /* Landscape logical width */
#define PAGER_LANDSCAPE_HEIGHT  222   /* Landscape logical height */

/* Target frame rate */
#define PAGER_TARGET_FPS  20
#define PAGER_FRAME_MS    (1000 / PAGER_TARGET_FPS)

/* RGB565 color format: RRRRRGGGGGGBBBBB */
#define RGB565(r, g, b) (uint16_t)(((r) >> 3) << 11 | ((g) >> 2) << 5 | ((b) >> 3))

/* Predefined colors */
#define COLOR_BLACK       RGB565(0, 0, 0)
#define COLOR_WHITE       RGB565(255, 255, 255)
#define COLOR_RED         RGB565(255, 0, 0)
#define COLOR_GREEN       RGB565(0, 255, 0)
#define COLOR_BLUE        RGB565(0, 0, 255)
#define COLOR_YELLOW      RGB565(255, 255, 0)
#define COLOR_CYAN        RGB565(0, 255, 255)
#define COLOR_MAGENTA     RGB565(255, 0, 255)
#define COLOR_ORANGE      RGB565(255, 165, 0)
#define COLOR_PURPLE      RGB565(128, 0, 128)
#define COLOR_GRAY        RGB565(128, 128, 128)
#define COLOR_DARK_GRAY   RGB565(64, 64, 64)
#define COLOR_LIGHT_GRAY  RGB565(192, 192, 192)

/* Tetris piece colors (standard) */
#define COLOR_I_PIECE     RGB565(0, 255, 255)    /* Cyan */
#define COLOR_O_PIECE     RGB565(255, 255, 0)    /* Yellow */
#define COLOR_T_PIECE     RGB565(128, 0, 128)    /* Purple */
#define COLOR_S_PIECE     RGB565(0, 255, 0)      /* Green */
#define COLOR_Z_PIECE     RGB565(255, 0, 0)      /* Red */
#define COLOR_J_PIECE     RGB565(0, 0, 255)      /* Blue */
#define COLOR_L_PIECE     RGB565(255, 165, 0)    /* Orange */

/* Button codes (internal bitmask - not Linux evdev codes) */
typedef enum {
    PBTN_NONE  = 0,
    PBTN_UP    = (1 << 0),
    PBTN_DOWN  = (1 << 1),
    PBTN_LEFT  = (1 << 2),
    PBTN_RIGHT = (1 << 3),
    PBTN_A     = (1 << 4),   /* Green button */
    PBTN_B     = (1 << 5),   /* Red button */
    PBTN_POWER = (1 << 6),   /* Power button */
} pager_button_t;

/* Backwards compatibility aliases */
#define BTN_NONE  PBTN_NONE
#define BTN_UP    PBTN_UP
#define BTN_DOWN  PBTN_DOWN
#define BTN_LEFT  PBTN_LEFT
#define BTN_RIGHT PBTN_RIGHT
#define BTN_A     PBTN_A
#define BTN_B     PBTN_B
#define BTN_POWER PBTN_POWER

/* Input state structure */
typedef struct {
    uint8_t current;     /* Currently held buttons (bitmask) */
    uint8_t pressed;     /* Just pressed this frame (bitmask) */
    uint8_t released;    /* Just released this frame (bitmask) */
} pager_input_t;

/* Input event types */
typedef enum {
    PAGER_EVENT_NONE = 0,
    PAGER_EVENT_PRESS = 1,
    PAGER_EVENT_RELEASE = 2,
} pager_event_type_t;

/* Input event structure (for event queue) */
typedef struct {
    uint8_t button;              /* Which button (PBTN_* bitmask, single bit) */
    pager_event_type_t type;     /* PRESS or RELEASE */
    uint32_t timestamp;          /* When event occurred (ms) */
} pager_input_event_t;

/* Font size options */
typedef enum {
    FONT_SMALL  = 1,    /* 5x7 pixels */
    FONT_MEDIUM = 2,    /* 10x14 pixels (2x scale) */
    FONT_LARGE  = 3,    /* 15x21 pixels (3x scale) */
} font_size_t;

/*
 * Display orientation
 */

/* Orientation modes for pager_set_rotation() */
typedef enum {
    ROTATION_0   = 0,    /* Portrait (default): 222x480, no rotation */
    ROTATION_90  = 90,   /* Landscape: 480x222, 90° CW */
    ROTATION_180 = 180,  /* Portrait inverted: 222x480, 180° */
    ROTATION_270 = 270,  /* Landscape inverted: 480x222, 270° CW */
} pager_rotation_t;

/* Set display rotation. All drawing will be automatically rotated.
 * ROTATION_0:   Portrait (222 wide x 480 tall)
 * ROTATION_90:  Landscape (480 wide x 222 tall) - for right-handed portrait
 * ROTATION_180: Portrait inverted
 * ROTATION_270: Landscape inverted (480 wide x 222 tall) - for left-handed portrait
 */
void pager_set_rotation(pager_rotation_t rotation);

/* Get current logical screen width (depends on rotation) */
int pager_get_width(void);

/* Get current logical screen height (depends on rotation) */
int pager_get_height(void);

/*
 * Initialization and cleanup
 */

/* Initialize the graphics system. Returns 0 on success, -1 on error. */
int pager_init(void);

/* Clean up and close framebuffer. Always call on exit. */
void pager_cleanup(void);

/*
 * Frame management
 */

/* Flip the back buffer to the display. Call once per frame. */
void pager_flip(void);

/* Clear the screen to a solid color */
void pager_clear(uint16_t color);

/* Get current time in milliseconds (for timing) */
uint32_t pager_get_ticks(void);

/* Sleep for specified milliseconds */
void pager_delay(uint32_t ms);

/* Frame rate limiter - call at end of game loop. Returns actual frame time. */
uint32_t pager_frame_sync(void);

/*
 * Drawing primitives
 */

/* Set a single pixel */
void pager_set_pixel(int x, int y, uint16_t color);

/* Draw a filled rectangle */
void pager_fill_rect(int x, int y, int w, int h, uint16_t color);

/* Draw a rectangle outline */
void pager_draw_rect(int x, int y, int w, int h, uint16_t color);

/* Draw a horizontal line */
void pager_hline(int x, int y, int w, uint16_t color);

/* Draw a vertical line */
void pager_vline(int x, int y, int h, uint16_t color);

/* Draw a line (Bresenham's algorithm) */
void pager_draw_line(int x0, int y0, int x1, int y1, uint16_t color);

/* Draw a filled circle */
void pager_fill_circle(int cx, int cy, int r, uint16_t color);

/* Draw a circle outline */
void pager_draw_circle(int cx, int cy, int r, uint16_t color);

/*
 * Text rendering (built-in 5x7 bitmap font)
 */

/* Draw a single character. Returns width drawn. */
int pager_draw_char(int x, int y, char c, uint16_t color, font_size_t size);

/* Draw a string. Returns total width drawn. */
int pager_draw_text(int x, int y, const char *text, uint16_t color, font_size_t size);

/* Draw centered text */
void pager_draw_text_centered(int y, const char *text, uint16_t color, font_size_t size);

/* Get width of text in pixels */
int pager_text_width(const char *text, font_size_t size);

/* Draw a number (helper for scores) */
int pager_draw_number(int x, int y, int num, uint16_t color, font_size_t size);

/*
 * Input handling
 */

/* Poll input and update state. Call once per frame before checking buttons. */
void pager_poll_input(pager_input_t *input);

/* Check if a button is currently held */
#define pager_button_held(input, btn)    ((input)->current & (btn))

/* Check if a button was just pressed this frame */
#define pager_button_pressed(input, btn) ((input)->pressed & (btn))

/* Check if a button was just released this frame */
#define pager_button_released(input, btn) ((input)->released & (btn))

/* Wait for any button press (blocking) */
pager_button_t pager_wait_button(void);

/*
 * Thread-safe input event queue
 *
 * For multi-threaded applications, use these functions instead of poll_input().
 * Events are queued and each event is only consumed once, regardless of which
 * thread reads it. This solves the problem of missed button presses when
 * multiple threads poll for input.
 */

/* Get the next input event from the queue.
 * Returns 1 if an event was retrieved, 0 if queue is empty.
 * Thread-safe: multiple threads can call this safely.
 */
int pager_get_input_event(pager_input_event_t *event);

/* Check if there are any pending input events.
 * Returns 1 if events are available, 0 if queue is empty.
 */
int pager_has_input_events(void);

/* Get current button state without consuming edge events.
 * Returns bitmask of currently held buttons.
 * Thread-safe: can be called from any thread.
 */
uint8_t pager_peek_buttons(void);

/* Clear all pending input events from the queue.
 * Useful when transitioning between app states (e.g., entering a menu).
 */
void pager_clear_input_events(void);

/*
 * Utility functions
 */

/* Simple random number generator (0 to max-1) */
int pager_random(int max);

/* Seed the random number generator */
void pager_seed_random(uint32_t seed);

/* Clamp a value to a range */
#define CLAMP(x, lo, hi) ((x) < (lo) ? (lo) : ((x) > (hi) ? (hi) : (x)))

/* Min/Max macros */
#define MIN(a, b) ((a) < (b) ? (a) : (b))
#define MAX(a, b) ((a) > (b) ? (a) : (b))

/* Absolute value */
#define ABS(x) ((x) < 0 ? -(x) : (x))

/*
 * Audio - RTTTL Ringtone playback
 *
 * The Pager supports RTTTL (Ring Tone Text Transfer Language) format.
 * This is used by the built-in RINGTONE command.
 */

/* RTTTL playback modes */
typedef enum {
    RTTTL_SOUND_ONLY     = 0,  /* Sound only (default) */
    RTTTL_SOUND_VIBRATE  = 1,  /* Sound + vibration */
    RTTTL_VIBRATE_ONLY   = 2,  /* Silent vibration pattern */
} rtttl_mode_t;

/* Play an RTTTL ringtone string (non-blocking, runs in background) */
void pager_play_rtttl(const char *rtttl);

/* Play RTTTL with mode: RTTTL_SOUND_ONLY, RTTTL_SOUND_VIBRATE, RTTTL_VIBRATE_ONLY */
void pager_play_rtttl_ex(const char *rtttl, rtttl_mode_t mode);

/* Stop any currently playing audio/vibration */
void pager_stop_audio(void);

/* Check if audio is currently playing */
int pager_audio_playing(void);

/*
 * Built-in game music (RTTTL format)
 */

/* Tetris Theme (Korobeiniki) - Complete A section */
#define RTTTL_TETRIS_THEME \
    "tetris:d=4,o=5,b=160:" \
    "e6,8b,8c6,8d6,16e6,16d6,8c6,8b,a,8a,8c6,e6,8d6,8c6," \
    "b,8b,8c6,d6,e6,c6,a,2a,8p," \
    "d6,8f6,a6,8g6,8f6,e6,8e6,8c6,e6,8d6,8c6," \
    "b,8b,8c6,d6,e6,c6,a,a"

/* Tetris Theme Part B (slower melodic section) */
#define RTTTL_TETRIS_B \
    "tetrisb:d=4,o=5,b=160:" \
    "2e6,2c6,2d6,2b,2c6,2a,2g#,2b,64p," \
    "2e6,2c6,2d6,2b,c6,e6,2a6,1g#6"

/* Tetris Full Theme - A + B (loops back to start) */
#define RTTTL_TETRIS_FULL \
    "tetrisfull:d=4,o=5,b=160:" \
    "e6,8b,8c6,8d6,16e6,16d6,8c6,8b,a,8a,8c6,e6,8d6,8c6," \
    "b,8b,8c6,d6,e6,c6,a,2a,8p," \
    "d6,8f6,a6,8g6,8f6,e6,8e6,8c6,e6,8d6,8c6," \
    "b,8b,8c6,d6,e6,c6,a,2a," \
    "2e6,2c6,2d6,2b,2c6,2a,2g#,2b,64p," \
    "2e6,2c6,2d6,2b,c6,e6,2a6,1g#6"

/* Tetris bass line / countermelody */
#define RTTTL_TETRIS_BASS \
    "tetrisbass:d=4,o=4,b=160:" \
    "e,e,e,e,a,a,a,a,g#,g#,g#,g#,a,b,c5,8p," \
    "d5,d5,d5,d5,c5,c5,c5,c5,b,b,b,b,a,2a"

/* Game Over - Part 1: SMB death intro */
#define RTTTL_GAME_OVER_1 \
    "smbdeath:d=4,o=5,b=90:" \
    "8p,16b,16f6,16p,16f6,16f.6,16e.6,16d6,16c6,16p,16e,16p,16c,4p"

/* Game Over - Part 2: Game over melody */
#define RTTTL_GAME_OVER_2 \
    "gameover:d=4,o=4,b=170:" \
    "8c5,4p,8g4,4p,4e4,32p,8a4,8b4,6a4,4g#4,6a#4,6g#4,8g4,8f4,1g4"

/* Game Over combined (for backwards compatibility - uses part 1) */
#define RTTTL_GAME_OVER RTTTL_GAME_OVER_1

/* Level Up jingle */
#define RTTTL_LEVEL_UP \
    "levelup:d=16,o=5,b=200:" \
    "c,e,g,c6,8p,g,c6,e6,8g6"

/* Victory fanfare */
#define RTTTL_VICTORY \
    "victory:d=4,o=5,b=180:" \
    "g,g,g,2d#,f,f,f,2d," \
    "g,g,g,d#6,d6,c6,b,8a,2g"

/* Pac-Man intro */
#define RTTTL_PACMAN \
    "pacman:d=4,o=5,b=160:" \
    "b,b6,f#6,d#6,8b6,8f#6,d#6,c6,c7,g6,f6,8c7,8g6,f6"

/* Space Invaders */
#define RTTTL_INVADERS \
    "invaders:d=8,o=4,b=120:" \
    "e,4e,e,4e,c,4c,d,4d,e,4e,4p," \
    "f,4f,f,4f,d,4d,e,4e,d,4d"

/*
 * ============================================================
 * VIBRATION
 * ============================================================
 */

/* Vibrate for duration in milliseconds */
void pager_vibrate(int duration_ms);

/* Play vibration pattern: "on_ms,off_ms,on_ms,..." */
void pager_vibrate_pattern(const char *pattern);

/*
 * ============================================================
 * LED CONTROL
 * ============================================================
 */

/* Set LED brightness (0-255) - for a-button-led, b-button-led */
void pager_led_set(const char *name, int brightness);

/* Set D-pad button RGB color (0-255 each) - "up", "down", "left", "right" */
void pager_led_rgb(const char *button, uint8_t r, uint8_t g, uint8_t b);

/* Set D-pad LED from 0xRRGGBB color */
void pager_led_dpad(const char *direction, uint32_t color);

/* Turn off all LEDs */
void pager_led_all_off(void);

/*
 * ============================================================
 * BACKLIGHT / BRIGHTNESS CONTROL
 * ============================================================
 */

/* Set screen brightness as percentage (0-100).
 * Returns 0 on success, -1 if backlight control not available.
 */
int pager_set_brightness(int percent);

/* Get current screen brightness as percentage (0-100).
 * Returns -1 if backlight control not available.
 */
int pager_get_brightness(void);

/* Get maximum brightness value from hardware.
 * Returns -1 if backlight control not available.
 */
int pager_get_max_brightness(void);

/* Turn screen off (sets brightness to 0).
 * Returns 0 on success, -1 if backlight control not available.
 */
int pager_screen_off(void);

/* Turn screen on (sets brightness to 80%).
 * Returns 0 on success, -1 if backlight control not available.
 */
int pager_screen_on(void);

/*
 * ============================================================
 * AUDIO EXTENSIONS
 * ============================================================
 */

/* Simple blocking beep */
void pager_beep(int freq, int duration_ms);

/* Play RTTTL synchronously (blocking) with optional vibration */
void pager_play_rtttl_sync(const char *rtttl, int with_vibration);

/*
 * ============================================================
 * TTF FONT SUPPORT
 * ============================================================
 */

/* Draw TTF text at position. Returns width drawn, or -1 on error.
 * font_path: path to .ttf file
 * font_size: size in pixels (e.g., 24.0)
 */
int pager_draw_ttf(int x, int y, const char *text, uint16_t color,
                   const char *font_path, float font_size);

/* Get width of TTF text in pixels */
int pager_ttf_width(const char *text, const char *font_path, float font_size);

/* Get height of TTF font in pixels */
int pager_ttf_height(const char *font_path, float font_size);

/* Draw centered TTF text */
void pager_draw_ttf_centered(int y, const char *text, uint16_t color,
                             const char *font_path, float font_size);

/* Draw right-aligned TTF text */
void pager_draw_ttf_right(int y, const char *text, uint16_t color,
                          const char *font_path, float font_size, int padding);

/* Free cached TTF font data (optional, called automatically on cleanup) */
void pager_ttf_cleanup(void);

/*
 * ============================================================
 * IMAGE SUPPORT (JPG, PNG, BMP, GIF)
 * ============================================================
 *
 * Supports loading and drawing images in common formats:
 * - JPEG (.jpg, .jpeg)
 * - PNG (.png)
 * - BMP (.bmp)
 * - GIF (.gif) - first frame only
 *
 * Images are converted to RGB565 format for the display.
 */

/* Image structure for pre-loaded images */
typedef struct {
    int width;
    int height;
    uint16_t *pixels;  /* RGB565 pixel data */
} pager_image_t;

/* Load image from file into memory. Returns NULL on error.
 * Caller must call pager_free_image() when done.
 */
pager_image_t *pager_load_image(const char *filepath);

/* Free a loaded image */
void pager_free_image(pager_image_t *img);

/* Draw a loaded image at position (x, y) */
void pager_draw_image(int x, int y, const pager_image_t *img);

/* Draw a loaded image scaled to fit dst_w x dst_h */
void pager_draw_image_scaled(int x, int y, int dst_w, int dst_h, const pager_image_t *img);

/* Load and draw image from file in one call.
 * Returns 0 on success, -1 on error.
 * Note: For repeated drawing, use pager_load_image() instead.
 */
int pager_draw_image_file(int x, int y, const char *filepath);

/* Load and draw image from file, scaled to fit.
 * Returns 0 on success, -1 on error.
 */
int pager_draw_image_file_scaled(int x, int y, int dst_w, int dst_h, const char *filepath);

/* Get image dimensions without loading the full image.
 * Returns 0 on success, -1 on error.
 */
int pager_get_image_info(const char *filepath, int *width, int *height);

#endif /* PAGERCTL_H */
