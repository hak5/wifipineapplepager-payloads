/*
 * pagerctl.c - WiFi Pineapple Pager Hardware Control Library
 */

#include "pagerctl.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <fcntl.h>
#include <time.h>
#include <errno.h>
#include <signal.h>
#include <sys/ioctl.h>
#include <sys/time.h>
#include <sys/wait.h>
#include <linux/fb.h>
#include <linux/input.h>
#include <pthread.h>

/* stb_truetype for TTF font support */
#define STB_TRUETYPE_IMPLEMENTATION
#include "stb_truetype.h"

/* stb_image for image loading (JPG, PNG, BMP, GIF) */
#define STB_IMAGE_IMPLEMENTATION
#define STBI_NO_HDR
#define STBI_NO_LINEAR
#include "stb_image.h"

/* Framebuffer state */
static int fb_fd = -1;
static uint16_t *framebuffer = NULL;
static struct timeval start_time;

/* Input state */
static int input_fd = -1;
static uint8_t prev_buttons = 0;
static uint8_t current_buttons = 0;  /* Current button state (thread-safe read) */

/* Input event queue for thread-safe event handling */
#define INPUT_QUEUE_SIZE 32
static pager_input_event_t event_queue[INPUT_QUEUE_SIZE];
static volatile int queue_head = 0;  /* Write position */
static volatile int queue_tail = 0;  /* Read position */
static pthread_mutex_t input_mutex = PTHREAD_MUTEX_INITIALIZER;

/* Random state */
static uint32_t rand_state = 1;

/* Rotation state */
static pager_rotation_t current_rotation = ROTATION_0;
static int logical_width = PAGER_FB_WIDTH;
static int logical_height = PAGER_FB_HEIGHT;

/* Hardware paths */
#define VIBRATOR_PATH "/sys/class/gpio/vibrator/value"

/* 5x7 bitmap font (ASCII 32-127) */
static const uint8_t font_5x7[][5] = {
    {0x00,0x00,0x00,0x00,0x00}, /* 32 (space) */
    {0x00,0x00,0x5F,0x00,0x00}, /* 33 ! */
    {0x00,0x07,0x00,0x07,0x00}, /* 34 " */
    {0x14,0x7F,0x14,0x7F,0x14}, /* 35 # */
    {0x24,0x2A,0x7F,0x2A,0x12}, /* 36 $ */
    {0x23,0x13,0x08,0x64,0x62}, /* 37 % */
    {0x36,0x49,0x55,0x22,0x50}, /* 38 & */
    {0x00,0x05,0x03,0x00,0x00}, /* 39 ' */
    {0x00,0x1C,0x22,0x41,0x00}, /* 40 ( */
    {0x00,0x41,0x22,0x1C,0x00}, /* 41 ) */
    {0x08,0x2A,0x1C,0x2A,0x08}, /* 42 * */
    {0x08,0x08,0x3E,0x08,0x08}, /* 43 + */
    {0x00,0x50,0x30,0x00,0x00}, /* 44 , */
    {0x08,0x08,0x08,0x08,0x08}, /* 45 - */
    {0x00,0x60,0x60,0x00,0x00}, /* 46 . */
    {0x20,0x10,0x08,0x04,0x02}, /* 47 / */
    {0x3E,0x51,0x49,0x45,0x3E}, /* 48 0 */
    {0x00,0x42,0x7F,0x40,0x00}, /* 49 1 */
    {0x42,0x61,0x51,0x49,0x46}, /* 50 2 */
    {0x21,0x41,0x45,0x4B,0x31}, /* 51 3 */
    {0x18,0x14,0x12,0x7F,0x10}, /* 52 4 */
    {0x27,0x45,0x45,0x45,0x39}, /* 53 5 */
    {0x3C,0x4A,0x49,0x49,0x30}, /* 54 6 */
    {0x01,0x71,0x09,0x05,0x03}, /* 55 7 */
    {0x36,0x49,0x49,0x49,0x36}, /* 56 8 */
    {0x06,0x49,0x49,0x29,0x1E}, /* 57 9 */
    {0x00,0x36,0x36,0x00,0x00}, /* 58 : */
    {0x00,0x56,0x36,0x00,0x00}, /* 59 ; */
    {0x00,0x08,0x14,0x22,0x41}, /* 60 < */
    {0x14,0x14,0x14,0x14,0x14}, /* 61 = */
    {0x41,0x22,0x14,0x08,0x00}, /* 62 > */
    {0x02,0x01,0x51,0x09,0x06}, /* 63 ? */
    {0x32,0x49,0x79,0x41,0x3E}, /* 64 @ */
    {0x7E,0x11,0x11,0x11,0x7E}, /* 65 A */
    {0x7F,0x49,0x49,0x49,0x36}, /* 66 B */
    {0x3E,0x41,0x41,0x41,0x22}, /* 67 C */
    {0x7F,0x41,0x41,0x22,0x1C}, /* 68 D */
    {0x7F,0x49,0x49,0x49,0x41}, /* 69 E */
    {0x7F,0x09,0x09,0x01,0x01}, /* 70 F */
    {0x3E,0x41,0x41,0x51,0x32}, /* 71 G */
    {0x7F,0x08,0x08,0x08,0x7F}, /* 72 H */
    {0x00,0x41,0x7F,0x41,0x00}, /* 73 I */
    {0x20,0x40,0x41,0x3F,0x01}, /* 74 J */
    {0x7F,0x08,0x14,0x22,0x41}, /* 75 K */
    {0x7F,0x40,0x40,0x40,0x40}, /* 76 L */
    {0x7F,0x02,0x04,0x02,0x7F}, /* 77 M */
    {0x7F,0x04,0x08,0x10,0x7F}, /* 78 N */
    {0x3E,0x41,0x41,0x41,0x3E}, /* 79 O */
    {0x7F,0x09,0x09,0x09,0x06}, /* 80 P */
    {0x3E,0x41,0x51,0x21,0x5E}, /* 81 Q */
    {0x7F,0x09,0x19,0x29,0x46}, /* 82 R */
    {0x46,0x49,0x49,0x49,0x31}, /* 83 S */
    {0x01,0x01,0x7F,0x01,0x01}, /* 84 T */
    {0x3F,0x40,0x40,0x40,0x3F}, /* 85 U */
    {0x1F,0x20,0x40,0x20,0x1F}, /* 86 V */
    {0x7F,0x20,0x18,0x20,0x7F}, /* 87 W */
    {0x63,0x14,0x08,0x14,0x63}, /* 88 X */
    {0x03,0x04,0x78,0x04,0x03}, /* 89 Y */
    {0x61,0x51,0x49,0x45,0x43}, /* 90 Z */
    {0x00,0x00,0x7F,0x41,0x41}, /* 91 [ */
    {0x02,0x04,0x08,0x10,0x20}, /* 92 \ */
    {0x41,0x41,0x7F,0x00,0x00}, /* 93 ] */
    {0x04,0x02,0x01,0x02,0x04}, /* 94 ^ */
    {0x40,0x40,0x40,0x40,0x40}, /* 95 _ */
    {0x00,0x01,0x02,0x04,0x00}, /* 96 ` */
    {0x20,0x54,0x54,0x54,0x78}, /* 97 a */
    {0x7F,0x48,0x44,0x44,0x38}, /* 98 b */
    {0x38,0x44,0x44,0x44,0x20}, /* 99 c */
    {0x38,0x44,0x44,0x48,0x7F}, /* 100 d */
    {0x38,0x54,0x54,0x54,0x18}, /* 101 e */
    {0x08,0x7E,0x09,0x01,0x02}, /* 102 f */
    {0x08,0x14,0x54,0x54,0x3C}, /* 103 g */
    {0x7F,0x08,0x04,0x04,0x78}, /* 104 h */
    {0x00,0x44,0x7D,0x40,0x00}, /* 105 i */
    {0x20,0x40,0x44,0x3D,0x00}, /* 106 j */
    {0x00,0x7F,0x10,0x28,0x44}, /* 107 k */
    {0x00,0x41,0x7F,0x40,0x00}, /* 108 l */
    {0x7C,0x04,0x18,0x04,0x78}, /* 109 m */
    {0x7C,0x08,0x04,0x04,0x78}, /* 110 n */
    {0x38,0x44,0x44,0x44,0x38}, /* 111 o */
    {0x7C,0x14,0x14,0x14,0x08}, /* 112 p */
    {0x08,0x14,0x14,0x18,0x7C}, /* 113 q */
    {0x7C,0x08,0x04,0x04,0x08}, /* 114 r */
    {0x48,0x54,0x54,0x54,0x20}, /* 115 s */
    {0x04,0x3F,0x44,0x40,0x20}, /* 116 t */
    {0x3C,0x40,0x40,0x20,0x7C}, /* 117 u */
    {0x1C,0x20,0x40,0x20,0x1C}, /* 118 v */
    {0x3C,0x40,0x30,0x40,0x3C}, /* 119 w */
    {0x44,0x28,0x10,0x28,0x44}, /* 120 x */
    {0x0C,0x50,0x50,0x50,0x3C}, /* 121 y */
    {0x44,0x64,0x54,0x4C,0x44}, /* 122 z */
    {0x00,0x08,0x36,0x41,0x00}, /* 123 { */
    {0x00,0x00,0x7F,0x00,0x00}, /* 124 | */
    {0x00,0x41,0x36,0x08,0x00}, /* 125 } */
    {0x08,0x08,0x2A,0x1C,0x08}, /* 126 ~ */
    {0x08,0x1C,0x2A,0x08,0x08}, /* 127 DEL (arrow) */
};

#define FONT_WIDTH  5
#define FONT_HEIGHT 7
#define FONT_FIRST  32
#define FONT_LAST   127

/* Signal handler for clean exit */
static volatile int running = 1;

static void signal_handler(int sig) {
    (void)sig;
    running = 0;
}

/* Forward declaration for TTF cleanup (defined at end of file) */
void pager_ttf_cleanup(void);

/*
 * Initialization
 */

int pager_init(void) {
    struct fb_var_screeninfo vinfo;
    struct fb_fix_screeninfo finfo;

    /* Set up signal handlers */
    signal(SIGINT, signal_handler);
    signal(SIGTERM, signal_handler);

    /* Open framebuffer */
    fb_fd = open("/dev/fb0", O_RDWR);
    if (fb_fd < 0) {
        perror("Failed to open /dev/fb0");
        return -1;
    }

    /* Get screen info (for verification) */
    if (ioctl(fb_fd, FBIOGET_VSCREENINFO, &vinfo) < 0) {
        perror("FBIOGET_VSCREENINFO");
        close(fb_fd);
        fb_fd = -1;
        return -1;
    }

    if (ioctl(fb_fd, FBIOGET_FSCREENINFO, &finfo) < 0) {
        perror("FBIOGET_FSCREENINFO");
        close(fb_fd);
        fb_fd = -1;
        return -1;
    }

    /* Verify dimensions */
    if (vinfo.xres != PAGER_FB_WIDTH || vinfo.yres != PAGER_FB_HEIGHT) {
        fprintf(stderr, "Warning: Expected %dx%d, got %dx%d\n",
                PAGER_FB_WIDTH, PAGER_FB_HEIGHT, vinfo.xres, vinfo.yres);
    }

    /* Allocate framebuffer */
    framebuffer = (uint16_t *)malloc(PAGER_FB_WIDTH * PAGER_FB_HEIGHT * sizeof(uint16_t));
    if (!framebuffer) {
        perror("Failed to allocate framebuffer");
        close(fb_fd);
        fb_fd = -1;
        return -1;
    }

    /* Clear to black */
    memset(framebuffer, 0, PAGER_FB_WIDTH * PAGER_FB_HEIGHT * sizeof(uint16_t));

    /* Open input device */
    input_fd = open("/dev/input/event0", O_RDONLY | O_NONBLOCK);
    if (input_fd < 0) {
        /* Try event1 as fallback */
        input_fd = open("/dev/input/event1", O_RDONLY | O_NONBLOCK);
    }
    if (input_fd < 0) {
        fprintf(stderr, "Warning: Could not open input device\n");
    }

    /* Initialize timing */
    gettimeofday(&start_time, NULL);

    /* Seed random with time */
    pager_seed_random(pager_get_ticks());

    return 0;
}

/*
 * Rotation support
 */

void pager_set_rotation(pager_rotation_t rotation) {
    current_rotation = rotation;
    switch (rotation) {
        case ROTATION_90:
        case ROTATION_270:
            logical_width = PAGER_FB_HEIGHT;   /* 480 */
            logical_height = PAGER_FB_WIDTH;   /* 222 */
            break;
        default:  /* ROTATION_0, ROTATION_180 */
            logical_width = PAGER_FB_WIDTH;    /* 222 */
            logical_height = PAGER_FB_HEIGHT;  /* 480 */
            break;
    }
}

int pager_get_width(void) {
    return logical_width;
}

int pager_get_height(void) {
    return logical_height;
}

/* Transform logical coordinates to framebuffer coordinates based on rotation */
static void transform_coords(int lx, int ly, int *fx, int *fy) {
    switch (current_rotation) {
        case ROTATION_0:   /* No rotation */
            *fx = lx;
            *fy = ly;
            break;
        case ROTATION_90:  /* 90° CW: (lx,ly) -> (ly, 479-lx) for 480x222 logical */
            *fx = ly;
            *fy = PAGER_FB_HEIGHT - 1 - lx;
            break;
        case ROTATION_180: /* 180°: (lx,ly) -> (221-lx, 479-ly) */
            *fx = PAGER_FB_WIDTH - 1 - lx;
            *fy = PAGER_FB_HEIGHT - 1 - ly;
            break;
        case ROTATION_270: /* 270° CW (90° CCW): (lx,ly) -> (221-ly, lx) for 480x222 logical */
            *fx = PAGER_FB_WIDTH - 1 - ly;
            *fy = lx;
            break;
        default:
            *fx = lx;
            *fy = ly;
            break;
    }
}

/* Raw pixel write (no rotation, direct to framebuffer) */
static void raw_set_pixel(int fx, int fy, uint16_t color) {
    if (!framebuffer) return;
    if (fx < 0 || fx >= PAGER_FB_WIDTH || fy < 0 || fy >= PAGER_FB_HEIGHT) return;
    framebuffer[fy * PAGER_FB_WIDTH + fx] = color;
}

void pager_cleanup(void) {
    /* Free TTF font cache */
    pager_ttf_cleanup();

    if (framebuffer) {
        /* Clear screen on exit */
        memset(framebuffer, 0, PAGER_FB_WIDTH * PAGER_FB_HEIGHT * sizeof(uint16_t));
        pager_flip();

        free(framebuffer);
        framebuffer = NULL;
    }

    if (fb_fd >= 0) {
        close(fb_fd);
        fb_fd = -1;
    }

    if (input_fd >= 0) {
        close(input_fd);
        input_fd = -1;
    }
}

/*
 * Frame management
 */

void pager_flip(void) {
    if (fb_fd >= 0 && framebuffer) {
        lseek(fb_fd, 0, SEEK_SET);
        write(fb_fd, framebuffer, PAGER_FB_WIDTH * PAGER_FB_HEIGHT * sizeof(uint16_t));
    }
}

void pager_clear(uint16_t color) {
    if (!framebuffer) return;

    if (color == 0) {
        memset(framebuffer, 0, PAGER_FB_WIDTH * PAGER_FB_HEIGHT * sizeof(uint16_t));
    } else {
        for (int i = 0; i < PAGER_FB_WIDTH * PAGER_FB_HEIGHT; i++) {
            framebuffer[i] = color;
        }
    }
}

uint32_t pager_get_ticks(void) {
    struct timeval now;
    gettimeofday(&now, NULL);
    return (uint32_t)((now.tv_sec - start_time.tv_sec) * 1000 +
                      (now.tv_usec - start_time.tv_usec) / 1000);
}

void pager_delay(uint32_t ms) {
    usleep(ms * 1000);
}

uint32_t pager_frame_sync(void) {
    static uint32_t last_frame = 0;
    uint32_t now = pager_get_ticks();
    uint32_t elapsed = now - last_frame;

    if (elapsed < PAGER_FRAME_MS) {
        pager_delay(PAGER_FRAME_MS - elapsed);
        now = pager_get_ticks();
        elapsed = now - last_frame;
    }

    last_frame = now;
    return elapsed;
}

/*
 * Drawing primitives
 */

void pager_set_pixel(int x, int y, uint16_t color) {
    if (!framebuffer) return;
    if (x < 0 || x >= logical_width || y < 0 || y >= logical_height) return;

    int fx, fy;
    transform_coords(x, y, &fx, &fy);
    raw_set_pixel(fx, fy, color);
}

void pager_fill_rect(int x, int y, int w, int h, uint16_t color) {
    if (!framebuffer) return;

    /* Clip to logical screen */
    int x1 = MAX(0, x);
    int y1 = MAX(0, y);
    int x2 = MIN(logical_width, x + w);
    int y2 = MIN(logical_height, y + h);

    /* For no rotation, use fast path */
    if (current_rotation == ROTATION_0) {
        for (int py = y1; py < y2; py++) {
            uint16_t *row = &framebuffer[py * PAGER_FB_WIDTH + x1];
            for (int px = x1; px < x2; px++) {
                *row++ = color;
            }
        }
    } else {
        /* With rotation, use pager_set_pixel for correctness */
        for (int py = y1; py < y2; py++) {
            for (int px = x1; px < x2; px++) {
                pager_set_pixel(px, py, color);
            }
        }
    }
}

void pager_draw_rect(int x, int y, int w, int h, uint16_t color) {
    pager_hline(x, y, w, color);
    pager_hline(x, y + h - 1, w, color);
    pager_vline(x, y, h, color);
    pager_vline(x + w - 1, y, h, color);
}

void pager_hline(int x, int y, int w, uint16_t color) {
    if (!framebuffer) return;
    if (y < 0 || y >= logical_height) return;

    int x1 = MAX(0, x);
    int x2 = MIN(logical_width, x + w);

    if (current_rotation == ROTATION_0) {
        uint16_t *row = &framebuffer[y * PAGER_FB_WIDTH + x1];
        for (int px = x1; px < x2; px++) {
            *row++ = color;
        }
    } else {
        for (int px = x1; px < x2; px++) {
            pager_set_pixel(px, y, color);
        }
    }
}

void pager_vline(int x, int y, int h, uint16_t color) {
    if (!framebuffer) return;
    if (x < 0 || x >= logical_width) return;

    int y1 = MAX(0, y);
    int y2 = MIN(logical_height, y + h);

    if (current_rotation == ROTATION_0) {
        for (int py = y1; py < y2; py++) {
            framebuffer[py * PAGER_FB_WIDTH + x] = color;
        }
    } else {
        for (int py = y1; py < y2; py++) {
            pager_set_pixel(x, py, color);
        }
    }
}

void pager_draw_line(int x0, int y0, int x1, int y1, uint16_t color) {
    int dx = ABS(x1 - x0);
    int dy = ABS(y1 - y0);
    int sx = x0 < x1 ? 1 : -1;
    int sy = y0 < y1 ? 1 : -1;
    int err = dx - dy;

    while (1) {
        pager_set_pixel(x0, y0, color);

        if (x0 == x1 && y0 == y1) break;

        int e2 = 2 * err;
        if (e2 > -dy) {
            err -= dy;
            x0 += sx;
        }
        if (e2 < dx) {
            err += dx;
            y0 += sy;
        }
    }
}

void pager_fill_circle(int cx, int cy, int r, uint16_t color) {
    for (int y = -r; y <= r; y++) {
        for (int x = -r; x <= r; x++) {
            if (x*x + y*y <= r*r) {
                pager_set_pixel(cx + x, cy + y, color);
            }
        }
    }
}

void pager_draw_circle(int cx, int cy, int r, uint16_t color) {
    int x = r;
    int y = 0;
    int err = 0;

    while (x >= y) {
        pager_set_pixel(cx + x, cy + y, color);
        pager_set_pixel(cx + y, cy + x, color);
        pager_set_pixel(cx - y, cy + x, color);
        pager_set_pixel(cx - x, cy + y, color);
        pager_set_pixel(cx - x, cy - y, color);
        pager_set_pixel(cx - y, cy - x, color);
        pager_set_pixel(cx + y, cy - x, color);
        pager_set_pixel(cx + x, cy - y, color);

        y++;
        err += 1 + 2*y;
        if (2*(err - x) + 1 > 0) {
            x--;
            err += 1 - 2*x;
        }
    }
}

/*
 * Text rendering
 */

int pager_draw_char(int x, int y, char c, uint16_t color, font_size_t size) {
    if (c < FONT_FIRST || c > FONT_LAST) c = '?';

    const uint8_t *glyph = font_5x7[c - FONT_FIRST];
    int scale = (int)size;

    for (int col = 0; col < FONT_WIDTH; col++) {
        uint8_t column = glyph[col];
        for (int row = 0; row < FONT_HEIGHT; row++) {
            if (column & (1 << row)) {
                for (int sy = 0; sy < scale; sy++) {
                    for (int sx = 0; sx < scale; sx++) {
                        pager_set_pixel(x + col * scale + sx,
                                       y + row * scale + sy,
                                       color);
                    }
                }
            }
        }
    }

    return (FONT_WIDTH + 1) * scale;
}

int pager_draw_text(int x, int y, const char *text, uint16_t color, font_size_t size) {
    if (!text) return 0;

    int start_x = x;

    while (*text) {
        if (*text == '\n') {
            x = start_x;
            y += (FONT_HEIGHT + 1) * (int)size;
        } else {
            x += pager_draw_char(x, y, *text, color, size);
        }
        text++;
    }

    return x - start_x;
}

void pager_draw_text_centered(int y, const char *text, uint16_t color, font_size_t size) {
    if (!text) return;

    int width = pager_text_width(text, size);
    int x = (logical_width - width) / 2;
    pager_draw_text(x, y, text, color, size);
}

int pager_text_width(const char *text, font_size_t size) {
    if (!text) return 0;

    int width = 0;
    int scale = (int)size;

    while (*text) {
        if (*text != '\n') {
            width += (FONT_WIDTH + 1) * scale;
        }
        text++;
    }

    if (width > 0) width -= scale; /* Remove trailing space */
    return width;
}

int pager_draw_number(int x, int y, int num, uint16_t color, font_size_t size) {
    char buf[16];
    snprintf(buf, sizeof(buf), "%d", num);
    return pager_draw_text(x, y, buf, color, size);
}

/*
 * Input handling
 */

/* Linux evdev key codes for Pager buttons */
#define KEY_PAGER_UP     103  /* KEY_UP */
#define KEY_PAGER_DOWN   108  /* KEY_DOWN */
#define KEY_PAGER_LEFT   105  /* KEY_LEFT */
#define KEY_PAGER_RIGHT  106  /* KEY_RIGHT */
#define KEY_PAGER_A      305  /* BTN_EAST (Green/A) - swapped */
#define KEY_PAGER_B      304  /* BTN_SOUTH (Red/B) - swapped */
#define KEY_PAGER_POWER  116  /* KEY_POWER */

/* Queue an input event (internal, called with mutex held) */
static void queue_input_event(uint8_t button, pager_event_type_t type) {
    int next_head = (queue_head + 1) % INPUT_QUEUE_SIZE;

    /* If queue is full, drop oldest event */
    if (next_head == queue_tail) {
        queue_tail = (queue_tail + 1) % INPUT_QUEUE_SIZE;
    }

    event_queue[queue_head].button = button;
    event_queue[queue_head].type = type;
    event_queue[queue_head].timestamp = pager_get_ticks();
    queue_head = next_head;
}

void pager_poll_input(pager_input_t *input) {
    if (!input) return;

    struct input_event ev;
    uint8_t new_buttons = prev_buttons;

    if (input_fd < 0) {
        input->current = 0;
        input->pressed = 0;
        input->released = 0;
        return;
    }

    pthread_mutex_lock(&input_mutex);

    /* Read all pending events */
    while (read(input_fd, &ev, sizeof(ev)) == sizeof(ev)) {
        if (ev.type != EV_KEY) continue;

        uint8_t btn = 0;
        switch (ev.code) {
            case KEY_PAGER_UP:    btn = PBTN_UP;    break;
            case KEY_PAGER_DOWN:  btn = PBTN_DOWN;  break;
            case KEY_PAGER_LEFT:  btn = PBTN_LEFT;  break;
            case KEY_PAGER_RIGHT: btn = PBTN_RIGHT; break;
            case KEY_PAGER_A:     btn = PBTN_A;     break;
            case KEY_PAGER_B:     btn = PBTN_B;     break;
            case KEY_PAGER_POWER: btn = PBTN_POWER; break;
            default: continue;
        }

        if (ev.value == 1) {
            new_buttons |= btn;  /* Press */
            queue_input_event(btn, PAGER_EVENT_PRESS);
        } else if (ev.value == 0) {
            new_buttons &= ~btn; /* Release */
            queue_input_event(btn, PAGER_EVENT_RELEASE);
        }
    }

    input->current = new_buttons;
    input->pressed = new_buttons & ~prev_buttons;
    input->released = ~new_buttons & prev_buttons;

    prev_buttons = new_buttons;
    current_buttons = new_buttons;  /* Update thread-safe state */

    pthread_mutex_unlock(&input_mutex);
}

/*
 * Thread-safe input event queue functions
 */

int pager_get_input_event(pager_input_event_t *event) {
    if (!event) return 0;

    pthread_mutex_lock(&input_mutex);

    /* First, read any new events from the device */
    struct input_event ev;
    while (input_fd >= 0 && read(input_fd, &ev, sizeof(ev)) == sizeof(ev)) {
        if (ev.type != EV_KEY) continue;

        uint8_t btn = 0;
        switch (ev.code) {
            case KEY_PAGER_UP:    btn = PBTN_UP;    break;
            case KEY_PAGER_DOWN:  btn = PBTN_DOWN;  break;
            case KEY_PAGER_LEFT:  btn = PBTN_LEFT;  break;
            case KEY_PAGER_RIGHT: btn = PBTN_RIGHT; break;
            case KEY_PAGER_A:     btn = PBTN_A;     break;
            case KEY_PAGER_B:     btn = PBTN_B;     break;
            case KEY_PAGER_POWER: btn = PBTN_POWER; break;
            default: continue;
        }

        if (ev.value == 1) {
            current_buttons |= btn;
            queue_input_event(btn, PAGER_EVENT_PRESS);
        } else if (ev.value == 0) {
            current_buttons &= ~btn;
            queue_input_event(btn, PAGER_EVENT_RELEASE);
        }
    }

    /* Check if queue has events */
    if (queue_head == queue_tail) {
        pthread_mutex_unlock(&input_mutex);
        return 0;  /* No events */
    }

    /* Get event from queue */
    *event = event_queue[queue_tail];
    queue_tail = (queue_tail + 1) % INPUT_QUEUE_SIZE;

    pthread_mutex_unlock(&input_mutex);
    return 1;  /* Event retrieved */
}

int pager_has_input_events(void) {
    pthread_mutex_lock(&input_mutex);

    /* First, read any new events from the device */
    struct input_event ev;
    while (input_fd >= 0 && read(input_fd, &ev, sizeof(ev)) == sizeof(ev)) {
        if (ev.type != EV_KEY) continue;

        uint8_t btn = 0;
        switch (ev.code) {
            case KEY_PAGER_UP:    btn = PBTN_UP;    break;
            case KEY_PAGER_DOWN:  btn = PBTN_DOWN;  break;
            case KEY_PAGER_LEFT:  btn = PBTN_LEFT;  break;
            case KEY_PAGER_RIGHT: btn = PBTN_RIGHT; break;
            case KEY_PAGER_A:     btn = PBTN_A;     break;
            case KEY_PAGER_B:     btn = PBTN_B;     break;
            case KEY_PAGER_POWER: btn = PBTN_POWER; break;
            default: continue;
        }

        if (ev.value == 1) {
            current_buttons |= btn;
            queue_input_event(btn, PAGER_EVENT_PRESS);
        } else if (ev.value == 0) {
            current_buttons &= ~btn;
            queue_input_event(btn, PAGER_EVENT_RELEASE);
        }
    }

    int has_events = (queue_head != queue_tail);
    pthread_mutex_unlock(&input_mutex);
    return has_events;
}

uint8_t pager_peek_buttons(void) {
    /* Atomic read of current button state - no mutex needed for single byte */
    return current_buttons;
}

void pager_clear_input_events(void) {
    pthread_mutex_lock(&input_mutex);
    queue_head = 0;
    queue_tail = 0;
    pthread_mutex_unlock(&input_mutex);
}

pager_button_t pager_wait_button(void) {
    pager_input_t input;

    /* Clear any pending input */
    pager_poll_input(&input);

    while (running) {
        pager_poll_input(&input);
        if (input.pressed) {
            return (pager_button_t)input.pressed;
        }
        pager_delay(10);
    }

    return BTN_NONE;
}

/*
 * Utility functions
 */

int pager_random(int max) {
    if (max <= 0) return 0;

    /* xorshift32 */
    rand_state ^= rand_state << 13;
    rand_state ^= rand_state >> 17;
    rand_state ^= rand_state << 5;

    return (int)(rand_state % (uint32_t)max);
}

void pager_seed_random(uint32_t seed) {
    rand_state = seed ? seed : 1;
}

/*
 * Audio - RTTTL playback via system RINGTONE command
 */

static pid_t audio_pid = 0;

/* Note frequencies (C4 = middle C = 262 Hz) */
static const int note_freqs[] = {
    /* C     C#    D     D#    E     F     F#    G     G#    A     A#    B  */
       262,  277,  294,  311,  330,  349,  370,  392,  415,  440,  466,  494,  /* Octave 4 */
};

/* Get frequency for a note (0=C, 1=C#, ... 11=B) and octave (1-8) */
static int get_note_freq(int note, int octave) {
    int base_freq = note_freqs[note % 12];
    int oct_diff = octave - 4;
    if (oct_diff > 0) {
        while (oct_diff-- > 0) base_freq *= 2;
    } else if (oct_diff < 0) {
        while (oct_diff++ < 0) base_freq /= 2;
    }
    return base_freq;
}

/* Parse and play RTTTL in child process with mode support */
static void play_rtttl_child_ex(const char *rtttl, int mode) {
    /* mode: 0=sound only, 1=sound+vibrate, 2=vibrate only */

    /* Skip name (everything before first colon) */
    const char *p = strchr(rtttl, ':');
    if (!p) return;
    p++;

    /* Parse defaults: d=duration, o=octave, b=bpm */
    int def_duration = 4;
    int def_octave = 5;
    int bpm = 120;

    while (*p && *p != ':') {
        while (*p == ' ' || *p == ',') p++;
        if (*p == 'd' && *(p+1) == '=') {
            p += 2;
            def_duration = atoi(p);
            while (*p >= '0' && *p <= '9') p++;
        } else if (*p == 'o' && *(p+1) == '=') {
            p += 2;
            def_octave = atoi(p);
            while (*p >= '0' && *p <= '9') p++;
        } else if (*p == 'b' && *(p+1) == '=') {
            p += 2;
            bpm = atoi(p);
            while (*p >= '0' && *p <= '9') p++;
        } else {
            p++;
        }
    }

    if (*p == ':') p++;

    /* Protect against division by zero */
    if (bpm <= 0) bpm = 120;

    /* Calculate whole note duration in ms */
    int whole_note_ms = (60 * 1000 * 4) / bpm;
    int use_sound = (mode == 0 || mode == 1);
    int use_vibrate = (mode == 1 || mode == 2);

    /* Parse and play notes */
    while (*p) {
        while (*p == ' ' || *p == ',') p++;
        if (!*p) break;

        /* Parse duration (optional, before note) */
        int duration = def_duration;
        if (*p >= '0' && *p <= '9') {
            duration = atoi(p);
            while (*p >= '0' && *p <= '9') p++;
        }

        /* Parse note */
        int note = -1;  /* -1 = rest */
        switch (*p) {
            case 'c': case 'C': note = 0; break;
            case 'd': case 'D': note = 2; break;
            case 'e': case 'E': note = 4; break;
            case 'f': case 'F': note = 5; break;
            case 'g': case 'G': note = 7; break;
            case 'a': case 'A': note = 9; break;
            case 'b': case 'B': note = 11; break;
            case 'h': case 'H': note = 11; break;  /* European B */
            case 'p': case 'P': note = -1; break;  /* Pause/rest */
        }
        if (*p) p++;

        /* Check for sharp */
        if (*p == '#') {
            if (note >= 0) note++;
            p++;
        }

        /* Check for dotted note */
        int dotted = 0;
        if (*p == '.') {
            dotted = 1;
            p++;
        }

        /* Parse octave (optional, after note) */
        int octave = def_octave;
        if (*p >= '0' && *p <= '9') {
            octave = *p - '0';
            p++;
        }

        /* Check for dotted note again (can appear after octave) */
        if (*p == '.') {
            dotted = 1;
            p++;
        }

        /* Calculate duration in ms */
        int note_ms = whole_note_ms / duration;
        if (dotted) note_ms = note_ms + note_ms / 2;

        /* Play the note */
        if (note >= 0) {
            int freq = get_note_freq(note, octave);

            /* Start sound if enabled */
            if (use_sound) {
                FILE *f = fopen("/sys/class/leds/buzzer/frequency", "w");
                if (f) { fprintf(f, "%d", freq); fclose(f); }
                f = fopen("/sys/class/leds/buzzer/brightness", "w");
                if (f) { fprintf(f, "255"); fclose(f); }
            }

            /* Start vibration if enabled */
            if (use_vibrate) {
                FILE *vf = fopen(VIBRATOR_PATH, "w");
                if (vf) { fprintf(vf, "1"); fclose(vf); }
            }

            usleep(note_ms * 900);  /* 90% tone */

            /* Stop sound */
            if (use_sound) {
                FILE *f = fopen("/sys/class/leds/buzzer/brightness", "w");
                if (f) { fprintf(f, "0"); fclose(f); }
            }

            /* Stop vibration */
            if (use_vibrate) {
                FILE *vf = fopen(VIBRATOR_PATH, "w");
                if (vf) { fprintf(vf, "0"); fclose(vf); }
            }

            usleep(note_ms * 100);  /* 10% gap */
        } else {
            /* Rest - ensure vibration is off */
            if (use_vibrate) {
                FILE *vf = fopen(VIBRATOR_PATH, "w");
                if (vf) { fprintf(vf, "0"); fclose(vf); }
            }
            usleep(note_ms * 1000);
        }
    }

    /* Ensure everything is off */
    if (use_sound) {
        FILE *f = fopen("/sys/class/leds/buzzer/brightness", "w");
        if (f) { fprintf(f, "0"); fclose(f); }
    }
    if (use_vibrate) {
        FILE *vf = fopen(VIBRATOR_PATH, "w");
        if (vf) { fprintf(vf, "0"); fclose(vf); }
    }
}

void pager_play_rtttl(const char *rtttl) {
    if (!rtttl) return;

    /* Stop any existing audio first */
    pager_stop_audio();

    /* Fork to play in background */
    audio_pid = fork();
    if (audio_pid == 0) {
        /* Child process - play RTTTL directly via buzzer sysfs */
        play_rtttl_child_ex(rtttl, 0);  /* Sound only */
        _exit(0);
    }
}

void pager_play_rtttl_ex(const char *rtttl, rtttl_mode_t mode) {
    if (!rtttl) return;

    /* Stop any existing audio first */
    pager_stop_audio();

    /* Fork to play in background */
    audio_pid = fork();
    if (audio_pid == 0) {
        /* Child process */
        play_rtttl_child_ex(rtttl, mode);
        _exit(0);
    }
}

void pager_stop_audio(void) {
    /* Turn off the buzzer hardware FIRST */
    FILE *f = fopen("/sys/class/leds/buzzer/brightness", "w");
    if (f) { fprintf(f, "0"); fclose(f); }

    /* Also turn off the vibrator */
    f = fopen(VIBRATOR_PATH, "w");
    if (f) { fprintf(f, "0"); fclose(f); }

    if (audio_pid > 0) {
        kill(audio_pid, SIGKILL);  /* Use SIGKILL for immediate stop */
        kill(-audio_pid, SIGKILL); /* Kill process group too */
        waitpid(audio_pid, NULL, WNOHANG);  /* Non-blocking wait */
        audio_pid = 0;
    }

    /* Kill any stray audio processes */
    system("killall -9 RINGTONE 2>/dev/null");

    /* Turn off buzzer again to be sure */
    f = fopen("/sys/class/leds/buzzer/brightness", "w");
    if (f) { fprintf(f, "0"); fclose(f); }
}

int pager_audio_playing(void) {
    if (audio_pid <= 0) return 0;

    int status;
    pid_t result = waitpid(audio_pid, &status, WNOHANG);
    if (result == audio_pid) {
        /* Process finished */
        audio_pid = 0;
        return 0;
    }
    return 1;
}

/*
 * ============================================================
 * VIBRATION SUPPORT
 * ============================================================
 */

void pager_vibrate(int duration_ms) {
    FILE *f = fopen(VIBRATOR_PATH, "w");
    if (f) { fprintf(f, "1"); fclose(f); }
    usleep(duration_ms * 1000);
    f = fopen(VIBRATOR_PATH, "w");
    if (f) { fprintf(f, "0"); fclose(f); }
}

void pager_vibrate_pattern(const char *pattern) {
    if (!pattern) return;

    char buf[256];
    strncpy(buf, pattern, sizeof(buf) - 1);
    buf[sizeof(buf) - 1] = '\0';
    
    int is_on = 1;
    char *token = strtok(buf, ",");
    FILE *f;
    
    while (token) {
        int duration = atoi(token);
        if (duration > 0) {
            f = fopen(VIBRATOR_PATH, "w");
            if (f) { fprintf(f, is_on ? "1" : "0"); fclose(f); }
            usleep(duration * 1000);
        }
        is_on = !is_on;
        token = strtok(NULL, ",");
    }
    
    f = fopen(VIBRATOR_PATH, "w");
    if (f) { fprintf(f, "0"); fclose(f); }
}

/*
 * ============================================================
 * LED SUPPORT
 * ============================================================
 */

#define LED_BASE_PATH "/sys/class/leds"

void pager_led_set(const char *name, int brightness) {
    if (!name) return;

    char path[256];
    snprintf(path, sizeof(path), "%s/%s/brightness", LED_BASE_PATH, name);
    FILE *f = fopen(path, "w");
    if (f) { fprintf(f, "%d", brightness); fclose(f); }
}

void pager_led_rgb(const char *button, uint8_t r, uint8_t g, uint8_t b) {
    if (!button) return;

    char path[256];
    FILE *f;

    snprintf(path, sizeof(path), "%s/%s-led-red/brightness", LED_BASE_PATH, button);
    f = fopen(path, "w");
    if (f) { fprintf(f, "%d", r); fclose(f); }

    snprintf(path, sizeof(path), "%s/%s-led-green/brightness", LED_BASE_PATH, button);
    f = fopen(path, "w");
    if (f) { fprintf(f, "%d", g); fclose(f); }

    snprintf(path, sizeof(path), "%s/%s-led-blue/brightness", LED_BASE_PATH, button);
    f = fopen(path, "w");
    if (f) { fprintf(f, "%d", b); fclose(f); }
}

void pager_led_dpad(const char *direction, uint32_t color) {
    if (!direction) return;

    uint8_t r = (color >> 16) & 0xFF;
    uint8_t g = (color >> 8) & 0xFF;
    uint8_t b = color & 0xFF;
    pager_led_rgb(direction, r, g, b);
}

void pager_led_all_off(void) {
    pager_led_set("a-button-led", 0);
    pager_led_set("b-button-led", 0);
    pager_led_dpad("up", 0);
    pager_led_dpad("down", 0);
    pager_led_dpad("left", 0);
    pager_led_dpad("right", 0);
}

/*
 * ============================================================
 * SIMPLE BEEP (blocking, for quick sound effects)
 * ============================================================
 */

void pager_beep(int freq, int duration_ms) {
    FILE *f;
    
    f = fopen("/sys/class/leds/buzzer/frequency", "w");
    if (f) { fprintf(f, "%d", freq); fclose(f); }
    
    f = fopen("/sys/class/leds/buzzer/brightness", "w");
    if (f) { fprintf(f, "255"); fclose(f); }
    
    usleep(duration_ms * 1000);
    
    f = fopen("/sys/class/leds/buzzer/brightness", "w");
    if (f) { fprintf(f, "0"); fclose(f); }
}

/*
 * ============================================================
 * RTTTL WITH VIBRATION (blocking, plays synchronously)
 * ============================================================
 */

void pager_play_rtttl_sync(const char *rtttl, int with_vibration) {
    if (!rtttl) return;

    /* Use the existing child function but in this process */
    /* This is blocking - use pager_play_rtttl for background */

    /* Simple implementation - parse and play inline */
    const char *p = rtttl;
    int default_dur = 4, default_oct = 5, bpm = 120;
    
    /* Skip name */
    while (*p && *p != ':') p++;
    if (*p == ':') p++;
    
    /* Parse defaults */
    while (*p && *p != ':') {
        if (*p == 'd' || *p == 'D') {
            p++;
            if (*p == '=') p++;
            default_dur = atoi(p);
        } else if (*p == 'o' || *p == 'O') {
            p++;
            if (*p == '=') p++;
            default_oct = atoi(p);
        } else if (*p == 'b' || *p == 'B') {
            p++;
            if (*p == '=') p++;
            bpm = atoi(p);
        }
        while (*p && *p != ',' && *p != ':') p++;
        if (*p == ',') p++;
    }
    if (*p == ':') p++;

    /* Protect against division by zero */
    if (bpm <= 0) bpm = 120;

    int whole_note_ms = (60000 * 4) / bpm;
    FILE *vib_f = NULL;
    
    /* Parse and play notes */
    while (*p) {
        while (*p == ' ' || *p == ',') p++;
        if (!*p) break;
        
        int duration = default_dur;
        int octave = default_oct;
        int note = -1;
        int sharp = 0;
        int dotted = 0;
        
        /* Duration prefix */
        if (*p >= '0' && *p <= '9') {
            duration = atoi(p);
            while (*p >= '0' && *p <= '9') p++;
        }
        
        /* Note */
        switch (*p) {
            case 'c': case 'C': note = 0; break;
            case 'd': case 'D': note = 2; break;
            case 'e': case 'E': note = 4; break;
            case 'f': case 'F': note = 5; break;
            case 'g': case 'G': note = 7; break;
            case 'a': case 'A': note = 9; break;
            case 'b': case 'B': note = 11; break;
            case 'p': case 'P': note = -1; break;
        }
        if (*p) p++;
        
        /* Sharp */
        if (*p == '#') { sharp = 1; p++; }
        
        /* Dotted */
        if (*p == '.') { dotted = 1; p++; }
        
        /* Octave suffix */
        if (*p >= '0' && *p <= '9') {
            octave = *p - '0';
            p++;
        }
        
        int note_ms = whole_note_ms / duration;
        if (dotted) note_ms = note_ms * 3 / 2;
        
        if (note >= 0) {
            /* Calculate frequency */
            static const int base_freqs[] = {262, 277, 294, 311, 330, 349, 370, 392, 415, 440, 466, 494};
            int freq = base_freqs[(note + sharp) % 12];
            int oct_diff = octave - 4;
            if (oct_diff > 0) for (int i = 0; i < oct_diff; i++) freq *= 2;
            else if (oct_diff < 0) for (int i = 0; i < -oct_diff; i++) freq /= 2;
            
            /* Play tone */
            FILE *f = fopen("/sys/class/leds/buzzer/frequency", "w");
            if (f) { fprintf(f, "%d", freq); fclose(f); }
            f = fopen("/sys/class/leds/buzzer/brightness", "w");
            if (f) { fprintf(f, "255"); fclose(f); }
            
            if (with_vibration) {
                vib_f = fopen(VIBRATOR_PATH, "w");
                if (vib_f) { fprintf(vib_f, "1"); fclose(vib_f); }
            }
            
            usleep(note_ms * 900);
            
            f = fopen("/sys/class/leds/buzzer/brightness", "w");
            if (f) { fprintf(f, "0"); fclose(f); }
            
            if (with_vibration) {
                vib_f = fopen(VIBRATOR_PATH, "w");
                if (vib_f) { fprintf(vib_f, "0"); fclose(vib_f); }
            }
            
            usleep(note_ms * 100);
        } else {
            /* Rest */
            if (with_vibration) {
                vib_f = fopen(VIBRATOR_PATH, "w");
                if (vib_f) { fprintf(vib_f, "0"); fclose(vib_f); }
            }
            usleep(note_ms * 1000);
        }
    }
    
    /* Ensure off */
    FILE *f = fopen("/sys/class/leds/buzzer/brightness", "w");
    if (f) { fprintf(f, "0"); fclose(f); }
    if (with_vibration) {
        vib_f = fopen(VIBRATOR_PATH, "w");
        if (vib_f) { fprintf(vib_f, "0"); fclose(vib_f); }
    }
}

/*
 * ============================================================
 * BACKLIGHT / BRIGHTNESS CONTROL
 * ============================================================
 */

/* Cached backlight path (found once on first use) */
static char backlight_path[256] = {0};
static int backlight_path_checked = 0;
static int max_brightness_cached = -1;

/* Find the backlight sysfs path */
static const char *find_backlight_path(void) {
    if (backlight_path_checked) {
        return backlight_path[0] ? backlight_path : NULL;
    }
    backlight_path_checked = 1;

    /* Common backlight paths on embedded Linux */
    const char *candidates[] = {
        "/sys/class/backlight/backlight",
        "/sys/class/backlight/lcd-backlight",
        "/sys/class/backlight/panel0-backlight",
        NULL
    };

    for (int i = 0; candidates[i]; i++) {
        char test_path[300];
        snprintf(test_path, sizeof(test_path), "%s/brightness", candidates[i]);
        if (access(test_path, W_OK) == 0) {
            strncpy(backlight_path, candidates[i], sizeof(backlight_path) - 1);
            return backlight_path;
        }
    }

    /* Try glob pattern as fallback */
    FILE *fp = popen("ls -d /sys/class/backlight/*/brightness 2>/dev/null | head -1", "r");
    if (fp) {
        char buf[256];
        if (fgets(buf, sizeof(buf), fp)) {
            /* Remove trailing newline and /brightness */
            char *nl = strchr(buf, '\n');
            if (nl) *nl = '\0';
            char *last_slash = strrchr(buf, '/');
            if (last_slash) *last_slash = '\0';
            strncpy(backlight_path, buf, sizeof(backlight_path) - 1);
            backlight_path[sizeof(backlight_path) - 1] = '\0';
        }
        pclose(fp);
    }

    return backlight_path[0] ? backlight_path : NULL;
}

int pager_get_max_brightness(void) {
    if (max_brightness_cached >= 0) {
        return max_brightness_cached;
    }

    const char *path = find_backlight_path();
    if (!path) return -1;

    char filepath[300];
    snprintf(filepath, sizeof(filepath), "%s/max_brightness", path);

    FILE *f = fopen(filepath, "r");
    if (!f) return -1;

    int value = -1;
    if (fscanf(f, "%d", &value) == 1) {
        max_brightness_cached = value;
    }
    fclose(f);
    return max_brightness_cached;
}

int pager_get_brightness(void) {
    const char *path = find_backlight_path();
    if (!path) return -1;

    char filepath[300];
    snprintf(filepath, sizeof(filepath), "%s/brightness", path);

    FILE *f = fopen(filepath, "r");
    if (!f) return -1;

    int value = -1;
    fscanf(f, "%d", &value);
    fclose(f);

    int max_val = pager_get_max_brightness();
    if (max_val <= 0 || value < 0) return -1;

    return (value * 100) / max_val;
}

int pager_set_brightness(int percent) {
    const char *path = find_backlight_path();
    if (!path) return -1;

    int max_val = pager_get_max_brightness();
    if (max_val <= 0) return -1;

    /* Clamp percent to 0-100 */
    if (percent < 0) percent = 0;
    if (percent > 100) percent = 100;

    int value = (max_val * percent) / 100;

    char filepath[300];
    snprintf(filepath, sizeof(filepath), "%s/brightness", path);

    FILE *f = fopen(filepath, "w");
    if (!f) return -1;

    fprintf(f, "%d", value);
    fflush(f);
    fclose(f);
    return 0;
}

int pager_screen_off(void) {
    /* Setting brightness to 10% or below turns off the backlight on Pager */
    return pager_set_brightness(10);
}

int pager_screen_on(void) {
    /* Restore screen to a reasonable default brightness */
    return pager_set_brightness(80);
}

/*
 * ============================================================
 * TTF FONT SUPPORT
 * ============================================================
 */

/* Cached font for performance */
static unsigned char *cached_font_data = NULL;
static size_t cached_font_size = 0;
static char cached_font_path[256] = {0};
static stbtt_fontinfo cached_font_info;
static int cached_font_valid = 0;

/* Load TTF font file into memory */
static unsigned char *load_font_file(const char *filename, size_t *size) {
    FILE *f = fopen(filename, "rb");
    if (!f) return NULL;

    fseek(f, 0, SEEK_END);
    *size = ftell(f);
    fseek(f, 0, SEEK_SET);

    unsigned char *data = malloc(*size);
    if (data) {
        fread(data, 1, *size, f);
    }
    fclose(f);
    return data;
}

/* Get or load cached font */
static int get_cached_font(const char *font_path, stbtt_fontinfo **font) {
    /* Null check to prevent crash */
    if (!font_path || !font) return -1;

    /* Check if already cached */
    if (cached_font_valid && strcmp(cached_font_path, font_path) == 0) {
        *font = &cached_font_info;
        return 0;
    }

    /* Free previous cache */
    if (cached_font_data) {
        free(cached_font_data);
        cached_font_data = NULL;
        cached_font_valid = 0;
    }

    /* Load new font */
    cached_font_data = load_font_file(font_path, &cached_font_size);
    if (!cached_font_data) {
        return -1;
    }

    if (!stbtt_InitFont(&cached_font_info, cached_font_data, 0)) {
        free(cached_font_data);
        cached_font_data = NULL;
        return -1;
    }

    strncpy(cached_font_path, font_path, sizeof(cached_font_path) - 1);
    cached_font_valid = 1;
    *font = &cached_font_info;
    return 0;
}

/* Free cached font (call on cleanup) */
void pager_ttf_cleanup(void) {
    if (cached_font_data) {
        free(cached_font_data);
        cached_font_data = NULL;
        cached_font_size = 0;
        cached_font_path[0] = '\0';
        cached_font_valid = 0;
    }
}

/* Draw TTF text at position */
int pager_draw_ttf(int x, int y, const char *text, uint16_t color,
                   const char *font_path, float font_size) {
    /* Null check to prevent crash */
    if (!text) return 0;

    stbtt_fontinfo *font;
    if (get_cached_font(font_path, &font) < 0) {
        return -1;
    }

    float scale = stbtt_ScaleForPixelHeight(font, font_size);

    int ascent, descent, line_gap;
    stbtt_GetFontVMetrics(font, &ascent, &descent, &line_gap);
    int baseline = (int)(ascent * scale);

    int cursor_x = x;

    for (const char *p = text; *p; p++) {
        int ch = *p;

        /* Get character metrics */
        int advance, lsb;
        stbtt_GetCodepointHMetrics(font, ch, &advance, &lsb);

        /* Get bitmap */
        int w, h, xoff, yoff;
        unsigned char *bitmap = stbtt_GetCodepointBitmap(font, 0, scale, ch, &w, &h, &xoff, &yoff);

        if (bitmap) {
            /* Draw bitmap with alpha blending */
            for (int row = 0; row < h; row++) {
                for (int col = 0; col < w; col++) {
                    unsigned char alpha = bitmap[row * w + col];
                    if (alpha > 32) {  /* Threshold for anti-aliasing */
                        pager_set_pixel(cursor_x + xoff + col,
                                       y + baseline + yoff + row, color);
                    }
                }
            }
            stbtt_FreeBitmap(bitmap, NULL);
        }

        cursor_x += (int)(advance * scale);

        /* Kerning adjustment */
        if (*(p + 1)) {
            cursor_x += (int)(stbtt_GetCodepointKernAdvance(font, ch, *(p + 1)) * scale);
        }
    }

    return cursor_x - x;  /* Return width drawn */
}

/* Get width of TTF text */
int pager_ttf_width(const char *text, const char *font_path, float font_size) {
    /* Null check to prevent crash */
    if (!text) return 0;

    stbtt_fontinfo *font;
    if (get_cached_font(font_path, &font) < 0) {
        return -1;
    }

    float scale = stbtt_ScaleForPixelHeight(font, font_size);
    int width = 0;

    for (const char *p = text; *p; p++) {
        int advance, lsb;
        stbtt_GetCodepointHMetrics(font, *p, &advance, &lsb);
        width += (int)(advance * scale);

        if (*(p + 1)) {
            width += (int)(stbtt_GetCodepointKernAdvance(font, *p, *(p + 1)) * scale);
        }
    }

    return width;
}

/* Get height of TTF font */
int pager_ttf_height(const char *font_path, float font_size) {
    if (!font_path) return -1;

    stbtt_fontinfo *font;
    if (get_cached_font(font_path, &font) < 0) {
        return -1;
    }

    float scale = stbtt_ScaleForPixelHeight(font, font_size);
    int ascent, descent, line_gap;
    stbtt_GetFontVMetrics(font, &ascent, &descent, &line_gap);

    return (int)((ascent - descent) * scale);
}

/* Draw centered TTF text */
void pager_draw_ttf_centered(int y, const char *text, uint16_t color,
                             const char *font_path, float font_size) {
    if (!text || !font_path) return;

    int width = pager_ttf_width(text, font_path, font_size);
    if (width > 0) {
        int x = (logical_width - width) / 2;
        pager_draw_ttf(x, y, text, color, font_path, font_size);
    }
}

/* Draw right-aligned TTF text */
void pager_draw_ttf_right(int y, const char *text, uint16_t color,
                          const char *font_path, float font_size, int padding) {
    if (!text || !font_path) return;

    int width = pager_ttf_width(text, font_path, font_size);
    if (width > 0) {
        int x = logical_width - width - padding;
        pager_draw_ttf(x, y, text, color, font_path, font_size);
    }
}

/*
 * ============================================================
 * IMAGE SUPPORT (JPG, PNG, BMP, GIF via stb_image)
 * ============================================================
 */

/* Convert RGB888 to RGB565 */
static inline uint16_t rgb888_to_rgb565(uint8_t r, uint8_t g, uint8_t b) {
    return ((r & 0xF8) << 8) | ((g & 0xFC) << 3) | (b >> 3);
}

/* Load image from file and return pager_image_t structure */
pager_image_t *pager_load_image(const char *filepath) {
    if (!filepath) return NULL;

    int width, height, channels;

    /* Load image - request RGB (3 channels) */
    unsigned char *data = stbi_load(filepath, &width, &height, &channels, 3);
    if (!data) {
        fprintf(stderr, "Failed to load image: %s\n", filepath);
        return NULL;
    }

    /* Allocate image structure */
    pager_image_t *img = malloc(sizeof(pager_image_t));
    if (!img) {
        stbi_image_free(data);
        return NULL;
    }

    /* Allocate RGB565 pixel buffer */
    img->pixels = malloc(width * height * sizeof(uint16_t));
    if (!img->pixels) {
        free(img);
        stbi_image_free(data);
        return NULL;
    }

    img->width = width;
    img->height = height;

    /* Convert RGB888 to RGB565 */
    for (int i = 0; i < width * height; i++) {
        uint8_t r = data[i * 3 + 0];
        uint8_t g = data[i * 3 + 1];
        uint8_t b = data[i * 3 + 2];
        img->pixels[i] = rgb888_to_rgb565(r, g, b);
    }

    stbi_image_free(data);
    return img;
}

/* Free a loaded image */
void pager_free_image(pager_image_t *img) {
    if (img) {
        if (img->pixels) {
            free(img->pixels);
        }
        free(img);
    }
}

/* Draw a loaded image at position */
void pager_draw_image(int x, int y, const pager_image_t *img) {
    if (!img || !img->pixels || !framebuffer) return;

    for (int iy = 0; iy < img->height; iy++) {
        int screen_y = y + iy;
        if (screen_y < 0 || screen_y >= logical_height) continue;

        for (int ix = 0; ix < img->width; ix++) {
            int screen_x = x + ix;
            if (screen_x < 0 || screen_x >= logical_width) continue;

            pager_set_pixel(screen_x, screen_y, img->pixels[iy * img->width + ix]);
        }
    }
}

/* Draw a loaded image scaled to fit width x height */
void pager_draw_image_scaled(int x, int y, int dst_w, int dst_h, const pager_image_t *img) {
    if (!img || !img->pixels || !framebuffer) return;
    if (dst_w <= 0 || dst_h <= 0) return;

    /* Use nearest-neighbor scaling for speed */
    for (int dy = 0; dy < dst_h; dy++) {
        int screen_y = y + dy;
        if (screen_y < 0 || screen_y >= logical_height) continue;

        int src_y = (dy * img->height) / dst_h;

        for (int dx = 0; dx < dst_w; dx++) {
            int screen_x = x + dx;
            if (screen_x < 0 || screen_x >= logical_width) continue;

            int src_x = (dx * img->width) / dst_w;
            pager_set_pixel(screen_x, screen_y, img->pixels[src_y * img->width + src_x]);
        }
    }
}

/* Load and draw image from file in one call (convenience function) */
int pager_draw_image_file(int x, int y, const char *filepath) {
    if (!filepath) return -1;

    pager_image_t *img = pager_load_image(filepath);
    if (!img) return -1;

    pager_draw_image(x, y, img);
    pager_free_image(img);
    return 0;
}

/* Load and draw image from file, scaled to fit */
int pager_draw_image_file_scaled(int x, int y, int dst_w, int dst_h, const char *filepath) {
    if (!filepath) return -1;

    pager_image_t *img = pager_load_image(filepath);
    if (!img) return -1;

    pager_draw_image_scaled(x, y, dst_w, dst_h, img);
    pager_free_image(img);
    return 0;
}

/* Get image dimensions without loading full image */
int pager_get_image_info(const char *filepath, int *width, int *height) {
    if (!filepath) return -1;

    int w, h, channels;
    if (stbi_info(filepath, &w, &h, &channels)) {
        if (width) *width = w;
        if (height) *height = h;
        return 0;
    }
    return -1;
}
