package platform

import (
	"bytes"
	"errors"
	"os/exec"
	"runtime"
	"strings"
)

// ErrNotFound means the keychain item does not exist.
var ErrNotFound = errors.New("keychain item not found")

// KeychainGet reads a macOS generic password.
func KeychainGet(service, account string) (string, error) {
	if runtime.GOOS != "darwin" {
		return "", ErrNotFound
	}
	args := []string{"find-generic-password", "-s", service, "-w"}
	if account != "" {
		args = []string{"find-generic-password", "-s", service, "-a", account, "-w"}
	}
	out, err := exec.Command("security", args...).Output()
	if err != nil {
		return "", ErrNotFound
	}
	return strings.TrimRight(string(out), "\r\n"), nil
}

func securityQuote(s string) string {
	return `"` + strings.ReplaceAll(strings.ReplaceAll(s, `\`, `\\`), `"`, `\"`) + `"`
}

// KeychainSet writes (or updates) a macOS generic password. The secret goes through
// stdin of `security -i`, never through the process argument list.
func KeychainSet(service, account, secret string) error {
	if runtime.GOOS != "darwin" {
		return errors.New("keychain chỉ có trên macOS")
	}
	cmd := exec.Command("security", "-i")
	cmd.Stdin = strings.NewReader("add-generic-password -U -s " + securityQuote(service) + " -a " + securityQuote(account) + " -w " + securityQuote(secret) + "\n")
	var stderr bytes.Buffer
	cmd.Stderr = &stderr
	if err := cmd.Run(); err != nil {
		return errors.New("không ghi được Keychain: " + strings.TrimSpace(stderr.String()))
	}
	if got, err := KeychainGet(service, account); err != nil || got != secret {
		return errors.New("không ghi được Keychain")
	}
	return nil
}

// KeychainDelete removes a macOS generic password, ignoring a missing item.
func KeychainDelete(service, account string) {
	if runtime.GOOS != "darwin" {
		return
	}
	args := []string{"delete-generic-password", "-s", service}
	if account != "" {
		args = append(args, "-a", account)
	}
	_ = exec.Command("security", args...).Run()
}
