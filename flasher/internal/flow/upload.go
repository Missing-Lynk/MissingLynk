// Staging the payload on the device, streaming it up atomically, and running mlflash.
package flow

import (
	"crypto/md5"
	"crypto/sha256"
	"encoding/hex"
	"fmt"
	"hash"
	"io"
	"os"
	"path"
	"path/filepath"
	"strconv"
	"strings"

	"github.com/Missing-Lynk/MissingLynk/flasher/internal/device"
	"github.com/Missing-Lynk/MissingLynk/flasher/internal/payload"
)

// Digest applets that may be present, best first. sha256sum is not assumed: the
// vendor slot is busybox and every other on-device digest in this repo uses md5sum.
// md5's weakness does not matter here - this compares a file against the local copy
// it was just streamed from.
var digestApplets = []struct {
	name  string
	local func() hash.Hash
}{
	{"sha256sum", sha256.New},
	{"md5sum", md5.New},
}

// Where the on-device flasher is uploaded to. Small enough for the tmpfs /tmp,
// unlike the image (see stageDir).
const remoteMlflash = "/tmp/mlflash"

// imageSize returns the byte size of path, or 0 if unavailable.
func imageSize(path string) int64 {
	info, err := os.Stat(path)
	if err != nil {
		return 0
	}

	return info.Size()
}

// stageDir returns a writable directory on the device large enough to hold the
// flash image. It prefers a removable card when one is mounted, because /tmp is
// tmpfs and staging there spends RAM the flash itself needs. Where no card is
// mounted it falls back to /tmp, which is accepted only when the free space
// there covers the image plus a margin. Both branches are reached on any device;
// which one a given unit takes is a property of that unit and its card, so it is
// decided here by looking rather than by knowing the model.
func stageDir(client deviceClient, imagePath string, emit Emit) (string, error) {
	if sd, err := sdCardDir(client); err != nil {
		return "", err
	} else if sd != "" {
		return sd, nil
	}

	needed := imageSize(imagePath)
	if needed == 0 {
		return "", fmt.Errorf("cannot read image size for staging")
	}

	// Safety margin for tmpfs metadata and whatever else is in /tmp.
	needed += 20 * 1024 * 1024

	dir, err := tmpStageDir(client, needed)
	if err == nil {
		emit(Event{Level: LevelWarn,
			Msg: "No card mounted; staging the image in /tmp. " +
				"Make sure the device has enough free RAM or the flash may fail mid-write."})
	}

	return dir, err
}

// tmpStageDir checks /tmp free space and returns "/tmp" if it can hold minBytes.
// BusyBox df on the vendor slot does not support -B1, so we use -k (1024-byte
// blocks) and scale the result.
func tmpStageDir(client deviceClient, minBytes int64) (string, error) {
	out, err := client.Run("df -k /tmp")
	if err != nil {
		return "", fmt.Errorf("checking /tmp free space: %w", err)
	}

	lines := strings.Split(strings.TrimSpace(out), "\n")
	if len(lines) < 2 {
		return "", fmt.Errorf("unexpected df output: %s", out)
	}

	fields := strings.Fields(lines[1])
	if len(fields) < 4 {
		return "", fmt.Errorf("unexpected df output: %s", out)
	}

	kb, err := strconv.ParseInt(fields[3], 10, 64)
	if err != nil {
		return "", fmt.Errorf("parsing df output: %w", err)
	}

	available := kb * 1024
	if available < minBytes {
		return "", fmt.Errorf("/tmp has only %d MiB free; need %d MiB. Free RAM on the device, "+
			"or mount a card for the image to stage on", available/(1024*1024), minBytes/(1024*1024))
	}

	return "/tmp", nil
}

// pushMlflash uploads the embedded on-device flasher to /tmp on the device.
func pushMlflash(client deviceClient, emit Emit) error {
	mlflashBin, mlflashSize := payload.Mlflash()
	emit(Event{Level: LevelInfo, Msg: fmt.Sprintf("Uploading mlflash (%d KiB)", mlflashSize/1024)})
	if err := client.Push(mlflashBin, remoteMlflash, "755"); err != nil {
		return fmt.Errorf("uploading mlflash: %w", err)
	}

	return nil
}

// pushPayload uploads the embedded mlflash (to /tmp) and the image (to stageDir,
// an SD-card mount) over cat streams and returns the remote image path.
//
// The image lands on a ".part" name and is renamed into place only after the stream
// closes cleanly, so an interrupted run leaves nothing at the final name. The
// temporary sits in stageDir because FAT and exFAT rename only within a directory.
func pushPayload(client deviceClient, imagePath, stageDir string, emit Emit) (string, error) {
	if err := pushMlflash(client, emit); err != nil {
		return "", err
	}

	imageFile, err := os.Open(imagePath)
	if err != nil {
		return "", err
	}

	defer imageFile.Close()
	stat, _ := imageFile.Stat()
	emit(Event{Level: LevelInfo, Msg: fmt.Sprintf("Uploading %s (%d MiB) to %s", filepath.Base(imagePath), stat.Size()/(1024*1024), stageDir)})

	base := filepath.Base(imagePath)
	remoteImg := path.Join(stageDir, base)
	partial := path.Join(stageDir, "."+base+".part")

	if err := client.Push(imageFile, partial, "644"); err != nil {
		removeRemote(client, partial)
		return "", fmt.Errorf("uploading image: %w", err)
	}

	if err := verifyUpload(client, imagePath, partial, emit); err != nil {
		removeRemote(client, partial)
		return "", err
	}

	if _, err := client.Run(fmt.Sprintf("mv %s %s",
		device.ShellQuote(partial), device.ShellQuote(remoteImg))); err != nil {
		removeRemote(client, partial)
		return "", fmt.Errorf("staging the uploaded image as %s: %w", remoteImg, err)
	}

	return remoteImg, nil
}

// verifyUpload compares the staged file's digest to the local image's. A device with
// no digest applet warns and continues: client.Push already fails on a dropped
// transport, and mlflash --inspect re-hashes every component before any write.
func verifyUpload(client deviceClient, localPath, remotePath string, emit Emit) error {
	for _, applet := range digestApplets {
		out, err := client.Run(fmt.Sprintf("%s %s", applet.name, device.ShellQuote(remotePath)))
		if err != nil {
			continue
		}

		fields := strings.Fields(strings.TrimSpace(out))
		if len(fields) == 0 {
			continue
		}

		want, err := localDigest(localPath, applet.local())
		if err != nil {
			return fmt.Errorf("hashing the local image: %w", err)
		}

		if !strings.EqualFold(fields[0], want) {
			return fmt.Errorf("the uploaded image does not match the local file (%s %s on the device, "+
				"%s here); the transfer was corrupted", applet.name, fields[0], want)
		}

		emit(Event{Level: LevelInfo, Msg: "Upload verified against the local image"})
		return nil
	}

	emit(Event{Level: LevelWarn, Msg: "The device has no digest tool, so the upload could not be " +
		"checked against the local file; mlflash still verifies every component before writing."})

	return nil
}

// localDigest hashes localPath with h, as lower-case hex.
func localDigest(localPath string, h hash.Hash) (string, error) {
	file, err := os.Open(localPath)
	if err != nil {
		return "", err
	}

	defer file.Close()
	if _, err := io.Copy(h, file); err != nil {
		return "", err
	}

	return hex.EncodeToString(h.Sum(nil)), nil
}

// sdCardDir returns the mount path of an inserted SD card on the device (a
// writable FAT/exFAT filesystem on a block device), or "" if none is mounted.
// The flash image is staged there rather than in the tmpfs /tmp, which a
// low-memory unit cannot spare.
func sdCardDir(client deviceClient) (string, error) {
	out, err := client.Run("mount")
	if err != nil {
		return "", fmt.Errorf("listing device mounts: %w", err)
	}

	for _, line := range strings.Split(out, "\n") {
		// e.g. "/dev/mmcblk2 on /tmp/sdcard type exfat (rw,relatime,...)"
		fields := strings.Fields(line)
		if len(fields) < 6 || fields[1] != "on" || fields[3] != "type" {
			continue
		}

		source, mountpoint, fstype, options := fields[0], fields[2], fields[4], fields[5]
		if !strings.HasPrefix(source, "/dev/mmcblk") && !strings.HasPrefix(source, "/dev/sd") {
			continue
		}

		if !isFatFilesystem(fstype) || !strings.HasPrefix(options, "(rw") {
			continue
		}

		return mountpoint, nil
	}

	return "", nil
}

// isFatFilesystem reports whether fstype is a removable-media FAT variant, the
// signature of an SD card (as opposed to the device's ubifs/squashfs partitions).
func isFatFilesystem(fstype string) bool {
	switch fstype {
	case "vfat", "exfat", "msdos", "fat", "fuseblk":
		return true

	default:
		return false
	}
}

// removeRemote best-effort deletes a remote path (the staged image after flashing).
func removeRemote(client deviceClient, remotePath string) {
	_, _ = client.Run("rm -f " + device.ShellQuote(remotePath))
}

// runMlflash runs the on-device flasher with args and relays its output as info
// events, so the user sees mlflash's own per-component messages.
func runMlflash(client deviceClient, emit Emit, args ...string) error {
	cmd := remoteMlflash
	for _, a := range args {
		cmd += " " + device.ShellQuote(a)
	}

	return client.RunStream(cmd, func(line string) {
		// ubiformat/libscan redraw a per-eraseblock "... N % complete" counter
		// hundreds of times; drop it (the activity bar shows progress) and skip the
		// empty tokens left by "\r\n" pairs. The phase summary lines still come through.
		line = strings.TrimRight(line, " ")
		if line == "" || strings.Contains(line, "% complete") {
			return
		}

		emit(Event{Level: LevelInfo, Msg: line})
	})
}
