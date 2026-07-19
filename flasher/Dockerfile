# Build ml-flasher (Linux) in a container - the reproducible build, needing no Go
# or Fyne build dependencies on the host. The build context is the REPO ROOT (it
# needs native/build/mlflash to embed). Driven by `make flasher`, which extracts
# the binary to flasher/build/ml-flasher:
#
#   DOCKER_BUILDKIT=1 docker build -f flasher/Dockerfile \
#       --output type=local,dest=flasher/build .
#
# native/build/mlflash must exist first (make native).

FROM golang:1.26-bookworm AS build

# Fyne cgo build deps: OpenGL, X11 and Wayland headers (Fyne's GLFW compiles both
# an X11 and a Wayland backend). Runtime needs only the corresponding shared libs,
# which exist on every desktop.
RUN apt-get update && apt-get install -y --no-install-recommends \
        gcc pkg-config libgl1-mesa-dev xorg-dev \
        libwayland-dev libxkbcommon-dev wayland-protocols ca-certificates \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /src

# Module graph first, for layer caching.
COPY flasher/go.mod flasher/go.sum ./flasher/
RUN cd flasher && go mod download

# Sources + the on-device binary to embed.
COPY flasher ./flasher
COPY native/build/mlflash ./native/build/mlflash
RUN cp native/build/mlflash flasher/internal/payload/mlflash \
    && cd flasher \
    && CGO_ENABLED=1 go build -tags migrated_fynedo -trimpath -o /out/ml-flasher .

# Export-only stage: `--output type=local` writes this stage's root to the host.
FROM scratch AS export
COPY --from=build /out/ml-flasher /ml-flasher
