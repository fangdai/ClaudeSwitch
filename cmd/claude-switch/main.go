// Command claude-switch switches Claude Desktop and Claude Code CLI accounts.
//
// Without arguments it opens the window. Subcommands:
//
//	status               print the state as JSON
//	switch <account>     switch Claude Desktop (name, e-mail or id)
//	cli-switch <account> switch Claude Code CLI
//	usage [--force]      refresh and print usage
//	install | uninstall  create or remove shortcuts
//	version
package main

import (
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"time"

	"github.com/fangdai/ClaudeSwitch/internal/core"
	"github.com/fangdai/ClaudeSwitch/internal/platform"
	"github.com/fangdai/ClaudeSwitch/internal/web"
)

var version = "dev"

func main() {
	args := os.Args[1:]
	if len(args) > 0 {
		platform.AttachParentConsole()
	}
	cmd := ""
	if len(args) > 0 {
		cmd = args[0]
	}
	var err error
	switch cmd {
	case "", "ui":
		err = runUI(false)
	case "serve":
		err = runUI(true)
	case "status":
		err = printJSON(core.NewEnv().Status())
	case "switch", "cli-switch":
		err = runSwitch(cmd, args[1:])
	case "usage":
		force := len(args) > 1 && args[1] == "--force"
		err = printJSON(core.NewEnv().RefreshUsage(force))
	case "install":
		err = install()
	case "uninstall":
		err = uninstall(len(args) > 1 && args[1] == "--purge")
	case "version", "--version", "-v":
		fmt.Println("claude-switch", version)
	case "help", "--help", "-h":
		fmt.Print(usage)
	default:
		fmt.Fprintf(os.Stderr, "Lệnh không hợp lệ: %s\n\n%s", cmd, usage)
		os.Exit(2)
	}
	if err != nil {
		fmt.Fprintln(os.Stderr, "Lỗi:", err)
		os.Exit(1)
	}
}

const usage = `Claude Switch - chuyển account Claude Desktop và Claude Code CLI

Cách dùng:
  claude-switch                     mở cửa sổ ứng dụng
  claude-switch status              in trạng thái (JSON)
  claude-switch switch <account>    chuyển Claude Desktop (tên, email hoặc mã)
  claude-switch cli-switch <account> chuyển Claude Code CLI
  claude-switch usage [--force]     cập nhật và in usage
  claude-switch install             tạo shortcut / mục trong menu ứng dụng
  claude-switch uninstall [--purge] gỡ shortcut (--purge xóa cả account đã lưu)
  claude-switch serve               chạy giao diện, chỉ in địa chỉ (không mở cửa sổ)
  claude-switch version
`

func printJSON(v any) error {
	enc := json.NewEncoder(os.Stdout)
	enc.SetIndent("", "  ")
	return enc.Encode(v)
}

func runSwitch(cmd string, args []string) error {
	if len(args) == 0 {
		return fmt.Errorf("thiếu tên account")
	}
	env := core.NewEnv()
	q := strings.Join(args, " ")
	if cmd == "cli-switch" {
		id, err := core.FindAccount(env.CliStatus().Profiles, q)
		if err != nil {
			return err
		}
		msg, err := env.SwitchCli(id, false)
		if err == nil {
			fmt.Println(msg)
		}
		return err
	}
	id, err := core.FindAccount(env.DesktopState().Profiles, q)
	if err != nil {
		return err
	}
	_, err = env.SwitchDesktop(id, func(step, state, msg string) { fmt.Printf("[%s] %s\n", state, msg) })
	return err
}

// ---- window ---------------------------------------------------------------------------

type instance struct {
	URL   string `json:"url"`
	Token string `json:"token"`
	PID   int    `json:"pid"`
}

func instancePath(store string) string { return filepath.Join(store, "run", "ui.json") }

func liveInstance(store string) *instance {
	b, err := os.ReadFile(instancePath(store))
	if err != nil {
		return nil
	}
	var in instance
	if json.Unmarshal(b, &in) != nil || in.URL == "" {
		return nil
	}
	req, _ := http.NewRequest("GET", in.URL+"api/ping", nil)
	req.Header.Set("X-CS-Token", in.Token)
	c := &http.Client{Timeout: 800 * time.Millisecond}
	resp, err := c.Do(req)
	if err != nil {
		return nil
	}
	resp.Body.Close()
	if resp.StatusCode != 200 {
		return nil
	}
	return &in
}

// openWindow shows the UI in a Chromium "app" window (no tabs or address bar), falling
// back to the default browser. It returns the browser process when it owns one.
func openWindow(url, store string) *os.Process {
	for _, b := range platform.AppBrowsers() {
		cmd := exec.Command(b,
			"--app="+url,
			"--user-data-dir="+filepath.Join(store, "ui-browser"),
			"--window-size=500,820",
			"--no-first-run", "--no-default-browser-check", "--disable-features=Translate",
		)
		if err := cmd.Start(); err == nil {
			return cmd.Process
		}
	}
	_ = platform.OpenURL(url)
	return nil
}

func runUI(noWindow bool) error {
	env := core.NewEnv()
	if err := os.MkdirAll(filepath.Join(env.StoreDir, "run"), 0o700); err != nil {
		return err
	}
	if in := liveInstance(env.StoreDir); in != nil && !noWindow {
		openWindow(in.URL+"#t="+in.Token, env.StoreDir)
		return nil
	}
	srv, ln, err := web.New(env)
	if err != nil {
		return err
	}
	b, _ := json.Marshal(instance{URL: srv.URL, Token: srv.Token, PID: os.Getpid()})
	_ = os.WriteFile(instancePath(env.StoreDir), b, 0o600)
	defer os.Remove(instancePath(env.StoreDir))
	env.Logf("Claude Switch %s khởi động (%s).", version, srv.URL)

	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	done := make(chan error, 1)
	go func() { done <- srv.Serve(ctx, ln) }()

	full := srv.URL + "#t=" + srv.Token
	if noWindow {
		fmt.Println(full)
		return <-done
	}
	proc := openWindow(full, env.StoreDir)
	browserGone := make(chan struct{})
	if proc != nil {
		go func() { proc.Wait(); close(browserGone) }()
	}
	t := time.NewTicker(5 * time.Second)
	defer t.Stop()
	exited := false
	for {
		select {
		case err := <-done:
			return err
		case <-browserGone:
			exited, browserGone = true, nil
		case <-t.C:
		}
		idle := time.Since(srv.LastSeen())
		// The window polls every few seconds (slower while minimized).
		if (exited && idle > 20*time.Second) || idle > 6*time.Minute {
			cancel()
			return <-done
		}
	}
}
