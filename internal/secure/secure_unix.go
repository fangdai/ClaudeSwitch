//go:build !windows

package secure

import (
	"encoding/hex"
	"errors"
	"os"
	"path/filepath"
	"runtime"
	"sync"

	"github.com/fangdai/ClaudeSwitch/internal/platform"
)

const keychainService = "ClaudeSwitch"
const keychainAccount = "profile-key"

var (
	keyMu    sync.Mutex
	keyCache []byte
)

func masterKey(storeDir string, create bool) ([]byte, error) {
	keyMu.Lock()
	defer keyMu.Unlock()
	if keyCache != nil {
		return keyCache, nil
	}
	// CLAUDESWITCH_KEY_STORE=file forces the key file (tests, headless macOS).
	if runtime.GOOS == "darwin" && os.Getenv("CLAUDESWITCH_KEY_STORE") != "file" {
		if s, err := platform.KeychainGet(keychainService, keychainAccount); err == nil {
			if k, err := hex.DecodeString(s); err == nil && len(k) == 32 {
				keyCache = k
				return k, nil
			}
		}
		if !create {
			return nil, ErrDecrypt
		}
		k, err := newKey()
		if err != nil {
			return nil, err
		}
		if err := platform.KeychainSet(keychainService, keychainAccount, hex.EncodeToString(k)); err != nil {
			return nil, err
		}
		keyCache = k
		return k, nil
	}
	path := filepath.Join(storeDir, ".profile-key")
	if b, err := os.ReadFile(path); err == nil {
		if k, err := hex.DecodeString(string(b)); err == nil && len(k) == 32 {
			keyCache = k
			return k, nil
		}
		return nil, errors.New("file khóa " + path + " bị hỏng")
	}
	if !create {
		return nil, ErrDecrypt
	}
	k, err := newKey()
	if err != nil {
		return nil, err
	}
	if err := os.MkdirAll(storeDir, 0o700); err != nil {
		return nil, err
	}
	f, err := os.OpenFile(path, os.O_WRONLY|os.O_CREATE|os.O_EXCL, 0o600)
	if err != nil {
		return nil, err
	}
	defer f.Close()
	if _, err := f.WriteString(hex.EncodeToString(k)); err != nil {
		return nil, err
	}
	keyCache = k
	return k, nil
}

func protect(plain []byte, storeDir string) ([]byte, error) {
	k, err := masterKey(storeDir, true)
	if err != nil {
		return nil, err
	}
	return sealGCM(k, plain)
}

func unprotect(data []byte, storeDir string) ([]byte, error) {
	k, err := masterKey(storeDir, false)
	if err != nil {
		return nil, ErrDecrypt
	}
	return openGCM(k, data)
}
