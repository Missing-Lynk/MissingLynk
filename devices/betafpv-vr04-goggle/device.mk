# device.mk - the manifest for one supported device (BetaFPV VR04 HD goggle, P1_GND).
#
# Single source of truth for this device's identity, capabilities, and build pointers. The root
# Makefile does `include devices/$(DEVICE)/device.mk` and every target reads DEV_* from here; the
# Python CLI and Go flasher read the same file (later). make-native KEY=VALUE, no quotes (so the
# tooling parser stays a trivial split). One folder per device (federated: the DTS + fragments
# live in kernel/devices/<name>/, the rootfs profile/overlay in rootfs/, this manifest ties them).
# See plans/device-hal.md.

DEV_NAME           = betafpv-vr04-goggle
DEV_VENDOR         = betafpv
DEV_MODEL          = Artosyn Proxima-9311 (BetaFPV VR04 HD goggle)
DEV_CLASS          = goggle

# Identity (sdk_version.json on the device; the flasher whitelist + mlimg target string).
DEV_PRODUCT        = P1_GND_VR04
DEV_HW_VERSION     = v2.0
DEV_FW_VERSION     = 1.0.44.rel
DEV_BOARD_TYPE     = c402
DEV_RF_ROLE        = gnd

# Capabilities: source of truth for UI gating (injected into ml-hud as -D defines, step 6) + docs.
# Kernel/rootfs do not branch on these; they resolve concrete files by name (below).
DEV_HAS_DISPLAY    = 1
DEV_HAS_CAMERA     = 0
DEV_HAS_KEYPAD     = 1
DEV_HAS_BUZZER     = 1
DEV_HAS_LED        = 1
DEV_HAS_DVR        = 1
DEV_HAS_FC_LINK    = 0

# Build pointers. Kernel + rootfs both resolve by DEV_NAME (= DEVICE), no explicit path needed:
#   kernel/devices/$(DEV_NAME)/  (DTS + fragments)   rootfs/devices/$(DEV_NAME)/ (board.conf + overlay/)
# DEV_DTB is the built .dtb basename (ramboot/flash-kernel refs).
DEV_DTB            = proxima-9311.dtb
DEV_UI_BOARD       = betafpv_p1_hd                 # userspace/ml-hud/src/hal/board_<this>.c
DEV_MLIMG_TARGET   = P1_GND_VR04
