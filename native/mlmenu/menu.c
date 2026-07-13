/* menu.c - the on-goggle MissingLynk menu app.
 *
 * Watches the buttons (/dev/input/event0). On the open gesture (long-press of a key,
 * default RIGHT) it grabs the input device (the vendor UI, fed via uinput_proxy, goes
 * silent), SIGSTOPs test_uidesign so it stops drawing over us, renders the menu, handles
 * up/down/center/back, then clears the screen, SIGCONTs the UI and ungrabs.
 *
 * Layout lives in render_menu(); drawing primitives are in draw.c; the component list and
 * descriptions are in config.c. Usage: mlmenu [open_keycode] [hold_ms]  (default 68 1200).
 */
#include "draw.h"
#include "config.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <fcntl.h>
#include <dirent.h>
#include <signal.h>
#include <time.h>
#include <poll.h>
#include <sys/ioctl.h>
#include <linux/input.h>

#define FONT "/usr/usrdata/fonts/HarmonyOS_Sans_Regular_subset.ttf"
#define INPUT "/dev/input/event0"
#define UI_PROC "test_uidesign"

/* adc-keys evdev codes */
#define K_BACK 66
#define K_CENTER 69
#define K_UP 87
#define K_DOWN 83
#define DEFAULT_OPEN_KEY 68     /* RIGHT */
#define DEFAULT_HOLD_MS 1200

static pid_t find_proc(const char *name)
{
    DIR *dir = opendir("/proc");
    if (dir == NULL) {
        return -1;
    }
    struct dirent *entry;
    pid_t found = -1;
    while ((entry = readdir(dir)) != NULL) {
        if (entry->d_name[0] < '0' || entry->d_name[0] > '9') {
            continue;
        }
        char path[64], comm[64];
        snprintf(path, sizeof path, "/proc/%s/comm", entry->d_name);
        FILE *file = fopen(path, "r");
        if (file == NULL) {
            continue;
        }
        if (fgets(comm, sizeof comm, file)) {
            comm[strcspn(comm, "\n")] = '\0';
            if (strcmp(comm, name) == 0) {
                found = (pid_t)atoi(entry->d_name);
            }
        }
        fclose(file);
        if (found > 0) {
            break;
        }
    }
    closedir(dir);
    return found;
}

static long now_ms(void)
{
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return ts.tv_sec * 1000L + ts.tv_nsec / 1000000L;
}

/* a key went down; return 1 if held >= hold_ms (open gesture), 0 if released first */
static int is_long_press(int fd, int key, int hold_ms)
{
    long t0 = now_ms();
    for (;;) {
        long rem = hold_ms - (now_ms() - t0);
        if (rem <= 0) {
            return 1;
        }
        struct pollfd pfd = {fd, POLLIN, 0};
        int poll_ret = poll(&pfd, 1, (int)rem);
        if (poll_ret <= 0) {
            return 1;   /* timeout: still held, no release came */
        }
        struct input_event ev;
        if (read(fd, &ev, sizeof ev) != sizeof ev) {
            return 0;
        }
        if (ev.type == EV_KEY && ev.code == key && ev.value == 0) {
            return 0;   /* released */
        }
    }
}

static void drain_input(int fd)
{
    struct input_event ev;
    struct pollfd pfd = {fd, POLLIN, 0};
    while (poll(&pfd, 1, 0) > 0 && read(fd, &ev, sizeof ev) == sizeof ev) { }
}

static void render_menu(Canvas *canvas, const Font *font, const Comp *comps, int n, int sel)
{
    int W = canvas->w, H = canvas->h;
    canvas_clear(canvas, C_BLACK);

    /* double frame + corner blocks */
    canvas_box(canvas, 46, 46, W - 92, H - 92, 3, C_GREEN);
    canvas_box(canvas, 62, 62, W - 124, H - 124, 1, C_DIM);
    int corners[4][2] = {{46, 46}, {W - 46, 46}, {46, H - 46}, {W - 46, H - 46}};
    for (int i = 0; i < 4; i++) {
        canvas_fill(canvas, corners[i][0] - 10, corners[i][1] - 10, 20, 20, C_GREEN);
    }

    /* block title (shadow then bright), centered */
    const char *title = "MISSINGLYNK";
    int cell = 15, gap = 12, ty = 120;
    int tx = (W - title_width(title, cell, gap)) / 2;
    draw_title(canvas, title, tx + 5, ty + 5, cell, gap, C_SHADOW);
    draw_title(canvas, title, tx, ty, cell, gap, C_GREEN);

    canvas_text_center(canvas, font, "-=[ goggle component control ]=-", ty + 150, 38, COL_DIM);
    canvas_fill(canvas, 110, 360, W - 220, 2, C_DIM);

    /* component rows */
    int x_cur = 150, x_box = 230, x_name = 330, x_desc = 760;
    int y0 = 440, dy = 84, bs = 46;
    for (int i = 0; i < n; i++) {
        int y = y0 + i * dy;
        Color col = (i == sel) ? COL_GREEN : COL_DIM;
        if (i == sel) {
            canvas_fill(canvas, 78, y - 14, W - 156, 76, C_HILITE);
            canvas_triangle(canvas, x_cur, y + 6, 40, C_GREEN);
        }
        canvas_box(canvas, x_box, y, bs, bs, 3, (i == sel) ? C_GREEN : C_DIM);
        if (comps[i].on) {
            canvas_fill(canvas, x_box + 10, y + 10, bs - 20, bs - 20, C_GREEN);
        }
        canvas_text(canvas, font, comps[i].name, x_name, y, 48, col);
        canvas_text(canvas, font, describe(comps[i].name), x_desc, y, 48, (i == sel) ? COL_GREEN : COL_DIM);
    }

    canvas_text_center(canvas, font, "up / down : move      center : toggle      back : exit", 892, 34, COL_GREEN);
    canvas_text_center(canvas, font, "[ * ]  changes take effect after a power-cycle", 940, 34, COL_DIM);

    canvas_present(canvas);
}

/* run the menu once (already grabbed + UI stopped); returns when the user exits */
static void run_menu(Canvas *canvas, const Font *font, int fd)
{
    Comp comps[MAX_COMP];
    int n = load_config(comps);
    int sel = 0;
    render_menu(canvas, font, comps, n, sel);

    struct input_event ev;
    while (read(fd, &ev, sizeof ev) == sizeof ev) {
        if (ev.type != EV_KEY) {
            continue;
        }
        int down = (ev.value == 1), repeat = (ev.value == 2);
        if (!down && !repeat) {
            continue;
        }

        if (ev.code == K_UP && (down || repeat)) {
            sel = (sel - 1 + n) % (n ? n : 1);
            render_menu(canvas, font, comps, n, sel);
        } else if (ev.code == K_DOWN && (down || repeat)) {
            sel = (sel + 1) % (n ? n : 1);
            render_menu(canvas, font, comps, n, sel);
        } else if (ev.code == K_CENTER && down && n > 0) {
            comps[sel].on = !comps[sel].on;
            save_config(comps, n);
            render_menu(canvas, font, comps, n, sel);
        } else if (ev.code == K_BACK && down) {
            return;
        }
    }
}

int main(int argc, char **argv)
{
    int open_key = (argc > 1) ? atoi(argv[1]) : DEFAULT_OPEN_KEY;
    int hold_ms = (argc > 2) ? atoi(argv[2]) : DEFAULT_HOLD_MS;

    Font font;
    if (font_load(FONT, &font) != 0) {
        return 1;
    }

    Canvas canvas;
    if (canvas_open(&canvas) != 0) {
        return 1;
    }

    int fd = open(INPUT, O_RDONLY);
    if (fd < 0) {
        perror("open " INPUT);
        return 1;
    }

    fprintf(stderr, "mlmenu: ready, open=keycode %d hold %dms (fb %dx%d pages %d)\n",
            open_key, hold_ms, canvas.w, canvas.h, canvas.npages);

    struct input_event ev;
    while (read(fd, &ev, sizeof ev) == sizeof ev) {
        if (ev.type != EV_KEY || ev.code != open_key || ev.value != 1) {
            continue;
        }
        if (!is_long_press(fd, open_key, hold_ms)) {
            continue;
        }

        ioctl(fd, EVIOCGRAB, 1);
        pid_t ui = find_proc(UI_PROC);
        if (ui > 0) {
            kill(ui, SIGSTOP);
        }
        drain_input(fd);

        run_menu(&canvas, &font, fd);

        canvas_clear(&canvas, C_TRANSP);
        canvas_present(&canvas);
        if (ui > 0) {
            kill(ui, SIGCONT);
        }
        ioctl(fd, EVIOCGRAB, 0);
        drain_input(fd);
    }
    return 0;
}
