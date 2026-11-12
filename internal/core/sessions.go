package core

import (
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"time"
)

// Claude Desktop keeps Claude Code session files per account and organization:
// claude-code-sessions/<account>/<org>/local_*.json. Syncing copies them across saved
// accounts (verbatim) so every account shows the same history.

func (e *Env) sessionsRoot() string {
	if e.DesktopDir == "" {
		return ""
	}
	return filepath.Join(e.DesktopDir, "claude-code-sessions")
}

func sessionFiles(dir string) map[string]os.FileInfo {
	out := map[string]os.FileInfo{}
	m, _ := filepath.Glob(filepath.Join(dir, "local_*.json"))
	for _, p := range m {
		if st, err := os.Stat(p); err == nil && !st.IsDir() {
			out[filepath.Base(p)] = st
		}
	}
	return out
}

func (e *Env) newestOrg(acct string) string {
	root := e.sessionsRoot()
	if root == "" {
		return ""
	}
	entries, _ := os.ReadDir(filepath.Join(root, acct))
	var orgs []string
	best, bestT := "", time.Time{}
	for _, en := range entries {
		if !en.IsDir() || !IsGUID(en.Name()) {
			continue
		}
		orgs = append(orgs, en.Name())
		for _, st := range sessionFiles(filepath.Join(root, acct, en.Name())) {
			if st.ModTime().After(bestT) {
				best, bestT = en.Name(), st.ModTime()
			}
		}
	}
	// A freshly signed-in account can have only scheduled-tasks.json, no sessions yet.
	if best == "" && len(orgs) == 1 {
		return orgs[0]
	}
	return best
}

func (e *Env) sessionCount(acct, org string) int {
	if org == "" || e.sessionsRoot() == "" {
		return 0
	}
	return len(sessionFiles(filepath.Join(e.sessionsRoot(), acct, org)))
}

func lastActivityMs(path string) (float64, bool) {
	b, err := os.ReadFile(path)
	if err != nil {
		return 0, false
	}
	v, err := decodeJSON(b)
	m, _ := v.(map[string]any)
	if err != nil || m == nil {
		return 0, false
	}
	switch t := m["lastActivityAt"].(type) {
	case string:
		if tt, err := time.Parse(time.RFC3339Nano, t); err == nil {
			return float64(tt.UnixMilli()), true
		}
	default:
		if f, ok := num(t); ok {
			return f, true
		}
	}
	return 0, false
}

type manifest struct {
	Seen   map[string]int   `json:"seen"`
	Copies []map[string]any `json:"copies"`
}

func (e *Env) manifestPath() string { return filepath.Join(e.StoreDir, "synced.json") }

func (e *Env) readManifest() *manifest {
	m := &manifest{Seen: map[string]int{}}
	raw := readJSONMap(e.manifestPath())
	for k := range dict(raw, "seen") {
		m.Seen[k] = 1
	}
	if list, ok := raw["copies"].([]any); ok {
		for _, c := range list {
			if cm, ok := c.(map[string]any); ok {
				m.Copies = append(m.Copies, cm)
			}
		}
	}
	return m
}

// forget drops the "seen" marks of one session in one account, so a later sync copies it
// again. RemoveCopies uses it: removing our own copies is not the user deleting a session.
func (m *manifest) forget(acct, name string) {
	if acct == "" || name == "" {
		return
	}
	for k := range m.Seen {
		parts := strings.Split(k, "|")
		if len(parts) == 3 && parts[2] == name && (parts[0] == acct || parts[1] == acct) {
			delete(m.Seen, k)
		}
	}
}

func copySession(src, dst string) error {
	b, err := os.ReadFile(src)
	if err != nil {
		return err
	}
	if err := writeAtomic(dst, b); err != nil {
		return err
	}
	if st, err := os.Stat(src); err == nil {
		os.Chtimes(dst, st.ModTime(), st.ModTime())
	}
	return nil
}

// SyncResult counts what a sync changed.
type SyncResult struct{ Copied, Updated, Skipped int }

func (r SyncResult) String() string {
	return fmt.Sprintf("Đã đồng bộ session (thêm %d, cập nhật %d).", r.Copied, r.Updated)
}

// SyncSessions makes every saved account show the same Claude Code sessions.
// Sessions the user deleted are never recreated.
func (e *Env) SyncSessions() (SyncResult, error) {
	var res SyncResult
	profiles := e.DesktopProfiles()
	if len(profiles) < 2 || e.sessionsRoot() == "" {
		return res, nil
	}
	dirs := map[string]string{}
	for _, p := range profiles {
		org := str(p.Meta, "orgUuid")
		if org == "" {
			org = e.newestOrg(p.UUID)
		}
		if org == "" {
			name := str(p.Meta, "label")
			if name == "" {
				name = p.UUID[:4]
			}
			return res, userErr("Chưa xác định được thư mục session của account %s. Hãy mở Claude bằng account này một lần rồi đồng bộ lại.", name)
		}
		dirs[p.UUID] = filepath.Join(e.sessionsRoot(), p.UUID, org)
	}
	man := e.readManifest()
	bkRoot := filepath.Join(e.StoreDir, "session-backups", stamp(e))
	for i := 0; i < len(profiles); i++ {
		for j := i + 1; j < len(profiles); j++ {
			P, Q := profiles[i].UUID, profiles[j].UUID
			dp, dq := dirs[P], dirs[Q]
			pair := []string{P, Q}
			sort.Strings(pair)
			fp, fq := sessionFiles(dp), sessionFiles(dq)
			names := map[string]bool{}
			for n := range fp {
				names[n] = true
			}
			for n := range fq {
				names[n] = true
			}
			sorted := make([]string, 0, len(names))
			for n := range names {
				sorted = append(sorted, n)
			}
			sort.Strings(sorted)
			for _, n := range sorted {
				key := strings.Join(pair, "|") + "|" + n
				sp, inP := fp[n]
				sq, inQ := fq[n]
				a, b := filepath.Join(dp, n), filepath.Join(dq, n)
				switch {
				case inP && inQ:
					man.Seen[key] = 1
					if fileSha(a) == fileSha(b) {
						continue
					}
					ta, oka := lastActivityMs(a)
					tb, okb := lastActivityMs(b)
					cmp := 0
					if oka && okb {
						cmp = compareF(ta, tb)
					}
					if cmp == 0 {
						cmp = compareT(sp.ModTime(), sq.ModTime())
					}
					if cmp == 0 {
						res.Skipped++
						continue
					}
					src, dst, loser := a, b, Q
					if cmp < 0 {
						src, dst, loser = b, a, P
					}
					if err := copySession(dst, filepath.Join(bkRoot, loser, n)); err != nil {
						return res, err
					}
					if err := copySession(src, dst); err != nil {
						return res, err
					}
					h := fileSha(dst)
					for _, c := range man.Copies {
						if strings.EqualFold(str(c, "path"), dst) {
							c["hash"] = h
						}
					}
					res.Updated++
				case inP || inQ:
					if man.Seen[key] == 1 {
						continue // the user deleted it on one side: do not recreate
					}
					src, dst, to := a, b, Q
					if inQ {
						src, dst, to = b, a, P
					}
					if err := copySession(src, dst); err != nil {
						return res, err
					}
					man.Seen[key] = 1
					man.Copies = append(man.Copies, map[string]any{"path": dst, "hash": fileSha(dst), "account": to, "at": nowISO(e)})
					res.Copied++
				}
			}
		}
	}
	if err := writeJSON(e.manifestPath(), man); err != nil {
		return res, err
	}
	e.Logf("Đồng bộ session: sao chép %d, cập nhật %d", res.Copied, res.Updated)
	return res, nil
}

func compareF(a, b float64) int {
	switch {
	case a > b:
		return 1
	case a < b:
		return -1
	}
	return 0
}

func compareT(a, b time.Time) int {
	switch {
	case a.After(b):
		return 1
	case a.Before(b):
		return -1
	}
	return 0
}

// RemoveCopies deletes session copies made by sync that were not modified since.
func (e *Env) RemoveCopies() (removed, kept int, err error) {
	man := e.readManifest()
	var keep []map[string]any
	for _, c := range man.Copies {
		p := str(c, "path")
		if p == "" || !fileExists(p) {
			continue
		}
		if fileSha(p) == str(c, "hash") {
			if os.Remove(p) == nil {
				man.forget(str(c, "account"), filepath.Base(p))
				removed++
				continue
			}
		}
		keep = append(keep, c)
		kept++
	}
	man.Copies = keep
	err = writeJSON(e.manifestPath(), man)
	e.Logf("Gỡ session đã sao chép: xóa %d, giữ lại %d (đã bị sửa)", removed, kept)
	return
}

// recentSessions counts sessions active in the last 10 minutes for an account.
func (e *Env) recentSessions(acct, org string) int {
	if org == "" || e.sessionsRoot() == "" {
		return 0
	}
	now := e.now()
	n := 0
	for name, st := range sessionFiles(filepath.Join(e.sessionsRoot(), acct, org)) {
		if now.Sub(st.ModTime()) > time.Hour {
			continue
		}
		ms, ok := lastActivityMs(filepath.Join(e.sessionsRoot(), acct, org, name))
		if !ok {
			ms = float64(st.ModTime().UnixMilli())
		}
		if float64(now.UnixMilli())-ms <= 600000 {
			n++
		}
	}
	return n
}

// SyncDesktopSessions is the "sync now" action. Claude Desktop reads the session list only
// when it starts, and may overwrite files it has open, so a running Claude is closed first
// and opened again afterwards; the copies then show up right away.
func (e *Env) SyncDesktopSessions(p Progress) (string, error) {
	running := e.DesktopRunning()
	if running {
		p.emit(e, "close", "running", "Đang đóng Claude…")
		if err := e.StopDesktop(); err != nil {
			p.emit(e, "close", "error", "Không đóng hẳn được Claude.")
			return "", err
		}
		p.emit(e, "close", "done", "Đã đóng Claude.")
	} else {
		p.emit(e, "close", "skipped", "Claude đang tắt.")
	}
	p.emit(e, "sync", "running", "Đang đồng bộ session…")
	r, err := e.SyncSessions()
	if err != nil {
		p.emit(e, "sync", "error", "Chưa đồng bộ được session.")
	} else {
		p.emit(e, "sync", "done", r.String())
	}
	if running {
		p.emit(e, "open", "running", "Đang mở lại Claude…")
		if e.StartDesktop() {
			p.emit(e, "open", "done", "Đã mở lại Claude.")
		} else {
			p.emit(e, "open", "warn", "Chưa tự mở được Claude, hãy mở bằng tay.")
		}
	} else {
		p.emit(e, "open", "skipped", "Mở Claude để xem session.")
	}
	if err != nil {
		return "", err
	}
	return r.String(), nil
}
