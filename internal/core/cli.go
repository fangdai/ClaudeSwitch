package core

import (
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"time"

	"github.com/fangdai/ClaudeSwitch/internal/platform"
	"github.com/fangdai/ClaudeSwitch/internal/secure"
)

const oauthClientID = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"

// keychainServiceFor mirrors how Claude Code names its macOS Keychain item for a
// custom CLAUDE_CONFIG_DIR.
func keychainServiceFor(configDir string) string {
	h := sha256.Sum256([]byte(configDir))
	return "Claude Code-credentials-" + hex.EncodeToString(h[:])[:8]
}

// ---- credential storage (file, or the macOS Keychain) -------------------------------

type credStore struct {
	file             string
	service, account string
}

func (e *Env) cliCreds() credStore {
	return credStore{file: e.CliCredentialsPath, service: e.CliKeychainService, account: e.CliKeychainAccount}
}

func (s credStore) keychain() bool {
	if s.service == "" {
		return false
	}
	if _, err := platform.KeychainGet(s.service, s.account); err == nil {
		return true
	}
	return !fileExists(s.file)
}

type snapshot struct {
	data   []byte
	exists bool
}

func (s credStore) read() snapshot {
	if s.keychain() {
		v, err := platform.KeychainGet(s.service, s.account)
		if err != nil {
			return snapshot{}
		}
		return snapshot{data: []byte(v), exists: true}
	}
	b, err := os.ReadFile(s.file)
	if err != nil {
		return snapshot{}
	}
	return snapshot{data: b, exists: true}
}

func (s credStore) write(b []byte) error {
	if s.keychain() {
		return platform.KeychainSet(s.service, s.account, string(b))
	}
	return writeAtomic(s.file, b)
}

func (s credStore) restore(snap snapshot) error {
	if snap.exists {
		return s.write(snap.data)
	}
	if s.keychain() {
		platform.KeychainDelete(s.service, s.account)
		return nil
	}
	if err := os.Remove(s.file); err != nil && !errors.Is(err, os.ErrNotExist) {
		return err
	}
	return nil
}

func readFileSnap(path string) snapshot {
	b, err := os.ReadFile(path)
	if err != nil {
		return snapshot{}
	}
	return snapshot{data: b, exists: true}
}

// ---- state ----------------------------------------------------------------------------

// CliState is the live CLI login. UUID is the verified token owner when Verified is set;
// ClaimedUUID is what .claude.json says (Claude Desktop's embedded Claude Code rewrites it).
type CliState struct {
	LoggedIn    bool
	UUID        string
	ClaimedUUID string
	Verified    bool
	Mismatch    bool
	Oauth       map[string]any
	Account     map[string]any
}

func parseCliState(creds, config []byte) *CliState {
	st := &CliState{}
	if v, err := decodeJSON(creds); err == nil {
		m, _ := v.(map[string]any)
		st.Oauth = dict(m, "claudeAiOauth")
	}
	if v, err := decodeJSON(config); err == nil {
		m, _ := v.(map[string]any)
		st.Account = dict(m, "oauthAccount")
	}
	st.UUID = str(st.Account, "accountUuid")
	st.ClaimedUUID = st.UUID
	st.LoggedIn = IsGUID(st.UUID) && str(st.Oauth, "accessToken") != "" && str(st.Oauth, "refreshToken") != ""
	return st
}

func (e *Env) readCliState() *CliState {
	return parseCliState(e.cliCreds().read().data, readFileSnap(e.CliConfigFile).data)
}

// CliLiveState resolves who really owns the live CLI login.
func (e *Env) CliLiveState() *CliState {
	st := e.readCliState()
	if str(st.Oauth, "accessToken") == "" || str(st.Oauth, "refreshToken") == "" {
		return st
	}
	owner := e.resolveOwner(st.Oauth, st.ClaimedUUID, false)
	if owner == "" {
		return st
	}
	st.Verified, st.LoggedIn = true, true
	st.UUID = owner
	if !strings.EqualFold(owner, st.ClaimedUUID) {
		st.Mismatch = true
		st.Account = map[string]any{"accountUuid": owner}
		if saved, err := e.readCliProfile(owner); err == nil {
			st.Account = saved.Account
		}
	}
	return st
}

// ---- token identity ---------------------------------------------------------------------
// Only SHA-256 hashes of tokens are stored.

func (e *Env) identityPath() string { return filepath.Join(e.StoreDir, "cli", "identity.json") }

func tokenKey(token string) string {
	if token == "" {
		return ""
	}
	return sha256Hex([]byte(token))
}

func (e *Env) identityMap() map[string]map[string]any {
	out := map[string]map[string]any{}
	for k, v := range dict(readJSONMap(e.identityPath()), "tokens") {
		if m, ok := v.(map[string]any); ok {
			out[k] = m
		}
	}
	return out
}

func (e *Env) addIdentity(uuid string, oauth map[string]any) {
	if !IsGUID(uuid) || oauth == nil {
		return
	}
	m := e.identityMap()
	t := e.now().UnixMilli()
	for _, name := range []string{"accessToken", "refreshToken"} {
		if k := tokenKey(str(oauth, name)); k != "" {
			m[k] = map[string]any{"uuid": uuid, "t": t}
		}
	}
	type kv struct {
		k string
		t float64
	}
	var list []kv
	for k, v := range m {
		f, _ := num(v["t"])
		list = append(list, kv{k, f})
	}
	sort.Slice(list, func(i, j int) bool { return list[i].t > list[j].t })
	keep := map[string]any{}
	for i, x := range list {
		if i >= 80 {
			break
		}
		keep[x.k] = m[x.k]
	}
	if err := writeJSON(e.identityPath(), map[string]any{"version": 1, "tokens": keep}); err != nil {
		e.Logf("Không ghi được identity.json: %v", err)
	}
}

func (e *Env) requestOwner(oauth map[string]any) string {
	token := str(oauth, "accessToken")
	if token == "" {
		return ""
	}
	if exp, ok := num(oauth["expiresAt"]); ok && exp <= float64(e.now().UnixMilli()) {
		return ""
	}
	r := e.http("GET", "https://api.anthropic.com/api/oauth/profile", token, nil)
	if r.Status != 200 {
		return ""
	}
	owner := str(dict(r.Body, "account"), "uuid")
	if !IsGUID(owner) {
		return ""
	}
	return owner
}

// resolveOwner returns the verified owner of a token set, or "" when unknown.
func (e *Env) resolveOwner(oauth map[string]any, claimed string, skipSaved bool) string {
	access, refresh := str(oauth, "accessToken"), str(oauth, "refreshToken")
	if access == "" {
		return ""
	}
	ids := e.identityMap()
	for _, k := range []string{tokenKey(access), tokenKey(refresh)} {
		if v, ok := ids[k]; k != "" && ok && IsGUID(str(v, "uuid")) {
			return str(v, "uuid")
		}
	}
	if !skipSaved {
		for _, uuid := range e.cliProfileIDs() {
			saved, err := e.readCliProfile(uuid)
			if err != nil {
				continue
			}
			if str(saved.Oauth, "accessToken") == access || (refresh != "" && str(saved.Oauth, "refreshToken") == refresh) {
				// A saved copy is trusted only once its own owner was proven.
				v, ok := ids[tokenKey(str(saved.Oauth, "accessToken"))]
				if !e.VerifyOwner || (ok && strings.EqualFold(str(v, "uuid"), uuid)) {
					return uuid
				}
			}
		}
	}
	if !e.VerifyOwner {
		if IsGUID(claimed) {
			return claimed
		}
		return ""
	}
	owner := e.requestOwner(oauth)
	if owner != "" {
		e.addIdentity(owner, oauth)
		if claimed != "" && !strings.EqualFold(owner, claimed) {
			e.Logf("CLI: token thuộc account %s, cấu hình ghi %s.", owner, claimed)
		}
	}
	return owner
}

// ---- saved CLI profiles -------------------------------------------------------------------

type cliProfile struct {
	UUID    string
	Oauth   map[string]any
	Account map[string]any
}

func (e *Env) cliProfileDir(uuid string) string {
	return filepath.Join(e.StoreDir, "cli", "profiles", uuid)
}

func (e *Env) cliProfileIDs() []string {
	entries, _ := os.ReadDir(filepath.Join(e.StoreDir, "cli", "profiles"))
	var out []string
	for _, en := range entries {
		if en.IsDir() && IsGUID(en.Name()) {
			out = append(out, en.Name())
		}
	}
	return out
}

func (e *Env) readCliProfile(uuid string) (*cliProfile, error) {
	bad := userErr("Account CLI đã lưu bị hỏng hoặc không giải mã được. Chưa thay đổi đăng nhập hiện tại.")
	if !IsGUID(uuid) {
		return nil, userErr("Mã account CLI không hợp lệ.")
	}
	b, err := os.ReadFile(filepath.Join(e.cliProfileDir(uuid), "auth.bin"))
	if err != nil {
		return nil, bad
	}
	plain, err := secure.Unprotect(b, e.StoreDir)
	if err != nil {
		return nil, bad
	}
	v, err := decodeJSON(plain)
	m, _ := v.(map[string]any)
	if err != nil || m == nil {
		return nil, bad
	}
	p := &cliProfile{UUID: str(m, "uuid"), Oauth: dict(m, "oauth"), Account: dict(m, "account")}
	if !strings.EqualFold(p.UUID, uuid) || !strings.EqualFold(str(p.Account, "accountUuid"), uuid) || str(p.Oauth, "accessToken") == "" || str(p.Oauth, "refreshToken") == "" {
		return nil, bad
	}
	return p, nil
}

// saveCliProfile stores a verified login. Unverified logins are never saved.
func (e *Env) saveCliProfile(st *CliState) error {
	if !st.LoggedIn {
		return userErr("CLI chưa đăng nhập đầy đủ. Hãy bấm Đăng nhập CLI trước.")
	}
	if !st.Verified {
		return userErr("Chưa xác minh được account của đăng nhập CLI hiện tại. Chưa lưu gì.")
	}
	if !strings.EqualFold(str(st.Account, "accountUuid"), st.UUID) {
		return userErr("Thông tin account CLI không khớp token. Chưa lưu gì.")
	}
	plain, _ := json.Marshal(map[string]any{"version": 1, "uuid": st.UUID, "oauth": st.Oauth, "account": st.Account})
	enc, err := secure.Protect(plain, e.StoreDir)
	if err != nil {
		return err
	}
	dir := e.cliProfileDir(st.UUID)
	if err := writeAtomic(filepath.Join(dir, "auth.bin"), enc); err != nil {
		return err
	}
	e.addIdentity(st.UUID, st.Oauth)
	old := readJSONMap(filepath.Join(dir, "meta.json"))
	email := str(st.Account, "emailAddress")
	label := str(old, "label")
	if label == "" {
		label = str(readJSONMap(filepath.Join(e.profileDir(st.UUID), "meta.json")), "label")
	}
	if label == "" {
		if email != "" {
			label = email
		} else {
			label = "Account " + st.UUID[:4]
		}
	}
	if err := writeJSON(filepath.Join(dir, "meta.json"), map[string]any{"label": label, "email": email, "savedAt": nowISO(e)}); err != nil {
		return err
	}
	e.Logf("Đã lưu account Claude CLI.")
	return nil
}

// SaveCli saves the live CLI login (after verifying its owner).
func (e *Env) SaveCli() error { return e.saveCliProfile(e.CliLiveState()) }

// SetCliLabel renames a saved CLI account.
func (e *Env) SetCliLabel(uuid, label string) error {
	return setLabel(filepath.Join(e.cliProfileDir(uuid), "meta.json"), uuid, label)
}

// syncActiveCli keeps the saved copy of the active account current: the CLI rotates its
// tokens, and restoring an old refresh token later would fail.
func (e *Env) syncActiveCli(st *CliState) {
	if !st.Verified || !fileExists(filepath.Join(e.cliProfileDir(st.UUID), "auth.bin")) {
		return
	}
	if saved, err := e.readCliProfile(st.UUID); err == nil &&
		str(saved.Oauth, "accessToken") == str(st.Oauth, "accessToken") &&
		str(saved.Oauth, "refreshToken") == str(st.Oauth, "refreshToken") {
		return
	}
	if err := e.saveCliProfile(st); err != nil {
		e.Logf("Không cập nhật được bản lưu CLI: %v", err)
	}
}

// ---- guards -----------------------------------------------------------------------------

// CliOverrides lists configuration that bypasses the OAuth login.
func (e *Env) CliOverrides() []string {
	var out []string
	for _, k := range []string{"ANTHROPIC_API_KEY", "ANTHROPIC_AUTH_TOKEN", "CLAUDE_CODE_OAUTH_TOKEN", "ANTHROPIC_PROFILE"} {
		if os.Getenv(k) != "" {
			out = append(out, k)
		}
	}
	for _, k := range []string{"CLAUDE_CODE_USE_BEDROCK", "CLAUDE_CODE_USE_VERTEX", "CLAUDE_CODE_USE_FOUNDRY"} {
		if v := os.Getenv(k); v == "1" || v == "true" {
			out = append(out, k)
		}
	}
	if str(readJSONMap(filepath.Join(e.CliConfigDir, "settings.json")), "apiKeyHelper") != "" {
		out = append(out, "apiKeyHelper")
	}
	return out
}

// CliRunning counts open Claude Code CLI sessions (not the Desktop app nor the copy
// embedded in Claude Desktop).
func (e *Env) CliRunning() int {
	if e.NoAppControl {
		return 0
	}
	desk := strings.ToLower(filepath.Clean(e.DesktopDir))
	n := 0
	for _, p := range platform.Processes("claude") {
		path := strings.ToLower(p.Path)
		if isDesktopProcess(p) || (e.DesktopDir != "" && strings.HasPrefix(path, desk)) ||
			strings.Contains(path, "claude-data") || strings.Contains(path, "windowsapps") {
			continue
		}
		n++
	}
	return n
}

func (e *Env) assertCliCanChange() error {
	if e.FindCliPath() == "" {
		return userErr("Chưa tìm thấy Claude CLI trên máy.")
	}
	if len(e.CliOverrides()) > 0 {
		return userErr("CLI đang dùng API key, token hoặc nhà cung cấp từ cấu hình bên ngoài. Hãy bỏ cấu hình ghi đè trước khi chuyển account đăng nhập.")
	}
	if e.CliRunning() > 0 {
		return userErr("Hãy thoát các phiên Claude CLI đang chạy rồi chuyển account. Công cụ không tự đóng phiên CLI của bạn.")
	}
	return nil
}

// ---- switch ---------------------------------------------------------------------------

func expiresSoon(e *Env, oauth map[string]any, margin time.Duration) bool {
	exp, ok := num(oauth["expiresAt"])
	return ok && exp <= float64(e.now().Add(margin).UnixMilli())
}

// SwitchCli makes the CLI use a saved account. force skips the "already active" and
// expiry checks (used right after a fresh login).
func (e *Env) SwitchCli(uuid string, force bool) (string, error) {
	if err := e.assertCliCanChange(); err != nil {
		return "", err
	}
	target, err := e.readCliProfile(uuid)
	if err != nil {
		return "", err
	}
	current := e.CliLiveState()
	if !force && current.Verified && strings.EqualFold(current.UUID, uuid) && !current.Mismatch {
		return "CLI đang dùng account này.", nil
	}
	if !force && expiresSoon(e, target.Oauth, time.Minute) {
		var renewed map[string]any
		if !e.NoAppControl {
			renewed, _ = e.renewInactive(uuid)
		}
		if renewed == nil {
			name := str(readJSONMap(filepath.Join(e.cliProfileDir(uuid), "meta.json")), "label")
			if name == "" {
				name = str(target.Account, "emailAddress")
			}
			return "", userErr("Đăng nhập CLI đã lưu của %s đã hết hiệu lực. Bấm \"Thêm account CLI\" và đăng nhập lại account đó. CLI hiện tại chưa bị thay đổi.", name)
		}
		if target, err = e.readCliProfile(uuid); err != nil {
			return "", err
		}
	}
	store := e.cliCreds()
	credSnap, cfgSnap := store.read(), readFileSnap(e.CliConfigFile)
	credDoc, err := parseJSONText(orEmpty(credSnap.data))
	if err != nil {
		return "", userErr("File đăng nhập CLI bị lỗi định dạng. Chưa thay đổi đăng nhập.")
	}
	cfgDoc, err := parseJSONText(orEmpty(cfgSnap.data))
	if err != nil {
		return "", userErr("File cấu hình CLI bị lỗi định dạng. Chưa thay đổi đăng nhập.")
	}
	if err := credDoc.Set("claudeAiOauth", target.Oauth); err != nil {
		return "", err
	}
	if err := cfgDoc.Set("oauthAccount", target.Account); err != nil {
		return "", err
	}
	// Never save an unproven login under a guessed account; it stays in the backup below.
	if current.Verified && !strings.EqualFold(current.UUID, uuid) {
		if err := e.saveCliProfile(current); err != nil {
			return "", err
		}
	}
	if err := e.writeCliBackup(credSnap, cfgSnap); err != nil {
		return "", err
	}
	if again := store.read(); string(again.data) != string(credSnap.data) {
		return "", userErr("Đăng nhập CLI vừa thay đổi. Hãy thử lại.")
	}
	if again := readFileSnap(e.CliConfigFile); string(again.data) != string(cfgSnap.data) {
		return "", userErr("Cấu hình CLI vừa thay đổi. Hãy thử lại.")
	}
	apply := func() error {
		if err := store.write(credDoc.bytes()); err != nil {
			return err
		}
		if err := e.failAt("cliAfterCredentials"); err != nil {
			return err
		}
		if err := writeAtomic(e.CliConfigFile, cfgDoc.bytes()); err != nil {
			return err
		}
		check := e.readCliState()
		if !check.LoggedIn || !strings.EqualFold(check.UUID, uuid) || str(check.Oauth, "accessToken") != str(target.Oauth, "accessToken") {
			return errors.New("kiểm tra đăng nhập CLI sau khi ghi không khớp")
		}
		return nil
	}
	if err := apply(); err != nil {
		e1 := store.restore(credSnap)
		e2 := restoreSnap(e.CliConfigFile, cfgSnap)
		if e1 != nil || e2 != nil {
			return "", userErr("Không khôi phục tự động được CLI. Bản sao lưu mã hóa nằm trong thư mục cli/backups.")
		}
		return "", userErr("Chưa chuyển được CLI; đã khôi phục đăng nhập cũ. %v", err)
	}
	e.addIdentity(uuid, target.Oauth)
	if current.LoggedIn && !current.Verified {
		e.Logf("CLI: đăng nhập trước khi chuyển chưa xác minh được chủ sở hữu, chỉ giữ trong bản sao lưu.")
		return "Đã chuyển account CLI. Đăng nhập cũ chưa xác minh được account nên không lưu đè; nếu chuyển lại bị lỗi, đăng nhập lại account đó.", nil
	}
	e.Logf("Đã chuyển account CLI sang %s.", uuid)
	return "Đã chuyển account CLI. Mở phiên Claude CLI mới để sử dụng.", nil
}

func orEmpty(b []byte) []byte {
	if len(b) == 0 {
		return []byte("{}")
	}
	return b
}

func restoreSnap(path string, s snapshot) error {
	if s.exists {
		return writeAtomic(path, s.data)
	}
	if err := os.Remove(path); err != nil && !errors.Is(err, os.ErrNotExist) {
		return err
	}
	return nil
}

func (e *Env) writeCliBackup(cred, cfg snapshot) error {
	enc := func(s snapshot) any {
		if !s.exists {
			return nil
		}
		return base64.StdEncoding.EncodeToString(s.data)
	}
	plain, _ := json.Marshal(map[string]any{"credentials": enc(cred), "config": enc(cfg), "credentialsExisted": cred.exists, "configExisted": cfg.exists})
	data, err := secure.Protect(plain, e.StoreDir)
	if err != nil {
		return err
	}
	dir := filepath.Join(e.StoreDir, "cli", "backups")
	if err := writeAtomic(filepath.Join(dir, stamp(e)+".bin"), data); err != nil {
		return err
	}
	pruneDirs(dir, 20)
	return nil
}

// ---- login --------------------------------------------------------------------------------

func (e *Env) pendingLoginPath() string {
	return filepath.Join(e.StoreDir, "cli", "pending-login.json")
}

// CliPending describes an in-progress CLI login.
type CliPending struct {
	ID    string `json:"id"`
	State string `json:"state"` // waiting | ready | failed
	dir   string
}

func (e *Env) loginState(dir string) *CliState {
	creds := readFileSnap(filepath.Join(dir, ".credentials.json")).data
	if len(creds) == 0 && e.CliKeychainService != "" {
		if v, err := platform.KeychainGet(keychainServiceFor(dir), e.CliKeychainAccount); err == nil {
			creds = []byte(v)
		}
	}
	return parseCliState(creds, readFileSnap(filepath.Join(dir, ".claude.json")).data)
}

func (e *Env) cliPending() *CliPending {
	m := readJSONMap(e.pendingLoginPath())
	id := str(m, "id")
	if len(id) != 32 {
		return nil
	}
	p := &CliPending{ID: id, State: "waiting", dir: filepath.Join(e.StoreDir, "cli", "login", id)}
	if e.loginState(p.dir).LoggedIn {
		p.State = "ready"
	} else if t, err := time.Parse(time.RFC3339Nano, str(m, "startedAt")); err != nil || e.now().Sub(t) > 30*time.Minute {
		p.State = "failed"
	}
	return p
}

// StartCliLogin opens `claude auth login` in its own terminal, in a separate config folder
// so the current CLI login stays untouched.
func (e *Env) StartCliLogin() (string, error) {
	if err := e.assertCliCanChange(); err != nil {
		return "", err
	}
	if p := e.cliPending(); p != nil && p.State == "waiting" {
		return "Đang chờ đăng nhập CLI.", nil
	}
	e.clearPendingLogin()
	var rnd [16]byte
	if _, err := randRead(rnd[:]); err != nil {
		return "", err
	}
	id := hex.EncodeToString(rnd[:])
	dir := filepath.Join(e.StoreDir, "cli", "login", id)
	if err := ensureDir(dir); err != nil {
		return "", err
	}
	if !e.NoAppControl {
		env := map[string]string{"CLAUDE_CONFIG_DIR": dir, "CLAUDE_SECURESTORAGE_CONFIG_DIR": dir}
		if _, err := platform.OpenTerminal("Claude Switch - dang nhap CLI", env, platform.Home(), []string{e.FindCliPath(), "auth", "login", "--claudeai"}, true); err != nil {
			return "", userErr("Không mở được cửa sổ đăng nhập CLI: %v", err)
		}
	}
	if err := writeJSON(e.pendingLoginPath(), map[string]any{"id": id, "startedAt": nowISO(e)}); err != nil {
		return "", err
	}
	return "Đã mở đăng nhập CLI. Hoàn tất trong trình duyệt và cửa sổ CLI.", nil
}

func (e *Env) clearPendingLogin() {
	if p := e.cliPending(); p != nil {
		if e.CliKeychainService != "" {
			platform.KeychainDelete(keychainServiceFor(p.dir), e.CliKeychainAccount)
		}
		os.RemoveAll(p.dir)
	}
	os.Remove(e.pendingLoginPath())
}

// CancelCliLogin forgets an unfinished login.
func (e *Env) CancelCliLogin() { e.clearPendingLogin() }

// FinishCliLogin saves the account from a completed login and selects it.
func (e *Env) FinishCliLogin() (string, error) {
	p := e.cliPending()
	if p == nil || p.State != "ready" {
		return "", userErr("Chưa hoàn tất đăng nhập CLI.")
	}
	st := e.loginState(p.dir)
	if e.VerifyOwner {
		if owner := e.requestOwner(st.Oauth); owner != "" && !strings.EqualFold(owner, st.UUID) {
			return "", userErr("Account đăng nhập không khớp token trả về. Hãy đăng nhập lại.")
		}
	}
	st.Verified = true
	if err := e.saveCliProfile(st); err != nil {
		return "", err
	}
	if _, err := e.SwitchCli(st.UUID, true); err != nil {
		return "", err
	}
	e.clearPendingLogin()
	return "Đã lưu và chọn account CLI vừa đăng nhập.", nil
}

// OpenCli starts an interactive Claude CLI session in a new terminal.
func (e *Env) OpenCli() error {
	path := e.FindCliPath()
	if path == "" {
		return userErr("Chưa tìm thấy Claude CLI.")
	}
	if e.NoAppControl {
		return nil
	}
	_, err := platform.OpenTerminal("Claude CLI", nil, platform.Home(), []string{path}, false)
	return err
}
