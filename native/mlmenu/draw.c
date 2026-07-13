/* draw.c - implementation of the drawing layer (see draw.h). */
#include "draw.h"   /* pulls in stb_truetype.h declarations (guarded) first */

/* this is the one translation unit that emits the stb_truetype implementation;
 * define the macro after draw.h so the header's implementation block is included
 * exactly once (it lives outside stb's include guard). */
#define STB_TRUETYPE_IMPLEMENTATION
#include "stb_truetype.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <fcntl.h>
#include <sys/ioctl.h>
#include <sys/mman.h>

#define FB "/dev/fb0"
#define STRIDE_PX 2048
#define FBIOGET_VSCREENINFO 0x4600

const Color COL_GREEN = {3, 15, 7};
const Color COL_DIM = {1, 9, 4};

static unsigned char *read_file(const char *path, long *out_len)
{
    FILE *f = fopen(path, "rb");
    if (f == NULL) {
        return NULL;
    }
    fseek(f, 0, SEEK_END);
    long len = ftell(f);
    fseek(f, 0, SEEK_SET);
    unsigned char *buf = malloc((size_t)len);
    if (buf == NULL) {
        fclose(f);
        return NULL;
    }
    size_t got = fread(buf, 1, (size_t)len, f);
    fclose(f);
    if (got != (size_t)len) {
        free(buf);
        return NULL;
    }
    if (out_len) {
        *out_len = len;
    }
    return buf;
}

int font_load(const char *path, Font *font)
{
    font->data = read_file(path, NULL);
    if (font->data == NULL) {
        fprintf(stderr, "cannot read font %s\n", path);
        return -1;
    }
    if (stbtt_InitFont(&font->info, font->data, stbtt_GetFontOffsetForIndex(font->data, 0)) == 0) {
        fprintf(stderr, "invalid font %s\n", path);
        free(font->data);
        return -1;
    }
    return 0;
}

/* an 8-bit coverage bitmap of rasterized text */
typedef struct { unsigned char *cov; int width; int height; } Glyphs;

static int text_extent(const stbtt_fontinfo *font, const char *text, float scale, float pen0)
{
    float pen = pen0;
    int right = 0;
    for (int i = 0; text[i]; i++) {
        int x0, y0, x1, y1;
        stbtt_GetCodepointBitmapBox(font, text[i], scale, scale, &x0, &y0, &x1, &y1);
        if ((int)pen + x1 > right) {
            right = (int)pen + x1;
        }
        int adv, lsb;
        stbtt_GetCodepointHMetrics(font, text[i], &adv, &lsb);
        pen += adv * scale;
    }
    return right;
}

static void blend_glyph(Glyphs *g, const unsigned char *bm, int gw, int gh, int ox, int oy)
{
    for (int j = 0; j < gh; j++) {
        for (int k = 0; k < gw; k++) {
            int px = ox + k, py = oy + j;
            if (px < 0 || px >= g->width || py < 0 || py >= g->height) {
                continue;
            }
            unsigned char src = bm[j * gw + k];
            unsigned char *dst = &g->cov[py * g->width + px];
            if (src > *dst) {
                *dst = src;
            }
        }
    }
}

static Glyphs render_text(const stbtt_fontinfo *font, const char *text, int px_height)
{
    Glyphs g = {NULL, 0, 0};
    float scale = stbtt_ScaleForPixelHeight(font, (float)px_height);
    int ascent, descent, line_gap;
    stbtt_GetFontVMetrics(font, &ascent, &descent, &line_gap);
    int baseline = (int)(ascent * scale) + 1;

    g.width = text_extent(font, text, scale, 2.0f) + 2;
    g.height = px_height + 4;
    g.cov = calloc((size_t)g.width * g.height, 1);
    if (g.cov == NULL) {
        return g;
    }

    float pen = 2.0f;
    for (int i = 0; text[i]; i++) {
        int gw, gh, gx, gy;
        unsigned char *bm = stbtt_GetCodepointBitmap(font, scale, scale, text[i], &gw, &gh, &gx, &gy);
        blend_glyph(&g, bm, gw, gh, (int)pen + gx, baseline + gy);
        stbtt_FreeBitmap(bm, NULL);
        int adv, lsb;
        stbtt_GetCodepointHMetrics(font, text[i], &adv, &lsb);
        pen += adv * scale;
    }
    return g;
}

int canvas_open(Canvas *canvas)
{
    canvas->fd = open(FB, O_RDWR);
    if (canvas->fd < 0) {
        perror("open " FB);
        return -1;
    }

    unsigned char vinfo[256];
    int xres = 1920, yres = 1080, yvirt = 1080;
    if (ioctl(canvas->fd, FBIOGET_VSCREENINFO, vinfo) == 0) {
        xres = (int)(*(uint32_t *)(vinfo + 0));
        yres = (int)(*(uint32_t *)(vinfo + 4));
        yvirt = (int)(*(uint32_t *)(vinfo + 12));
    }
    if (xres <= 0) {
        xres = 1920;
    }
    if (yres <= 0) {
        yres = 1080;
    }
    canvas->w = xres;
    canvas->h = yres;
    canvas->npages = yvirt / yres;
    if (canvas->npages < 1) {
        canvas->npages = 1;
    }

    size_t fbbytes = (size_t)STRIDE_PX * yres * canvas->npages * 2;
    canvas->fb = mmap(NULL, fbbytes, PROT_READ | PROT_WRITE, MAP_SHARED, canvas->fd, 0);
    if (canvas->fb == MAP_FAILED) {
        perror("mmap");
        close(canvas->fd);
        return -1;
    }

    canvas->px = malloc((size_t)canvas->w * canvas->h * 2);
    if (canvas->px == NULL) {
        munmap(canvas->fb, fbbytes);
        close(canvas->fd);
        return -1;
    }
    return 0;
}

void canvas_clear(Canvas *canvas, uint16_t color)
{
    for (int i = 0; i < canvas->w * canvas->h; i++) {
        canvas->px[i] = color;
    }
}

void canvas_fill(Canvas *canvas, int x, int y, int w, int h, uint16_t color)
{
    for (int j = y; j < y + h; j++) {
        if (j < 0 || j >= canvas->h) {
            continue;
        }
        for (int k = x; k < x + w; k++) {
            if (k < 0 || k >= canvas->w) {
                continue;
            }
            canvas->px[j * canvas->w + k] = color;
        }
    }
}

void canvas_box(Canvas *canvas, int x, int y, int w, int h, int thickness, uint16_t color)
{
    canvas_fill(canvas, x, y, w, thickness, color);
    canvas_fill(canvas, x, y + h - thickness, w, thickness, color);
    canvas_fill(canvas, x, y, thickness, h, color);
    canvas_fill(canvas, x + w - thickness, y, thickness, h, color);
}

void canvas_triangle(Canvas *canvas, int x, int y, int size, uint16_t color)
{
    for (int j = 0; j < size; j++) {
        int span = (j <= size / 2 ? j : size - j) * 2;
        canvas_fill(canvas, x, y + j, span / 2 + 1, 1, color);
    }
}

/* over-composite a coverage pixel of `col` onto an opaque dst */
static uint16_t over(uint16_t dst, unsigned char cov, Color col)
{
    int a = cov >> 4;
    if (a == 0) {
        return dst;
    }
    int sr = col.r * a / 15, sg = col.g * a / 15, sb = col.b * a / 15;
    int dr = (dst >> 8) & 0xF, dg = (dst >> 4) & 0xF, db = dst & 0xF;
    int inv = 15 - a;
    int r = sr + dr * inv / 15, g = sg + dg * inv / 15, b = sb + db * inv / 15;
    return (uint16_t)((0xF << 12) | (r << 8) | (g << 4) | b);
}

void canvas_text(Canvas *canvas, const Font *font, const char *str, int x, int y, int px, Color col)
{
    Glyphs g = render_text(&font->info, str, px);
    if (g.cov == NULL) {
        return;
    }
    for (int j = 0; j < g.height; j++) {
        for (int k = 0; k < g.width; k++) {
            int dx = x + k, dy = y + j;
            if (dx < 0 || dx >= canvas->w || dy < 0 || dy >= canvas->h) {
                continue;
            }
            canvas->px[dy * canvas->w + dx] = over(canvas->px[dy * canvas->w + dx], g.cov[j * g.width + k], col);
        }
    }
    free(g.cov);
}

int text_width(const Font *font, const char *str, int px)
{
    float scale = stbtt_ScaleForPixelHeight(&font->info, (float)px);
    return text_extent(&font->info, str, scale, 2.0f) + 2;
}

void canvas_text_center(Canvas *canvas, const Font *font, const char *str, int y, int px, Color col)
{
    canvas_text(canvas, font, str, (canvas->w - text_width(font, str, px)) / 2, y, px, col);
}

void canvas_present(Canvas *canvas)
{
    for (int p = 0; p < canvas->npages; p++) {
        for (int y = 0; y < canvas->h; y++) {
            uint16_t *dst = canvas->fb + (size_t)(y + p * canvas->h) * STRIDE_PX;
            memcpy(dst, canvas->px + (size_t)y * canvas->w, (size_t)canvas->w * 2);
        }
    }
}

typedef struct { char ch; unsigned char rows[7]; } BlockGlyph;
static const BlockGlyph BLOCKS[] = {
    {'M', {0x11, 0x1B, 0x15, 0x11, 0x11, 0x11, 0x11}},
    {'I', {0x1F, 0x04, 0x04, 0x04, 0x04, 0x04, 0x1F}},
    {'S', {0x0F, 0x10, 0x10, 0x0E, 0x01, 0x01, 0x1E}},
    {'N', {0x11, 0x19, 0x15, 0x13, 0x11, 0x11, 0x11}},
    {'G', {0x0E, 0x11, 0x10, 0x17, 0x11, 0x11, 0x0F}},
    {'L', {0x10, 0x10, 0x10, 0x10, 0x10, 0x10, 0x1F}},
    {'Y', {0x11, 0x11, 0x0A, 0x04, 0x04, 0x04, 0x04}},
    {'K', {0x11, 0x12, 0x14, 0x18, 0x14, 0x12, 0x11}},
};

static const unsigned char *block_for(char ch)
{
    for (size_t i = 0; i < sizeof(BLOCKS) / sizeof(BLOCKS[0]); i++) {
        if (BLOCKS[i].ch == ch) {
            return BLOCKS[i].rows;
        }
    }
    return NULL;
}

static int block_cols(const unsigned char *g)
{
    int mask = 0;
    for (int r = 0; r < 7; r++) {
        for (int col = 0; col < 5; col++) {
            if (g[r] & (1 << (4 - col))) {
                if (col + 1 > mask) {
                    mask = col + 1;
                }
            }
        }
    }
    return mask ? mask : 5;
}

static int kern(char a, char b)
{
    if (a == 'L' && b == 'Y') {
        return -14;
    }
    return 0;
}

int title_width(const char *str, int cell, int gap)
{
    int x = 0;
    for (int i = 0; str[i]; i++) {
        if (i) {
            x += gap + kern(str[i - 1], str[i]);
        }
        const unsigned char *g = block_for(str[i]);
        x += (g ? block_cols(g) : 5) * cell;
    }
    return x;
}

void draw_title(Canvas *canvas, const char *str, int x, int y, int cell, int gap, uint16_t color)
{
    int cx = x;
    for (int i = 0; str[i]; i++) {
        if (i) {
            cx += gap + kern(str[i - 1], str[i]);
        }
        const unsigned char *g = block_for(str[i]);
        if (g) {
            for (int r = 0; r < 7; r++) {
                for (int col = 0; col < 5; col++) {
                    if (g[r] & (1 << (4 - col))) {
                        canvas_fill(canvas, cx + col * cell, y + r * cell, cell - 1, cell - 1, color);
                    }
                }
            }
            cx += block_cols(g) * cell;
        }
    }
}
