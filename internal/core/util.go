package core

import (
	"bytes"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"time"
)

var guidRx = regexp.MustCompile(`^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$`)

// IsGUID reports whether s looks like an account id.
func IsGUID(s string) bool { return guidRx.MatchString(s) }

// UserError is a message meant for the user (Vietnamese, no secrets).
type UserError struct{ Msg string }

func (e *UserError) Error() string { return e.Msg }

func userErr(format string, a ...any) error { return &UserError{Msg: fmt.Sprintf(format, a...)} }

func sha256Hex(b []byte) string {
	h := sha256.Sum256(b)
	return strings.ToUpper(hex.EncodeToString(h[:]))
}

func fileSha(path string) string {
	b, err := os.ReadFile(path)
	if err != nil {
		return ""
	}
	return sha256Hex(b)
}

func ensureDir(dir string) error { return os.MkdirAll(dir, 0o700) }

// writeAtomic writes through a temporary file and renames it over the target.
func writeAtomic(path string, data []byte) error {
	if err := ensureDir(filepath.Dir(path)); err != nil {
		return err
	}
	mode := os.FileMode(0o600)
	if st, err := os.Stat(path); err == nil {
		mode = st.Mode().Perm()
	}
	tmp := path + ".cs-tmp"
	f, err := os.OpenFile(tmp, os.O_WRONLY|os.O_CREATE|os.O_TRUNC, mode)
	if err != nil {
		return err
	}
	if _, err := f.Write(data); err != nil {
		f.Close()
		os.Remove(tmp)
		return err
	}
	if err := f.Sync(); err != nil {
		f.Close()
		os.Remove(tmp)
		return err
	}
	f.Close()
	if back, err := os.ReadFile(tmp); err != nil || !bytes.Equal(back, data) {
		os.Remove(tmp)
		return errors.New("ghi file tạm không khớp")
	}
	if err := os.Rename(tmp, path); err != nil {
		os.Remove(tmp)
		return err
	}
	return nil
}

// decodeJSON parses JSON keeping numbers exact.
func decodeJSON(b []byte) (any, error) {
	b = bytes.TrimPrefix(b, []byte{0xEF, 0xBB, 0xBF})
	dec := json.NewDecoder(bytes.NewReader(b))
	dec.UseNumber()
	var v any
	if err := dec.Decode(&v); err != nil {
		return nil, err
	}
	if dec.More() {
		return nil, errors.New("dữ liệu thừa sau JSON")
	}
	return v, nil
}

// readJSONMap reads a JSON object file; missing or broken files give nil.
func readJSONMap(path string) map[string]any {
	b, err := os.ReadFile(path)
	if err != nil || len(bytes.TrimSpace(b)) == 0 {
		return nil
	}
	v, err := decodeJSON(b)
	if err != nil {
		return nil
	}
	m, _ := v.(map[string]any)
	return m
}

func writeJSON(path string, v any) error {
	b, err := json.MarshalIndent(v, "", "  ")
	if err != nil {
		return err
	}
	return writeAtomic(path, b)
}

func str(m map[string]any, key string) string {
	if m == nil {
		return ""
	}
	s, _ := m[key].(string)
	return s
}

func dict(m map[string]any, key string) map[string]any {
	if m == nil {
		return nil
	}
	d, _ := m[key].(map[string]any)
	return d
}

func num(v any) (float64, bool) {
	switch n := v.(type) {
	case json.Number:
		f, err := n.Float64()
		return f, err == nil
	case float64:
		return n, true
	case int:
		return float64(n), true
	case int64:
		return float64(n), true
	}
	return 0, false
}

// Logf appends one line to the daily log. Never pass secrets.
func (e *Env) Logf(format string, a ...any) {
	dir := filepath.Join(e.StoreDir, "logs")
	if ensureDir(dir) != nil {
		return
	}
	now := e.now()
	f, err := os.OpenFile(filepath.Join(dir, "claude-switch-"+now.Format("20060102")+".log"), os.O_APPEND|os.O_CREATE|os.O_WRONLY, 0o600)
	if err != nil {
		return
	}
	defer f.Close()
	fmt.Fprintf(f, "%s %s\n", now.Format("2006-01-02 15:04:05"), fmt.Sprintf(format, a...))
}

// Progress receives step updates of a long operation.
type Progress func(step, state, msg string)

func (p Progress) emit(e *Env, step, state, msg string) {
	e.Logf("[%s] %s %s", step, state, msg)
	if p != nil {
		p(step, state, msg)
	}
}

func nowISO(e *Env) string { return e.now().Format(time.RFC3339Nano) }

// pruneDirs keeps the newest n entries (by name) in dir.
func pruneDirs(dir string, keep int) {
	entries, err := os.ReadDir(dir)
	if err != nil || len(entries) <= keep {
		return
	}
	names := make([]string, 0, len(entries))
	for _, en := range entries {
		names = append(names, en.Name())
	}
	// ReadDir is sorted ascending: drop the oldest.
	for _, n := range names[:len(names)-keep] {
		os.RemoveAll(filepath.Join(dir, n))
	}
}

func stamp(e *Env) string { return e.now().Format("20060102-150405.000") }
