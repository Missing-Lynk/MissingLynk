/*
 * fbtext - render text to the goggle framebuffer in the OSD's own font.
 *
 * The goggle OSD is drawn to /dev/fb0 (arfb, ARGB4444, stride 4096 B/line,
 * triple-buffered: 3 pages of `yres` rows). We rasterize text from the device's
 * HarmonyOS TTF with stb_truetype, premultiply over the alpha channel so it
 * composites like the native OSD, and write it to all buffer pages.
 *
 * One-shot by design: at startup (no video) it persists; once video starts the
 * OSD repaints over it, which is fine for a "modified state" indicator.
 *
 * Usage: ./fbtext "TEXT" X Y [px_height] [rgb444] [font_path]
 *   defaults: px_height=34  rgb444=FFF (white)
 *             font=/usr/usrdata/fonts/HarmonyOS_Sans_Regular_subset.ttf
 *   X,Y = top-left of the text box.
 * Build: native/build.sh (arm64 glibc<=2.25 container).
 */
#define STB_TRUETYPE_IMPLEMENTATION
#include "stb_truetype.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <unistd.h>
#include <fcntl.h>
#include <sys/ioctl.h>

#define FB "/dev/fb0"
#define STRIDE_PX 2048
#define FBIOGET_VSCREENINFO 0x4600
#define DEFAULT_FONT "/usr/usrdata/fonts/HarmonyOS_Sans_Regular_subset.ttf"

/* command-line parameters */
typedef struct {
    const char *text;
    int x;
    int y;
    int px_height;
    unsigned rgb444;
    const char *font_path;
} Args;

/* an RGB color, one nibble (0..15) per channel */
typedef struct {
    int r;
    int g;
    int b;
} Color;

/* an 8-bit coverage bitmap of rendered text */
typedef struct {
    unsigned char *cov;
    int width;
    int height;
} Glyphs;

/* framebuffer page geometry */
typedef struct {
    int yres;
    int npages;
} FbInfo;


static unsigned char *read_file(const char *path, long *out_len)
{
    FILE *file = fopen(path, "rb");
    if (file == NULL) {
        return NULL;
    }

    fseek(file, 0, SEEK_END);
    long len = ftell(file);
    fseek(file, 0, SEEK_SET);

    unsigned char *buf = malloc((size_t)len);
    if (buf == NULL) {
        fclose(file);
        return NULL;
    }

    size_t got = fread(buf, 1, (size_t)len, file);
    fclose(file);

    if (got != (size_t)len) {
        free(buf);
        return NULL;
    }

    if (out_len != NULL) {
        *out_len = len;
    }

    return buf;
}


static int load_font(const char *path, stbtt_fontinfo *font, unsigned char **buf)
{
    unsigned char *data = read_file(path, NULL);
    if (data == NULL) {
        fprintf(stderr, "cannot read font %s\n", path);
        return -1;
    }

    int offset = stbtt_GetFontOffsetForIndex(data, 0);
    if (stbtt_InitFont(font, data, offset) == 0) {
        fprintf(stderr, "invalid font %s\n", path);
        free(data);

        return -1;
    }

    *buf = data;
    return 0;
}


static Color parse_color(unsigned rgb444)
{
    Color color;
    color.r = (rgb444 >> 8) & 0xF;
    color.g = (rgb444 >> 4) & 0xF;
    color.b = rgb444 & 0xF;

    return color;
}


/* coverage (0..255) -> premultiplied ARGB4444 of the given color */
static uint16_t premultiply(unsigned char coverage, Color color)
{
    int a = coverage >> 4;
    int r = (color.r * a) / 15;
    int g = (color.g * a) / 15;
    int b = (color.b * a) / 15;

    return (uint16_t)((a << 12) | (r << 8) | (g << 4) | b);
}


/* rightmost ink column the text occupies. A glyph's ink can overhang its advance
 * (e.g. the 'k' in MissingLynk), so sizing the buffer from advances alone clips the
 * last character; we track the actual ink right edge instead.
 */
static int text_extent(const stbtt_fontinfo *font, const char *text, float scale, float pen0)
{
    float pen = pen0;
    int right = 0;
    for (int i = 0; text[i] != '\0'; i++) {
        int x0;
        int y0;
        int x1;
        int y1;

        stbtt_GetCodepointBitmapBox(font, text[i], scale, scale, &x0, &y0, &x1, &y1);
        if ((int)pen + x1 > right) {
            right = (int)pen + x1;
        }

        int advance;
        int left_bearing;
        stbtt_GetCodepointHMetrics(font, text[i], &advance, &left_bearing);
        pen += advance * scale;
    }

    return right;
}


static int text_baseline(const stbtt_fontinfo *font, float scale)
{
    int ascent;
    int descent;
    int line_gap;
    stbtt_GetFontVMetrics(font, &ascent, &descent, &line_gap);

    return (int)(ascent * scale) + 1;
}


/* max-blend one glyph bitmap into the coverage buffer at (ox, oy) */
static void blend_glyph(
  Glyphs *glyphs,
  const unsigned char *bitmap,
  int gw,
  int gh,
  int ox,
  int oy
)
{
    for (int j = 0; j < gh; j++) {
        for (int k = 0; k < gw; k++) {
            int px = ox + k;
            int py = oy + j;
            if (px < 0 || px >= glyphs->width || py < 0 || py >= glyphs->height) {
                continue;
            }

            unsigned char src = bitmap[j * gw + k];
            unsigned char *dst = &glyphs->cov[py * glyphs->width + px];
            if (src > *dst) {
                *dst = src;
            }
        }
    }
}


static Glyphs render_text(const stbtt_fontinfo *font, const char *text, int px_height)
{
    Glyphs glyphs;
    glyphs.cov = NULL;
    glyphs.width = 0;
    glyphs.height = 0;

    float scale = stbtt_ScaleForPixelHeight(font, (float)px_height);
    int baseline = text_baseline(font, scale);

    float pen_start = 2.0f;
    glyphs.width = text_extent(font, text, scale, pen_start) + 2;
    glyphs.height = px_height + 4;
    glyphs.cov = calloc((size_t)glyphs.width * glyphs.height, 1);
    if (glyphs.cov == NULL) {
        return glyphs;
    }

    float pen_x = pen_start;
    for (int i = 0; text[i] != '\0'; i++) {
        int gw;
        int gh;
        int gx;
        int gy;
        unsigned char *bitmap = stbtt_GetCodepointBitmap(font, scale, scale,
                                                         text[i], &gw, &gh, &gx, &gy);
        blend_glyph(&glyphs, bitmap, gw, gh, (int)pen_x + gx, baseline + gy);
        stbtt_FreeBitmap(bitmap, NULL);

        int advance;
        int left_bearing;
        stbtt_GetCodepointHMetrics(font, text[i], &advance, &left_bearing);
        pen_x += advance * scale;
    }

    return glyphs;
}


static FbInfo fb_query(int fd)
{
    FbInfo info;
    info.yres = 1080;
    info.npages = 1;

    unsigned char vinfo[256];
    if (ioctl(fd, FBIOGET_VSCREENINFO, vinfo) != 0) {
        return info;
    }

    uint32_t yres = *(uint32_t *)(vinfo + 4);
    uint32_t yres_virtual = *(uint32_t *)(vinfo + 12);
    if (yres == 0) {
        return info;
    }

    info.yres = (int)yres;
    info.npages = (int)(yres_virtual / yres);
    if (info.npages < 1) {
        info.npages = 1;
    }

    return info;
}


/* write one pixel row into every buffer page at (x, y) */
static void write_row(
  int fd,
  const uint16_t *row,
  int width,
  int x,
  int y,
  const FbInfo *info
)
{
    for (int page = 0; page < info->npages; page++) {
        off_t offset = ((off_t)(y + page * info->yres) * STRIDE_PX + x) * 2;
        if (pwrite(fd, row, (size_t)width * 2, offset) < 0) {
            perror("pwrite");
            return;
        }
    }
}


static void fb_blit(int fd, const Glyphs *glyphs, int x, int y, Color color, const FbInfo *info)
{
    uint16_t *row = malloc((size_t)glyphs->width * sizeof(uint16_t));
    if (row == NULL) {
        return;
    }

    for (int j = 0; j < glyphs->height; j++) {
        for (int k = 0; k < glyphs->width; k++) {
            row[k] = premultiply(glyphs->cov[j * glyphs->width + k], color);
        }
        write_row(fd, row, glyphs->width, x, y + j, info);
    }

    free(row);
}


static int parse_args(int argc, char **argv, Args *args)
{
    if (argc < 4) {
        fprintf(stderr, "usage: %s \"TEXT\" X Y [px_height] [rgb444] [font_path]\n", argv[0]);
        return -1;
    }

    args->text = argv[1];
    args->x = atoi(argv[2]);
    args->y = atoi(argv[3]);
    args->px_height = 34;

    if (argc > 4) {
        args->px_height = atoi(argv[4]);
    }

    args->rgb444 = 0xFFF;
    if (argc > 5) {
        args->rgb444 = (unsigned)strtoul(argv[5], NULL, 16);
    }

    args->font_path = DEFAULT_FONT;
    if (argc > 6) {
        args->font_path = argv[6];
    }

    return 0;
}


int main(int argc, char **argv)
{
    Args args;
    if (parse_args(argc, argv, &args) != 0) {
        return 2;
    }

    stbtt_fontinfo font;
    unsigned char *font_data;
    if (load_font(args.font_path, &font, &font_data) != 0) {
        return 1;
    }

    Glyphs glyphs = render_text(&font, args.text, args.px_height);
    free(font_data);
    if (glyphs.cov == NULL) {
        fprintf(stderr, "render failed\n");
        return 1;
    }

    int fd = open(FB, O_RDWR);
    if (fd < 0) {
        perror("open " FB);
        free(glyphs.cov);
        return 1;
    }

    FbInfo info = fb_query(fd);
    Color color = parse_color(args.rgb444);
    fb_blit(fd, &glyphs, args.x, args.y, color, &info);

    fprintf(stderr, "fbtext: '%s' %dx%d @(%d,%d) px=%d color=%03x pages=%d\n",
            args.text, glyphs.width, glyphs.height, args.x, args.y,
            args.px_height, args.rgb444, info.npages);

    close(fd);
    free(glyphs.cov);

    return 0;
}
