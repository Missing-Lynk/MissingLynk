// Package device is the host side of the device link: the legacy-Dropbear SSH
// client, byte-streaming file push (no scp/sftp on the device), running mlflash
// and relaying its output, and reading the unit identity.
package device

import (
	"bufio"
	"bytes"
	"encoding/json"
	"fmt"
	"io"
	"net"
	"strings"
	"sync"
	"time"

	"golang.org/x/crypto/ssh"
)

// SSH port and the well-known device coordinates. The gadget address is fixed
// (no DHCP on stock), and root's password differs per slot.
const (
	Port          = "22"
	DefaultIP     = "192.168.3.100"
	StockPassword = "artosyn" // vendor slot A (and the air unit)
	OpenPassword  = "libre"   // our open slot B
)

// Client is a connected SSH session factory to one device.
type Client struct {
	IP  string
	ssh *ssh.Client
}

// legacyConfig re-enables the ancient algorithms the vendor Dropbear speaks,
// alongside the modern ones our open slot B uses, so one config talks to either
// stack. Host-key verification is skipped: the key changes on every slot hop, so
// there is nothing stable to pin.
func legacyConfig(user, password string, timeout time.Duration) *ssh.ClientConfig {
	return &ssh.ClientConfig{
		User:            user,
		Auth:            []ssh.AuthMethod{ssh.Password(password)},
		HostKeyCallback: ssh.InsecureIgnoreHostKey(),
		HostKeyAlgorithms: []string{
			ssh.KeyAlgoRSASHA256, ssh.KeyAlgoRSASHA512, ssh.KeyAlgoRSA,
		},
		Config: ssh.Config{
			KeyExchanges: []string{
				"curve25519-sha256", "curve25519-sha256@libssh.org",
				"diffie-hellman-group14-sha256",
				"diffie-hellman-group14-sha1", "diffie-hellman-group1-sha1",
			},
			Ciphers: []string{
				"aes128-ctr", "aes192-ctr", "aes256-ctr",
				"aes128-cbc", "3des-cbc",
			},
			MACs: []string{"hmac-sha2-256", "hmac-sha1"},
		},
		Timeout: timeout,
	}
}

// Dial opens a connection. user is normally "root"; password differs per slot.
func Dial(ip, user, password string, timeout time.Duration) (*Client, error) {
	conn, err := ssh.Dial("tcp", net.JoinHostPort(ip, Port), legacyConfig(user, password, timeout))
	if err != nil {
		return nil, err
	}

	return &Client{IP: ip, ssh: conn}, nil
}

// Reachable reports whether the SSH port answers within timeout, without
// authenticating. Used by discovery to probe a candidate interface cheaply.
func Reachable(ip string, timeout time.Duration) bool {
	conn, err := net.DialTimeout("tcp", net.JoinHostPort(ip, Port), timeout)
	if err != nil {
		return false
	}

	_ = conn.Close()
	return true
}

// Close tears down the SSH connection.
func (client *Client) Close() error { return client.ssh.Close() }

// Run executes cmd and returns its stdout; on a non-zero exit the stderr is
// folded into the returned error.
func (client *Client) Run(cmd string) (string, error) {
	sess, err := client.ssh.NewSession()
	if err != nil {
		return "", err
	}
	defer sess.Close()

	var stdout, stderr bytes.Buffer
	sess.Stdout = &stdout
	sess.Stderr = &stderr
	if err := sess.Run(cmd); err != nil {
		return stdout.String(), fmt.Errorf("remote %q: %w (%s)", cmd, err, strings.TrimSpace(stderr.String()))
	}

	return stdout.String(), nil
}

// RunStream runs cmd and invokes onLine for every line of stdout and stderr as
// it arrives, so long-running mlflash output is relayed live. It returns the
// command's exit status.
func (client *Client) RunStream(cmd string, onLine func(string)) error {
	sess, err := client.ssh.NewSession()
	if err != nil {
		return err
	}

	defer sess.Close()
	stdout, err := sess.StdoutPipe()
	if err != nil {
		return err
	}

	stderr, err := sess.StderrPipe()
	if err != nil {
		return err
	}

	if err := sess.Start(cmd); err != nil {
		return err
	}

	var wg sync.WaitGroup
	relay := func(pipe io.Reader) {
		defer wg.Done()
		scanner := bufio.NewScanner(pipe)
		scanner.Buffer(make([]byte, 64*1024), 1024*1024)
		scanner.Split(scanLinesCR)
		for scanner.Scan() {
			onLine(scanner.Text())
		}
	}

	wg.Add(2)
	go relay(stdout)
	go relay(stderr)
	wg.Wait()

	return sess.Wait()
}

// Push streams content to remotePath on the device and sets its mode (e.g. "755").
// The device has no scp/sftp, so bytes go over a plain exec channel via `cat`.
// remotePath is shell-quoted, so it may contain any characters.
func (client *Client) Push(content io.Reader, remotePath, mode string) error {
	sess, err := client.ssh.NewSession()
	if err != nil {
		return err
	}

	defer sess.Close()
	sess.Stdin = content
	cmd := fmt.Sprintf("cat > %s && chmod %s %s", ShellQuote(remotePath), mode, ShellQuote(remotePath))
	return sess.Run(cmd)
}

// SDKVersion mirrors /usr/usrdata/sdk_version.json on the device.
type SDKVersion struct {
	HardwareVersion string `json:"hardware_version"`
	SoftwareVersion string `json:"software_version"`
	SequenceNumber  string `json:"sequence_number"`
	ProductVersion  string `json:"product_version"`
}

// ReadSDKVersion parses the device's sdk_version.json.
func (client *Client) ReadSDKVersion() (*SDKVersion, error) {
	out, err := client.Run("cat /usr/usrdata/sdk_version.json")
	if err != nil {
		return nil, err
	}

	var version SDKVersion
	if err := json.Unmarshal([]byte(out), &version); err != nil {
		return nil, fmt.Errorf("parse sdk_version.json: %w", err)
	}

	return &version, nil
}

// Unit is the coarse identity: goggle, air unit, or unrecognized.
type Unit string

const (
	UnitGoggle  Unit = "P1_GND"
	UnitAir     Unit = "P1_SKY"
	UnitUnknown Unit = "unknown"
)

// Identify names the connected unit from its product_version (the same signal
// the Python CLI and mlflash's board check use).
func (version *SDKVersion) Identify() Unit {
	switch {
	case strings.HasPrefix(version.ProductVersion, string(UnitGoggle)):
		return UnitGoggle

	case strings.HasPrefix(version.ProductVersion, string(UnitAir)):
		return UnitAir

	default:
		return UnitUnknown
	}
}

// scanLinesCR is a bufio.SplitFunc that breaks on either a newline or a carriage
// return, so tools that redraw progress in place with '\r' (ubiformat/libscan)
// yield one token per update instead of one giant blob. The delimiter is dropped;
// a "\r\n" pair yields an empty token, which the caller filters out.
func scanLinesCR(data []byte, atEOF bool) (advance int, token []byte, err error) {
	if atEOF && len(data) == 0 {
		return 0, nil, nil
	}

	if i := bytes.IndexAny(data, "\r\n"); i >= 0 {
		return i + 1, data[:i], nil
	}

	if atEOF {
		return len(data), data, nil
	}

	return 0, nil, nil
}

// ShellQuote wraps s in single quotes for safe use in a remote /bin/sh command.
// A single quote in s is escaped, so s may contain any characters.
func ShellQuote(s string) string {
	return "'" + strings.ReplaceAll(s, "'", `'\''`) + "'"
}
