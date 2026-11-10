package core

import (
	"path/filepath"
	"runtime"
	"strings"
)

// AccountView is one account card.
type AccountView struct {
	UUID              string `json:"uuid"`
	Label             string `json:"label"`
	Email             string `json:"email"`
	DisplayName       string `json:"displayName,omitempty"`
	OrgUUID           string `json:"orgUuid,omitempty"`
	SavedAt           string `json:"savedAt,omitempty"`
	HasAuth           bool   `json:"hasAuth"`
	IsActive          bool   `json:"isActive"`
	SessionCount      int    `json:"sessionCount"`
	AuthRemovedReason string `json:"authRemovedReason,omitempty"`
}

// DesktopStatus describes Claude Desktop.
type DesktopStatus struct {
	Installed      bool           `json:"installed"`
	DataDir        string         `json:"dataDir"`
	Running        bool           `json:"running"`
	LoggedIn       bool           `json:"loggedIn"`
	ActiveUUID     string         `json:"activeUuid"`
	UnsavedCurrent bool           `json:"unsavedCurrent"`
	ConfigError    string         `json:"configError,omitempty"`
	Profiles       []AccountView  `json:"profiles"`
	RecentActive   int            `json:"recentActive"`
	CopiedCount    int            `json:"copiedCount"`
	PendingAdd     map[string]any `json:"pendingAdd"`
}

// CliStatus describes the Claude Code CLI.
type CliStatus struct {
	Installed        bool          `json:"installed"`
	Path             string        `json:"path"`
	ConfigDir        string        `json:"configDir"`
	LoggedIn         bool          `json:"loggedIn"`
	ActiveUUID       string        `json:"activeUuid"`
	Email            string        `json:"email"`
	Profiles         []AccountView `json:"profiles"`
	UnsavedCurrent   bool          `json:"unsavedCurrent"`
	IdentityMismatch bool          `json:"identityMismatch"`
	Unverified       bool          `json:"unverified"`
	AuthOverrides    []string      `json:"authOverrides"`
	RunningCount     int           `json:"runningCount"`
	PendingLogin     *CliPending   `json:"pendingLogin"`
}

// Status is everything the UI shows.
type Status struct {
	Platform string         `json:"platform"`
	StoreDir string         `json:"storeDir"`
	Desktop  DesktopStatus  `json:"desktop"`
	Cli      CliStatus      `json:"cli"`
	Usage    *UsageCache    `json:"usage"`
	Settings map[string]any `json:"settings"`
}

// DesktopStatus reads the Claude Desktop state.
func (e *Env) DesktopState() DesktopStatus {
	d := DesktopStatus{Installed: e.DesktopInstalled(), DataDir: e.DesktopDir, Profiles: []AccountView{}}
	if !d.Installed {
		return d
	}
	c, err := e.readDesktopConfig()
	if err != nil {
		d.ConfigError = err.Error()
	} else if c.auth != nil {
		d.LoggedIn, d.ActiveUUID = true, c.auth.UUID
	}
	for _, p := range e.DesktopProfiles() {
		org := str(p.Meta, "orgUuid")
		if org == "" {
			org = e.newestOrg(p.UUID)
		}
		v := AccountView{UUID: p.UUID, Label: str(p.Meta, "label"), Email: str(p.Meta, "email"), DisplayName: str(p.Meta, "displayName"),
			OrgUUID: org, SavedAt: str(p.Meta, "savedAt"), HasAuth: p.HasAuth, SessionCount: e.sessionCount(p.UUID, org)}
		v.IsActive = d.ActiveUUID != "" && strings.EqualFold(d.ActiveUUID, p.UUID)
		if v.IsActive {
			d.RecentActive = e.recentSessions(p.UUID, org)
		}
		d.Profiles = append(d.Profiles, v)
	}
	if d.ActiveUUID != "" {
		d.UnsavedCurrent = !fileExists(filepath.Join(e.profileDir(d.ActiveUUID), "auth.bin"))
	}
	d.Running = e.DesktopRunning()
	d.CopiedCount = len(e.readManifest().Copies)
	d.PendingAdd = e.pendingAdd()
	return d
}

// CliState reads the Claude Code CLI state (and keeps the active saved copy current).
func (e *Env) CliStatus() CliStatus {
	path := e.FindCliPath()
	s := CliStatus{Installed: path != "", Path: path, ConfigDir: e.CliConfigDir, Profiles: []AccountView{}, AuthOverrides: e.CliOverrides()}
	if s.AuthOverrides == nil {
		s.AuthOverrides = []string{}
	}
	live := e.CliLiveState()
	overridden := len(s.AuthOverrides) > 0
	if !overridden {
		e.syncActiveCli(live)
	}
	usable := live.Verified && !overridden
	s.LoggedIn = live.LoggedIn && !overridden
	if usable {
		s.ActiveUUID = live.UUID
		s.Email = str(live.Account, "emailAddress")
		s.UnsavedCurrent = !fileExists(filepath.Join(e.cliProfileDir(live.UUID), "auth.bin"))
		s.IdentityMismatch = live.Mismatch
	}
	s.Unverified = live.LoggedIn && !live.Verified && !overridden
	for _, id := range e.cliProfileIDs() {
		meta := readJSONMap(filepath.Join(e.cliProfileDir(id), "meta.json"))
		s.Profiles = append(s.Profiles, AccountView{UUID: id, Label: str(meta, "label"), Email: str(meta, "email"), SavedAt: str(meta, "savedAt"),
			HasAuth: fileExists(filepath.Join(e.cliProfileDir(id), "auth.bin")), IsActive: usable && strings.EqualFold(live.UUID, id),
			AuthRemovedReason: str(meta, "authRemovedReason")})
	}
	s.RunningCount = e.CliRunning()
	s.PendingLogin = e.cliPending()
	return s
}

// Status collects the full state shown by the UI.
func (e *Env) Status() *Status {
	return &Status{
		Platform: runtime.GOOS,
		StoreDir: e.StoreDir,
		Desktop:  e.DesktopState(),
		Cli:      e.CliStatus(),
		Usage:    e.ReadUsage(),
		Settings: e.PublicSettings(),
	}
}

// FindAccount resolves a name, e-mail or id (prefix) among saved accounts.
func FindAccount(list []AccountView, query string) (string, error) {
	q := strings.ToLower(strings.TrimSpace(query))
	var hits []string
	for _, a := range list {
		if strings.EqualFold(a.UUID, q) {
			return a.UUID, nil
		}
		if strings.ToLower(a.Label) == q || strings.ToLower(a.Email) == q || (len(q) >= 4 && strings.HasPrefix(strings.ToLower(a.UUID), q)) {
			hits = append(hits, a.UUID)
		}
	}
	if len(hits) == 1 {
		return hits[0], nil
	}
	if len(hits) > 1 {
		return "", userErr("Có nhiều account khớp '%s'.", query)
	}
	return "", userErr("Không tìm thấy account '%s'.", query)
}
