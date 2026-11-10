// Package secure encrypts saved logins for the current OS user.
//
//   - Windows: DPAPI (CurrentUser), byte-compatible with profiles saved by the old
//     PowerShell version.
//   - macOS:   AES-256-GCM with a random key kept in the login Keychain.
//   - Linux:   AES-256-GCM with a random key in a 0600 file inside the data folder.
package secure

import (
	"crypto/aes"
	"crypto/cipher"
	"crypto/rand"
	"errors"
)

var magic = []byte("CSW1")

// ErrDecrypt is returned for data that cannot be decrypted by this user.
var ErrDecrypt = errors.New("không giải mã được dữ liệu đã lưu")

// Protect encrypts plain for the current user. storeDir is used for the Linux key file.
func Protect(plain []byte, storeDir string) ([]byte, error) { return protect(plain, storeDir) }

// Unprotect reverses Protect.
func Unprotect(data []byte, storeDir string) ([]byte, error) { return unprotect(data, storeDir) }

func sealGCM(key, plain []byte) ([]byte, error) {
	block, err := aes.NewCipher(key)
	if err != nil {
		return nil, err
	}
	gcm, err := cipher.NewGCM(block)
	if err != nil {
		return nil, err
	}
	nonce := make([]byte, gcm.NonceSize())
	if _, err := rand.Read(nonce); err != nil {
		return nil, err
	}
	out := append([]byte{}, magic...)
	out = append(out, nonce...)
	return gcm.Seal(out, nonce, plain, magic), nil
}

func openGCM(key, data []byte) ([]byte, error) {
	if len(data) < len(magic) || string(data[:len(magic)]) != string(magic) {
		return nil, ErrDecrypt
	}
	block, err := aes.NewCipher(key)
	if err != nil {
		return nil, err
	}
	gcm, err := cipher.NewGCM(block)
	if err != nil {
		return nil, err
	}
	rest := data[len(magic):]
	if len(rest) < gcm.NonceSize() {
		return nil, ErrDecrypt
	}
	plain, err := gcm.Open(nil, rest[:gcm.NonceSize()], rest[gcm.NonceSize():], magic)
	if err != nil {
		return nil, ErrDecrypt
	}
	return plain, nil
}

func newKey() ([]byte, error) {
	k := make([]byte, 32)
	_, err := rand.Read(k)
	return k, err
}
