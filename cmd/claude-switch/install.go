package main

import (
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strings"

	"github.com/fangdai/ClaudeSwitch/internal/core"
	"github.com/fangdai/ClaudeSwitch/internal/platform"
)

func copySelf(dst string) error {
	src, err := os.Executable()
	if err != nil {
		return err
	}
	if a, b := filepath.Clean(src), filepath.Clean(dst); strings.EqualFold(a, b) {
		return nil
	}
	in, err := os.Open(src)
	if err != nil {
		return err
	}
	defer in.Close()
	if err := os.MkdirAll(filepath.Dir(dst), 0o755); err != nil {
		return err
	}
	tmp := dst + ".new"
	out, err := os.OpenFile(tmp, os.O_WRONLY|os.O_CREATE|os.O_TRUNC, 0o755)
	if err != nil {
		return err
	}
	if _, err := io.Copy(out, in); err != nil {
		out.Close()
		return err
	}
	out.Close()
	os.Remove(dst)
	return os.Rename(tmp, dst)
}

func installedExe() string {
	switch runtime.GOOS {
	case "windows":
		return filepath.Join(core.DefaultStoreDir(), "app", "claude-switch.exe")
	default:
		return filepath.Join(platform.Home(), ".local", "bin", "claude-switch")
	}
}

func psQuote(s string) string { return "'" + strings.ReplaceAll(s, "'", "''") + "'" }

func windowsShortcuts() []string {
	return []string{
		filepath.Join(platform.Home(), "Desktop", "Claude Switch.lnk"),
		filepath.Join(os.Getenv("APPDATA"), `Microsoft\Windows\Start Menu\Programs`, "Claude Switch.lnk"),
	}
}

const desktopEntry = `[Desktop Entry]
Type=Application
Name=Claude Switch
Comment=Chuyển account Claude Desktop và Claude Code CLI
Exec=%s
Icon=claude-switch
Terminal=false
Categories=Utility;
`

const iconSVG = `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 64 64"><rect width="64" height="64" rx="14" fill="#c96442"/><path d="M20 24h20l-5-5m9 21H24l5 5" fill="none" stroke="#fff" stroke-width="5" stroke-linecap="round" stroke-linejoin="round"/></svg>`

func install() error {
	exe := installedExe()
	if err := copySelf(exe); err != nil {
		return fmt.Errorf("không chép được ứng dụng: %w", err)
	}
	switch runtime.GOOS {
	case "windows":
		var script strings.Builder
		script.WriteString("$ws = New-Object -ComObject WScript.Shell;")
		for i, lnk := range windowsShortcuts() {
			os.MkdirAll(filepath.Dir(lnk), 0o755)
			script.WriteString(fmt.Sprintf("$s = $ws.CreateShortcut(%s); $s.TargetPath = %s; $s.WorkingDirectory = %s; $s.Description = 'Claude Switch'; $s.IconLocation = %s;",
				psQuote(lnk), psQuote(exe), psQuote(filepath.Dir(exe)), psQuote(filepath.Join(os.Getenv("SystemRoot"), `System32\imageres.dll`)+",109")))
			if i == 0 {
				script.WriteString("$s.Hotkey = 'CTRL+ALT+C';")
			}
			script.WriteString("$s.Save();")
		}
		cmd := exec.Command("powershell.exe", "-NoProfile", "-NonInteractive", "-Command", script.String())
		platform.Hide(cmd)
		if out, err := cmd.CombinedOutput(); err != nil {
			return fmt.Errorf("không tạo được shortcut: %s", strings.TrimSpace(string(out)))
		}
		fmt.Println("Đã cài Claude Switch:", exe)
		fmt.Println("Shortcut trên Desktop và Start Menu (phím tắt Ctrl+Alt+C).")
	case "linux":
		apps := filepath.Join(platform.Home(), ".local", "share", "applications")
		icons := filepath.Join(platform.Home(), ".local", "share", "icons", "hicolor", "scalable", "apps")
		os.MkdirAll(apps, 0o755)
		os.MkdirAll(icons, 0o755)
		if err := os.WriteFile(filepath.Join(icons, "claude-switch.svg"), []byte(iconSVG), 0o644); err != nil {
			return err
		}
		if err := os.WriteFile(filepath.Join(apps, "claude-switch.desktop"), []byte(fmt.Sprintf(desktopEntry, exe)), 0o755); err != nil {
			return err
		}
		fmt.Println("Đã cài Claude Switch:", exe)
		fmt.Println("Mở từ menu ứng dụng (Claude Switch) hoặc gõ: claude-switch")
	case "darwin":
		fmt.Println("Đã chép lệnh claude-switch vào", exe)
		fmt.Println("Ứng dụng có giao diện: kéo \"Claude Switch.app\" vào thư mục Applications.")
	}
	return nil
}

func uninstall(purge bool) error {
	switch runtime.GOOS {
	case "windows":
		for _, l := range windowsShortcuts() {
			os.Remove(l)
		}
	case "linux":
		os.Remove(filepath.Join(platform.Home(), ".local", "share", "applications", "claude-switch.desktop"))
		os.Remove(filepath.Join(platform.Home(), ".local", "share", "icons", "hicolor", "scalable", "apps", "claude-switch.svg"))
	}
	self, _ := os.Executable()
	if exe := installedExe(); !strings.EqualFold(filepath.Clean(self), filepath.Clean(exe)) {
		os.Remove(exe)
	} else {
		fmt.Println("Hãy tự xóa file đang chạy sau khi thoát:", exe)
	}
	if purge {
		if err := os.RemoveAll(core.DefaultStoreDir()); err != nil {
			return err
		}
		fmt.Println("Đã xóa toàn bộ dữ liệu và account đã lưu.")
	} else {
		fmt.Println("Đã gỡ shortcut. Account đã lưu vẫn nằm ở", core.DefaultStoreDir())
	}
	return nil
}
