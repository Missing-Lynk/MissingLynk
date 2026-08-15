package manifest

import (
	"archive/tar"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// component is one member of a test bundle. Digest and length are computed from body
// unless overridden, so a good bundle needs no hand-maintained hashes.
type component struct {
	name string
	body []byte

	// Overrides for the corruption cases. Zero means "use the real value".
	claimBytes  int64
	claimDigest string
}

// buildBundle mirrors write_tar() in glue/flash/mlimg.py.
func buildBundle(t *testing.T, formatVersion int, targetDevice string, components []component) string {
	t.Helper()

	entries := make([]Component, 0, len(components))
	for _, c := range components {
		digest := sha256.Sum256(c.body)
		entry := Component{
			Name:         c.name,
			Role:         "open",
			Target:       c.name,
			Method:       "mtdtool-raw",
			File:         c.name + ".bin",
			SHA256:       hex.EncodeToString(digest[:]),
			Bytes:        int64(len(c.body)),
			StoredSHA256: hex.EncodeToString(digest[:]),
			StoredBytes:  int64(len(c.body)),
		}

		if c.claimBytes != 0 {
			entry.StoredBytes = c.claimBytes
		}

		if c.claimDigest != "" {
			entry.StoredSHA256 = c.claimDigest
		}

		entries = append(entries, entry)
	}

	body, err := json.Marshal(Manifest{
		FormatVersion: formatVersion,
		TargetDevice:  targetDevice,
		Version:       "test-1.0",
		Components:    entries,
	})
	if err != nil {
		t.Fatalf("marshalling the test manifest: %v", err)
	}

	path := filepath.Join(t.TempDir(), "test.mlimg")
	file, err := os.Create(path)
	if err != nil {
		t.Fatalf("creating the test bundle: %v", err)
	}

	defer file.Close()
	writer := tar.NewWriter(file)
	add := func(name string, data []byte) {
		t.Helper()

		if err := writer.WriteHeader(&tar.Header{Name: name, Mode: 0o644, Size: int64(len(data))}); err != nil {
			t.Fatalf("writing tar header %s: %v", name, err)
		}

		if _, err := writer.Write(data); err != nil {
			t.Fatalf("writing tar body %s: %v", name, err)
		}
	}

	add(manifestMember, body)
	for _, c := range components {
		add(c.name+".bin", c.body)
	}

	if err := writer.Close(); err != nil {
		t.Fatalf("closing the test bundle: %v", err)
	}

	return path
}

// goodBundle is the happy-path bundle every test starts from.
func goodBundle(t *testing.T) string {
	t.Helper()
	return buildBundle(t, FormatVersion, "P1_GND_VR04", []component{
		{name: "kernel", body: []byte("kernel payload")},
		{name: "rootfs", body: []byte("rootfs payload")},
	})
}

func TestReadReportsTheManifest(t *testing.T) {
	m, err := Read(goodBundle(t))
	if err != nil {
		t.Fatalf("Read() = %v, want no error", err)
	}

	if m.TargetDevice != "P1_GND_VR04" {
		t.Errorf("TargetDevice = %q, want %q", m.TargetDevice, "P1_GND_VR04")
	}

	if len(m.Components) != 2 {
		t.Errorf("got %d components, want 2", len(m.Components))
	}
}

// Refused by name rather than parsed best-effort: guessing at an unknown layout is
// what the version field exists to prevent.
func TestReadRejectsAnUnknownFormatVersion(t *testing.T) {
	path := buildBundle(t, FormatVersion+1, "P1_GND_VR04", []component{{name: "kernel", body: []byte("x")}})

	_, err := Read(path)
	if err == nil {
		t.Fatal("Read() = nil error, want a format-version rejection")
	}

	if !strings.Contains(err.Error(), "format version") {
		t.Errorf("Read() error = %q, want it to name the format version", err)
	}
}

func TestReadRejectsANonBundle(t *testing.T) {
	path := filepath.Join(t.TempDir(), "not.mlimg")
	if err := os.WriteFile(path, []byte("this is not a tar"), 0o644); err != nil {
		t.Fatalf("writing the test file: %v", err)
	}

	if _, err := Read(path); err == nil {
		t.Fatal("Read() = nil error, want a rejection for a non-tar file")
	}
}

// Verbatim compare, as board_matches() does on the device. A prefix match would
// accept an image mlflash then rejects after the upload.
func TestMatchesDeviceIsExact(t *testing.T) {
	m := &Manifest{TargetDevice: "P1_GND_VR04"}

	tests := []struct {
		name    string
		product string
		want    bool
	}{
		{name: "exact", product: "P1_GND_VR04", want: true},
		{name: "air unit", product: "P1_SKY", want: false},
		{name: "prefix of the target", product: "P1_GND", want: false},
		{name: "target is a prefix of it", product: "P1_GND_VR04_X", want: false},
		{name: "empty", product: "", want: false},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			if got := m.MatchesDevice(tt.product); got != tt.want {
				t.Fatalf("MatchesDevice(%q) = %v, want %v", tt.product, got, tt.want)
			}
		})
	}
}

func TestVerifyAcceptsAnIntactBundle(t *testing.T) {
	path := goodBundle(t)
	m, err := Read(path)
	if err != nil {
		t.Fatalf("Read() = %v", err)
	}

	if err := m.Verify(path); err != nil {
		t.Fatalf("Verify() = %v, want no error", err)
	}
}

// A truncated download is a short member, reported as a length fault so the message
// names the real cause.
func TestVerifyRejectsATruncatedComponent(t *testing.T) {
	path := buildBundle(t, FormatVersion, "P1_GND_VR04", []component{
		{name: "kernel", body: []byte("short"), claimBytes: 4096},
	})

	m, err := Read(path)
	if err != nil {
		t.Fatalf("Read() = %v", err)
	}

	err = m.Verify(path)
	if err == nil {
		t.Fatal("Verify() = nil error, want a truncation rejection")
	}

	if !strings.Contains(err.Error(), "truncated") {
		t.Errorf("Verify() error = %q, want it to name the truncation", err)
	}
}

func TestVerifyRejectsACorruptComponent(t *testing.T) {
	path := buildBundle(t, FormatVersion, "P1_GND_VR04", []component{
		{name: "kernel", body: []byte("kernel payload"), claimDigest: strings.Repeat("a", 64)},
	})

	m, err := Read(path)
	if err != nil {
		t.Fatalf("Read() = %v", err)
	}

	err = m.Verify(path)
	if err == nil {
		t.Fatal("Verify() = nil error, want a digest rejection")
	}

	if !strings.Contains(err.Error(), "digest") {
		t.Errorf("Verify() error = %q, want it to name the digest", err)
	}
}

// A gzipped component records two digests: sha256 for the payload written to flash,
// stored_sha256 for the tar member. The host sees only the member, so checking the
// payload pair would fail every real bundle.
func TestVerifyUsesTheStoredDigestNotThePayloadDigest(t *testing.T) {
	member := []byte("the compressed member bytes")
	memberDigest := sha256.Sum256(member)

	// Deliberately unequal to the member, as it is for a real gzipped component.
	payload := []byte("the much longer inflated payload that never appears in the tar")
	payloadDigest := sha256.Sum256(payload)

	body, err := json.Marshal(Manifest{
		FormatVersion: FormatVersion,
		TargetDevice:  "P1_GND_VR04",
		Version:       "test-1.0",
		Components: []Component{{
			Name: "rootfs", Role: "open", Target: "userapp", Method: "ubiformat", File: "rootfs.ubi",
			SHA256: hex.EncodeToString(payloadDigest[:]), Bytes: int64(len(payload)),
			StoredSHA256: hex.EncodeToString(memberDigest[:]), StoredBytes: int64(len(member)),
		}},
	})
	if err != nil {
		t.Fatalf("marshalling the test manifest: %v", err)
	}

	path := filepath.Join(t.TempDir(), "compressed.mlimg")
	file, err := os.Create(path)
	if err != nil {
		t.Fatalf("creating the test bundle: %v", err)
	}

	defer file.Close()
	writer := tar.NewWriter(file)
	for _, m := range []struct {
		name string
		data []byte
	}{{manifestMember, body}, {"rootfs.ubi", member}} {
		if err := writer.WriteHeader(&tar.Header{Name: m.name, Mode: 0o644, Size: int64(len(m.data))}); err != nil {
			t.Fatalf("writing tar header: %v", err)
		}

		if _, err := writer.Write(m.data); err != nil {
			t.Fatalf("writing tar body: %v", err)
		}
	}

	if err := writer.Close(); err != nil {
		t.Fatalf("closing the test bundle: %v", err)
	}

	parsed, err := Read(path)
	if err != nil {
		t.Fatalf("Read() = %v", err)
	}

	if err := parsed.Verify(path); err != nil {
		t.Fatalf("Verify() = %v; a component whose stored bytes differ from its payload must pass", err)
	}
}

// Must fail rather than pass vacuously: the walk only checks members it finds.
func TestVerifyRejectsAMissingComponent(t *testing.T) {
	path := goodBundle(t)
	m, err := Read(path)
	if err != nil {
		t.Fatalf("Read() = %v", err)
	}

	m.Components = append(m.Components, Component{
		Name: "dtb", File: "dtb.bin", StoredBytes: 12, StoredSHA256: strings.Repeat("b", 64),
	})

	err = m.Verify(path)
	if err == nil {
		t.Fatal("Verify() = nil error, want a missing-component rejection")
	}

	if !strings.Contains(err.Error(), "does not contain") {
		t.Errorf("Verify() error = %q, want it to name the missing component", err)
	}
}
