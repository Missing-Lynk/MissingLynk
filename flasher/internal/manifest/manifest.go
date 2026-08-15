// Package manifest reads the .mlimg bundle host-side, so a wrong or corrupt image
// fails before the upload rather than after it. mlflash re-checks everything on the
// device.
//
// The bundle (glue/flash/mlimg.py) is an uncompressed tar whose first member is
// manifest.json. Only the fields the host needs are modelled, to limit drift against
// native/mlflash/src/mlimg.c.
package manifest

import (
	"archive/tar"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"hash"
	"io"
	"os"
)

// FormatVersion must track MLIMG_FORMAT_VERSION in native/mlflash/src/mlimg.h and
// FORMAT_VERSION in glue/flash/mlimg.py.
const FormatVersion = 1

// manifestMember is written first by mlimg.py.
const manifestMember = "manifest.json"

// Component is one flashable payload's manifest entry. sha256/bytes describe the
// payload written to flash; stored_* describe the tar member, which differs for a
// gzip-compressed component. The host only sees the member, so Verify checks stored_*.
type Component struct {
	Name         string `json:"name"`
	Role         string `json:"role"`
	Target       string `json:"target"`
	Method       string `json:"method"`
	File         string `json:"file"`
	SHA256       string `json:"sha256"`
	Bytes        int64  `json:"bytes"`
	StoredSHA256 string `json:"stored_sha256"`
	StoredBytes  int64  `json:"stored_bytes"`
}

// Manifest is the bundle's manifest.json, restricted to the fields the host uses.
type Manifest struct {
	FormatVersion int         `json:"format_version"`
	TargetDevice  string      `json:"target_device"`
	Version       string      `json:"version"`
	Components    []Component `json:"components"`
}

// Read parses the bundle's manifest.json. Stops at the first member, so its cost is
// independent of bundle size.
func Read(path string) (*Manifest, error) {
	file, err := os.Open(path)
	if err != nil {
		return nil, err
	}

	defer file.Close()
	reader := tar.NewReader(file)
	header, err := reader.Next()
	if err != nil {
		return nil, fmt.Errorf("%s is not a readable .mlimg bundle: %w", path, err)
	}

	if header.Name != manifestMember {
		return nil, fmt.Errorf("%s is not an .mlimg bundle: first member is %q, expected %q",
			path, header.Name, manifestMember)
	}

	body, err := io.ReadAll(reader)
	if err != nil {
		return nil, fmt.Errorf("reading %s from %s: %w", manifestMember, path, err)
	}

	var m Manifest
	if err := json.Unmarshal(body, &m); err != nil {
		return nil, fmt.Errorf("parsing %s from %s: %w", manifestMember, path, err)
	}

	if m.FormatVersion != FormatVersion {
		return nil, fmt.Errorf("%s has bundle format version %d; this flasher understands version %d",
			path, m.FormatVersion, FormatVersion)
	}

	if m.TargetDevice == "" || m.Version == "" {
		return nil, fmt.Errorf("%s: manifest is missing target_device or version", path)
	}

	if len(m.Components) == 0 {
		return nil, fmt.Errorf("%s: manifest lists no components", path)
	}

	return &m, nil
}

// MatchesDevice reports whether the bundle targets the unit with this
// sdk_version.json product_version. Verbatim equality, matching board_matches() in
// native/mlflash/src/board.c; anything looser accepts images the device rejects.
func (m *Manifest) MatchesDevice(productVersion string) bool {
	return m.TargetDevice == productVersion
}

// Verify checks every component member against its recorded stored length and
// digest, and that none is missing. Catches a corrupt download before the upload.
func (m *Manifest) Verify(path string) error {
	file, err := os.Open(path)
	if err != nil {
		return err
	}

	defer file.Close()

	// Indexed by member name: the tar is walked once, in write order.
	wanted := make(map[string]*Component, len(m.Components))
	for i := range m.Components {
		wanted[m.Components[i].File] = &m.Components[i]
	}

	reader := tar.NewReader(file)
	for {
		header, err := reader.Next()
		if err == io.EOF {
			break
		}

		if err != nil {
			return fmt.Errorf("reading %s: %w", path, err)
		}

		component, ok := wanted[header.Name]
		if !ok {
			// manifest.json itself, and anything else the manifest does not claim.
			continue
		}

		if err := verifyMember(reader, component); err != nil {
			return fmt.Errorf("%s: %w", path, err)
		}

		delete(wanted, header.Name)
	}

	for name := range wanted {
		return fmt.Errorf("%s: the manifest lists component %q but the bundle does not contain it",
			path, name)
	}

	return nil
}

// verifyMember hashes one tar member against the manifest. Length is checked first:
// a truncated download names itself better than "digest mismatch" would.
func verifyMember(reader io.Reader, component *Component) error {
	digest := sha256.New()
	n, err := io.Copy(digest, reader)
	if err != nil {
		return fmt.Errorf("reading component %s: %w", component.Name, err)
	}

	if n != component.StoredBytes {
		return fmt.Errorf("component %s is %d bytes but the manifest records %d "+
			"(the bundle is truncated or corrupt)", component.Name, n, component.StoredBytes)
	}

	if got := sum(digest); got != component.StoredSHA256 {
		return fmt.Errorf("component %s has digest %s but the manifest records %s "+
			"(the bundle is corrupt)", component.Name, short(got), short(component.StoredSHA256))
	}

	return nil
}

// sum renders a hash as the lower-case hex the manifest stores.
func sum(h hash.Hash) string {
	return hex.EncodeToString(h.Sum(nil))
}

// short abbreviates a digest for an error message.
func short(digest string) string {
	if len(digest) <= 16 {
		return digest
	}

	return digest[:16] + "..."
}
