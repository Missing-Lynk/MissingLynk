/* draw.h - framebuffer canvas, font text, and the block title font.
 * The drawing layer for the on-goggle menu. Compose into an offscreen buffer with the
 * canvas_* calls, then canvas_present() to push it to every framebuffer page.
 */
#ifndef MLMENU_DRAW_H
#define MLMENU_DRAW_H

#include <stdint.h>
#include "stb_truetype.h"

/* an RGB color, one nibble (0..15) per channel, for anti-aliased text */
typedef struct { int r, g, b; } Color;
extern const Color COL_GREEN;
extern const Color COL_DIM;

/* opaque ARGB4444 fills (A=F) */
#define C_BLACK  0xF000u
#define C_TRANSP 0x0000u
#define C_GREEN  0xF3F7u
#define C_DIM    0xF194u
#define C_SHADOW 0xF042u
#define C_HILITE 0xF031u

/* the goggle's TTF, loaded once */
typedef struct { stbtt_fontinfo info; unsigned char *data; } Font;
int font_load(const char *path, Font *font);

/* an offscreen ARGB4444 buffer the size of one screen, plus the mmap'd framebuffer */
typedef struct {
    int fd;
    uint16_t *fb;     /* mmap of the whole (multi-page) framebuffer */
    uint16_t *px;     /* w*h offscreen compose buffer */
    int w, h;         /* xres, yres */
    int npages;
} Canvas;

int  canvas_open(Canvas *canvas);
void canvas_clear(Canvas *canvas, uint16_t color);
void canvas_fill(Canvas *canvas, int x, int y, int w, int h, uint16_t color);
void canvas_box(Canvas *canvas, int x, int y, int w, int h, int thickness, uint16_t color);
void canvas_triangle(Canvas *canvas, int x, int y, int size, uint16_t color);  /* right-pointing */
void canvas_text(Canvas *canvas, const Font *font, const char *str, int x, int y, int px, Color col);
void canvas_text_center(Canvas *canvas, const Font *font, const char *str, int y, int px, Color col);
int  text_width(const Font *font, const char *str, int px);
void canvas_present(Canvas *canvas);  /* copy the offscreen buffer to all framebuffer pages */

/* the chunky title banner (drawn from a 5x7 block font, not the TTF) */
int  title_width(const char *str, int cell, int gap);
void draw_title(Canvas *canvas, const char *str, int x, int y, int cell, int gap, uint16_t color);

#endif
