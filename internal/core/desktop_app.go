package core

import (
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"runtime"
	"strings"
	"time"

	"github.com/fangdai/ClaudeSwitch/internal/platform"
)

// isDesktopProcess tells Claude Desktop apart from the Claude Code CLI, which shares
// the executable name "claude" on Windows.
func isDesktopProcess(p platform.Proc) bool {
	path := strings.ToLower(filepath.ToSlash(p.Path))
	switch runtime.GOOS {
	case "windows":
		return strings.Contains(path, "/windowsapps/claude_") || strings.Contains(path, "/anthropicclaude/")
	case "darwin":
		return strings.Contains(path, "/claude.app/contents/")
	default:
		return strings.Contains(path, "claude-desktop") || strings.Contains(path, "/claude/claude")
	}
}

func (e *Env) desktopProcs() []platform.Proc {
	if e.NoAppControl {
		return nil
	}
	names := []string{"claude"}
	if runtime.GOOS == "darwin" {
		names = []string{"Claude", "Claude Helper", "Claude Helper (Renderer)", "Claude Helper (GPU)", "Claude Helper (Plugin)", "chrome_crashpad_handler"}
	} else if runtime.GOOS == "linux" {
		names = []string{"claude-desktop", "claude", "electron"}
	}
	var out []platform.Proc
	for _, p := range platform.Processes(names...) {
		if isDesktopProcess(p) {
			out = append(out, p)
		}
	}
	return out
}

// DesktopRunning reports whether Claude Desktop is open.
func (e *Env) DesktopRunning() bool { return len(e.desktopProcs()) > 0 }

var pkgRx = regexp.MustCompile(`(?i)[\\/]WindowsApps[\\/]((Claude)_[^\\/]*__([a-z0-9]+))[\\/]`)

// rememberDesktopApp stores how to start Claude Desktop, learned from its running process.
func (e *Env) rememberDesktopApp() {
	for _, p := range e.desktopProcs() {
		if m := pkgRx.FindStringSubmatch(p.Path); m != nil {
			root := p.Path[:strings.Index(strings.ToLower(p.Path), strings.ToLower(m[1]))+len(m[1])]
			appID := "Claude"
			if b, err := os.ReadFile(filepath.Join(root, "AppxManifest.xml")); err == nil {
				if mm := regexp.MustCompile(`<Application\s+Id="([^"]+)"`).FindSubmatch(b); mm != nil {
					appID = string(mm[1])
				}
			}
			e.updateSettings(map[string]any{"desktopAppId": m[2] + "_" + m[3] + "!" + appID, "desktopExe": ""})
			return
		}
		if p.Path != "" && runtime.GOOS == "windows" {
			e.updateSettings(map[string]any{"desktopExe": p.Path})
			return
		}
	}
}

func (e *Env) desktopAppID() string {
	if id := str(e.Settings(), "desktopAppId"); id != "" {
		return id
	}
	if runtime.GOOS != "windows" || e.NoAppControl {
		return ""
	}
	// One-off lookup; the result is cached in settings.
	cmd := exec.Command("powershell.exe", "-NoProfile", "-NonInteractive", "-Command",
		"(Get-StartApps | Where-Object { $_.AppID -like 'Claude_*!*' } | Select-Object -First 1).AppID")
	platform.Hide(cmd)
	out, err := cmd.Output()
	id := strings.TrimSpace(string(out))
	if err == nil && strings.Contains(id, "!") {
		e.updateSettings(map[string]any{"desktopAppId": id})
		return id
	}
	return ""
}

// DesktopInstalled reports whether Claude Desktop seems installed.
func (e *Env) DesktopInstalled() bool {
	if e.DesktopDir != "" && platform.Exists(filepath.Join(e.DesktopDir, "config.json")) {
		return true
	}
	if e.NoAppControl {
		return false
	}
	switch runtime.GOOS {
	case "darwin":
		return platform.Exists("/Applications/Claude.app")
	case "windows":
		return platform.Exists(filepath.Join(os.Getenv("LOCALAPPDATA"), "AnthropicClaude"))
	}
	return false
}

// StopDesktop closes Claude Desktop, gently first.
func (e *Env) StopDesktop() error {
	if e.NoAppControl {
		return nil
	}
	procs := e.desktopProcs()
	if len(procs) == 0 {
		return nil
	}
	e.rememberDesktopApp()
	if runtime.GOOS == "darwin" {
		_ = exec.Command("osascript", "-e", `tell application "Claude" to quit`).Run()
	} else {
		for _, p := range procs {
			_ = platform.Stop(p.PID, false)
		}
	}
	if waitUntil(4*time.Second, func() bool { return !e.DesktopRunning() }) {
		time.Sleep(800 * time.Millisecond)
		return nil
	}
	deadline := time.Now().Add(10 * time.Second)
	for time.Now().Before(deadline) {
		left := e.desktopProcs()
		if len(left) == 0 {
			time.Sleep(800 * time.Millisecond)
			return nil
		}
		for _, p := range left {
			_ = platform.Stop(p.PID, true)
		}
		time.Sleep(300 * time.Millisecond)
	}
	return userErr("Không đóng hẳn được Claude. Hãy tự thoát Claude (kể cả ở khay hệ thống) rồi thử lại. Chưa có gì bị thay đổi.")
}

// StartDesktop opens Claude Desktop. It returns false when it could not.
func (e *Env) StartDesktop() bool {
	if e.NoAppControl {
		return true
	}
	var cmd *exec.Cmd
	switch runtime.GOOS {
	case "windows":
		if id := e.desktopAppID(); id != "" {
			cmd = exec.Command("explorer.exe", `shell:AppsFolder\`+id)
		} else if exe := str(e.Settings(), "desktopExe"); exe != "" && platform.Exists(exe) {
			cmd = exec.Command(exe)
		} else if p := filepath.Join(os.Getenv("LOCALAPPDATA"), "AnthropicClaude", "claude.exe"); platform.Exists(p) {
			cmd = exec.Command(p)
		}
	case "darwin":
		cmd = exec.Command("open", "-a", "Claude")
	default:
		if p := platform.LookPath("claude-desktop"); p != "" {
			cmd = exec.Command(p)
		}
	}
	if cmd == nil {
		e.Logf("Không tìm thấy cách mở Claude Desktop.")
		return false
	}
	if runtime.GOOS != "windows" || filepath.Base(cmd.Path) == "explorer.exe" {
		platform.Hide(cmd)
	}
	if err := cmd.Start(); err != nil {
		e.Logf("Mở Claude thất bại.")
		return false
	}
	go cmd.Wait()
	return true
}

func waitUntil(d time.Duration, ok func() bool) bool {
	end := time.Now().Add(d)
	for time.Now().Before(end) {
		if ok() {
			return true
		}
		time.Sleep(300 * time.Millisecond)
	}
	return ok()
}
