# Build orchestrator for the MissingLynk wrapper: drives the component builds and the
# device bring-up. Component sources live in the submodules (kernel/, rootfs/) and the
# in-tree userspace/, native/, and glue/ trees.
#
# DEVICE=<name> selects the target device; the manifest devices/<name>/device.mk feeds the
# kernel (BOARD), the dtb name, load map, and the rootfs profile. Select it ONCE with
# `make setup DEVICE=<name>` (persisted to .device); then every target below uses it with no
# repetition. A command-line DEVICE=<name> still overrides for a one-off.
# List devices: `ls devices/`. Add one: see docs/adding-a-device.md.
#
# Build (cross-builds need docker with arm64 emulation via qemu binfmt):
#   make native       device tools (native/build.sh: mtdtool, fbtext, minidhcpd, mlmenu)
#   make umtprd       uMTP-Responder for the MTP-over-USB recordings gadget (clones upstream)
#   make userspace    the on-device programs (make -C userspace: daemons, gstreamer, hud)
#   make kernel       the open kernel Image + dtb + out-of-tree modules
#   make rootfs       the slim Alpine slot-B rootfs (production; integrates native + userspace + kernel)
#   make rootfs-dev   the dev rootfs (adds scp/sftp, strace/tcpdump/htop for bring-up)
#   make all          native + userspace + kernel, then the slim rootfs
#   make image        all + capture vendor slot blobs + assemble one flashable .mlimg bundle
#
# Prerequisite (needs the device connected; blobs persist in firmware/bin/):
#   make fetch-blobs  pull the vendor firmware blobs the rootfs stages (chagall, ...)
#   make image-blobs  dump the raw slot partitions the .mlimg's vendor components need
#
# Device bring-up (writes slot B only; slot A is never touched, and no target flips the active
# slot - that stays a deliberate manual step once the flashed kernel is proven):
#   make flash-rootfs flash rootfs/build/rootfs.ubi onto slot B (userapp1)
#   make ramboot      RAM-boot the built kernel (from files) against slot B; nothing committed
#   make flash-kernel flash the built kernel Image + dtb onto slot B (kernel1/dtb1)
#   make flashboot    RAM-boot slot B's flashed kernel1/dtb1 to prove the on-flash copy boots
#
# Clean:
#   make clean        remove component build outputs (keeps the pinned kernel tree)
#   make distclean    also remove the kernel build tree (forces a full kernel re-fetch + rebuild)

SHELL := /bin/bash

# Device selector: which supported device to build for. The name matches devices/<name>/ (the
# manifest below), kernel/devices/<name>/ (DTS + config fragments), and the rootfs profile.
# Resolved from .device (written by `make setup DEVICE=<name>`); a command-line DEVICE=<name>
# overrides; absent both, the goggle. So a bare `make` after `make setup` targets the selection.
DEVICE ?= $(shell cat .device 2>/dev/null || echo betafpv-vr04-goggle)
include devices/$(DEVICE)/device.mk

all:
	$(MAKE) native
	$(MAKE) userspace
	$(MAKE) kernel
	$(MAKE) rootfs

# Select the active device, persisted to .device (per-machine, gitignored).
#   make setup DEVICE=<name>   set + show;   make setup   show current.   List: ls devices/
setup:
ifeq ($(origin DEVICE),command line)
	@test -d "devices/$(DEVICE)" || { echo "unknown device '$(DEVICE)' (see: ls devices/)"; exit 1; }
	@echo "$(DEVICE)" > .device
	@echo "device set -> $(DEVICE)"
else
	@echo "current device -> $(DEVICE)"
endif
	@echo "  product=$(DEV_PRODUCT)  dtb=$(DEV_DTB)  mlimg=$(DEV_MLIMG_TARGET)"

native:
	./native/build.sh

# uMTP-Responder for the MTP-over-USB recordings gadget. Kept out of `native`/`all`: it clones a
# pinned upstream from the network, so it must not break the offline-cacheable common build.
# Build once; rootfs/build.sh stages native/umtprd/build/umtprd if present.
umtprd:
	./native/umtprd/build.sh

# The manifest's capability flags reach ml-hud as compile-time -D defines (device-agnostic UI code,
# per-device caps). userspace/ builds standalone too, so its Makefile defaults these to the goggle.
userspace:
	$(MAKE) -C userspace \
	  DEV_HAS_DISPLAY=$(DEV_HAS_DISPLAY) DEV_HAS_CAMERA=$(DEV_HAS_CAMERA) \
	  DEV_HAS_KEYPAD=$(DEV_HAS_KEYPAD) DEV_HAS_BUZZER=$(DEV_HAS_BUZZER) \
	  DEV_HAS_LED=$(DEV_HAS_LED) DEV_HAS_DVR=$(DEV_HAS_DVR) DEV_HAS_FC_LINK=$(DEV_HAS_FC_LINK)

# Host-side flashing GUI (ml-flasher). Built reproducibly in a container (needs
# only Docker on the host); embeds native/build/mlflash and extracts the binary to
# flasher/build/ml-flasher. Kept out of `native`/`all` (needs Docker + network).
flasher:
	DOCKER_BUILDKIT=1 docker build -f flasher/Dockerfile --output type=local,dest=flasher/build .

flasher-windows:
	DOCKER_BUILDKIT=1 docker build -f flasher/Dockerfile.windows --output type=local,dest=flasher/build .

kernel:
	BOARD=$(DEVICE) kernel/scripts/build.sh
	kernel/modules/build.sh

fetch-blobs:
	uv run missinglynk fetch-blobs

rootfs:
	FLAVOR=slim ./rootfs/build.sh $(DEVICE)

rootfs-dev:
	FLAVOR=dev ./rootfs/build.sh $(DEVICE)

# One flashable .mlimg bundle (uboot + env + kernel + dtb + rootfs, everything a vendor slot
# carries except SPL): build every component, capture the vendor slot blobs, then assemble and
# self-verify. The blob capture needs the device connected once; it persists in firmware/bin/
# and is skipped on later runs, so a rebuild after the first capture needs no device.
image: all image-blobs
	uv run python glue/flash/mlimg.py build --device $(DEV_MLIMG_TARGET)

# Raw slot partitions the mlimg's vendor components need (stock uboot + env + an OTRA template).
# Captured from a connected device into firmware/bin/<P1_GND>/; skipped when already present.
image-blobs:
	@if [ -n "$$(find firmware/bin -name 'uboot.bin' -o -name '*uboot0.bin' -o -name '*uboot1.bin' 2>/dev/null | head -1)" ]; then \
	  echo "[image] vendor slot blobs already in firmware/bin (skipping dump)"; \
	else \
	  echo "[image] capturing vendor slot blobs from the connected device..."; \
	  uv run missinglynk dump-partitions --dest firmware/bin; \
	fi

flash-rootfs:
	DEVICE=$(DEVICE) glue/flash/flash-rootfs-b.sh

ramboot:
	@source kernel/scripts/pin.env && \
	  DEVICE=$(DEVICE) glue/boot/ram-boot.sh "$$KERNEL_BUILD_DEFAULT/linux/arch/arm64/boot/Image" \
	                        "$$KERNEL_BUILD_DEFAULT/linux/arch/arm64/boot/$(DEV_DTB)"

flash-kernel:
	@source kernel/scripts/pin.env && \
	  DEVICE=$(DEVICE) glue/flash/flash-kernel-b.sh "$$KERNEL_BUILD_DEFAULT/linux/arch/arm64/boot/Image" \
	                               "$$KERNEL_BUILD_DEFAULT/linux/arch/arm64/boot/$(DEV_DTB)"

flashboot:
	DEVICE=$(DEVICE) glue/boot/ram-boot-flashed-b.sh

clean:
	-$(MAKE) -C userspace clean
	rm -f native/fbtext native/minidhcpd native/mtdtool native/mlmenu/mlmenu
	rm -rf native/umtprd/build
	rm -rf rootfs/build
	-kernel/modules/build.sh clean

distclean: clean
	rm -rf kernel/build

.PHONY: all setup native umtprd userspace flasher flasher-windows kernel fetch-blobs rootfs rootfs-dev image image-blobs flash-rootfs ramboot flash-kernel flashboot clean distclean
