# device.mk - manifest for the BetaFPV VR04 HD air unit (P1_SKY): identity, capabilities, and
# build pointers for this device (the goggle manifest carries the shared mechanism notes).
# See docs/adding-a-device.md.

DEV_NAME           = betafpv-vr04-air
DEV_VENDOR         = betafpv
DEV_MODEL          = Artosyn Proxima-9311 (BetaFPV VR04 HD air unit)
DEV_CLASS          = air

# Identity (sdk_version.json on the device; the flasher whitelist + mlimg target string).
DEV_PRODUCT        = P1_SKY
DEV_HW_VERSION     = v1.0
DEV_FW_VERSION     = 1.0.44.rel
DEV_BOARD_TYPE     = c401
DEV_RF_ROLE        = air

# Capabilities: source of truth for UI gating (injected into ml-hud as -D defines) + docs.
# Kernel/rootfs do not branch on these; they resolve concrete files by name. The HAS_* flags
# compose (a unit may set several), so they describe hardware, not a device class.
# Comments sit on their own lines so the make values stay bare (a trailing inline comment would
# leave whitespace in the value, which then leaks into ml-hud's -D defines).
DEV_HAS_DISPLAY     = 0
# NT99235 sensor capture.
DEV_HAS_CAMERA      = 1
# No adc-keys ladder (the goggle's input); a single bind button instead, so KEYPAD=0/GPIO_KEYS=1.
DEV_HAS_KEYPAD      = 0
# Bind button: global GPIO 42 (vendor bank 1 pin 19), active low, KEY_CONNECT on the open kernel.
DEV_HAS_GPIO_KEYS   = 1
DEV_HAS_BUZZER      = 0
# Two plain GPIO LEDs (red bind on GPIO 0, green power on GPIO 1, active-low leds-gpio), NOT the
# goggle's WS2812-over-SPI chain, so this does NOT imply ml-ledd (WS2812-only, via the goggle overlay).
DEV_HAS_LED         = 1
# No microSD -> no DVR, no MTP (rootfs board.conf HAS_SD=0); an SD variant flips these two + HAS_SD.
DEV_HAS_SD          = 0
DEV_HAS_DVR         = 0
# MSP over /dev/ttyS1, air-only.
DEV_HAS_FC_LINK     = 1

# Build pointers. Kernel + rootfs resolve by DEV_NAME (kernel/devices/$(DEV_NAME)/,
# rootfs/devices/$(DEV_NAME)/). DEV_DTB is the built .dtb basename.
DEV_DTB            = proxima-9311-air.dtb
DEV_UI_BOARD       =                               # none - the air unit has no menu/OSD UI
DEV_MLIMG_TARGET   = P1_SKY

# RAM-boot host load map (glue/boot/ram-boot.sh loady addresses; below the 0x25000000 mmz
# carveout, above the decompressed kernel at 0x200a0000).
DEV_KADDR          = 0x21800000
DEV_RDADDR         = 0x23000000
DEV_DTADDR         = 0x24800000

# Flash partition table, U-Boot mtdparts syntax, in flash order: the host tooling's single copy
# of the layout (see docs/adding-a-device.md). Same layout as the goggle, confirmed on-device;
# stated per device rather than shared because the table describes this board's flash, not the
# SoC. Sizes are cumulative; only the first entry states an explicit @offset.
DEV_MTDPARTS       = spi32766.1:256k@0(spl0),256k(spl1),256k(spl2),256k(spl3),256k(gpt0),256k(gpt1),512K(vendor),6M(factory),384K(env0),384K(env1),768K(uboot0),768K(uboot1),6M(kernel0),6M(kernel1),384K(dtb0),384K(dtb1),45M(userapp0),45M(userapp1),6M(usr_data),6M(usr_log)
