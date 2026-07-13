# Builds the compiled (aarch64, static) helpers under glue/ into build/. All are regenerable
# from the .c next to their scripts; build/ is git-ignored. The boot/ and flash/ scripts
# expect these prebuilt, so run `make` (or `make <tool>`) before using them.
#
# NOT covered: recovery/payload/ - a bare-metal freestanding build (linker scripts,
# objcopy, gmi wrapping) documented step-by-step in recovery/RECOVERY.md; build it
# from that runbook when (and only when) you need it.

CROSS ?= aarch64-linux-gnu-
CC := $(CROSS)gcc
CFLAGS ?= -static -O2 -Wall
BUILD := build

TOOLS := $(BUILD)/uboot-trigger $(BUILD)/wdt-reset $(BUILD)/ml-rf-replay

all: $(TOOLS)

$(BUILD)/uboot-trigger: boot/uboot-trigger.c boot/wdt.h | $(BUILD)
	$(CC) $(CFLAGS) -o $@ $<

$(BUILD)/wdt-reset: boot/wdt-reset.c boot/wdt.h | $(BUILD)
	$(CC) $(CFLAGS) -o $@ $<

$(BUILD)/ml-rf-replay: capture/ml-rf-replay.c | $(BUILD)
	$(CC) $(CFLAGS) -o $@ $<

$(BUILD):
	mkdir -p $(BUILD)

clean:
	rm -rf $(BUILD)

.PHONY: all clean
