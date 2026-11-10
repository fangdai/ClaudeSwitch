// Package platform hides the operating-system specific parts: process lists, closing
// apps, opening terminals and opening the UI window.
package platform

import (
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strings"
)

// Proc is a running process. Path is empty when the OS does not allow reading it.
type Proc struct {
	PID  int
	Name string
	Path string
}

// Processes lists running processes whose executable base name matches one of names
// (case-insensitive, without .exe). An empty names list returns every process.
func Processes(names ...string) []Proc {
	want := map[string]bool{}
	for _, n := range names {
		want[strings.ToLower(strings.TrimSuffix(n, ".exe"))] = true
	}
	var out []Proc
	for _, p := range listProcesses() {
		base := strings.ToLower(strings.TrimSuffix(p.Name, ".exe"))
		if len(want) == 0 || want[base] {
			if p.Path == "" {
				p.Path = processPath(p.PID)
			}
			out = append(out, p)
		}
	}
	return out
}

// LookPath finds an executable on PATH, returning "" when missing.
func LookPath(name string) string {
	p, err := exec.LookPath(name)
	if err != nil {
		return ""
	}
	if abs, err := filepath.Abs(p); err == nil {
		return abs
	}
	return p
}

// Exists reports whether a file or directory exists.
func Exists(path string) bool {
	if path == "" {
		return false
	}
	_, err := os.Stat(path)
	return err == nil
}

// Home returns the user's home directory.
func Home() string {
	h, err := os.UserHomeDir()
	if err != nil {
		return "."
	}
	return h
}

// IsWindows/IsMac/IsLinux are small readability helpers.
func IsWindows() bool { return runtime.GOOS == "windows" }
func IsMac() bool     { return runtime.GOOS == "darwin" }
func IsLinux() bool   { return runtime.GOOS == "linux" }

// shellQuote quotes a string for POSIX sh.
func shellQuote(s string) string {
	return "'" + strings.ReplaceAll(s, "'", `'"'"'`) + "'"
}

// ShellCommand builds a POSIX shell command line with environment assignments.
func ShellCommand(env map[string]string, argv []string) string {
	var b strings.Builder
	for k, v := range env {
		b.WriteString(k + "=" + shellQuote(v) + " ")
	}
	for i, a := range argv {
		if i > 0 {
			b.WriteByte(' ')
		}
		b.WriteString(shellQuote(a))
	}
	return b.String()
}

// AppBrowsers lists Chromium-based browsers that support --app windows, best first.
func AppBrowsers() []string {
	var c []string
	switch runtime.GOOS {
	case "windows":
		for _, base := range []string{os.Getenv("ProgramFiles(x86)"), os.Getenv("ProgramFiles"), os.Getenv("LOCALAPPDATA")} {
			if base == "" {
				continue
			}
			c = append(c,
				filepath.Join(base, `Microsoft\Edge\Application\msedge.exe`),
				filepath.Join(base, `Google\Chrome\Application\chrome.exe`),
				filepath.Join(base, `BraveSoftware\Brave-Browser\Application\brave.exe`))
		}
	case "darwin":
		for _, app := range []string{"Google Chrome", "Microsoft Edge", "Chromium", "Brave Browser"} {
			for _, root := range []string{"/Applications", filepath.Join(Home(), "Applications")} {
				c = append(c, filepath.Join(root, app+".app", "Contents", "MacOS", app))
			}
		}
	default:
		for _, n := range []string{"google-chrome", "google-chrome-stable", "chromium", "chromium-browser", "microsoft-edge", "microsoft-edge-stable", "brave-browser"} {
			if p := LookPath(n); p != "" {
				c = append(c, p)
			}
		}
	}
	var out []string
	for _, p := range c {
		if Exists(p) {
			out = append(out, p)
		}
	}
	return out
}

// OpenURL opens a URL with the system default handler.
func OpenURL(url string) error {
	var cmd *exec.Cmd
	switch runtime.GOOS {
	case "windows":
		cmd = exec.Command("rundll32", "url.dll,FileProtocolHandler", url)
	case "darwin":
		cmd = exec.Command("open", url)
	default:
		cmd = exec.Command("xdg-open", url)
	}
	Hide(cmd)
	return cmd.Start()
}
