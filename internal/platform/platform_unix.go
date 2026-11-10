//go:build !windows

package platform

import (
	"errors"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strconv"
	"strings"
	"syscall"
)

func listProcesses() []Proc {
	if runtime.GOOS == "linux" {
		entries, _ := os.ReadDir("/proc")
		var out []Proc
		for _, e := range entries {
			pid, err := strconv.Atoi(e.Name())
			if err != nil {
				continue
			}
			path, _ := os.Readlink(filepath.Join("/proc", e.Name(), "exe"))
			name := filepath.Base(path)
			if path == "" {
				if b, err := os.ReadFile(filepath.Join("/proc", e.Name(), "comm")); err == nil {
					name = strings.TrimSpace(string(b))
				}
			}
			out = append(out, Proc{PID: pid, Name: name, Path: path})
		}
		return out
	}
	// macOS: comm is the full executable path.
	b, err := exec.Command("ps", "-axww", "-o", "pid=,comm=").Output()
	if err != nil {
		return nil
	}
	var out []Proc
	for _, line := range strings.Split(string(b), "\n") {
		line = strings.TrimSpace(line)
		i := strings.IndexByte(line, ' ')
		if i < 0 {
			continue
		}
		pid, err := strconv.Atoi(line[:i])
		if err != nil {
			continue
		}
		path := strings.TrimSpace(line[i+1:])
		out = append(out, Proc{PID: pid, Name: filepath.Base(path), Path: path})
	}
	return out
}

func processPath(pid int) string { return "" }

// Stop sends SIGTERM (or SIGKILL when force is set).
func Stop(pid int, force bool) error {
	sig := syscall.SIGTERM
	if force {
		sig = syscall.SIGKILL
	}
	return syscall.Kill(pid, sig)
}

// Hide is a no-op outside Windows.
func Hide(cmd *exec.Cmd) {}

// AttachParentConsole is a no-op outside Windows.
func AttachParentConsole() {}

// AllowForeground is a no-op outside Windows.
func AllowForeground(int) {}

// OpenTerminal runs argv in a new terminal window.
func OpenTerminal(title string, env map[string]string, dir string, argv []string, pauseOnFail bool) (*os.Process, error) {
	script := "cd " + shellQuote(dir) + " && " + ShellCommand(env, argv)
	if pauseOnFail {
		script += ` || { echo; echo "Chua xong. Nhan Enter de dong cua so."; read _; }`
	}
	if runtime.GOOS == "darwin" {
		as := strings.ReplaceAll(strings.ReplaceAll(script+"; exit", `\`, `\\`), `"`, `\"`)
		cmd := exec.Command("osascript",
			"-e", `tell application "Terminal" to do script "`+as+`"`,
			"-e", `tell application "Terminal" to activate`)
		return nil, cmd.Run()
	}
	candidates := [][]string{
		{"x-terminal-emulator", "-T", title, "-e", "sh", "-c", script},
		{"gnome-terminal", "--title", title, "--", "sh", "-c", script},
		{"konsole", "-p", "tabtitle=" + title, "-e", "sh", "-c", script},
		{"xfce4-terminal", "-T", title, "-x", "sh", "-c", script},
		{"kitty", "-T", title, "sh", "-c", script},
		{"alacritty", "-t", title, "-e", "sh", "-c", script},
		{"xterm", "-T", title, "-e", "sh", "-c", script},
	}
	for _, c := range candidates {
		if LookPath(c[0]) == "" {
			continue
		}
		cmd := exec.Command(c[0], c[1:]...)
		if err := cmd.Start(); err == nil {
			go cmd.Wait()
			return nil, nil
		}
	}
	return nil, errors.New("không tìm thấy chương trình terminal nào (x-terminal-emulator, gnome-terminal, konsole, xterm…)")
}
