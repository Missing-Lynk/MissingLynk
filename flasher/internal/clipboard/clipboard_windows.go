//go:build windows

package clipboard

// The Windows clipboard text formats are CR-LF delimited (CF_TEXT, CF_UNICODETEXT).
const clipboardWantsCRLF = true
