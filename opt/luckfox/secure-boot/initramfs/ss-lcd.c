/*
 * ss-lcd — ST7789 status display for the SeedSigner initramfs (Luckfox Pico Mini).
 *
 * Usage: ss-lcd <color> <line1> [line2 ...]
 *        ss-lcd diag
 *        ss-lcd waitkey <chipdev> <line> [<addr> <value> ...]
 *   line1 is drawn as a centred title at 3x scale, remaining lines are body
 *   text at 2x scale. <color> applies to all text; the background is black.
 *   Colors: red green yellow cyan magenta blue white orange grey
 *   "diag" draws a test pattern (white bar + asymmetric corner squares) for
 *   checking the panel's coordinate mapping on a headless board.
 *   "waitkey" writes each <addr> <value> pair to physical memory via /dev/mem
 *   (Rockchip write-with-mask format), then blocks until the GPIO line reads
 *   LOW — used by /init for the KEY-press escape hatch after a failed rootfs
 *   verification. The register pairs configure IOMUX/pull-up/direction/IE,
 *   because the RV1106 pinctrl driver silently ignores gpiolib bias flags.
 *
 * The panel wiring matches the SeedSigner app's io_config.json FOX_22 profile
 * (seedsigner/hardware/io_config.json). Every register value and timing below
 * comes from seedsigner/hardware/displays/ST7789.py — the driver the app
 * actually uses for 240x240 panels (st7789_mpy.py is only used for 320x240):
 *   SPI  /dev/spidev0.0, mode 0, 40 MHz, kernel-managed CE, 4 KiB transfers
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
#include <sys/mman.h>
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

/* ST7789 commands (ST7789.py) */
#define CMD_SLPOUT 0x11
#define CMD_INVON 0x21
#define CMD_CASET 0x2A
#define CMD_RASET 0x2B
#define CMD_RAMWR 0x2C
#define CMD_COLMOD 0x3A
#define CMD_MADCTL 0x36

/* MADCTL and COLMOD exactly as ST7789.py init() writes them (0x70 / 0x05).
 * Verified on this board: with these values the panel displays a row-major
 * frame exactly as sent — no rotation, no mirror. */
#define MADCTL_VALUE 0x70

/* COLMOD: RGB order, 16 bits/pixel (pixels are byteswapped to MSB-first in
 * put_pixel(), matching ST7789.py's convert("BGR;16") + byteswap()). */
#define COLMOD_VALUE 0x05

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

    int rc = ioctl(gpio_chip_fd, GPIO_V2_GET_LINE_IOCTL, &req);
    if (rc < 0) {
        fprintf(stderr, "ss-lcd: gpio request failed (%s)\n", strerror(errno));
        return -1;
    }
    /* The new line fd is NOT reliably the ioctl() return value. This SDK
     * kernel's linereq_create() writes it into req.fd and returns 0 (a
     * Rockchip backport of an upstream change); mainline returns it directly.
     * Using the return value here would silently target fd 0 (stdin) and
     * every SET_VALUES would fail with ENOTTY while DC stays stuck. */
    return rc > 0 ? rc : req.fd;
}

static void gpio_set(int line_fd, int value)
{
    struct gpio_v2_line_values v;

    memset(&v, 0, sizeof(v));
    v.bits = value ? 1 : 0;
    v.mask = 1;
    /* GPIO v2 line fds have NO write handler — only ioctls. (pwrite() fails
     * with ESPIPE: uClibc implements it as lseek+write and the kernel's
     * no_llseek rejects the seek.) */
    if (ioctl(line_fd, GPIO_V2_LINE_SET_VALUES_IOCTL, &v) < 0) {
        fprintf(stderr, "ss-lcd: gpio set failed (%s)\n", strerror(errno));
    }
}

/* Write a 32-bit value to a physical address via /dev/mem. mmap is the only
 * path that reaches RV1106 peripheral addresses: lseek() past the end of RAM
 * fails EFBIG (the kernel sizes /dev/mem to system memory), while an mmap at
 * the page-aligned base works — this is exactly what the `io` tool does, and
 * it is how /usr/bin/configure-gpio.sh configures every button pin on each
 * boot. Values are in Rockchip write-with-mask format (bits [31:16] mask,
 * bits [15:0] value). */
static int mem_write32(uint32_t addr, uint32_t value)
{
    off_t page = (off_t)(addr & ~(uint32_t)0xFFF);
    size_t off = (size_t)(addr & 0xFFF);
    /* Cover [page, page+off+4), rounded up to whole pages. */
    size_t len = ((off + 4) + 4095) & ~(size_t)4095;
    int fd = open("/dev/mem", O_RDWR);

    if (fd < 0) {
        fprintf(stderr, "ss-lcd: /dev/mem not available (%s)\n", strerror(errno));
        return -1;
    }
    void *p = mmap(NULL, len, PROT_READ | PROT_WRITE, MAP_SHARED, fd, page);
    if (p == MAP_FAILED) {
        fprintf(stderr, "ss-lcd: /dev/mem mmap of 0x%08X failed (%s)\n", addr, strerror(errno));
        close(fd);
        return -1;
    }
    *(volatile uint32_t *)((uint8_t *)p + off) = value;
    munmap(p, len);
    close(fd);
    return 0;
}

/* Block until `line` on `chipdev` reads LOW (active-low button pressed).
 * The caller must have already configured the pin's IOMUX/pull/IE registers
 * (passed as addr/value pairs) — the RV1106 pinctrl driver silently ignores
 * GPIO_V2 bias flags, so a plain gpiolib request alone leaves the pin
 * un-pulled and floating. Returns 0 on press, -1 on error. */
static int gpio_wait_pressed(const char *chipdev, uint32_t line,
                             const uint32_t *regs, size_t n_regs)
{
    struct gpio_v2_line_request req;
    size_t i;

    for (i = 0; i < n_regs; i += 2) {
        if (mem_write32(regs[i], regs[i + 1]) < 0)
            return -1;
    }

    int fd = open(chipdev, O_RDWR);
    if (fd < 0) {
        fprintf(stderr, "ss-lcd: %s not available (%s)\n", chipdev, strerror(errno));
        return -1;
    }
    memset(&req, 0, sizeof(req));
    req.offsets[0] = line;
    req.num_lines = 1;
    snprintf(req.consumer, sizeof(req.consumer), "ss-lcd");
    req.config.flags = GPIO_V2_LINE_FLAG_INPUT;

    if (ioctl(fd, GPIO_V2_GET_LINE_IOCTL, &req) < 0) {
        fprintf(stderr, "ss-lcd: gpio input request failed (%s)\n", strerror(errno));
        close(fd);
        return -1;
    }
    int line_fd = req.fd > 0 ? req.fd : 0;

    /* Let the pull-up settle before sampling, then poll at 20 Hz. */
    usleep(100 * 1000);
    for (;;) {
        struct gpio_v2_line_values v;
        memset(&v, 0, sizeof(v));
        v.mask = 1; /* select line 0 — a zero mask makes the kernel return EINVAL */
        if (ioctl(line_fd, GPIO_V2_LINE_GET_VALUES_IOCTL, &v) < 0) {
            fprintf(stderr, "ss-lcd: gpio read failed (%s)\n", strerror(errno));
            close(line_fd);
            return -1;
        }
        if (!(v.bits & 1))
            break; /* pressed (active-low) */
        usleep(50 * 1000);
    }
    close(line_fd);
    close(fd);
    return 0;
}

/* ---------- SPI ---------- */

static int spi_xfer(const void *buf, size_t len)
{
    const uint8_t *p = (const uint8_t *)buf;

    while (len > 0) {
        struct spi_ioc_transfer xfer;
        size_t n = len < XFER_CHUNK ? len : XFER_CHUNK;

        memset(&xfer, 0, sizeof(xfer));
        /* tx_buf is a DIRECT userspace pointer to the data — spidev does
         * copy_from_user() from it. (A pointer to an iovec makes the kernel
         * dereference the struct as pixel data -> EFAULT.) */
        xfer.tx_buf = (unsigned long)p;
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

/* ---------- panel init (ST7789.py init()) ---------- */

struct init_cmd {
    uint8_t cmd;
    const uint8_t *data;
    size_t data_len;
    int delay_ms;
};

static const uint8_t gamma_pos[] = { 0xD0, 0x04, 0x0D, 0x11, 0x13, 0x2B, 0x3F,
                                     0x54, 0x4C, 0x18, 0x0D, 0x0B, 0x1F, 0x23 };
static const uint8_t gamma_neg[] = { 0xD0, 0x04, 0x0C, 0x11, 0x13, 0x2C, 0x3F,
                                     0x44, 0x51, 0x2F, 0x1F, 0x1F, 0x20, 0x23 };

/* Register-for-register copy of ST7789.py init() (minus the reset, which
 * hard_reset() does). Note: no NORON/0xB6/SWRESET — that was the mpy driver. */
static const struct init_cmd init_cmds[] = {
    { CMD_MADCTL, (const uint8_t[]){ MADCTL_VALUE }, 1, 0 },
    { CMD_COLMOD, (const uint8_t[]){ COLMOD_VALUE }, 1, 0 },
    { 0xB2, (const uint8_t[]){ 0x0C, 0x0C, 0x00, 0x33, 0x33 }, 5, 0 },
    { 0xB7, (const uint8_t[]){ 0x35 }, 1, 0 },
    { 0xBB, (const uint8_t[]){ 0x19 }, 1, 0 },
    { 0xC0, (const uint8_t[]){ 0x2C }, 1, 0 },
    { 0xC2, (const uint8_t[]){ 0x01 }, 1, 0 },
    { 0xC3, (const uint8_t[]){ 0x12 }, 1, 0 },
    { 0xC4, (const uint8_t[]){ 0x20 }, 1, 0 },
    { 0xC6, (const uint8_t[]){ 0x0F }, 1, 0 },
    { 0xD0, (const uint8_t[]){ 0xA4, 0xA1 }, 2, 0 },
    { 0xE0, gamma_pos, sizeof(gamma_pos), 0 },
    { 0xE1, gamma_neg, sizeof(gamma_neg), 0 },
    /* SLPOUT: the ST7789 datasheet requires >=120 ms before any subsequent
     * command (incl. DISPON); ST7789.py uses 150 ms for OS timer headroom. */
    { CMD_SLPOUT, NULL, 0, 150 },
    { 0x29, NULL, 0, 0 }, /* DISPON */
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

/* reset() from ST7789.py: high 10 ms, low 10 ms, then high with a FULL
 * 150 ms wait before any command. The datasheet needs 5 ms before commands
 * and 120 ms specifically before SLPOUT; the register writes in between only
 * buy ~20-30 ms, so without this wait SLPOUT lands inside the forbidden
 * window and the panel intermittently never wakes (screen stays black). */
static void hard_reset(void)
{
    gpio_set(rst_line_fd, 1);
    usleep(10 * 1000);
    gpio_set(rst_line_fd, 0);
    usleep(10 * 1000);
    gpio_set(rst_line_fd, 1);
    usleep(150 * 1000);
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

static uint16_t rgb565(int r, int g, int b)
{
    /* RGB565 value: red in the top bits. The wire format is big-endian per
     * pixel (MSB first), matching ST7789.py's convert("BGR;16") + byteswap()
     * — verified against Pillow 11.0.0 (the device version): a pure-red
     * pixel yields value 0xF800, i.e. R in the high bits, consistent with
     * COLMOD 0x05 (RGB order). */
    return (uint16_t)(((r & 0xF8) << 8) | ((g & 0xFC) << 3) | (b >> 3));
}

static void put_pixel(uint16_t *fb, int x, int y, uint16_t color)
{
    if (x < 0 || x >= PANEL_W || y < 0 || y >= PANEL_H)
        return;
    /* fb is a uint16_t array: pixel (x,y) lives at ELEMENT index y*W+x.
     * (An earlier version indexed with (y*W+x)*2 — treating the element
     * index as a byte offset — which stretched the image 2x and wrote past
     * the end of the allocation for every row y >= 120.) The panel wants
     * MSB-first pixels, so byteswap on this little-endian CPU. */
    fb[y * PANEL_W + x] = (uint16_t)(((color & 0xFF) << 8) | (color >> 8));
}

/* Glyph scaling is fixed-point: `scale8` is the pixel size of ONE source
 * font pixel in eighths (24 == 3x, 16 == 2x, 20 == 2.5x). Each set source
 * pixel becomes a rectangle [col*scale8, (col+1)*scale8) >> 3, so fractional
 * scales render without seams or double-width pixels. */
static void put_glyph(uint16_t *fb, int ch, int x, int y, int scale8, uint16_t fg)
{
    const unsigned char *glyph = (const unsigned char *)font8x8_basic[ch & 0x7F];
    int row, col;

    for (row = 0; row < 8; row++) {
        for (col = 0; col < 8; col++) {
            /* font8x8_basic rows are LSB-first: bit 0 is the LEFTMOST pixel.
             * (Testing MSB-first, as with most VGA fonts, draws every glyph
             * horizontally mirrored.) */
            if (!(glyph[row] & (0x01 << col)))
                continue;
            int x0 = x + ((col * scale8) >> 3);
            int x1 = x + (((col + 1) * scale8) >> 3);
            int y0 = y + ((row * scale8) >> 3);
            int y1 = y + (((row + 1) * scale8) >> 3);
            int px, py;
            for (py = y0; py < y1; py++)
                for (px = x0; px < x1; px++)
                    put_pixel(fb, px, py, fg);
        }
    }
}

static void draw_text(uint16_t *fb, const char *text, int x, int y, int scale8, uint16_t fg)
{
    while (*text) {
        put_glyph(fb, *text, x, y, scale8, fg);
        x += (8 * scale8) >> 3;
        text++;
    }
}

static void draw_text_centered(uint16_t *fb, const char *text, int y, int scale8, uint16_t fg)
{
    int w = (int)strlen(text) * ((8 * scale8) >> 3);
    int x = (PANEL_W - w) / 2;

    if (x < 0)
        x = 0;
    draw_text(fb, text, x, y, scale8, fg);
}

static uint16_t parse_color(const char *name)
{
    /* RGB565 from 8-bit components */
#define C(r, g, b) rgb565((r), (g), (b))
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

    if (argc < 2 || (argc < 3 && strcmp(argv[1], "diag") && strcmp(argv[1], "waitkey"))) {
        fprintf(stderr, "usage: ss-lcd <color> <line1> [line2 ...] | diag | waitkey ...\n");
        return 2;
    }

    /* waitkey mode: no LCD involvement. Exits 0 on key press, non-zero on any
     * error — /init treats a failure as "cannot confirm" and halts. */
    if (!strcmp(argv[1], "waitkey")) {
        uint32_t regs[32];
        size_t n = 0;
        long line;
        int r;

        if (argc < 4) {
            fprintf(stderr, "usage: ss-lcd waitkey <chipdev> <line> [<addr> <value> ...]\n");
            return 2;
        }
        line = strtol(argv[3], NULL, 0);
        if (line < 0 || line > 0xFF) {
            fprintf(stderr, "ss-lcd: bad line '%s'\n", argv[3]);
            return 2;
        }
        for (r = 4; r < argc; r += 2) {
            if (r + 1 >= argc || n + 2 > sizeof(regs) / sizeof(regs[0])) {
                fprintf(stderr, "ss-lcd: register args must be addr/value pairs\n");
                return 2;
            }
            regs[n++] = (uint32_t)strtoul(argv[r], NULL, 0);
            regs[n++] = (uint32_t)strtoul(argv[r + 1], NULL, 0);
        }

        if (gpio_wait_pressed(argv[2], (uint32_t)line, regs, n) < 0)
            return 1;
        return 0;
    }

    /* Best effort from here on: any failure prints to the console and exits 0. */
    int diag = !strcmp(argv[1], "diag");
    uint16_t fg = diag ? 0 : parse_color(argv[1]);

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

    /* The app enables controller inversion by default for these panels:
     * set_color_inversion(False) with NORMAL_COLORS_REQUIRE_INVERSION=True
     * sends INVON (display_driver.py). */
    lcd_cmd(CMD_INVON);

    fb = calloc((size_t)PANEL_W * PANEL_H * 2, 1);
    if (!fb) {
        fprintf(stderr, "ss-lcd: out of memory\n");
        return 0;
    }


    if (diag) {
        /* Diagnostic pattern: white bar across rows 100..139, red square
         * top-right, green square bottom-left. Correct mapping shows exactly
         * that; a transpose/mirror moves the squares. */
        int x2, y2;
        for (y2 = 100; y2 < 140; y2++)
            for (x2 = 0; x2 < PANEL_W; x2++)
                put_pixel(fb, x2, y2, rgb565(255, 255, 255));
        for (y2 = 0; y2 < 40; y2++)
            for (x2 = 200; x2 < PANEL_W; x2++)
                put_pixel(fb, x2, y2, rgb565(255, 0, 0));
        for (y2 = 200; y2 < PANEL_H; y2++)
            for (x2 = 0; x2 < 40; x2++)
                put_pixel(fb, x2, y2, rgb565(0, 255, 0));
    } else {
        /* argv[2] is the title — 3x if it fits the panel width, else 2.5x,
         * else 2x (fixed-point eighths); the rest are body lines at 2x. */
        int tlen = (int)strlen(argv[2]);
        static const int tscales[] = { 24, 20, 16 }; /* 3x, 2.5x, 2x */
        int ti, tscale8;
        for (ti = 0; ti < 3; ti++) {
            if (tlen * ((8 * tscales[ti]) >> 3) <= PANEL_W || ti == 2) {
                tscale8 = tscales[ti];
                break;
            }
        }
        int y = 48;
        draw_text_centered(fb, argv[2], y, tscale8, fg);
        y += ((8 * tscale8) >> 3) + 16;
        for (i = 3; i < argc && y < PANEL_H - 16; i++) {
            draw_text(fb, argv[i], 8, y, 16, fg); /* 2x */
            y += ((8 * 16) >> 3) + 4;
        }
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
