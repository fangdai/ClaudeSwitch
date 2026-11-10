package core

import (
	"encoding/base64"
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"sort"
	"strings"

	"github.com/fangdai/ClaudeSwitch/internal/secure"
)

// Claude Desktop keeps its login in three config.json values (encrypted by Electron with a
// per-machine key) and in the Network/Cookies database. Swapping them swaps the account.
const (
	keyTc   = "oauth:tokenCache"
	keyTc2  = "oauth:tokenCacheV2"
	keyUUID = "lastKnownAccountUuid"
)

var desktopKeys = []string{keyTc, keyTc2, keyUUID}

// DesktopAuth is the login stored in config.json.
type DesktopAuth struct {
	UUID  string
	Tc    string // legacy, may be empty
	HasTc bool
	Tc2   string
}

type desktopConfig struct {
	path string
	doc  *jsonText
	obj  map[string]any
	auth *DesktopAuth
}

func authFrom(m map[string]any) *DesktopAuth {
	u, t2 := str(m, keyUUID), str(m, keyTc2)
	_, hasTc := m[keyTc]
	t1 := str(m, keyTc)
	// Current Claude versions only write V2; a present legacy key must still be valid.
	if !IsGUID(u) || t2 == "" || (hasTc && t1 == "") {
		return nil
	}
	return &DesktopAuth{UUID: u, Tc: t1, HasTc: hasTc, Tc2: t2}
}

func (e *Env) configPath() string {
	if e.DesktopDir == "" {
		return ""
	}
	return filepath.Join(e.DesktopDir, "config.json")
}

func (e *Env) cookiePaths() (cookies, journal string) {
	net := filepath.Join(e.DesktopDir, "Network", "Cookies")
	old := filepath.Join(e.DesktopDir, "Cookies")
	if _, err := os.Stat(net); err != nil {
		if _, err2 := os.Stat(old); err2 == nil {
			return old, old + "-journal"
		}
	}
	return net, net + "-journal"
}

func (e *Env) readDesktopConfig() (*desktopConfig, error) {
	p := e.configPath()
	if p == "" {
		return nil, userErr("Không tìm thấy thư mục dữ liệu của Claude Desktop.")
	}
	b, err := os.ReadFile(p)
	if err != nil {
		return nil, userErr("Không tìm thấy config.json của Claude (thư mục dữ liệu chưa có).")
	}
	doc, err := parseJSONText(b)
	if err != nil {
		return nil, userErr("config.json đang bị lỗi định dạng nên không đọc được.")
	}
	obj, _ := doc.object()
	return &desktopConfig{path: p, doc: doc, obj: obj, auth: authFrom(obj)}, nil
}

func checkEditable(c *desktopConfig) error {
	for _, k := range desktopKeys {
		if n := c.doc.Count(k); n > 1 {
			return userErr("config.json có khóa '%s' xuất hiện %d lần nên công cụ không dám sửa. Chưa có gì bị thay đổi.", k, n)
		}
		if v, ok := c.obj[k]; ok && v != nil {
			if _, isStr := v.(string); !isStr {
				return userErr("Giá trị của khóa '%s' trong config.json có định dạng lạ nên công cụ không dám sửa. Chưa có gì bị thay đổi.", k)
			}
		}
	}
	return nil
}

// writeDesktopConfig writes a modified config and verifies that only login keys changed.
func (e *Env) writeDesktopConfig(c *desktopConfig, want *DesktopAuth) error {
	newObj, err := c.doc.object()
	if err != nil {
		return userErr("Bản config.json mới không hợp lệ.")
	}
	orig, _ := os.ReadFile(c.path)
	origDoc, err := parseJSONText(orig)
	if err != nil {
		return userErr("config.json vừa bị thay đổi. Hãy thử lại.")
	}
	origObj, _ := origDoc.object()
	if !sameExcept(origObj, newObj, desktopKeys...) {
		return userErr("Kiểm tra sau khi sửa: các khóa khác trong config.json bị thay đổi.")
	}
	if want != nil {
		got := authFrom(newObj)
		if got == nil || got.UUID != want.UUID || got.Tc2 != want.Tc2 || got.Tc != want.Tc {
			return userErr("Kiểm tra sau khi sửa: thông tin đăng nhập mới không khớp.")
		}
	} else {
		for _, k := range desktopKeys {
			if _, ok := newObj[k]; ok {
				return userErr("Kiểm tra sau khi sửa: khóa đăng nhập vẫn còn.")
			}
		}
	}
	return writeAtomic(c.path, c.doc.bytes())
}

// ---- profiles ----------------------------------------------------------------------

// DesktopProfile is a saved Claude Desktop account.
type DesktopProfile struct {
	UUID    string
	Meta    map[string]any
	HasAuth bool
}

func (e *Env) profileDir(uuid string) string { return filepath.Join(e.StoreDir, "profiles", uuid) }

// DesktopProfiles lists saved accounts, oldest first.
func (e *Env) DesktopProfiles() []DesktopProfile {
	entries, _ := os.ReadDir(filepath.Join(e.StoreDir, "profiles"))
	var out []DesktopProfile
	for _, en := range entries {
		if !en.IsDir() || !IsGUID(en.Name()) {
			continue
		}
		dir := e.profileDir(en.Name())
		out = append(out, DesktopProfile{
			UUID:    en.Name(),
			Meta:    readJSONMap(filepath.Join(dir, "meta.json")),
			HasAuth: fileExists(filepath.Join(dir, "auth.bin")),
		})
	}
	sort.SliceStable(out, func(i, j int) bool { return str(out[i].Meta, "addedAt") < str(out[j].Meta, "addedAt") })
	return out
}

func fileExists(p string) bool { _, err := os.Stat(p); return err == nil }

type desktopSaved struct {
	Auth    DesktopAuth
	Cookies []byte
}

// Payload layout is shared with the previous PowerShell version.
type desktopPayload struct {
	V          int     `json:"v"`
	UUID       string  `json:"lastKnownAccountUuid"`
	TokenCache *string `json:"tokenCache"`
	TokenV2    string  `json:"tokenCacheV2"`
	Cookies    *string `json:"cookies"`
	SavedAt    string  `json:"savedAt"`
}

func (e *Env) writeDesktopAuth(a *DesktopAuth, cookies []byte) error {
	p := desktopPayload{V: 1, UUID: a.UUID, TokenV2: a.Tc2, SavedAt: nowISO(e)}
	if a.HasTc {
		t := a.Tc
		p.TokenCache = &t
	}
	if cookies != nil {
		s := base64.StdEncoding.EncodeToString(cookies)
		p.Cookies = &s
	}
	plain, _ := json.Marshal(p)
	enc, err := secure.Protect(plain, e.StoreDir)
	if err != nil {
		return err
	}
	return writeAtomic(filepath.Join(e.profileDir(a.UUID), "auth.bin"), enc)
}

func (e *Env) readDesktopAuth(uuid string) (*desktopSaved, error) {
	b, err := os.ReadFile(filepath.Join(e.profileDir(uuid), "auth.bin"))
	if err != nil {
		return nil, userErr("Chưa có thông tin đăng nhập đã lưu cho tài khoản này. Chưa có gì bị thay đổi.")
	}
	plain, err := secure.Unprotect(b, e.StoreDir)
	if err != nil {
		return nil, userErr("File đăng nhập đã lưu bị hỏng hoặc không giải mã được. Chưa có gì bị thay đổi. Hãy đăng nhập lại account này rồi lưu lại.")
	}
	v, err := decodeJSON(plain)
	m, _ := v.(map[string]any)
	if err != nil || m == nil {
		return nil, userErr("File đăng nhập đã lưu không hợp lệ. Chưa có gì bị thay đổi.")
	}
	a := &DesktopAuth{UUID: str(m, "lastKnownAccountUuid"), Tc2: str(m, "tokenCacheV2"), Tc: str(m, "tokenCache")}
	a.HasTc = m["tokenCache"] != nil
	if !IsGUID(a.UUID) || a.Tc2 == "" || (a.HasTc && a.Tc == "") || !strings.EqualFold(a.UUID, uuid) {
		return nil, userErr("File đăng nhập đã lưu không hợp lệ. Chưa có gì bị thay đổi.")
	}
	out := &desktopSaved{Auth: *a}
	if s := str(m, "cookies"); s != "" {
		if out.Cookies, err = base64.StdEncoding.DecodeString(s); err != nil {
			return nil, userErr("Phần cookie đã lưu bị hỏng. Chưa có gì bị thay đổi.")
		}
	}
	return out, nil
}

func (e *Env) claudeJSONAccount() map[string]any { return dict(readJSONMap(e.ClaudeJSON), "oauthAccount") }

// saveDesktopProfile stores the current Desktop login and refreshes its metadata.
func (e *Env) saveDesktopProfile(c *desktopConfig) error {
	a := c.auth
	if a == nil {
		return userErr("Claude chưa đăng nhập nên không có gì để lưu.")
	}
	var old *desktopSaved
	if s, err := e.readDesktopAuth(a.UUID); err == nil {
		old = s
	}
	cookiesPath, _ := e.cookiePaths()
	cookies, cerr := os.ReadFile(cookiesPath)
	cookiesUpdated := cerr == nil
	if cerr != nil {
		cookies = nil
		if old != nil {
			cookies = old.Cookies
		}
		if !errors.Is(cerr, os.ErrNotExist) {
			e.Logf("Cookies đang bị khóa: chỉ lưu phần config, giữ cookie cũ.")
		}
	}
	if err := e.writeDesktopAuth(a, cookies); err != nil {
		return err
	}
	metaPath := filepath.Join(e.profileDir(a.UUID), "meta.json")
	meta := readJSONMap(metaPath)
	if meta == nil {
		meta = map[string]any{}
	}
	email, disp, org := str(meta, "email"), str(meta, "displayName"), str(meta, "orgUuid")
	if cj := e.claudeJSONAccount(); cj != nil && strings.EqualFold(str(cj, "accountUuid"), a.UUID) {
		if v := str(cj, "emailAddress"); v != "" {
			email = v
		}
		if v := str(cj, "displayName"); v != "" {
			disp = v
		}
		if v := str(cj, "organizationUuid"); v != "" {
			org = v
		}
	} else if n := e.newestOrg(a.UUID); n != "" {
		org = n
	}
	label := str(meta, "label")
	if label == "" {
		switch {
		case disp != "":
			label = disp
		case email != "":
			label = strings.SplitN(email, "@", 2)[0]
		default:
			label = "Account " + a.UUID[:4]
		}
	}
	added := str(meta, "addedAt")
	if added == "" {
		added = nowISO(e)
	}
	meta["label"], meta["email"], meta["displayName"], meta["orgUuid"] = label, email, disp, org
	meta["savedAt"], meta["addedAt"], meta["hasCookies"] = nowISO(e), added, cookies != nil
	if err := writeJSON(metaPath, meta); err != nil {
		return err
	}
	e.Logf("Đã lưu profile %s (cookie cập nhật: %v)", a.UUID, cookiesUpdated)
	if pend := e.pendingAdd(); pend != nil && !strings.EqualFold(str(pend, "previousAccount"), a.UUID) {
		os.Remove(e.pendingAddPath())
	}
	return nil
}

// SaveDesktop saves the account Claude Desktop is logged in with.
func (e *Env) SaveDesktop() (string, error) {
	c, err := e.readDesktopConfig()
	if err != nil {
		return "", err
	}
	if c.auth == nil {
		return "", userErr("Claude chưa đăng nhập nên không lưu gì (giữ nguyên profile đã lưu).")
	}
	return c.auth.UUID, e.saveDesktopProfile(c)
}

// SetDesktopLabel renames a saved account.
func (e *Env) SetDesktopLabel(uuid, label string) error {
	return setLabel(filepath.Join(e.profileDir(uuid), "meta.json"), uuid, label)
}

func setLabel(metaPath, uuid, label string) error {
	if !IsGUID(uuid) {
		return userErr("Thiếu mã tài khoản.")
	}
	meta := readJSONMap(metaPath)
	if meta == nil {
		return userErr("Chưa có profile cho tài khoản này.")
	}
	clean := strings.TrimSpace(strings.Map(func(r rune) rune {
		if r < 32 {
			return -1
		}
		return r
	}, label))
	if r := []rune(clean); len(r) > 30 {
		clean = string(r[:30])
	}
	if clean == "" {
		return userErr("Tên không được để trống.")
	}
	meta["label"] = clean
	return writeJSON(metaPath, meta)
}

// ---- backups -----------------------------------------------------------------------

type desktopBackup struct {
	dir                     string
	config, cookies, journal bool
}

func copyIfExists(src, dst string) (bool, error) {
	b, err := os.ReadFile(src)
	if errors.Is(err, os.ErrNotExist) {
		return false, nil
	}
	if err != nil {
		return false, err
	}
	return true, writeAtomic(dst, b)
}

func (e *Env) newDesktopBackup() (*desktopBackup, error) {
	root := filepath.Join(e.StoreDir, "backups")
	bk := &desktopBackup{dir: filepath.Join(root, stamp(e))}
	cookies, journal := e.cookiePaths()
	var err error
	if bk.config, err = copyIfExists(e.configPath(), filepath.Join(bk.dir, "config.json")); err != nil {
		return nil, err
	}
	if bk.cookies, err = copyIfExists(cookies, filepath.Join(bk.dir, "Cookies")); err != nil {
		return nil, err
	}
	if bk.journal, err = copyIfExists(journal, filepath.Join(bk.dir, "Cookies-journal")); err != nil {
		return nil, err
	}
	if err := writeJSON(filepath.Join(bk.dir, "backup.json"), map[string]bool{"config": bk.config, "cookies": bk.cookies, "journal": bk.journal}); err != nil {
		return nil, err
	}
	pruneDirs(root, 10)
	return bk, nil
}

func restoreFile(dst string, had bool, src string) error {
	if had {
		b, err := os.ReadFile(src)
		if err != nil {
			return err
		}
		return writeAtomic(dst, b)
	}
	if err := os.Remove(dst); err != nil && !errors.Is(err, os.ErrNotExist) {
		return err
	}
	return nil
}

func (e *Env) restoreDesktopBackup(bk *desktopBackup) error {
	cookies, journal := e.cookiePaths()
	if bk.config {
		if err := restoreFile(e.configPath(), true, filepath.Join(bk.dir, "config.json")); err != nil {
			return err
		}
	}
	if err := restoreFile(cookies, bk.cookies, filepath.Join(bk.dir, "Cookies")); err != nil {
		return err
	}
	return restoreFile(journal, bk.journal, filepath.Join(bk.dir, "Cookies-journal"))
}

// ---- switch / add --------------------------------------------------------------------

func (e *Env) failAt(point string) error {
	if e.FailAt == point {
		return errors.New("lỗi giả lập (" + point + ")")
	}
	return nil
}

func (e *Env) recoverDesktop(bk *desktopBackup, p Progress, what string, cause error) error {
	e.Logf("LỖI sau bước sao lưu: %v", cause)
	restoreErr := e.restoreDesktopBackup(bk)
	opened := e.StartDesktop()
	var msg string
	if restoreErr == nil {
		msg = "Không " + what + " được (" + cause.Error() + "). Đã khôi phục lại cấu hình và đăng nhập như trước, "
		if opened {
			msg += "Claude đã được mở lại."
		} else {
			msg += "hãy tự mở lại Claude."
		}
	} else {
		msg = "Không " + what + " được (" + cause.Error() + ") VÀ khôi phục tự động cũng lỗi. Bản sao lưu nằm ở: " + bk.dir
	}
	p.emit(e, "switch", "error", msg)
	return &UserError{Msg: msg}
}

func (e *Env) closeAndBackup(p Progress) (*desktopBackup, error) {
	p.emit(e, "close", "running", "Đang đóng Claude…")
	if err := e.StopDesktop(); err != nil {
		p.emit(e, "close", "error", err.Error())
		e.StartDesktop()
		return nil, err
	}
	p.emit(e, "close", "done", "Đã đóng Claude.")
	p.emit(e, "backup", "running", "Đang sao lưu…")
	bk, err := e.newDesktopBackup()
	if err != nil {
		p.emit(e, "backup", "error", "Không sao lưu được.")
		e.StartDesktop()
		return nil, userErr("Không sao lưu được cấu hình nên dừng lại. Chưa có gì bị thay đổi.")
	}
	return bk, nil
}

// SwitchDesktop changes Claude Desktop to a saved account.
func (e *Env) SwitchDesktop(target string, p Progress) (warning string, err error) {
	if !IsGUID(target) {
		return "", userErr("Thiếu mã tài khoản cần chuyển sang.")
	}
	tgt, err := e.readDesktopAuth(target)
	if err != nil {
		return "", err
	}
	c, err := e.readDesktopConfig()
	if err != nil {
		return "", err
	}
	if err := checkEditable(c); err != nil {
		return "", err
	}
	if c.auth != nil && strings.EqualFold(c.auth.UUID, target) {
		p.emit(e, "done", "ok", "Tài khoản này đang được dùng rồi, không cần chuyển.")
		return "", nil
	}
	syncOn, _ := e.Settings()["syncSessions"].(bool)

	bk, err := e.closeAndBackup(p)
	if err != nil {
		return "", err
	}
	step := func() error {
		c, err := e.readDesktopConfig()
		if err != nil {
			return err
		}
		if c.auth != nil {
			if err := e.saveDesktopProfile(c); err != nil {
				return err
			}
		} else {
			e.Logf("Trạng thái hiện tại chưa đăng nhập: không ghi đè profile.")
		}
		p.emit(e, "backup", "done", "Đã sao lưu cấu hình và đăng nhập.")
		if err := e.failAt("afterBackup"); err != nil {
			return err
		}
		if syncOn {
			p.emit(e, "sync", "running", "Đang đồng bộ session…")
			if r, err := e.SyncSessions(); err != nil {
				e.Logf("Đồng bộ session lỗi (bỏ qua): %v", err)
				p.emit(e, "sync", "warn", "Chưa đồng bộ được session, bỏ qua bước này.")
				warning = "Chưa đồng bộ được session."
			} else {
				p.emit(e, "sync", "done", r.String())
			}
		} else {
			p.emit(e, "sync", "skipped", "Đồng bộ session đang tắt.")
		}
		p.emit(e, "switch", "running", "Đang đổi tài khoản…")
		if c, err = e.readDesktopConfig(); err != nil {
			return err
		}
		if err := checkEditable(c); err != nil {
			return err
		}
		if tgt.Auth.HasTc {
			err = c.doc.Set(keyTc, tgt.Auth.Tc)
		} else {
			err = c.doc.Remove(keyTc)
		}
		if err == nil {
			err = c.doc.Set(keyTc2, tgt.Auth.Tc2)
		}
		if err == nil {
			err = c.doc.Set(keyUUID, tgt.Auth.UUID)
		}
		if err != nil {
			return err
		}
		if err := e.writeDesktopConfig(c, &tgt.Auth); err != nil {
			return err
		}
		if err := e.failAt("afterConfig"); err != nil {
			return err
		}
		cookies, journal := e.cookiePaths()
		if tgt.Cookies != nil {
			if err := writeAtomic(cookies, tgt.Cookies); err != nil {
				return err
			}
		} else if err := os.Remove(cookies); err == nil {
			e.Logf("Profile chưa có cookie: đã xóa cookie của account cũ.")
		}
		os.Remove(journal)
		if err := e.failAt("afterCookies"); err != nil {
			return err
		}
		p.emit(e, "switch", "done", "Đã đổi tài khoản.")
		return nil
	}
	if err := step(); err != nil {
		return "", e.recoverDesktop(bk, p, "đổi tài khoản", err)
	}
	p.emit(e, "open", "running", "Đang mở lại Claude…")
	if e.StartDesktop() {
		p.emit(e, "open", "done", "Đã mở lại Claude.")
	} else {
		p.emit(e, "open", "warn", "Chưa tự mở được Claude, hãy mở bằng tay.")
		warning = strings.TrimSpace(warning + " Hãy tự mở lại Claude.")
	}
	if warning != "" {
		p.emit(e, "done", "ok", "Đã chuyển tài khoản. "+warning)
	} else {
		p.emit(e, "done", "ok", "Đã chuyển tài khoản xong.")
	}
	return warning, nil
}

func (e *Env) pendingAddPath() string { return filepath.Join(e.StoreDir, "pending-add.json") }
func (e *Env) pendingAdd() map[string]any { return readJSONMap(e.pendingAddPath()) }

// PrepareAddDesktop saves the current account, then opens Claude at its login screen.
func (e *Env) PrepareAddDesktop(p Progress) error {
	c, err := e.readDesktopConfig()
	if err != nil {
		return err
	}
	if c.auth == nil {
		return userErr("Claude chưa đăng nhập account nào để lưu lại. Hãy đăng nhập account đầu tiên trước.")
	}
	if err := checkEditable(c); err != nil {
		return err
	}
	for _, k := range []string{keyTc2, keyUUID} {
		if c.doc.Count(k) != 1 {
			return userErr("config.json thiếu khóa '%s' nên chưa thể thêm account.", k)
		}
	}
	prev := c.auth.UUID
	bk, err := e.closeAndBackup(p)
	if err != nil {
		return err
	}
	step := func() error {
		c, err := e.readDesktopConfig()
		if err != nil {
			return err
		}
		if c.auth == nil {
			return errors.New("không lưu được account hiện tại nên không dám gỡ đăng nhập")
		}
		if err := e.saveDesktopProfile(c); err != nil {
			return err
		}
		if _, err := e.readDesktopAuth(c.auth.UUID); err != nil {
			return err
		}
		p.emit(e, "backup", "done", "Đã sao lưu và lưu account hiện tại.")
		if err := e.failAt("afterBackup"); err != nil {
			return err
		}
		p.emit(e, "switch", "running", "Đang chuẩn bị màn hình đăng nhập…")
		for _, k := range desktopKeys {
			if err := c.doc.Remove(k); err != nil {
				return err
			}
		}
		if err := e.writeDesktopConfig(c, nil); err != nil {
			return err
		}
		cookies, journal := e.cookiePaths()
		os.Remove(cookies)
		os.Remove(journal)
		if err := writeJSON(e.pendingAddPath(), map[string]any{"previousAccount": prev, "startedAt": nowISO(e)}); err != nil {
			return err
		}
		p.emit(e, "switch", "done", "Đã chuẩn bị màn hình đăng nhập.")
		return nil
	}
	if err := step(); err != nil {
		return e.recoverDesktop(bk, p, "thêm account", err)
	}
	p.emit(e, "open", "running", "Đang mở lại Claude…")
	if e.StartDesktop() {
		p.emit(e, "open", "done", "Claude đã mở ở màn hình đăng nhập.")
	} else {
		p.emit(e, "open", "warn", "Hãy tự mở lại Claude.")
	}
	p.emit(e, "login", "running", "Hãy đăng nhập account còn lại trong cửa sổ Claude.")
	return nil
}

// CancelAddDesktop goes back to the account used before adding.
func (e *Env) CancelAddDesktop(p Progress) error {
	pend := e.pendingAdd()
	prev := str(pend, "previousAccount")
	os.Remove(e.pendingAddPath())
	if !IsGUID(prev) {
		return nil
	}
	_, err := e.SwitchDesktop(prev, p)
	return err
}

// CheckAddedLogin saves the new account once Claude shows a different login.
// It returns the new account id when one was saved.
func (e *Env) CheckAddedLogin() (string, string) {
	pend := e.pendingAdd()
	if pend == nil {
		return "", ""
	}
	c, err := e.readDesktopConfig()
	if err != nil || c.auth == nil {
		return "", ""
	}
	if strings.EqualFold(c.auth.UUID, str(pend, "previousAccount")) {
		return "", "Đây vẫn là account cũ. Hãy đăng nhập account còn lại (khác account này)."
	}
	if err := e.saveDesktopProfile(c); err != nil {
		return "", err.Error()
	}
	os.Remove(e.pendingAddPath())
	return c.auth.UUID, ""
}
