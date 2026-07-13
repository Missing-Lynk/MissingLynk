# mlmenu - on-goggle menu

A native daemon that draws a green-on-black "MissingLynk" menu on the goggle screen so you
can enable/disable components without a PC. Long-press a button (default RIGHT) to open it;
up/down move, center toggles, back exits.

## How it works

On the open gesture it grabs the input device (`EVIOCGRAB` on `/dev/input/event0`, so the
vendor UI fed via `uinput_proxy` goes silent), `SIGSTOP`s `test_uidesign` so it stops
drawing over us, renders the menu to `/dev/fb0`, then on exit clears the screen,
`SIGCONT`s the UI and ungrabs. The menu list comes from the same config file the Python
CLI writes (`/usrdata/missinglynk/config`); toggling rewrites it (applies next boot).

## Files

| file        | responsibility |
|-------------|----------------|
| `draw.h/.c` | drawing layer: framebuffer canvas (fill/box/triangle), TTF text, the block title font. No menu knowledge. |
| `config.h/.c` | the component list: read/write the config file and one-line descriptions. |
| `menu.c`    | the app: input/open-gesture, freezing the vendor UI, the menu layout (`render_menu`), the loop, `main`. |

Drawing primitives are reusable and menu-agnostic; the layout and component data are
separate, so each kind of change has one place to go.

## Common changes

- **Add a component to the menu**: enable it via the Python CLI so it lands in the config
  file (the menu lists whatever the config contains, in order), then add a one-line
  description in `describe()` in `config.c`.
- **Change the layout / colors / wording**: `render_menu()` in `menu.c` (positions, sizes)
  and the `C_*` color defines / `COL_*` text colors in `draw.h`/`draw.c`.
- **Change the open gesture or buttons**: the `K_*` / `DEFAULT_OPEN_KEY` / `DEFAULT_HOLD_MS`
  defines and the watch loop in `menu.c`. The open key and hold time are also runtime args:
  `mlmenu <open_keycode> <hold_ms>`.
- **Add a new drawing primitive**: add it to `draw.c` and declare it in `draw.h`.

## Build

`native/build.sh` (arm64 gcc:7 container, glibc <= the goggle's 2.25). Output:
`native/mlmenu/mlmenu`. The Python CLI installs it as always-on infrastructure
(`ALWAYS_FILES`) and launches it unconditionally at boot, so it cannot be disabled and
strand you. It is not a toggleable component and does not list itself in the menu.
