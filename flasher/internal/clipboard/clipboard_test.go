package clipboard

import (
	"runtime"
	"strings"
	"testing"
)

// toCRLF is tested on every host, not only Windows: it is the whole of the Windows behaviour, and
// a Windows-only test would never run in this project's checks.
func TestToCRLF(t *testing.T) {
	tests := []struct {
		name string
		in   string
		want string
	}{
		{name: "LF becomes CRLF", in: "one\ntwo\nthree", want: "one\r\ntwo\r\nthree"},
		{name: "an existing CRLF is not doubled", in: "one\r\ntwo", want: "one\r\ntwo"},
		{name: "a mixed string ends up uniform", in: "one\r\ntwo\nthree", want: "one\r\ntwo\r\nthree"},
		{name: "a lone CR is left alone", in: "one\rtwo", want: "one\rtwo"},
		{name: "no line ending at all", in: "one line", want: "one line"},
		{name: "empty", in: "", want: ""},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			if got := toCRLF(tt.in); got != tt.want {
				t.Fatalf("toCRLF(%q) = %q, want %q", tt.in, got, tt.want)
			}
		})
	}
}

// Every line of a copied log must survive, whatever the host: a lost line ending is the whole bug
// this package exists for.
func TestPrepareKeepsEveryLine(t *testing.T) {
	const log = "-> Looking for a connected device\n   Found gadget interface\n-> Reading the device"

	got := Prepare(log)
	if strings.Count(got, "\n") != 2 {
		t.Fatalf("Prepare() = %q, want 2 line breaks", got)
	}

	if runtime.GOOS == "windows" {
		if strings.Count(got, "\r\n") != 2 {
			t.Fatalf("Prepare() = %q, want CRLF endings on Windows", got)
		}

		return
	}

	if strings.Contains(got, "\r") {
		t.Fatalf("Prepare() = %q, want the text unchanged off Windows", got)
	}
}
