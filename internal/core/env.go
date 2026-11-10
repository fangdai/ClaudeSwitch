// Package core holds every account operation: Claude Desktop, Claude Code CLI and usage.
// It never writes tokens to logs, status or metadata.
package core

import (
	"os"
	"os/user"
	"path/filepath"
	"runtime"
	"sort"
	"strings"
	"sync"
	"time"

	"github.com/fangdai/ClaudeSwitch/internal/platform"
)

// Env describes where everything lives. Tests build one over temporary folders.
type Env struct {
	StoreDir string // Claude Switch data
	// Claude Desktop userData folder ("" when Claude Desktop is not installed).
	DesktopDir string
	// ~/.claude.json written by Claude Code (CLI and the Desktop-embedded copy).
	ClaudeJSON string

	CliConfigDir       string
	CliConfigFile      string
	CliCredentialsPath string
	// CliKeychainService is set on macOS, where the CLI keeps its login in the Keychain.
	CliKeychainService string
	CliKeychainAccount string
	CliPath            string

	// NoAppControl never touches real processes or the network (tests).
	NoAppControl bool
	// VerifyOwner asks the server who owns a CLI token. Off in offline tests.
	VerifyOwner bool
	// HTTP performs requests; tests replace it.
	HTTP HTTPFunc
	Now  func() time.Time
	// FailAt injects failures in tests.
	FailAt string

	mu sync.Mutex
}

// Lock serialises mutating operations inside this process.
func (e *Env) Lock() func() {
	e.mu.Lock()
	return e.mu.Unlock
}

func (e *Env) now() time.Time {
	if e.Now != nil {
		return e.Now()
	}
	return time.Now()
}

// DefaultStoreDir is the per-user data folder of Claude Switch.
func DefaultStoreDir() string {
	switch runtime.GOOS {
	case "windows":
		if d := os.Getenv("LOCALAPPDATA"); d != "" {
			return filepath.Join(d, "ClaudeSwitch")
		}
	case "darwin":
		return filepath.Join(platform.Home(), "Library", "Application Support", "ClaudeSwitch")
	}
	if d := os.Getenv("XDG_DATA_HOME"); d != "" {
		return filepath.Join(d, "ClaudeSwitch")
	}
	return filepath.Join(platform.Home(), ".local", "share", "ClaudeSwitch")
}

// FindDesktopDir returns the Claude Desktop userData folder with the newest config.json.
func FindDesktopDir() string {
	var candidates []string
	home := platform.Home()
	switch runtime.GOOS {
	case "windows":
		local, roaming := os.Getenv("LOCALAPPDATA"), os.Getenv("APPDATA")
		if m, _ := filepath.Glob(filepath.Join(local, "Claude-Data", "claude_*")); m != nil {
			candidates = append(candidates, m...)
		}
		if m, _ := filepath.Glob(filepath.Join(local, "Packages", "Claude_*", "LocalCache", "Roaming", "Claude")); m != nil {
			candidates = append(candidates, m...)
		}
		candidates = append(candidates, filepath.Join(roaming, "Claude"))
	case "darwin":
		candidates = append(candidates, filepath.Join(home, "Library", "Application Support", "Claude"))
	default:
		cfg := os.Getenv("XDG_CONFIG_HOME")
		if cfg == "" {
			cfg = filepath.Join(home, ".config")
		}
		candidates = append(candidates, filepath.Join(cfg, "Claude"))
	}
	type c struct {
		dir string
		t   time.Time
	}
	var found []c
	for _, d := range candidates {
		if st, err := os.Stat(filepath.Join(d, "config.json")); err == nil {
			found = append(found, c{d, st.ModTime()})
		}
	}
	if len(found) == 0 {
		return ""
	}
	sort.Slice(found, func(i, j int) bool { return found[i].t.After(found[j].t) })
	return found[0].dir
}

// NewEnv builds the real environment of this machine.
func NewEnv() *Env {
	home := platform.Home()
	e := &Env{
		StoreDir:    DefaultStoreDir(),
		DesktopDir:  FindDesktopDir(),
		ClaudeJSON:  filepath.Join(home, ".claude.json"),
		VerifyOwner: true,
	}
	e.HTTP = defaultHTTP
	cfgDir := os.Getenv("CLAUDE_CONFIG_DIR")
	if cfgDir != "" {
		e.CliConfigDir = cfgDir
		e.CliConfigFile = filepath.Join(cfgDir, ".claude.json")
	} else {
		e.CliConfigDir = filepath.Join(home, ".claude")
		e.CliConfigFile = filepath.Join(home, ".claude.json")
	}
	credDir := e.CliConfigDir
	if d := os.Getenv("CLAUDE_SECURESTORAGE_CONFIG_DIR"); d != "" {
		credDir = d
	}
	e.CliCredentialsPath = filepath.Join(credDir, ".credentials.json")
	if runtime.GOOS == "darwin" {
		e.CliKeychainService = "Claude Code-credentials"
		if cfgDir != "" {
			e.CliKeychainService = keychainServiceFor(cfgDir)
		}
		e.CliKeychainAccount = currentUserName()
	}
	return e
}

func currentUserName() string {
	if u := os.Getenv("USER"); u != "" {
		return u
	}
	if u, err := user.Current(); err == nil {
		return u.Username
	}
	return ""
}

// FindCliPath locates the Claude Code CLI executable.
func (e *Env) FindCliPath() string {
	if e.CliPath != "" {
		if platform.Exists(e.CliPath) {
			return e.CliPath
		}
		return ""
	}
	home := platform.Home()
	var cands []string
	switch runtime.GOOS {
	case "windows":
		cands = []string{
			filepath.Join(home, ".local", "bin", "claude.exe"),
			filepath.Join(os.Getenv("APPDATA"), "npm", "node_modules", "@anthropic-ai", "claude-code", "bin", "claude.exe"),
			filepath.Join(os.Getenv("APPDATA"), "npm", "claude.cmd"),
		}
	default:
		cands = []string{
			filepath.Join(home, ".local", "bin", "claude"),
			filepath.Join(home, ".claude", "local", "claude"),
			"/opt/homebrew/bin/claude",
			"/usr/local/bin/claude",
		}
	}
	for _, c := range cands {
		if platform.Exists(c) {
			return c
		}
	}
	if p := platform.LookPath("claude"); p != "" && !strings.Contains(strings.ToLower(p), "windowsapps") {
		return p
	}
	return ""
}
