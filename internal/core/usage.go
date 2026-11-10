package core

import (
	"crypto/rand"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"time"
)

func randRead(b []byte) (int, error) { return rand.Read(b) }

// UsageWindow is one quota window ("5 giờ", "7 ngày"…).
type UsageWindow struct {
	ID          string  `json:"id"`
	Label       string  `json:"label"`
	UsedPercent float64 `json:"usedPercent"`
	ResetsAt    string  `json:"resetsAt,omitempty"`
}

// UsageRecord is the cached quota of one account.
type UsageRecord struct {
	State           string        `json:"state"` // ok | cached | limited | login_expired | missing_login | wrong_account | unavailable
	CheckedAt       string        `json:"checkedAt"`
	UpdatedAt       string        `json:"updatedAt,omitempty"`
	AuthFingerprint string        `json:"authFingerprint,omitempty"`
	Windows         []UsageWindow `json:"windows"`
	Message         string        `json:"message,omitempty"`
	RetryAt         string        `json:"retryAt,omitempty"`
}

// UsageCache maps account ids to their usage.
type UsageCache struct {
	Accounts map[string]*UsageRecord `json:"accounts"`
}

func (e *Env) usagePath() string { return filepath.Join(e.StoreDir, "usage.json") }

// ReadUsage loads the shared usage cache.
func (e *Env) ReadUsage() *UsageCache {
	c := &UsageCache{Accounts: map[string]*UsageRecord{}}
	raw := readJSONMap(e.usagePath())
	for id, v := range dict(raw, "accounts") {
		m, ok := v.(map[string]any)
		if !ok {
			continue
		}
		r := &UsageRecord{State: str(m, "state"), CheckedAt: str(m, "checkedAt"), UpdatedAt: str(m, "updatedAt"),
			AuthFingerprint: str(m, "authFingerprint"), Message: str(m, "message"), RetryAt: str(m, "retryAt")}
		if list, ok := m["windows"].([]any); ok {
			for _, w := range list {
				wm, _ := w.(map[string]any)
				p, ok := num(wm["usedPercent"])
				if !ok {
					continue
				}
				r.Windows = append(r.Windows, UsageWindow{ID: str(wm, "id"), Label: str(wm, "label"), UsedPercent: p, ResetsAt: str(wm, "resetsAt")})
			}
		}
		c.Accounts[id] = r
	}
	return c
}

var usageLabels = []struct{ key, label string }{
	{"five_hour", "5 giờ"},
	{"seven_day", "7 ngày"},
	{"seven_day_opus", "Opus · 7 ngày"},
	{"seven_day_sonnet", "Sonnet · 7 ngày"},
	{"seven_day_overage_included", "Fable · 7 ngày"},
}

// parseUsageWindows keeps only well-formed windows (0 is a valid value).
func parseUsageWindows(payload map[string]any) []UsageWindow {
	var out []UsageWindow
	for _, l := range usageLabels {
		w := dict(payload, l.key)
		if w == nil {
			continue
		}
		p, ok := num(w["utilization"])
		if !ok || p < 0 || p > 100 || p != p {
			continue
		}
		uw := UsageWindow{ID: l.key, Label: l.label, UsedPercent: p}
		if t, err := time.Parse(time.RFC3339Nano, str(w, "resets_at")); err == nil {
			uw.ResetsAt = t.UTC().Format(time.RFC3339Nano)
		}
		out = append(out, uw)
	}
	return out
}

func parseTime(s string) time.Time {
	t, err := time.Parse(time.RFC3339Nano, s)
	if err != nil {
		return time.Time{}
	}
	return t
}

// usageAccountIDs lists Desktop and CLI accounts once each.
func (e *Env) usageAccountIDs() []string {
	set := map[string]bool{}
	for _, p := range e.DesktopProfiles() {
		set[strings.ToLower(p.UUID)] = true
	}
	for _, id := range e.cliProfileIDs() {
		set[strings.ToLower(id)] = true
	}
	var out []string
	for id := range set {
		out = append(out, id)
	}
	sort.Strings(out)
	return out
}

type usageAuth struct {
	oauth  map[string]any
	active bool
}

func (e *Env) usageAuth(uuid string, live *CliState) *usageAuth {
	if live != nil && live.Verified && strings.EqualFold(live.UUID, uuid) {
		return &usageAuth{oauth: live.Oauth, active: true}
	}
	p, err := e.readCliProfile(uuid)
	if err != nil {
		return nil
	}
	return &usageAuth{oauth: p.Oauth}
}

// renewInactive refreshes the token of a saved, not active, CLI account. The CLI owns
// the renewal of its active login. It returns the HTTP status of the refresh call.
func (e *Env) renewInactive(uuid string) (map[string]any, int) {
	live := e.CliLiveState()
	if live.Verified && strings.EqualFold(live.UUID, uuid) {
		return nil, 0
	}
	p, err := e.readCliProfile(uuid)
	if err != nil {
		return nil, 0
	}
	if !expiresSoon(e, p.Oauth, time.Minute) {
		return p.Oauth, 200
	}
	r := e.http("POST", "https://platform.claude.com/v1/oauth/token", "", map[string]any{
		"grant_type": "refresh_token", "refresh_token": str(p.Oauth, "refreshToken"), "client_id": oauthClientID,
	})
	e.Logf("Usage: làm mới đăng nhập CLI %s, HTTP %d.", uuid, r.Status)
	access := str(r.Body, "access_token")
	expiresIn, ok := num(r.Body["expires_in"])
	if r.Status != 200 || access == "" || !ok {
		return nil, r.Status
	}
	renewed := map[string]any{}
	for k, v := range p.Oauth {
		renewed[k] = v
	}
	renewed["accessToken"] = access
	if rt := str(r.Body, "refresh_token"); rt != "" {
		renewed["refreshToken"] = rt
	}
	renewed["expiresAt"] = e.now().UnixMilli() + int64(expiresIn*1000)
	if sc := str(r.Body, "scope"); sc != "" {
		renewed["scopes"] = strings.Fields(sc)
	}
	if err := e.saveCliProfile(&CliState{LoggedIn: true, Verified: true, UUID: uuid, Oauth: renewed, Account: p.Account}); err != nil {
		return nil, r.Status
	}
	return renewed, 200
}

func fingerprint(oauth map[string]any) string { return tokenKey(str(oauth, "accessToken")) }

// desktopFallback shows the last quota Claude Desktop recorded for the account's
// organization when live data is unavailable.
func (e *Env) desktopFallback(uuid string, r *UsageRecord) *UsageRecord {
	if r.State == "ok" || e.DesktopDir == "" {
		return r
	}
	hist := readJSONMap(filepath.Join(e.DesktopDir, "plan-usage-history.json"))
	org := str(readJSONMap(filepath.Join(e.profileDir(uuid), "meta.json")), "orgUuid")
	samples, _ := hist["samples"].([]any)
	if org == "" || len(samples) == 0 {
		return r
	}
	var best map[string]any
	var bestT float64 = -1
	for _, s := range samples {
		m, _ := s.(map[string]any)
		// Native Desktop v2 stores explicit organization ids; unscoped samples are skipped.
		if !strings.EqualFold(str(m, "org"), org) {
			continue
		}
		if t, ok := num(m["t"]); ok && t > bestT {
			best, bestT = m, t
		}
	}
	if best == nil {
		return r
	}
	at := time.UnixMilli(int64(bestT)).UTC()
	if at.Before(parseTime(r.UpdatedAt)) || at.After(e.now().Add(2*time.Minute)) {
		return r
	}
	u := dict(best, "u")
	payload := map[string]any{}
	for short, full := range map[string]string{"fh": "five_hour", "sd": "seven_day", "so": "seven_day_opus", "sn": "seven_day_sonnet"} {
		if v, ok := u[short]; ok {
			payload[full] = map[string]any{"utilization": v}
		}
	}
	w := parseUsageWindows(payload)
	if len(w) == 0 {
		return r
	}
	r.State = "cached"
	r.UpdatedAt = at.Format(time.RFC3339Nano)
	r.Windows = w
	r.Message = "Dữ liệu gần nhất từ Desktop. Chưa lấy được số liệu trực tiếp."
	return r
}

func (e *Env) updateAccountUsage(uuid string, prev *UsageRecord, force bool, live *CliState) *UsageRecord {
	now := e.now()
	auth := e.usageAuth(uuid, live)
	var fp string
	if auth != nil {
		fp = fingerprint(auth.oauth)
	}
	same := prev != nil && prev.AuthFingerprint == fp
	if same && parseTime(prev.RetryAt).After(now) {
		return e.desktopFallback(uuid, prev)
	}
	maxAge := 120 * time.Second
	if force {
		maxAge = 60 * time.Second
	}
	if same && parseTime(prev.CheckedAt).After(now.Add(-maxAge)) {
		return e.desktopFallback(uuid, prev)
	}
	r := &UsageRecord{State: "unavailable", CheckedAt: now.UTC().Format(time.RFC3339Nano), AuthFingerprint: fp}
	if prev != nil {
		r.UpdatedAt, r.Windows = prev.UpdatedAt, prev.Windows
	}
	if auth == nil {
		r.State, r.Message = "missing_login", "Đăng nhập account này trong mục CLI để xem usage."
		if reason := str(readJSONMap(filepath.Join(e.cliProfileDir(uuid), "meta.json")), "authRemovedReason"); reason != "" {
			// Never keep showing numbers that may belong to another account.
			r.Message, r.Windows, r.UpdatedAt = reason, nil, ""
		}
		return e.desktopFallback(uuid, r)
	}
	oauth := auth.oauth
	if !auth.active && expiresSoon(e, oauth, time.Minute) {
		renewed, status := e.renewInactive(uuid)
		if renewed != nil {
			oauth = renewed
			r.AuthFingerprint = fingerprint(oauth)
		} else if status == 400 || status == 401 {
			r.State, r.Message = "login_expired", "Đăng nhập CLI đã lưu của account này đã bị thu hồi. Đăng nhập lại account này trong mục CLI."
			r.RetryAt = now.Add(6 * time.Hour).UTC().Format(time.RFC3339Nano)
			return e.desktopFallback(uuid, r)
		}
	}
	// A login saved under this account must really belong to it, otherwise two cards
	// would show one account's quota.
	if owner := e.resolveOwner(oauth, uuid, true); owner != "" && !strings.EqualFold(owner, uuid) {
		r.State, r.Windows, r.UpdatedAt = "wrong_account", nil, ""
		r.Message = "Đăng nhập đã lưu thuộc account khác. Đăng nhập lại account này trong mục CLI."
		return r
	}
	if expiresSoon(e, oauth, 0) {
		r.State, r.Message = "login_expired", "Đăng nhập CLI đã hết hạn. Mở CLI hoặc đăng nhập lại để cập nhật."
		r.RetryAt = now.Add(10 * time.Minute).UTC().Format(time.RFC3339Nano)
		return e.desktopFallback(uuid, r)
	}
	reply := e.http("GET", "https://api.anthropic.com/api/oauth/usage", str(oauth, "accessToken"), nil)
	switch reply.Status {
	case 200:
		if w := parseUsageWindows(reply.Body); len(w) > 0 {
			r.State, r.Windows, r.UpdatedAt = "ok", w, e.now().UTC().Format(time.RFC3339Nano)
		} else {
			r.Message = "Máy chủ chưa trả về cửa sổ usage của account này."
		}
	case 401:
		r.State, r.Message = "login_expired", "Đăng nhập CLI cần được làm mới để xem usage."
		r.RetryAt = now.Add(10 * time.Minute).UTC().Format(time.RFC3339Nano)
	case 403:
		r.Message = "Đăng nhập này chưa được phép đọc usage."
		r.RetryAt = now.Add(10 * time.Minute).UTC().Format(time.RFC3339Nano)
	case 429:
		r.State, r.Message = "limited", "Máy chủ đang giới hạn lượt kiểm tra usage. Công cụ sẽ thử lại sau."
		r.RetryAt = now.Add(time.Duration(reply.RetrySeconds) * time.Second).UTC().Format(time.RFC3339Nano)
	default:
		r.Message = "Chưa kết nối được máy chủ usage. Bấm cập nhật để thử lại."
		r.RetryAt = now.Add(time.Minute).UTC().Format(time.RFC3339Nano)
	}
	return e.desktopFallback(uuid, r)
}

// repairCliProfiles moves aside saved CLI logins that belong to another account (written
// by versions that trusted the name in .claude.json).
func (e *Env) repairCliProfiles() {
	for _, uuid := range e.cliProfileIDs() {
		saved, err := e.readCliProfile(uuid)
		if err != nil {
			continue
		}
		owner := e.resolveOwner(saved.Oauth, uuid, true)
		if owner == "" || strings.EqualFold(owner, uuid) {
			continue
		}
		// Hand the login to its real owner when newer than that owner's saved copy.
		if ownerSaved, err := e.readCliProfile(owner); err == nil {
			a, _ := num(saved.Oauth["expiresAt"])
			b, _ := num(ownerSaved.Oauth["expiresAt"])
			if a > b {
				_ = e.saveCliProfile(&CliState{LoggedIn: true, Verified: true, UUID: owner, Oauth: saved.Oauth, Account: ownerSaved.Account})
			}
		}
		dir := e.cliProfileDir(uuid)
		aside := filepath.Join(dir, "auth.wrong-"+e.now().Format("20060102-150405")+".bin")
		if err := os.Rename(filepath.Join(dir, "auth.bin"), aside); err != nil {
			continue
		}
		meta := readJSONMap(filepath.Join(dir, "meta.json"))
		if meta == nil {
			meta = map[string]any{}
		}
		meta["authRemovedReason"] = "Đăng nhập đã lưu bị lẫn sang account khác nên đã được gỡ. Đăng nhập lại account này trong mục CLI."
		_ = writeJSON(filepath.Join(dir, "meta.json"), meta)
		e.Logf("CLI: profile %s chứa đăng nhập của %s; đã chuyển sang file .wrong.", uuid, owner)
	}
}

// RefreshUsage updates every account's quota and returns the cache.
func (e *Env) RefreshUsage(force bool) *UsageCache {
	cache := e.ReadUsage()
	if e.NoAppControl && e.HTTP == nil {
		return cache
	}
	e.repairCliProfiles()
	live := e.CliLiveState()
	e.syncActiveCli(live)
	for _, id := range e.usageAccountIDs() {
		cache.Accounts[id] = e.updateAccountUsage(id, cache.Accounts[id], force, live)
	}
	if err := writeJSON(e.usagePath(), cache); err != nil {
		e.Logf("Không ghi được usage.json: %v", err)
	}
	return cache
}
