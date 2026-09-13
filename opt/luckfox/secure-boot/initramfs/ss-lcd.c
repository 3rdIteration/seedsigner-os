/*
 * ss-lcd — ST7789 status display for the SeedSigner initramfs (Luckfox Pico Mini).
 *
 * Usage: ss-lcd <color> <line1> [line2 ...]
 *   line1 is drawn as a centred title at 3x scale, remaining lines are body
 *   text at 2x scale. <color> applies to all text; the background is black.
 *   Colors: red green yellow cyan magenta blue white orange grey
 *
 * The panel wiring matches the SeedSigner app's io_config.json FOX_22 profile
 * (seedsigner/hardware/io_config.json) and its st7789_mpy.py driver, which is
 * the reference for every value below:
 *   SPI  /dev/spidev0.0, mode 0, 40 MHz, 4 KiB transfers
 *   DC   gpiochip1 line 20
 *   RST  gpiochip1 line 19
 *   BL   disabled (panel backlight is always on)
 *
 * The initramfs runs before the app, so this program must be self-contained:
 * no Python, no PIL, no libgpiod — only raw SPI_IOC_MESSAGE and the GPIO v2
 * uAPI. It exits 0 even when the display is absent or broken: a status screen
 * must never become a second failure mode (same contract as
 * files/show-screen-message.py).
 */

#include <errno.h>
#include <fcntl.h>
#include <linux/gpio.h>
#include <linux/spi/spidev.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/uio.h>
#include <unistd.h>

#include "font8x8_basic.h"

#define PANEL_W 240
#define PANEL_H 240
#define SPI_DEV "/dev/spidev0.0"
#define GPIO_CHIP "/dev/gpiochip1"
#define DC_LINE 20
#define RST_LINE 19
#define SPI_SPEED_HZ 40000000u
#define XFER_CHUNK 4096

/* ST7789 commands (st7789_mpy.py) */
#define CMD_SWRESET 0x01
#define CMD_SLPOUT 0x11
#define CMD_NORON 0x13
#define CMD_INVON 0x21
#define CMD_CASET 0x2A
#define CMD_RASET 0x2B
#define CMD_RAMWR 0x2C
#define CMD_COLMOD 0x3A
#define CMD_MADCTL 0x36

/* MADCTL for the app's default rotation (1) plus BGR data order:
 * 0x60 (MV|MX, from _DISPLAY_240x240[1]) | 0x08 (BGR). */
#define MADCTL_VALUE 0x68

static int spi_fd = -1;
static int gpio_chip_fd = -1;
static int dc_line_fd = -1;
static int rst_line_fd = -1;

/* ---------- GPIO v2 uAPI ---------- */

static int gpio_request_output(int line, uint8_t initial_value)
{
    struct gpio_v2_line_request req;

    memset(&req, 0, sizeof(req));
    req.offsets[0] = (uint32_t)line;
    req.num_lines = 1;
    snprintf(req.consumer, sizeof(req.consumer), "ss-lcd");
    req.config.flags = GPIO_V2_LINE_FLAG_OUTPUT;
    req.config.num_attrs = 1;
    req.config.attrs[0].attr.id = GPIO_V2_LINE_ATTR_ID_OUTPUT_VALUES;
    req.config.attrs[0].attr.values = initial_value ? 1 : 0;
    req.config.attrs[0].mask = 1;

    return ioctl(gpio_chip_fd, GPIO_V2_GET_LINE_IOCTL, &req);
}

static void gpio_set(int line_fd, int value)
{
    struct gpio_v2_line_values v;

    memset(&v, 0, sizeof(v));
    v.bits = value ? 1 : 0;
    v.mask = 1;
    if (pwrite(line_fd, &v, sizeof(v), 0) != (ssize_t)sizeof(v)) {
        fprintf(stderr, "ss-lcd: gpio set failed (%s)\n", strerror(errno));
    }
}

/* ---------- SPI ---------- */

static int spi_xfer(const void *buf, size_t len)
{
    const uint8_t *p = (const uint8_t *)buf;

    while (len > 0) {
        struct iovec iov;
        struct spi_ioc_transfer xfer;
        size_t n = len < XFER_CHUNK ? len : XFER_CHUNK;

        memset(&xfer, 0, sizeof(xfer));
        iov.iov_base = (void *)(uintptr_t)p;
        iov.iov_len = n;
        xfer.tx_buf = (unsigned long)&iov;
        xfer.len = n;
        if (ioctl(spi_fd, SPI_IOC_MESSAGE(1), &xfer) < 0) {
            fprintf(stderr, "ss-lcd: spi transfer failed (%s)\n", strerror(errno));
            return -1;
        }
        p += n;
        len -= n;
    }
    return 0;
}

static void lcd_cmd(uint8_t cmd)
{
    gpio_set(dc_line_fd, 0);
    (void)spi_xfer(&cmd, 1);
}

static int lcd_data(const void *buf, size_t len)
{
    gpio_set(dc_line_fd, 1);
    return spi_xfer(buf, len);
}

/* ---------- panel init (st7789_mpy.py _ST7789_INIT_CMDS) ---------- */

struct init_cmd {
    uint8_t cmd;
    const uint8_t *data;
    size_t data_len;
    int delay_ms;
};

static const uint8_t gamma_pos[] = { 0xD0, 0x00, 0x02, 0x07, 0x0A, 0x28, 0x32,
                                     0x44, 0x42, 0x06, 0x0E, 0x12, 0x14, 0x17 };
static const uint8_t gamma_neg[] = { 0xD0, 0x00, 0x02, 0x07, 0x0A, 0x28, 0x31,
                                     0x54, 0x47, 0x0E, 0x1C, 0x17, 0x1B, 0x1E };

static const struct init_cmd init_cmds[] = {
    { CMD_SLPOUT, NULL, 0, 120 },
    { CMD_NORON, NULL, 0, 0 },
    { 0xB6, (const uint8_t[]){ 0x0A, 0x82 }, 2, 0 },
    { CMD_COLMOD, (const uint8_t[]){ 0x55 }, 1, 10 },
    { 0xB2, (const uint8_t[]){ 0x0C, 0x0C, 0x00, 0x33, 0x33 }, 5, 0 },
    { 0xB7, (const uint8_t[]){ 0x35 }, 1, 0 },
    { 0xBB, (const uint8_t[]){ 0x28 }, 1, 0 },
    { 0xC0, (const uint8_t[]){ 0x0C }, 1, 0 },
    { 0xC2, (const uint8_t[]){ 0x01, 0xFF }, 2, 0 },
    { 0xC3, (const uint8_t[]){ 0x10 }, 1, 0 },
    { 0xC4, (const uint8_t[]){ 0x20 }, 1, 0 },
    { 0xC6, (const uint8_t[]){ 0x0F }, 1, 0 },
    { 0xD0, (const uint8_t[]){ 0xA4, 0xA1 }, 2, 0 },
    { 0xE0, gamma_pos, sizeof(gamma_pos), 0 },
    { 0xE1, gamma_neg, sizeof(gamma_neg), 0 },
    { 0x29, NULL, 0, 120 }, /* DISPON */
};

static void run_init_sequence(void)
{
    size_t i;

    for (i = 0; i < sizeof(init_cmds) / sizeof(init_cmds[0]); i++) {
        const struct init_cmd *c = &init_cmds[i];

        lcd_cmd(c->cmd);
        if (c->data_len > 0 && lcd_data(c->data, c->data_len) < 0)
            return;
        if (c->delay_ms > 0)
            usleep((useconds_t)c->delay_ms * 1000);
    }
}

/* hard_reset() from st7789_mpy.py: high 10 ms, low 10 ms, high 120 ms */
static void hard_reset(void)
{
    gpio_set(rst_line_fd, 1);
    usleep(10 * 1000);
    gpio_set(rst_line_fd, 0);
    usleep(10 * 1000);
    gpio_set(rst_line_fd, 1);
    usleep(120 * 1000);
}

static void set_window(int x0, int y0, int x1, int y1)
{
    uint8_t buf[4];

    buf[0] = (uint8_t)(x0 >> 8);
    buf[1] = (uint8_t)(x0 & 0xFF);
    buf[2] = (uint8_t)(x1 >> 8);
    buf[3] = (uint8_t)(x1 & 0xFF);
    lcd_cmd(CMD_CASET);
    (void)lcd_data(buf, 4);

    buf[0] = (uint8_t)(y0 >> 8);
    buf[1] = (uint8_t)(y0 & 0xFF);
    buf[2] = (uint8_t)(y1 >> 8);
    buf[3] = (uint8_t)(y1 & 0xFF);
    lcd_cmd(CMD_RASET);
    (void)lcd_data(buf, 4);

    lcd_cmd(CMD_RAMWR);
}

/* ---------- framebuffer / text ---------- */

static uint16_t rgb565_bgr(int r, int g, int b)
{
    /* BGR565 value: blue in the top bits (MADCTL BGR bit set). The wire
     * format is big-endian per pixel, matching st7789_mpy.py's
     * convert("BGR;16") + byteswap(). */
    return (uint16_t)(((b & 0xF8) << 8) | ((g & 0xFC) << 3) | (r >> 3));
}

static void put_pixel(uint16_t *fb, int x, int y, uint16_t color)
{
    if (x < 0 || x >= PANEL_W || y < 0 || y >= PANEL_H)
        return;
    /* big-endian on the wire */
    fb[(y * PANEL_W + x) * 2] = (uint8_t)(color >> 8);
    fb[(y * PANEL_W + x) * 2 + 1] = (uint8_t)(color & 0xFF);
}

/* draw one font row (8 px) of `ch` at (x, y), scaled by `scale` */
static void put_glyph(uint16_t *fb, int ch, int x, int y, int scale, uint16_t fg)
{
    const unsigned char *glyph = (const unsigned char *)font8x8_basic[ch & 0x7F];
    int row, col;

    for (row = 0; row < 8; row++) {
        for (col = 0; col < 8; col++) {
            if (!(glyph[row] & (0x80 >> col)))
                continue;
            int px, py;
            for (py = 0; py < scale; py++)
                for (px = 0; px < scale; px++)
                    put_pixel(fb, x + col * scale + px, y + row * scale + py, fg);
        }
    }
}

static void draw_text(uint16_t *fb, const char *text, int x, int y, int scale, uint16_t fg)
{
    while (*text) {
        put_glyph(fb, *text, x, y, scale, fg);
        x += 8 * scale;
        text++;
    }
}

static void draw_text_centered(uint16_t *fb, const char *text, int y, int scale, uint16_t fg)
{
    int w = (int)strlen(text) * 8 * scale;
    int x = (PANEL_W - w) / 2;

    if (x < 0)
        x = 0;
    draw_text(fb, text, x, y, scale, fg);
}

static uint16_t parse_color(const char *name)
{
    /* RGB565 from 8-bit components */
#define C(r, g, b) rgb565_bgr((r), (g), (b))
    if (!strcmp(name, "red")) return C(255, 0, 0);
    if (!strcmp(name, "green")) return C(0, 255, 0);
    if (!strcmp(name, "yellow")) return C(255, 255, 0);
    if (!strcmp(name, "cyan")) return C(0, 255, 255);
    if (!strcmp(name, "magenta")) return C(255, 0, 255);
    if (!strcmp(name, "blue")) return C(0, 0, 255);
    if (!strcmp(name, "white")) return C(255, 255, 255);
    if (!strcmp(name, "orange")) return C(255, 165, 0);
    if (!strcmp(name, "grey") || !strcmp(name, "gray")) return C(170, 170, 170);
#undef C
    fprintf(stderr, "ss-lcd: unknown color '%s'\n", name);
    exit(2);
}

/* ---------- main ---------- */

int main(int argc, char **argv)
{
    uint16_t *fb;
    int i;

    if (argc < 3) {
        fprintf(stderr, "usage: ss-lcd <color> <line1> [line2 ...]\n");
        return 2;
    }

    /* Best effort from here on: any failure prints to the console and exits 0. */
    uint16_t fg = parse_color(argv[1]);

    spi_fd = open(SPI_DEV, O_WRONLY);
    if (spi_fd < 0) {
        fprintf(stderr, "ss-lcd: %s not available (%s)\n", SPI_DEV, strerror(errno));
        return 0;
    }

    uint32_t speed = SPI_SPEED_HZ;
    uint8_t mode = SPI_MODE_0;
    uint8_t bits = 8;
    if (ioctl(spi_fd, SPI_IOC_WR_MAX_SPEED_HZ, &speed) < 0 ||
        ioctl(spi_fd, SPI_IOC_WR_MODE, &mode) < 0 ||
        ioctl(spi_fd, SPI_IOC_WR_BITS_PER_WORD, &bits) < 0) {
        fprintf(stderr, "ss-lcd: spi setup failed (%s)\n", strerror(errno));
        return 0;
    }

    gpio_chip_fd = open(GPIO_CHIP, O_RDWR);
    if (gpio_chip_fd < 0) {
        fprintf(stderr, "ss-lcd: %s not available (%s)\n", GPIO_CHIP, strerror(errno));
        return 0;
    }
    dc_line_fd = gpio_request_output(DC_LINE, 1);
    rst_line_fd = gpio_request_output(RST_LINE, 1);
    if (dc_line_fd < 0 || rst_line_fd < 0) {
        fprintf(stderr, "ss-lcd: display GPIO request failed\n");
        return 0;
    }

    hard_reset();
    run_init_sequence();
    /* st7789_mpy.py runs the init sequence twice: "once is not always enough" */
    run_init_sequence();

    uint8_t madctl = MADCTL_VALUE;
    lcd_cmd(CMD_MADCTL);
    (void)lcd_data(&madctl, 1);
    /* These panels only show correct colors with inversion on
     * (NORMAL_COLORS_REQUIRE_INVERSION in the app driver). */
    lcd_cmd(CMD_INVON);

    fb = calloc((size_t)PANEL_W * PANEL_H * 2, 1);
    if (!fb) {
        fprintf(stderr, "ss-lcd: out of memory\n");
        return 0;
    }

    /* argv[2] is the title (3x), the rest are body lines (2x). */
    int y = 48;
    draw_text_centered(fb, argv[2], y, 3, fg);
    y += 8 * 3 + 16;
    for (i = 3; i < argc && y < PANEL_H - 8 * 2; i++) {
        draw_text(fb, argv[i], 8, y, 2, fg);
        y += 8 * 2 + 4;
    }

    set_window(0, 0, PANEL_W - 1, PANEL_H - 1);
    if (lcd_data(fb, (size_t)PANEL_W * PANEL_H * 2) < 0) {
        fprintf(stderr, "ss-lcd: framebuffer write failed\n");
        return 0;
    }

    free(fb);
    /* Leave the panel on and release nothing: the initramfs is done with it. */
    return 0;
}
