// Package clipboard adapts text to the host clipboard's line-ending convention.
//
// The GUI builds its log with "\n", which is what the X11 selection carries and what every app
// pasting from it expects. The Windows clipboard formats CF_TEXT and CF_UNICODETEXT are defined as
// CR-LF delimited, and the clipboard underneath Fyne (glfw's _glfwSetClipboardStringWin32) hands
// the string over as a straight UTF-8 to UTF-16 conversion, translating nothing. A log copied on
// Windows therefore reaches the clipboard as bare LF, and an application that honours the
// convention renders the whole log as one line.
package clipboard

import "strings"

// Prepare returns text with the line endings this platform's clipboard expects.
func Prepare(text string) string {
	if !clipboardWantsCRLF {
		return text
	}

	return toCRLF(text)
}

// toCRLF rewrites every line ending as CRLF. Existing CRLF pairs are collapsed to LF first, so a
// string that already carries some survives with one CR per line rather than two.
func toCRLF(text string) string {
	return strings.ReplaceAll(strings.ReplaceAll(text, "\r\n", "\n"), "\n", "\r\n")
}
