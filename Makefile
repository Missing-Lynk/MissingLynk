# Build orchestrator for the MissingLynk wrapper: drives the component builds and the
# device bring-up. Component sources live in the submodules (kernel/, rootfs/) and the
# in-tree userspace/, native/, and glue/ trees.
#
# Build (cross-builds need docker with arm64 emulation via qemu binfmt):
#   make native       device tools (native/build.sh: mtdtool, fbtext, minidhcpd, mlmenu)
#   make userspace    the on-device programs (make -C userspace: daemons, gstreamer, hud)
#   make kernel       the open kernel Image + dtb + out-of-tree modules
#   make rootfs       the slim Alpine slot-B rootfs (production; integrates native + userspace + kernel)
#   make rootfs-dev   the dev rootfs (adds scp/sftp, strace/tcpdump/htop for bring-up)
#   make all          native + userspace + kernel, then the slim rootfs
#
# Prerequisite (needs the device connected; blobs persist in firmware/bin/):
#   make fetch-blobs  pull the vendor firmware blobs the rootfs stages (chagall, ...)
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

all:
	$(MAKE) native
	$(MAKE) userspace
	$(MAKE) kernel
	$(MAKE) rootfs

native:
	./native/build.sh

userspace:
	$(MAKE) -C userspace

kernel:
	kernel/scripts/build.sh
	kernel/modules/build.sh

fetch-blobs:
	uv run missinglynk fetch-blobs

rootfs:
	FLAVOR=slim ./rootfs/build.sh

rootfs-dev:
	FLAVOR=dev ./rootfs/build.sh

flash-rootfs:
	glue/flash/flash-rootfs-b.sh

ramboot:
	@source kernel/scripts/pin.env && \
	  glue/boot/ram-boot.sh "$$KERNEL_BUILD_DEFAULT/linux/arch/arm64/boot/Image" \
	                        "$$KERNEL_BUILD_DEFAULT/linux/arch/arm64/boot/proxima-9311.dtb"

flash-kernel:
	@source kernel/scripts/pin.env && \
	  glue/flash/flash-kernel-b.sh "$$KERNEL_BUILD_DEFAULT/linux/arch/arm64/boot/Image" \
	                               "$$KERNEL_BUILD_DEFAULT/linux/arch/arm64/boot/proxima-9311.dtb"

flashboot:
	glue/boot/ram-boot-flashed-b.sh

clean:
	-$(MAKE) -C userspace clean
	rm -f native/fbtext native/minidhcpd native/mtdtool native/mlmenu/mlmenu
	rm -rf rootfs/build
	-kernel/modules/build.sh clean

distclean: clean
	rm -rf kernel/build

.PHONY: all native userspace kernel fetch-blobs rootfs rootfs-dev flash-rootfs ramboot flash-kernel flashboot clean distclean
