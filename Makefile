# Build orchestrator for the MissingLynk wrapper: drives the component builds and the
# device bring-up. Component sources live in the submodules (kernel/, rootfs/) and the
# in-tree userspace/, native/, and glue/ trees.
#
# DEVICE=<name> selects the target device; the manifest devices/<name>/device.mk feeds the
# kernel (BOARD), the dtb name, load map, and the rootfs profile. Select it ONCE with
# `make setup DEVICE=<name>` (persisted to .device); then every target below uses it with no
# repetition. A command-line DEVICE=<name> still overrides for a one-off. There is no default:
# a device-dependent target with no device set fails rather than guessing.
# List devices: `make list-devices`. Add one: see docs/adding-a-device.md.
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
#   make flash-rootfs flash rootfs/build/rootfs-<device>.ubi onto slot B (userapp1)
#   make ramboot      RAM-boot the built kernel (from files) against slot B; nothing committed
#   make flash-kernel flash the built kernel Image + dtb onto slot B (kernel1/dtb1)
#   make flashboot    RAM-boot slot B's flashed kernel1/dtb1 to prove the on-flash copy boots
#
# Host-side checks (no device needed):
#   make check-python    lint + unit-test the Python CLI (missinglynk/); also: make lint, make test
#   make check-shell     shellcheck the host-side shell scripts (glue/, native/)
#   make check-userspace build + run the userspace submodule's host tests (make -C userspace check)
#   make check-native    build + run native/'s host tests (the .mlimg rootfs inflate writer)
#   make check-go        vet + unit-test the host flasher's Go packages (flasher/, minus the GUI)
#   make check           all five of the above
#
# Clean:
#   make clean        remove component build outputs (keeps the pinned kernel tree)
#   make distclean    also remove the kernel build tree (forces a full kernel re-fetch + rebuild)

SHELL := /bin/bash

# Device selector: which supported device to build for. The name matches devices/<name>/ (the
# manifest below), kernel/devices/<name>/ (DTS + config fragments), and the rootfs profile.
# Resolved from .device (written by `make setup DEVICE=<name>`); a command-line DEVICE=<name>
# overrides. There is no default: device-dependent targets require it (see require-device) and
# fail when it is empty. The include is silent so device-independent targets still parse with
# no device set.
DEVICE ?= $(shell cat .device 2>/dev/null)
-include devices/$(DEVICE)/device.mk

# The short unit id inside DEV_PRODUCT (P1_GND_VR04 -> P1_GND, P1_SKY -> P1_SKY): the first two
# underscore-separated fields. `missinglynk dump-partitions` names its output directory after this,
# so it is the key the vendor-blob paths below resolve under.
DEV_BLOBS_ID = $(word 1,$(subst _, ,$(DEV_PRODUCT)))_$(word 2,$(subst _, ,$(DEV_PRODUCT)))

all: require-device
	$(MAKE) native
	$(MAKE) userspace
	$(MAKE) kernel
	$(MAKE) rootfs

# Guard for device-dependent targets: fail with a pointer to the setup flow when no device is set.
.PHONY: require-device
require-device:
	@if [ -z "$(DEVICE)" ]; then \
	  echo "error: no device set. Run 'make list-devices' to see options," >&2; \
	  echo "       then 'make setup DEVICE=<name>' (or pass DEVICE=<name>)." >&2; \
	  exit 1; \
	fi

# List the devices you can build for, then set one with: make setup DEVICE=<name>
.PHONY: list-devices
list-devices:
	@echo "available devices:"
	@ls devices | sed 's/^/  - /'
	@echo
	@echo "select one with: make setup DEVICE=<name>"

# Select the active device, persisted to .device (per-machine, gitignored).
#   make setup DEVICE=<name>   set + show;   make setup   show current.   List: make list-devices
setup:
ifeq ($(origin DEVICE),command line)
	@test -n "$(strip $(DEVICE))" || { echo "empty DEVICE= (see: make list-devices)"; exit 1; }
	@test -d "devices/$(DEVICE)" || { echo "unknown device '$(DEVICE)' (see: make list-devices)"; exit 1; }
	@echo "$(DEVICE)" > .device
	@echo "device set -> $(DEVICE)"
	@echo "  product=$(DEV_PRODUCT)  dtb=$(DEV_DTB)  mlimg=$(DEV_MLIMG_TARGET)"
else ifeq ($(strip $(DEVICE)),)
	@echo "no device set."
	@echo "run 'make list-devices', then 'make setup DEVICE=<name>'."
else
	@echo "current device -> $(DEVICE)"
	@echo "  product=$(DEV_PRODUCT)  dtb=$(DEV_DTB)  mlimg=$(DEV_MLIMG_TARGET)"
endif
	@echo
	@echo "Note: all top-level targets (rootfs, image, flash-rootfs, ramboot, ...) build for the"
	@echo "active device (.device) unless overridden with DEVICE=<name>."

native:
	./native/build.sh

# Just native/build/mlflash, the one native binary the host flasher embeds. Every compile in
# native/ runs under arm64 emulation, so the release workflow builds this instead of `native`.
native-mlflash:
	./native/build.sh mlflash

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
	uv run python scripts/gen-flasher-devconf.py
	DOCKER_BUILDKIT=1 docker build -f flasher/docker/Dockerfile --output type=local,dest=flasher/build .

flasher-windows:
	uv run python scripts/gen-flasher-devconf.py
	DOCKER_BUILDKIT=1 docker build -f flasher/docker/Dockerfile.windows --output type=local,dest=flasher/build .

# Image + dtb + the shipped modules, all built in the hermetic container (container-build.sh
# builds+stages modules via kernel/modules/stage.sh, so the .ko match the Image's toolchain and
# vermagic). The host-side kernel/modules/build.sh is a dev-only fast path, run by hand when
# iterating on a single module - it is NOT part of the shipping build.
kernel:
	BOARD=$(DEVICE) kernel/scripts/build.sh

fetch-blobs:
	uv run missinglynk fetch-blobs

# Install the host-side auto-networking: the udev rule that enslaves an Artosyn gadget into
# br-artosyn on plug-in/reboot/ramboot, its attach script, and the NetworkManager keyfile;
# also removes the superseded non-bridge autonet. Needs sudo. See glue/docs/host-network-setup.md.
net-install:
	glue/net/net-install.sh

rootfs: require-device
	FLAVOR=slim ./rootfs/build.sh $(DEVICE)

rootfs-dev: require-device
	FLAVOR=dev ./rootfs/build.sh $(DEVICE)

# One flashable .mlimg bundle (uboot + env + kernel + dtb + rootfs, everything a vendor slot
# carries except SPL): build every component, capture the vendor slot blobs, then assemble and
# self-verify. The blob capture needs the device connected once; it persists in firmware/bin/
# and is skipped on later runs, so a rebuild after the first capture needs no device.
image: require-device all image-blobs
	@source kernel/scripts/pin.env && \
	uv run python glue/flash/mlimg.py build --device $(DEV_MLIMG_TARGET) \
	  --blobs-dir firmware/bin/$(DEV_BLOBS_ID) \
	  --dtb "$$KERNEL_BUILD_DEFAULT/linux/arch/arm64/boot/$(DEV_DTB)" \
	  --rootfs rootfs/build/rootfs-$(DEVICE).ubi

# Raw slot partitions the mlimg's vendor components need (stock uboot + env + an OTRA template).
# Captured from a connected device into firmware/bin/<DEV_BLOBS_ID>/, the short unit id
# dump-partitions names its output after; skipped when already present.
image-blobs:
	@if [ -n "$$(find firmware/bin/$(DEV_BLOBS_ID) -name '*uboot0.bin' 2>/dev/null | head -1)" ]; then \
	  echo "[image] vendor slot blobs already in firmware/bin/$(DEV_BLOBS_ID) (skipping dump)"; \
	else \
	  echo "[image] capturing vendor slot blobs from the connected device..."; \
	  uv run missinglynk dump-partitions --dest firmware/bin; \
	fi

flash-rootfs: require-device
	DEVICE=$(DEVICE) glue/flash/flash-rootfs-b.sh

# Guard for the targets that hand built kernel artifacts to a boot/flash script: report which
# file is missing and the build that produces it, rather than letting the script reject the empty
# paths with a bare usage line. One build tree is shared by all devices and holds whichever board
# was built last, so a present Image with a missing dtb means the tree belongs to another device.
.PHONY: require-kernel-build
require-kernel-build: require-device
	@source kernel/scripts/pin.env && \
	  boot="$$KERNEL_BUILD_DEFAULT/linux/arch/arm64/boot" && \
	  missing=0 && \
	  for f in Image $(DEV_DTB); do \
	    if [ ! -f "$$boot/$$f" ]; then echo "error: missing kernel artifact $$boot/$$f" >&2; missing=1; fi; \
	  done && \
	  if [ "$$missing" = 1 ]; then \
	    echo "       build it with 'make kernel DEVICE=$(DEVICE)'." >&2; \
	    if [ -f "$$boot/Image" ]; then \
	      echo "       Image is present but $(DEV_DTB) is not: the build tree was built for another device." >&2; \
	    fi; \
	    exit 1; \
	  fi

ramboot: require-kernel-build
	@source kernel/scripts/pin.env && \
	  DEVICE=$(DEVICE) glue/boot/ram-boot.sh "$$KERNEL_BUILD_DEFAULT/linux/arch/arm64/boot/Image" \
	                        "$$KERNEL_BUILD_DEFAULT/linux/arch/arm64/boot/$(DEV_DTB)"

flash-kernel: require-kernel-build
	@source kernel/scripts/pin.env && \
	  DEVICE=$(DEVICE) glue/flash/flash-kernel-b.sh "$$KERNEL_BUILD_DEFAULT/linux/arch/arm64/boot/Image" \
	                               "$$KERNEL_BUILD_DEFAULT/linux/arch/arm64/boot/$(DEV_DTB)"

flashboot: require-device
	DEVICE=$(DEVICE) glue/boot/ram-boot-flashed-b.sh

# Host-side checks for the Python code (missinglynk/, tests/, glue/). No device, no network:
# every device call is faked at the connection seam, so these run anywhere. Which paths are
# linted, and the per-path rule exemptions, are declared in pyproject.toml.
lint:
	uv run --group dev ruff check .

test:
	uv run --group dev pytest

check-python: lint test

# Shell lint for the host-side scripts. Source resolution and the other shellcheck settings live
# in .shellcheckrc, so a bare `shellcheck <file>` from the repo root behaves the same as this.
#
# missinglynk/templates/ is excluded on purpose: those files hold @PLACEHOLDER@ tokens and are not
# valid shell until `missinglynk install` renders them ($@NAME@ parses as the $@ array, and
# @SKIP_MV_MIN@ is not a number). The rendered hook is what actually runs on the device, and the
# pytest suite shellchecks that.
#
# Runs one pinned shellcheck, here and in CI, so the two cannot disagree. Which checks are on by
# default moves between releases (0.11 turned SC2002 "useless cat" and SC2015 "A && B || C" off),
# so an unpinned run reports a different set per machine: an installed shellcheck is therefore NOT
# picked up automatically. Set SHELLCHECK=<path> to override for a one-off, and bump the tag
# deliberately.
SHELLCHECK_IMAGE ?= koalaman/shellcheck:v0.11.0
SHELLCHECK ?=

# Excluded from the sweep. missinglynk/templates/ per the note above; android/gradlew is upstream
# Gradle's generated wrapper, not ours to style.
SHELLCHECK_SKIP ?= ^missinglynk/templates/|^android/gradlew$$

# --recurse-submodules because a plain `git ls-files` from the superproject reports kernel/,
# rootfs/ and userspace/ as single gitlink entries, so everything shipped inside them - including
# every script that runs on the device - was silently outside the gate. Extensionless scripts are
# picked up by shebang for the same reason: the init scripts and /usr/local/bin helpers have no
# .sh suffix, and they are the ones whose bugs reach hardware.
#
# init.d scripts are a second pass with two openrc idioms suppressed: SC2034 because openrc-run
# consumes `description`/`command`/`pidfile` from the script's environment rather than the script
# using them, and SC3043 because `local` is undefined in POSIX sh but supported by busybox ash,
# which is what runs them on the device. Everything else stays enabled for them.
check-shell:
	@run() { \
	    if [ -n "$(SHELLCHECK)" ]; then \
	        $(SHELLCHECK) "$$@"; \
	    else \
	        docker run --rm -v "$(CURDIR):/mnt" -w /mnt $(SHELLCHECK_IMAGE) "$$@"; \
	    fi; \
	}; \
	all=$$(git ls-files --recurse-submodules | grep -vE '$(SHELLCHECK_SKIP)'); \
	files=$$(printf '%s\n' "$$all" | while read -r f; do \
	    case "$$f" in \
	      */init.d/*) continue ;; \
	      *.sh) echo "$$f" ;; \
	      *) head -1 "$$f" 2>/dev/null | grep -qE '^#!.*\b(ba|da|a)?sh( |$$)' && echo "$$f" ;; \
	    esac; \
	done); \
	initd=$$(printf '%s\n' "$$all" | grep -E '/init\.d/' || true); \
	rc=0; \
	run $$files || rc=1; \
	if [ -n "$$initd" ]; then run -s sh -e SC2034,SC3043 $$initd || rc=1; fi; \
	exit $$rc

# The userspace submodule's own host tests: the :10000 frame builders, the MSP canvas encoder and
# the air's power/standby state machine, linked against checked-in captures and run on the host.
# Delegated rather than reimplemented, so `make -C userspace check` and this target cannot disagree.
#
# CI does NOT run this from here. The submodules are pinned over SSH URLs a runner has no key for,
# so every workflow in this repo sets submodules: false; the equivalent job lives in ml-userspace
# and fires on the commit that breaks a test rather than on the pointer bump that imports it.
check-userspace:
	$(MAKE) -C userspace check

# native/'s host tests: built with the host compiler and run here, not cross-built, because they
# exercise logic that is the same on either architecture. They need no device, no docker and no
# hardware. The device tools themselves still cross-build in the container (make native).
NATIVE_CHECK_CFLAGS := -O1 -Wall -Wextra -Werror

check-native:
	@mkdir -p native/build
	gcc $(NATIVE_CHECK_CFLAGS) -o native/build/ubi-inflate \
	  native/tests/ubi-inflate.c native/mlflash/src/ubi.c -lz
	native/build/ubi-inflate

# The host flasher's Go packages: gofmt, vet and unit tests. Two things make this less direct than
# `go test ./...`:
#
#   - internal/devconf/devices.json is generated (gen-flasher-devconf.py) and git-ignored, so the
#     module does not compile from a clean checkout until it is written. It is regenerated here
#     rather than assumed, the same as `make flasher` does.
#   - internal/gui is cgo over OpenGL/X11/Wayland headers, which the host is not required to have.
#     The GUI is compiled by the container build (make flasher); this target covers the packages
#     that hold the logic and need no display stack. GOFLAGS keeps the tags aligned with that
#     build so vet sees the same code.
#
# The last step vets the same packages again as GOOS=windows. netcfg's Windows backend is behind a
# build tag, so a Linux-only vet compiles neither it nor its tests, and a break in it surfaces only
# in the release container. The tests themselves still run on Linux alone: cross-compiling type-checks
# that code, it does not execute it.
GO_CHECK_PKGS := ./internal/device/... ./internal/devconf/... ./internal/flow/... \
                 ./internal/manifest/... ./internal/netcfg/... ./internal/present/... \
                 ./internal/whitelist/...

# The toolchain: a host `go` is used when present, otherwise the same pinned image
# flasher/docker/Dockerfile builds with, so a machine with only Docker can still run this. Keep the
# tag in step with the Dockerfile's FROM, or vet here and the release build can disagree about the
# standard library.
GO_IMAGE ?= golang:1.26-bookworm
GO ?= $(shell command -v go 2>/dev/null)

check-go:
	uv run python scripts/gen-flasher-devconf.py
	@# internal/payload embeds native/build/mlflash, also git-ignored and only present after
	@# `make native-mlflash`. The embed has to resolve for vet to run, but its contents do not
	@# matter here, so a placeholder stands in when the native build has not happened - and is
	@# removed again afterwards, so a later local `go build` still fails loudly instead of
	@# silently embedding an empty flasher.
	@placeholder=; \
	if [ ! -f flasher/internal/payload/mlflash ]; then \
	    : > flasher/internal/payload/mlflash; placeholder=1; \
	fi; \
	script='cd flasher && \
	    unformatted=$$(gofmt -l .) && \
	    { [ -z "$$unformatted" ] || { echo "gofmt needed:"; echo "$$unformatted"; exit 1; }; } && \
	    go vet $(GO_CHECK_PKGS) && go test $(GO_CHECK_PKGS) && \
	    GOOS=windows go vet $(GO_CHECK_PKGS)'; \
	rc=0; \
	if [ -n "$(GO)" ]; then \
	    sh -c "$$script" || rc=$$?; \
	else \
	    docker run --rm -v "$(CURDIR):/src" -v "$(HOME)/go:/go" -w /src \
	        $(GO_IMAGE) sh -c "$$script" || rc=$$?; \
	fi; \
	[ -z "$$placeholder" ] || rm -f flasher/internal/payload/mlflash; \
	exit $$rc

check: check-python check-shell check-userspace check-native check-go

clean:
	-$(MAKE) -C userspace clean
	rm -f native/fbtext native/minidhcpd native/mtdtool native/mlmenu/mlmenu
	rm -rf native/umtprd/build
	rm -rf rootfs/build
	-kernel/modules/build.sh clean

distclean: clean
	rm -rf kernel/build

.PHONY: all setup native native-mlflash umtprd userspace flasher flasher-windows kernel fetch-blobs net-install rootfs rootfs-dev image image-blobs flash-rootfs ramboot flash-kernel flashboot require-kernel-build lint test check-python check-shell check-userspace check-native check-go check clean distclean
