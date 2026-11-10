package core

import (
	"os"
	"testing"
)

func TestMain(m *testing.M) {
	// Never touch the developer's real macOS Keychain from tests.
	os.Setenv("CLAUDESWITCH_KEY_STORE", "file")
	os.Exit(m.Run())
}
