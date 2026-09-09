//go:build !windows

package clipboard

// X11 selections and the macOS pasteboard carry LF, which is what the caller already built.
const clipboardWantsCRLF = false
