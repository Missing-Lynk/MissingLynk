/**
 * @file ml-latency-counter.c
 * @brief Draw a free-running millisecond counter into the stock goggle's OSD framebuffer.
 *
 * The glass-to-glass harness needs a number on the panel that changes every frame. Point the air
 * unit's camera at the panel and the panel then carries two copies of it: the live one this tool
 * draws, and an older nested one that came back around through camera, encode, RF and decode.
 * Photograph the panel and the difference between the two is the full glass-to-glass latency.
 *
 * The difference is exact regardless of how laggy the OSD layer itself is. Both numbers are read
 * off the panel at one instant, so the OSD's own write-to-photon delay is subtracted out, while
 * the video layer's assembly-to-photon delay stays in, which is where glass-to-glass needs it.
 *
 * The target is the STOCK firmware's /dev/fb0, which is the real OSD overlay: ARGB4444, 2048 px
 * stride, yres_virtual = 3 stacked pages. The open stack's /dev/fb0 is DRM fbdev emulation that
 * nothing scans out, so writes there are invisible; the 16 bpp check below refuses it rather than
 * running to no effect. On the open stack the counter is drawn into the composite instead.
 *
 * Digits are 7-segment bars rather than glyphs from a font: they have to survive the camera, the
 * air-side encoder and the RF link, and a thin antialiased glyph smears into an unreadable blob.
 * They are flanked by two tracking markers and sat above a sweep bar, for the reasons given at
 * each below; on a filmed panel the digits alone were not enough.
 *
 * The layout is ml-pipeline's, to the pixel, so that glue/capture/latency-read.py reads a capture
 * from either stack with one set of constants. Anything changed here has to be changed in both.
 *
 * What this tool does NOT give you is the reading path: ml-pipeline's counter is recorded
 * digitally, so the reader knows the live copy's size, while a stock-goggle measurement is
 * PHOTOGRAPHED, leaving both copies at scales the reader would have to find. That part is unbuilt.
 *
 * Usage: ml-latency-counter [-d /dev/fb0] [-x X] [-y Y] [-s HEIGHT] [-r HZ] [-1]
 *   -x defaults to centring the box, -y to the row ml-pipeline uses.
 * Build: native/build.sh (arm64 glibc <= 2.25 container).
 */
#include <errno.h>
#include <fcntl.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/mman.h>
#include <time.h>
#include <unistd.h>

#include <linux/fb.h>

/* The defaults reproduce ml-pipeline's geometry exactly: at a digit height of 160 every proportion
 * below lands on the same integer the composite uses, so one reader geometry serves both. Changing
 * -s or -y is for fitting an unusual panel, and a capture made that way needs the reader's
 * constants moved to match.
 */
#define DEFAULT_DEVICE      "/dev/fb0"
#define DEFAULT_HEIGHT      160
#define DEFAULT_RATE_HZ     60
#define DEFAULT_TOP         180

/* The counter wraps every 100 s. Latency is tens of ms, so a wrap is never ambiguous, and a
 * decimal rollover is easier to subtract by eye than a truncated hex or binary one.
 */
#define COUNTER_DIGITS      5
#define COUNTER_MODULO      100000

/* ARGB4444, opaque. The box is filled so the video layer behind it cannot corrupt the read.
 *
 * The ink is grey, not white. The air unit meters for the dark goggle body around the panel, so a
 * white counter clips in the recording and a clipped digit blooms its gaps shut. Six fifteenths
 * short of full matches the level ml-pipeline draws in the composite.
 */
#define COLOR_INK           0xF999u
#define COLOR_BOX           0xF000u
#define COLOR_CLEAR         0x0000u

/* Segment proportions, as a fraction of the digit height. A thick bar and a wide gap are what
 * survive the link; they are not aesthetic choices.
 */
#define DIGIT_WIDTH_NUM     11
#define DIGIT_WIDTH_DEN     20
#define STROKE_NUM          1
#define STROKE_DEN          6
#define GAP_NUM             1
#define GAP_DEN             5
#define PAD_NUM             1
#define PAD_DEN             6

/* Tracking markers: a solid bar inside each end of the digit row, overhanging it so nothing else
 * in the box has their shape. A blown-out digit blooms its gaps shut and becomes an anonymous
 * blob; a solid bar has no gaps to lose, so the pair still carries the box's position and scale.
 * The gap to the nearest digit is wider than the digit gap so their bloom cannot bridge into it.
 */
#define MARK_W_NUM          13
#define MARK_W_DEN          40
#define MARK_GAP_NUM        2
#define MARK_GAP_DEN        5
#define MARK_OVER_NUM       3
#define MARK_OVER_DEN       40

/* The sweep bar: fills left to right once per SWEEP_MS and resets, carrying the time the digits
 * cannot. The panel advances the counter every frame, and a camera exposure spanning two of them
 * records both values superimposed - the union of two 7-segment glyphs is almost always a legible
 * WRONG digit, so the digits fail in a way no reader can detect. A bar degrades instead: the part
 * lit for the whole exposure is bright, the part lit for some of it is proportionally dimmer, and
 * integrating that returns the mean time across the exposure.
 */
#define SWEEP_MS            100
#define TRACK_H_NUM         11
#define TRACK_H_DEN         40

/* Segment bits, in the order a, b, c, d, e, f, g (top, top-right, bottom-right, bottom,
 * bottom-left, top-left, middle).
 */
#define SEG_A 0x01u
#define SEG_B 0x02u
#define SEG_C 0x04u
#define SEG_D 0x08u
#define SEG_E 0x10u
#define SEG_F 0x20u
#define SEG_G 0x40u

static const unsigned char g_digit_segments[10] = {
    SEG_A | SEG_B | SEG_C | SEG_D | SEG_E | SEG_F,
    SEG_B | SEG_C,
    SEG_A | SEG_B | SEG_G | SEG_E | SEG_D,
    SEG_A | SEG_B | SEG_C | SEG_D | SEG_G,
    SEG_F | SEG_G | SEG_B | SEG_C,
    SEG_A | SEG_F | SEG_G | SEG_C | SEG_D,
    SEG_A | SEG_F | SEG_G | SEG_E | SEG_C | SEG_D,
    SEG_A | SEG_B | SEG_C,
    SEG_A | SEG_B | SEG_C | SEG_D | SEG_E | SEG_F | SEG_G,
    SEG_A | SEG_B | SEG_C | SEG_D | SEG_F | SEG_G,
};

/* the framebuffer, as this tool needs to see it */
typedef struct {
    int fd;
    unsigned char *map;      /* NULL when mmap failed and the pwrite path is in use */
    size_t map_len;
    unsigned line_length;    /* bytes per row */
    unsigned xres;
    unsigned yres;           /* rows in one page */
    unsigned npages;         /* stacked pages in yres_virtual */
    int has_vsync;
} Framebuffer;

/* the counter box: a RAM-side render target, blitted to every page once per frame */
typedef struct {
    uint16_t *pixels;
    int x;
    int y;
    int width;
    int height;
    int digit_width;
    int digit_height;
    int stroke;
    int gap;
    int pad;
    int mark_w;
    int mark_h;
    int mark_y;
    int digits_x;            /* first digit's left edge, past the pad and the left marker */
    int track_w;
    int track_h;
    int track_y;
} Box;

/* command-line parameters */
typedef struct {
    const char *device;
    int x;                   /* < 0 centres the box */
    int y;
    int digit_height;
    int rate_hz;
    int once;
} Args;

static volatile sig_atomic_t g_stop;


static void on_signal(int signum)
{
    (void) signum;
    g_stop = 1;
}


static long long monotonic_ms(void)
{
    struct timespec now;

    clock_gettime(CLOCK_MONOTONIC, &now);

    return (long long) now.tv_sec * 1000 + now.tv_nsec / 1000000;
}


/**
 * @brief Open the framebuffer and read back its geometry.
 * @return 0 on success, -1 on failure (message already printed).
 */
static int fb_open(Framebuffer *fb, const char *device)
{
    struct fb_var_screeninfo var;
    struct fb_fix_screeninfo fix;

    memset(fb, 0, sizeof(*fb));

    fb->fd = open(device, O_RDWR);
    if (fb->fd < 0) {
        fprintf(stderr, "open %s: %s\n", device, strerror(errno));

        return -1;
    }

    if (ioctl(fb->fd, FBIOGET_VSCREENINFO, &var) != 0 ||
        ioctl(fb->fd, FBIOGET_FSCREENINFO, &fix) != 0) {
        fprintf(stderr, "%s: cannot read screeninfo: %s\n", device, strerror(errno));
        close(fb->fd);

        return -1;
    }

    /* The stock OSD overlay is 16 bpp. A 32 bpp node here is the open stack's fbdev emulation,
     * which is not scanned out, so drawing into it would silently do nothing.
     */
    if (var.bits_per_pixel != 16) {
        fprintf(stderr,
                "%s: %u bpp, not the stock 16 bpp OSD overlay - nothing here reaches the panel\n",
                device, var.bits_per_pixel);
        close(fb->fd);

        return -1;
    }

    fb->xres = var.xres;
    fb->yres = var.yres;
    fb->line_length = fix.line_length;
    fb->npages = (var.yres > 0) ? (var.yres_virtual / var.yres) : 1;
    if (fb->npages < 1) {
        fb->npages = 1;
    }

    fb->map_len = (size_t) fb->line_length * fb->yres * fb->npages;
    fb->map = mmap(NULL, fb->map_len, PROT_READ | PROT_WRITE, MAP_SHARED, fb->fd, 0);
    if (fb->map == MAP_FAILED) {
        fb->map = NULL;
        fb->map_len = 0;
    }

    /* Pacing off the panel keeps the write in a fixed phase to scanout, which bounds tearing to
     * the frames where the vendor OSD repaints under us.
     */
    unsigned arg = 0;
    fb->has_vsync = (ioctl(fb->fd, FBIO_WAITFORVSYNC, &arg) == 0);

    return 0;
}


static void fb_close(Framebuffer *fb)
{
    if (fb->map != NULL) {
        munmap(fb->map, fb->map_len);
        fb->map = NULL;
    }

    if (fb->fd >= 0) {
        close(fb->fd);
        fb->fd = -1;
    }
}


/**
 * @brief Copy the rendered box into every framebuffer page.
 *
 * All pages, because the vendor OSD pans between three of them and which one is live is not ours
 * to know. Writing all three costs one memcpy per row per page and removes the question.
 */
static void fb_blit(const Framebuffer *fb, const Box *box)
{
    size_t row_bytes = (size_t) box->width * 2;

    for (unsigned page = 0; page < fb->npages; page++) {
        for (int row = 0; row < box->height; row++) {
            off_t offset = (off_t) (box->y + row + (int) (page * fb->yres)) * fb->line_length
                         + (off_t) box->x * 2;
            const uint16_t *src = box->pixels + (size_t) row * box->width;

            if (fb->map != NULL) {
                memcpy(fb->map + offset, src, row_bytes);
            } else if (pwrite(fb->fd, src, row_bytes, offset) < 0) {
                fprintf(stderr, "pwrite: %s\n", strerror(errno));

                return;
            }
        }
    }
}


static void box_fill(Box *box, int x, int y, int width, int height, uint16_t color)
{
    for (int row = 0; row < height; row++) {
        int py = y + row;
        if (py < 0 || py >= box->height) {
            continue;
        }

        uint16_t *dst = box->pixels + (size_t) py * box->width;
        for (int col = 0; col < width; col++) {
            int px = x + col;
            if (px >= 0 && px < box->width) {
                dst[px] = color;
            }
        }
    }
}


/**
 * @brief Draw one 7-segment digit with its top-left corner at (@p x, @p y).
 */
static void box_draw_digit(Box *box, int x, int y, int digit)
{
    int width = box->digit_width;
    int height = box->digit_height;
    int stroke = box->stroke;
    int middle = (height - stroke) / 2;
    unsigned char segments = g_digit_segments[digit];

    if ((segments & SEG_A) != 0) {
        box_fill(box, x, y, width, stroke, COLOR_INK);
    }

    if ((segments & SEG_G) != 0) {
        box_fill(box, x, y + middle, width, stroke, COLOR_INK);
    }

    if ((segments & SEG_D) != 0) {
        box_fill(box, x, y + height - stroke, width, stroke, COLOR_INK);
    }

    if ((segments & SEG_F) != 0) {
        box_fill(box, x, y, stroke, middle + stroke, COLOR_INK);
    }

    if ((segments & SEG_B) != 0) {
        box_fill(box, x + width - stroke, y, stroke, middle + stroke, COLOR_INK);
    }

    if ((segments & SEG_E) != 0) {
        box_fill(box, x, y + middle, stroke, height - middle, COLOR_INK);
    }

    if ((segments & SEG_C) != 0) {
        box_fill(box, x + width - stroke, y + middle, stroke, height - middle, COLOR_INK);
    }
}


/**
 * @brief Render @p value, zero-padded, into the box buffer.
 */
static void box_render(Box *box, long long value)
{
    box_fill(box, 0, 0, box->width, box->height, COLOR_BOX);

    box_fill(box, box->pad, box->mark_y, box->mark_w, box->mark_h, COLOR_INK);
    box_fill(box, box->width - box->pad - box->mark_w, box->mark_y, box->mark_w, box->mark_h,
             COLOR_INK);

    /* Rounded down: the bar's right edge is the time it has reached, so rounding up would put the
     * edge ahead of the value the digits show.
     */
    int filled = (int) ((value % SWEEP_MS) * box->track_w / SWEEP_MS);

    if (filled > 0) {
        box_fill(box, box->pad, box->track_y, filled, box->track_h, COLOR_INK);
    }

    for (int index = COUNTER_DIGITS - 1; index >= 0; index--) {
        int digit = (int) (value % 10);
        int x = box->digits_x + index * (box->digit_width + box->gap);

        box_draw_digit(box, x, box->pad, digit);
        value /= 10;
    }
}


/**
 * @brief Size the box from the requested digit height and allocate its buffer.
 * @return 0 on success, -1 if the box does not fit the panel or allocation failed.
 */
static int box_init(Box *box, const Framebuffer *fb, const Args *args)
{
    memset(box, 0, sizeof(*box));

    box->digit_height = args->digit_height;
    box->digit_width = args->digit_height * DIGIT_WIDTH_NUM / DIGIT_WIDTH_DEN;
    box->stroke = args->digit_height * STROKE_NUM / STROKE_DEN;
    box->gap = args->digit_height * GAP_NUM / GAP_DEN;
    box->pad = args->digit_height * PAD_NUM / PAD_DEN;

    if (box->stroke < 1) {
        box->stroke = 1;
    }

    box->mark_w = args->digit_height * MARK_W_NUM / MARK_W_DEN;
    box->track_h = args->digit_height * TRACK_H_NUM / TRACK_H_DEN;

    int mark_gap = args->digit_height * MARK_GAP_NUM / MARK_GAP_DEN;
    int mark_over = args->digit_height * MARK_OVER_NUM / MARK_OVER_DEN;

    if (box->mark_w < 1) {
        box->mark_w = 1;
    }

    if (box->track_h < 1) {
        box->track_h = 1;
    }

    box->width = COUNTER_DIGITS * box->digit_width + (COUNTER_DIGITS - 1) * box->gap
               + 2 * (box->pad + box->mark_w + mark_gap);
    /* The track sits below the digits, inside the same pad. */
    box->height = 2 * box->pad + box->digit_height + box->pad + box->track_h;

    box->digits_x = box->pad + box->mark_w + mark_gap;
    box->mark_y = box->pad - mark_over;
    box->mark_h = box->digit_height + 2 * mark_over;
    box->track_w = box->width - 2 * box->pad;
    box->track_y = box->pad + box->digit_height + box->pad;

    if (box->mark_y < 0) {
        box->mark_y = 0;
    }

    box->x = (args->x >= 0) ? args->x : ((int) fb->xres - box->width) / 2;
    box->y = args->y;

    if (box->x < 0 || box->y < 0 ||
        box->x + box->width > (int) fb->xres || box->y + box->height > (int) fb->yres) {
        fprintf(stderr, "box %dx%d at (%d,%d) does not fit %ux%u\n",
                box->width, box->height, box->x, box->y, fb->xres, fb->yres);

        return -1;
    }

    box->pixels = calloc((size_t) box->width * box->height, sizeof(*box->pixels));
    if (box->pixels == NULL) {
        fprintf(stderr, "out of memory\n");

        return -1;
    }

    return 0;
}


/**
 * @brief Sleep until @p deadline, which is advanced by one period.
 */
static void wait_period(struct timespec *deadline, long period_ns)
{
    deadline->tv_nsec += period_ns;
    while (deadline->tv_nsec >= 1000000000L) {
        deadline->tv_nsec -= 1000000000L;
        deadline->tv_sec += 1;
    }

    clock_nanosleep(CLOCK_MONOTONIC, TIMER_ABSTIME, deadline, NULL);
}


static void usage(const char *program)
{
    fprintf(stderr,
            "usage: %s [-d DEVICE] [-x X] [-y Y] [-s HEIGHT] [-r HZ] [-1]\n"
            "  -d  framebuffer device (default %s)\n"
            "  -x  box left edge in px (default: centred)\n"
            "  -y  box top edge in px (default %d)\n"
            "  -s  digit height in px (default %d)\n"
            "  -r  redraw rate in Hz, ignored when the driver supports a vsync wait (default %d)\n"
            "  -1  draw one frame and exit\n",
            program, DEFAULT_DEVICE, DEFAULT_TOP, DEFAULT_HEIGHT, DEFAULT_RATE_HZ);
}


static int parse_args(Args *args, int argc, char **argv)
{
    args->device = DEFAULT_DEVICE;
    args->x = -1;
    args->y = DEFAULT_TOP;
    args->digit_height = DEFAULT_HEIGHT;
    args->rate_hz = DEFAULT_RATE_HZ;
    args->once = 0;

    int option;
    while ((option = getopt(argc, argv, "d:x:y:s:r:1")) != -1) {
        switch (option) {
            case 'd': {
                args->device = optarg;
            } break;
            case 'x': {
                args->x = atoi(optarg);
            } break;
            case 'y': {
                args->y = atoi(optarg);
            } break;
            case 's': {
                args->digit_height = atoi(optarg);
            } break;
            case 'r': {
                args->rate_hz = atoi(optarg);
            } break;
            case '1': {
                args->once = 1;
            } break;
            default: {
                return -1;
            } break;
        }
    }

    if (args->digit_height < 8 || args->rate_hz < 1 || args->rate_hz > 1000) {
        return -1;
    }

    return 0;
}


int main(int argc, char **argv)
{
    Args args;
    Framebuffer fb;
    Box box;

    if (parse_args(&args, argc, argv) != 0) {
        usage(argv[0]);

        return 2;
    }

    if (fb_open(&fb, args.device) != 0) {
        return 1;
    }

    if (box_init(&box, &fb, &args) != 0) {
        fb_close(&fb);

        return 1;
    }

    signal(SIGINT, on_signal);
    signal(SIGTERM, on_signal);

    fprintf(stderr, "%s: %ux%u, %u page(s), %u B/row, vsync %s\n",
            args.device, fb.xres, fb.yres, fb.npages, fb.line_length,
            fb.has_vsync ? "yes" : "no");
    fprintf(stderr, "counter box %dx%d at (%d,%d), %d digits, wraps every %d ms\n",
            box.width, box.height, box.x, box.y, COUNTER_DIGITS, COUNTER_MODULO);

    long period_ns = 1000000000L / args.rate_hz;
    struct timespec deadline;
    clock_gettime(CLOCK_MONOTONIC, &deadline);

    while (g_stop == 0) {
        if (fb.has_vsync) {
            unsigned arg = 0;
            ioctl(fb.fd, FBIO_WAITFORVSYNC, &arg);
        } else {
            wait_period(&deadline, period_ns);
        }

        /* Stamp as late as possible: everything between here and scanout is the OSD layer's own
         * delay, which the two-counter subtraction removes, but a stale stamp is a straight bias.
         */
        box_render(&box, monotonic_ms() % COUNTER_MODULO);
        fb_blit(&fb, &box);

        if (args.once != 0) {
            break;
        }
    }

    if (args.once == 0) {
        /* Leave the overlay as it was found: transparent, so the vendor OSD shows through again.
         */
        box_fill(&box, 0, 0, box.width, box.height, COLOR_CLEAR);
        fb_blit(&fb, &box);
    }

    free(box.pixels);
    fb_close(&fb);

    return 0;
}
