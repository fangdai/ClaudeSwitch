package core

import (
	"bytes"
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/fangdai/ClaudeSwitch/internal/secure"
)

const (
	accA = "aaaaaaaa-1111-4111-8111-aaaaaaaaaaaa"
	accB = "bbbbbbbb-2222-4222-8222-bbbbbbbbbbbb"
	accC = "cccccccc-3333-4333-8333-cccccccccccc"
	orgA = "a0a0a0a0-1111-4111-8111-a0a0a0a0a0a0"
	orgB = "b0b0b0b0-2222-4222-8222-b0b0b0b0b0b0"
)

func newTestEnv(t *testing.T) *Env {
	t.Helper()
	root := t.TempDir()
	e := &Env{
		StoreDir:           filepath.Join(root, "store"),
		DesktopDir:         filepath.Join(root, "desktop"),
		ClaudeJSON:         filepath.Join(root, "home", ".claude.json"),
		CliConfigDir:       filepath.Join(root, "home", ".claude"),
		CliConfigFile:      filepath.Join(root, "home", ".claude.json"),
		CliCredentialsPath: filepath.Join(root, "home", ".claude", ".credentials.json"),
		CliPath:            filepath.Join(root, "bin", "claude"),
		NoAppControl:       true,
	}
	must(t, os.MkdirAll(e.DesktopDir, 0o700))
	must(t, writeAtomic(e.CliPath, []byte("fake")))
	return e
}

func must(t *testing.T, err error) {
	t.Helper()
	if err != nil {
		t.Fatal(err)
	}
}

func writeFile(t *testing.T, path, text string) {
	t.Helper()
	must(t, writeAtomic(path, []byte(text)))
}

func readFile(t *testing.T, path string) string {
	t.Helper()
	b, err := os.ReadFile(path)
	must(t, err)
	return string(b)
}

// ---- jsontext ----------------------------------------------------------------------

func TestJSONTextKeepsOtherBytes(t *testing.T) {
	src := "\xEF\xBB\xBF{\n  \"big\": 9007199254740993,\n  \"oauth:tokenCacheV2\": \"old\",\n  \"nested\": {\"oauth:tokenCacheV2\": \"keep\"},\n  \"tail\": \"quote \\\" and {braces}\"\n}"
	doc, err := parseJSONText([]byte(src))
	must(t, err)
	must(t, doc.Set("oauth:tokenCacheV2", "new"))
	want := strings.Replace(src, `"oauth:tokenCacheV2": "old"`, `"oauth:tokenCacheV2": "new"`, 1)
	if string(doc.bytes()) != want {
		t.Fatalf("set changed other bytes:\n%s", doc.bytes())
	}
	must(t, doc.Remove("oauth:tokenCacheV2"))
	obj, err := doc.object()
	must(t, err)
	if _, ok := obj["oauth:tokenCacheV2"]; ok || str(dict(obj, "nested"), "oauth:tokenCacheV2") != "keep" {
		t.Fatal("remove touched the wrong key")
	}
	if !strings.Contains(string(doc.bytes()), "9007199254740993") || !bytes.HasPrefix(doc.bytes(), []byte{0xEF, 0xBB, 0xBF}) {
		t.Fatal("big number or BOM lost")
	}
	must(t, doc.Remove("tail"))
	must(t, doc.Remove("big"))
	must(t, doc.Remove("nested"))
	if _, err := doc.object(); err != nil {
		t.Fatalf("empty object invalid: %q", doc.text)
	}
	must(t, doc.Set("k", map[string]any{"a": 1}))
	if o, _ := doc.object(); dict(o, "k") == nil {
		t.Fatal("insert into empty object failed")
	}
}

func TestJSONTextRejectsDuplicates(t *testing.T) {
	doc, err := parseJSONText([]byte(`{"a":1,"a":2}`))
	must(t, err)
	if err := doc.Set("a", 3); err == nil {
		t.Fatal("duplicate key must be refused")
	}
}

func TestSecureRoundTrip(t *testing.T) {
	dir := t.TempDir()
	enc, err := secure.Protect([]byte("secret"), dir)
	must(t, err)
	if bytes.Contains(enc, []byte("secret")) {
		t.Fatal("plaintext visible")
	}
	plain, err := secure.Unprotect(enc, dir)
	must(t, err)
	if string(plain) != "secret" {
		t.Fatal("round trip failed")
	}
	if _, err := secure.Unprotect([]byte("garbage"), dir); err == nil {
		t.Fatal("garbage must not decrypt")
	}
}

// ---- Claude Desktop ------------------------------------------------------------------

func desktopConfigText(uuid string) string {
	return "{\n  \"numStartups\": 3,\n  \"" + keyTc + "\": \"TC-" + uuid + "\",\n  \"" + keyTc2 + "\": \"TC2-" + uuid + "\",\n  \"" + keyUUID + "\": \"" + uuid + "\",\n  \"other\": {\"x\": [1, 2]}\n}"
}

func loginDesktop(t *testing.T, e *Env, uuid, org string) {
	t.Helper()
	writeFile(t, e.configPath(), desktopConfigText(uuid))
	cookies, _ := e.cookiePaths()
	writeFile(t, cookies, "COOKIES-"+uuid)
	writeFile(t, e.ClaudeJSON, `{"oauthAccount":{"accountUuid":"`+uuid+`","emailAddress":"`+uuid[:1]+`@example.test","displayName":"User `+strings.ToUpper(uuid[:1])+`","organizationUuid":"`+org+`"}}`)
}

func TestDesktopSaveAndSwitch(t *testing.T) {
	e := newTestEnv(t)
	loginDesktop(t, e, accA, orgA)
	if _, err := e.SaveDesktop(); err != nil {
		t.Fatal(err)
	}
	loginDesktop(t, e, accB, orgB)
	if _, err := e.SaveDesktop(); err != nil {
		t.Fatal(err)
	}
	st := e.DesktopState()
	if len(st.Profiles) != 2 || st.ActiveUUID != accB || st.UnsavedCurrent || st.Profiles[0].Label != "User A" {
		t.Fatalf("unexpected status %+v", st)
	}
	var steps []string
	if _, err := e.SwitchDesktop(accA, func(s, state, _ string) { steps = append(steps, s+":"+state) }); err != nil {
		t.Fatal(err)
	}
	if got := readFile(t, e.configPath()); got != desktopConfigText(accA) {
		t.Fatalf("config not restored byte for byte:\n%s", got)
	}
	cookies, _ := e.cookiePaths()
	if readFile(t, cookies) != "COOKIES-"+accA {
		t.Fatal("cookies not switched")
	}
	if !strings.Contains(strings.Join(steps, ","), "done:ok") {
		t.Fatalf("no final step: %v", steps)
	}
	// Profile B was refreshed while switching away.
	if s, err := e.readDesktopAuth(accB); err != nil || string(s.Cookies) != "COOKIES-"+accB {
		t.Fatal("previous account not kept")
	}
}

func TestDesktopSwitchRollsBack(t *testing.T) {
	for _, point := range []string{"afterBackup", "afterConfig", "afterCookies"} {
		e := newTestEnv(t)
		loginDesktop(t, e, accA, orgA)
		e.SaveDesktop()
		loginDesktop(t, e, accB, orgB)
		e.SaveDesktop()
		e.FailAt = point
		before := readFile(t, e.configPath())
		if _, err := e.SwitchDesktop(accA, nil); err == nil || !strings.Contains(err.Error(), "khôi phục") {
			t.Fatalf("%s: expected restore message, got %v", point, err)
		}
		cookies, _ := e.cookiePaths()
		if readFile(t, e.configPath()) != before || readFile(t, cookies) != "COOKIES-"+accB {
			t.Fatalf("%s: not rolled back", point)
		}
	}
}

func TestDesktopAddFlow(t *testing.T) {
	e := newTestEnv(t)
	loginDesktop(t, e, accA, orgA)
	must(t, e.PrepareAddDesktop(nil))
	obj := readJSONMap(e.configPath())
	if _, ok := obj[keyTc2]; ok || obj["numStartups"] == nil {
		t.Fatal("login keys not removed or other keys lost")
	}
	cookies, _ := e.cookiePaths()
	if fileExists(cookies) || e.pendingAdd() == nil {
		t.Fatal("cookies kept or pending missing")
	}
	if id, _ := e.CheckAddedLogin(); id != "" {
		t.Fatal("no login yet")
	}
	loginDesktop(t, e, accA, orgA)
	if id, msg := e.CheckAddedLogin(); id != "" || msg == "" {
		t.Fatal("same account must not count as new")
	}
	loginDesktop(t, e, accC, orgB)
	if id, _ := e.CheckAddedLogin(); id != accC || e.pendingAdd() != nil {
		t.Fatal("new account not saved")
	}
	if len(e.DesktopProfiles()) != 2 {
		t.Fatal("expected two profiles")
	}
}

func TestSyncSessions(t *testing.T) {
	e := newTestEnv(t)
	loginDesktop(t, e, accA, orgA)
	e.SaveDesktop()
	loginDesktop(t, e, accB, orgB)
	e.SaveDesktop()
	dirA := filepath.Join(e.sessionsRoot(), accA, orgA)
	dirB := filepath.Join(e.sessionsRoot(), accB, orgB)
	writeFile(t, filepath.Join(dirA, "local_1.json"), `{"lastActivityAt":"2026-01-01T00:00:00Z","v":"a"}`)
	writeFile(t, filepath.Join(dirB, "local_2.json"), `{"lastActivityAt":"2026-01-01T00:00:00Z"}`)
	r, err := e.SyncSessions()
	must(t, err)
	if r.Copied != 2 || !fileExists(filepath.Join(dirB, "local_1.json")) {
		t.Fatalf("copy failed %+v", r)
	}
	writeFile(t, filepath.Join(dirB, "local_1.json"), `{"lastActivityAt":"2026-02-01T00:00:00Z","v":"b"}`)
	os.Remove(filepath.Join(dirA, "local_2.json"))
	r, err = e.SyncSessions()
	must(t, err)
	if r.Updated != 1 || !strings.Contains(readFile(t, filepath.Join(dirA, "local_1.json")), `"b"`) || fileExists(filepath.Join(dirA, "local_2.json")) {
		t.Fatalf("update or delete handling wrong %+v", r)
	}
	writeFile(t, filepath.Join(dirA, "local_3.json"), `{"v":3}`)
	_, err = e.SyncSessions()
	must(t, err)
	removed, kept, err := e.RemoveCopies()
	must(t, err)
	// local_3 copy is untouched -> removed; local_1 copy in B was edited -> kept.
	if removed != 1 || kept != 1 || fileExists(filepath.Join(dirB, "local_3.json")) || !fileExists(filepath.Join(dirB, "local_1.json")) {
		t.Fatalf("remove copies: %d %d", removed, kept)
	}
	// Removing our own copies is not a user deletion: syncing again brings them back.
	r, err = e.SyncSessions()
	must(t, err)
	if r.Copied != 1 || !fileExists(filepath.Join(dirB, "local_3.json")) {
		t.Fatalf("resync after remove copies %+v", r)
	}
	// A session the user deleted stays deleted.
	os.Remove(filepath.Join(dirB, "local_3.json"))
	r, err = e.SyncSessions()
	must(t, err)
	if r.Copied != 0 || fileExists(filepath.Join(dirB, "local_3.json")) {
		t.Fatalf("user deletion recreated %+v", r)
	}
}

// ---- CLI ---------------------------------------------------------------------------

type fakeServer struct {
	owners       map[string]string
	usage        map[string]float64
	usageStatus  int
	refreshCode  int
	profileCalls int
	usageCalls   int
	refreshCalls int
}

func (f *fakeServer) do(method, url, token string, body any) HTTPReply {
	switch url {
	case "https://api.anthropic.com/api/oauth/profile":
		f.profileCalls++
		if o, ok := f.owners[token]; ok {
			return HTTPReply{Status: 200, Body: map[string]any{"account": map[string]any{"uuid": o}}}
		}
		return HTTPReply{Status: 401}
	case "https://platform.claude.com/v1/oauth/token":
		f.refreshCalls++
		if f.refreshCode != 200 {
			return HTTPReply{Status: f.refreshCode}
		}
		f.owners["FAKE-ACCESS-RENEWED"] = accA
		return HTTPReply{Status: 200, Body: map[string]any{"access_token": "FAKE-ACCESS-RENEWED", "refresh_token": "FAKE-REFRESH-RENEWED", "expires_in": json.Number("28800")}}
	default:
		f.usageCalls++
		if f.usageStatus != 200 {
			return HTTPReply{Status: f.usageStatus, RetrySeconds: 900}
		}
		return HTTPReply{Status: 200, Body: map[string]any{
			"five_hour": map[string]any{"utilization": json.Number(jsonNum(f.usage[f.owners[token]])), "resets_at": "2026-11-06T10:00:00Z"},
			"seven_day": map[string]any{"utilization": json.Number("100")},
		}}
	}
}

func jsonNum(f float64) string { b, _ := json.Marshal(f); return string(b) }

func setCliLogin(t *testing.T, e *Env, claimed, access string, expires time.Time) {
	t.Helper()
	oauth := map[string]any{"accessToken": access, "refreshToken": strings.Replace(access, "ACCESS", "REFRESH", 1), "expiresAt": expires.UnixMilli()}
	b, _ := json.Marshal(map[string]any{"claudeAiOauth": oauth, "mcpOAuth": map[string]any{"keep": "untouched"}})
	must(t, writeAtomic(e.CliCredentialsPath, b))
	writeFile(t, e.CliConfigFile, `{"counter":9007199254740993,"oauthAccount":{"accountUuid":"`+claimed+`","emailAddress":"`+claimed[:1]+`@example.test"},"tail":"x"}`)
}

func TestCliSaveAndSwitch(t *testing.T) {
	e := newTestEnv(t)
	future := time.Now().Add(8 * time.Hour)
	setCliLogin(t, e, accA, "FAKE-ACCESS-A", future)
	must(t, e.SaveCli())
	setCliLogin(t, e, accB, "FAKE-ACCESS-B", future)
	must(t, e.SaveCli())
	if _, err := e.SwitchCli(accA, false); err != nil {
		t.Fatal(err)
	}
	creds := readJSONMap(e.CliCredentialsPath)
	cfg := readFile(t, e.CliConfigFile)
	if str(dict(creds, "claudeAiOauth"), "accessToken") != "FAKE-ACCESS-A" || dict(creds, "mcpOAuth") == nil {
		t.Fatal("credentials not switched or other providers lost")
	}
	if !strings.Contains(cfg, "9007199254740993") || !strings.Contains(cfg, accA) {
		t.Fatal("config not switched or big number lost")
	}
	e.FailAt = "cliAfterCredentials"
	before := readFile(t, e.CliCredentialsPath)
	if _, err := e.SwitchCli(accB, false); err == nil {
		t.Fatal("expected injected failure")
	}
	if readFile(t, e.CliCredentialsPath) != before {
		t.Fatal("credentials not restored after failure")
	}
	e.FailAt = ""
	setCliLogin(t, e, accA, "FAKE-ACCESS-A", time.Now().Add(-time.Hour))
	must(t, e.SaveCli())
	setCliLogin(t, e, accB, "FAKE-ACCESS-B", future)
	if _, err := e.SwitchCli(accA, false); err == nil || !strings.Contains(err.Error(), "hết hiệu lực") {
		t.Fatalf("expired saved login must be refused: %v", err)
	}
}

func TestCliIdentityFollowsToken(t *testing.T) {
	e := newTestEnv(t)
	srv := &fakeServer{owners: map[string]string{"FAKE-ACCESS-A": accA, "FAKE-ACCESS-B": accB, "FAKE-ACCESS-B2": accB}, usageStatus: 200}
	e.HTTP, e.VerifyOwner = srv.do, true
	future := time.Now().Add(8 * time.Hour)
	setCliLogin(t, e, accA, "FAKE-ACCESS-A", future)
	must(t, e.SaveCli())
	setCliLogin(t, e, accB, "FAKE-ACCESS-B", future)
	must(t, e.SaveCli())
	profileA := readFile(t, filepath.Join(e.cliProfileDir(accA), "auth.bin"))

	// Claude Desktop's embedded Claude Code rewrote the claim to A; the token is B's (rotated).
	setCliLogin(t, e, accA, "FAKE-ACCESS-B2", future)
	live := e.CliLiveState()
	if !live.Verified || live.UUID != accB || !live.Mismatch || str(live.Account, "accountUuid") != accB {
		t.Fatalf("owner not resolved from token: %+v", live)
	}
	e.syncActiveCli(live)
	if p, _ := e.readCliProfile(accB); str(p.Oauth, "accessToken") != "FAKE-ACCESS-B2" {
		t.Fatal("rotated token not saved under real owner")
	}
	if readFile(t, filepath.Join(e.cliProfileDir(accA), "auth.bin")) != profileA {
		t.Fatal("claimed account was overwritten")
	}
	calls := srv.profileCalls
	e.CliLiveState()
	if srv.profileCalls != calls {
		t.Fatal("owner lookups must be cached")
	}
	if strings.Contains(readFile(t, e.identityPath()), "FAKE-") {
		t.Fatal("identity cache holds raw tokens")
	}
	st := e.CliStatus()
	if st.ActiveUUID != accB || !st.IdentityMismatch || st.UnsavedCurrent {
		t.Fatalf("status wrong %+v", st)
	}
	if err := e.saveCliProfile(&CliState{LoggedIn: true, UUID: accA, Oauth: live.Oauth, Account: map[string]any{"accountUuid": accA}}); err == nil {
		t.Fatal("unverified login saved")
	}
	setCliLogin(t, e, accA, "FAKE-ACCESS-UNKNOWN", future)
	if st := e.CliStatus(); !st.Unverified || st.ActiveUUID != "" {
		t.Fatal("unknown token shown as an account")
	}

	// A profile corrupted by the old behaviour: A holding B's login.
	plain, _ := json.Marshal(map[string]any{"version": 1, "uuid": accA, "oauth": live.Oauth, "account": map[string]any{"accountUuid": accA}})
	enc, _ := secure.Protect(plain, e.StoreDir)
	must(t, writeAtomic(filepath.Join(e.cliProfileDir(accA), "auth.bin"), enc))
	if r := e.updateAccountUsage(accA, nil, true, e.CliLiveState()); r.State != "wrong_account" || len(r.Windows) != 0 {
		t.Fatalf("borrowed usage shown: %+v", r)
	}
	e.repairCliProfiles()
	if fileExists(filepath.Join(e.cliProfileDir(accA), "auth.bin")) {
		t.Fatal("corrupted profile not moved aside")
	}
	if m, _ := filepath.Glob(filepath.Join(e.cliProfileDir(accA), "auth.wrong-*.bin")); len(m) != 1 {
		t.Fatal("corrupted profile deleted instead of kept aside")
	}
	if r := e.updateAccountUsage(accA, &UsageRecord{Windows: []UsageWindow{{ID: "x", UsedPercent: 5}}}, true, e.CliLiveState()); r.State != "missing_login" || len(r.Windows) != 0 || !strings.Contains(r.Message, "lẫn") {
		t.Fatalf("repaired account state wrong: %+v", r)
	}
}

// ---- usage ---------------------------------------------------------------------------

func TestUsageWindowsParse(t *testing.T) {
	w := parseUsageWindows(map[string]any{
		"five_hour":   map[string]any{"utilization": json.Number("0")},
		"seven_day":   map[string]any{"utilization": "100"},
		"extra_usage": map[string]any{"utilization": nil},
	})
	if len(w) != 1 || w[0].UsedPercent != 0 {
		t.Fatalf("got %+v", w)
	}
}

func TestUsageRefresh(t *testing.T) {
	e := newTestEnv(t)
	srv := &fakeServer{owners: map[string]string{"FAKE-ACCESS-A": accA, "FAKE-ACCESS-B": accB}, usage: map[string]float64{accA: 26, accB: 50}, usageStatus: 200, refreshCode: 200}
	e.HTTP = srv.do
	setCliLogin(t, e, accA, "FAKE-ACCESS-A", time.Now().Add(-time.Hour))
	must(t, e.SaveCli())
	setCliLogin(t, e, accB, "FAKE-ACCESS-B", time.Now().Add(8*time.Hour))
	must(t, e.SaveCli())
	activeCreds := readFile(t, e.CliCredentialsPath)

	cache := e.RefreshUsage(false)
	a, b := cache.Accounts[accA], cache.Accounts[accB]
	if a.State != "ok" || b.State != "ok" || a.Windows[0].UsedPercent != 26 || b.Windows[0].UsedPercent != 50 {
		t.Fatalf("usage wrong: %+v %+v", a, b)
	}
	if srv.refreshCalls != 1 || readFile(t, e.CliCredentialsPath) != activeCreds {
		t.Fatal("inactive renewal must not touch the active login")
	}
	calls := srv.usageCalls
	e.RefreshUsage(false)
	if srv.usageCalls != calls {
		t.Fatal("fresh cache must prevent new requests")
	}
	if strings.Contains(readFile(t, e.usagePath()), "FAKE-") {
		t.Fatal("usage cache holds tokens")
	}
	srv.usageStatus = 429
	r := e.updateAccountUsage(accB, nil, true, e.CliLiveState())
	calls = srv.usageCalls
	r2 := e.updateAccountUsage(accB, r, true, e.CliLiveState())
	if r.State != "limited" || srv.usageCalls != calls || r2.RetryAt != r.RetryAt {
		t.Fatal("rate-limit delay not honoured")
	}
}

func TestUsageRevokedAndFallback(t *testing.T) {
	e := newTestEnv(t)
	srv := &fakeServer{owners: map[string]string{}, usageStatus: 200, refreshCode: 400}
	e.HTTP = srv.do
	loginDesktop(t, e, accA, orgA)
	e.SaveDesktop()
	setCliLogin(t, e, accA, "FAKE-ACCESS-A", time.Now().Add(-time.Hour))
	must(t, e.SaveCli())
	setCliLogin(t, e, accB, "FAKE-ACCESS-B", time.Now().Add(8*time.Hour))
	must(t, e.SaveCli())
	r := e.updateAccountUsage(accA, nil, true, e.CliLiveState())
	if r.State != "login_expired" || !strings.Contains(r.Message, "thu hồi") {
		t.Fatalf("revoked login not reported: %+v", r)
	}
	ts := time.Now().Add(-time.Hour).UnixMilli()
	b, _ := json.Marshal(map[string]any{"version": 2, "samples": []any{
		map[string]any{"t": ts, "org": orgA, "u": map[string]any{"fh": 0, "sd": 97}},
		map[string]any{"t": ts + 1000, "org": orgB, "u": map[string]any{"fh": 88, "sd": 99}},
		map[string]any{"t": ts + 2000, "u": map[string]any{"fh": 50}},
	}})
	must(t, writeAtomic(filepath.Join(e.DesktopDir, "plan-usage-history.json"), b))
	r = e.updateAccountUsage(accA, nil, true, e.CliLiveState())
	if r.State != "cached" || len(r.Windows) != 2 || r.Windows[0].UsedPercent != 0 || r.Windows[1].UsedPercent != 97 {
		t.Fatalf("desktop fallback wrong: %+v", r)
	}
}

func TestFindAccount(t *testing.T) {
	list := []AccountView{{UUID: accA, Label: "Đại", Email: "a@x"}, {UUID: accB, Label: "Cloud", Email: "b@x"}}
	if id, err := FindAccount(list, "cloud"); err != nil || id != accB {
		t.Fatal("label lookup failed")
	}
	if id, err := FindAccount(list, "aaaa"); err != nil || id != accA {
		t.Fatal("prefix lookup failed")
	}
	if _, err := FindAccount(list, "zzz"); err == nil {
		t.Fatal("unknown must fail")
	}
}
