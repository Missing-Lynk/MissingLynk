// Package payload carries what gets pushed to the device: the embedded mlflash
// binary. The .mlimg bundle is supplied by the caller (a file), not embedded here.
package payload

import (
	"bytes"
	_ "embed"
	"io"
)

// mlflashBin is the on-device flasher, copied in from native/build/mlflash during
// the Docker build (see the Dockerfile). Git-ignored; not committed.
//
//go:embed mlflash
var mlflashBin []byte

// Mlflash returns a reader over the embedded mlflash binary and its length.
func Mlflash() (io.Reader, int) {
	return bytes.NewReader(mlflashBin), len(mlflashBin)
}
