//go:build windows

package secure

import (
	"syscall"
	"unsafe"
)

var (
	crypt32                = syscall.NewLazyDLL("crypt32.dll")
	procCryptProtectData   = crypt32.NewProc("CryptProtectData")
	procCryptUnprotectData = crypt32.NewProc("CryptUnprotectData")
	procLocalFree          = syscall.NewLazyDLL("kernel32.dll").NewProc("LocalFree")
)

type dataBlob struct {
	size uint32
	data *byte
}

func blob(b []byte) *dataBlob {
	if len(b) == 0 {
		return &dataBlob{}
	}
	return &dataBlob{size: uint32(len(b)), data: &b[0]}
}

func (d *dataBlob) bytes() []byte {
	out := make([]byte, d.size)
	copy(out, unsafe.Slice(d.data, d.size))
	return out
}

const cryptprotectUIForbidden = 0x1

func protect(plain []byte, _ string) ([]byte, error) {
	var out dataBlob
	r, _, err := procCryptProtectData.Call(uintptr(unsafe.Pointer(blob(plain))), 0, 0, 0, 0, cryptprotectUIForbidden, uintptr(unsafe.Pointer(&out)))
	if r == 0 {
		return nil, err
	}
	defer procLocalFree.Call(uintptr(unsafe.Pointer(out.data)))
	return out.bytes(), nil
}

func unprotect(data []byte, _ string) ([]byte, error) {
	if len(data) == 0 {
		return nil, ErrDecrypt
	}
	var out dataBlob
	r, _, _ := procCryptUnprotectData.Call(uintptr(unsafe.Pointer(blob(data))), 0, 0, 0, 0, cryptprotectUIForbidden, uintptr(unsafe.Pointer(&out)))
	if r == 0 {
		return nil, ErrDecrypt
	}
	defer procLocalFree.Call(uintptr(unsafe.Pointer(out.data)))
	return out.bytes(), nil
}
