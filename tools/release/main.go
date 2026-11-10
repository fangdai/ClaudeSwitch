// Command release cross-compiles Claude Switch and packages it for every platform:
//
//	go run ./tools/release [-version v1.2.3] [-out dist]
//
// Output: one .zip (Windows, macOS .app) or .tar.gz (Linux) per OS/architecture.
package main

import (
	"archive/tar"
	"archive/zip"
	"compress/gzip"
	"crypto/sha256"
	"encoding/hex"
	"flag"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"time"
)

type target struct{ goos, goarch, name string }

var targets = []target{
	{"windows", "amd64", "windows-x64"},
	{"windows", "arm64", "windows-arm64"},
	{"darwin", "arm64", "macos-apple-silicon"},
	{"darwin", "amd64", "macos-intel"},
	{"linux", "amd64", "linux-x64"},
	{"linux", "arm64", "linux-arm64"},
}

type entry struct {
	name string
	data []byte
	mode os.FileMode
}

func main() {
	version := flag.String("version", "", "version (default: git describe)")
	out := flag.String("out", "dist", "output folder")
	flag.Parse()
	if *version == "" {
		*version = gitVersion()
	}
	must(os.RemoveAll(*out))
	must(os.MkdirAll(*out, 0o755))
	readme, err := os.ReadFile("README.md")
	must(err)
	var sums []string
	for _, t := range targets {
		bin := buildBinary(t, *version, *out)
		var files []entry
		var archive string
		switch t.goos {
		case "windows":
			files = []entry{
				{"Claude Switch/claude-switch.exe", bin, 0o755},
				{"Claude Switch/Cai dat.cmd", []byte(installCmd), 0o644},
				{"Claude Switch/README.md", readme, 0o644},
			}
			archive = fmt.Sprintf("ClaudeSwitch-%s-%s.zip", *version, t.name)
			writeZip(filepath.Join(*out, archive), files)
		case "darwin":
			app := "Claude Switch.app/Contents/"
			files = []entry{
				{app + "Info.plist", []byte(fmt.Sprintf(infoPlist, *version, *version)), 0o644},
				{app + "MacOS/claude-switch", bin, 0o755},
				{"README.md", readme, 0o644},
			}
			archive = fmt.Sprintf("ClaudeSwitch-%s-%s.zip", *version, t.name)
			writeZip(filepath.Join(*out, archive), files)
		default:
			files = []entry{
				{"claude-switch/claude-switch", bin, 0o755},
				{"claude-switch/install.sh", []byte(installSh), 0o755},
				{"claude-switch/README.md", readme, 0o644},
			}
			archive = fmt.Sprintf("ClaudeSwitch-%s-%s.tar.gz", *version, t.name)
			writeTarGz(filepath.Join(*out, archive), files)
		}
		sums = append(sums, sha256File(filepath.Join(*out, archive))+"  "+archive)
		fmt.Printf("  %-46s %5.1f MB\n", archive, float64(size(filepath.Join(*out, archive)))/1e6)
	}
	must(os.WriteFile(filepath.Join(*out, "SHA256SUMS.txt"), []byte(strings.Join(sums, "\n")+"\n"), 0o644))
	must(os.RemoveAll(filepath.Join(*out, "bin")))
	fmt.Println("Xong:", *out)
}

func gitVersion() string {
	b, err := exec.Command("git", "describe", "--tags", "--always", "--dirty").Output()
	if err != nil {
		return time.Now().Format("2006.01.02")
	}
	return strings.TrimSpace(string(b))
}

func buildBinary(t target, version, out string) []byte {
	exe := filepath.Join(out, "bin", t.name, "claude-switch")
	ldflags := "-s -w -X main.version=" + version
	if t.goos == "windows" {
		exe += ".exe"
		ldflags += " -H windowsgui"
	}
	cmd := exec.Command("go", "build", "-trimpath", "-ldflags", ldflags, "-o", exe, "./cmd/claude-switch")
	cmd.Env = append(os.Environ(), "GOOS="+t.goos, "GOARCH="+t.goarch, "CGO_ENABLED=0")
	cmd.Stdout, cmd.Stderr = os.Stdout, os.Stderr
	must(cmd.Run())
	b, err := os.ReadFile(exe)
	must(err)
	return b
}

func writeZip(path string, files []entry) {
	f, err := os.Create(path)
	must(err)
	defer f.Close()
	z := zip.NewWriter(f)
	for _, e := range files {
		h := &zip.FileHeader{Name: e.name, Method: zip.Deflate, Modified: time.Now()}
		h.SetMode(e.mode)
		w, err := z.CreateHeader(h)
		must(err)
		_, err = w.Write(e.data)
		must(err)
	}
	must(z.Close())
}

func writeTarGz(path string, files []entry) {
	f, err := os.Create(path)
	must(err)
	defer f.Close()
	gz := gzip.NewWriter(f)
	tw := tar.NewWriter(gz)
	for _, e := range files {
		must(tw.WriteHeader(&tar.Header{Name: e.name, Mode: int64(e.mode), Size: int64(len(e.data)), ModTime: time.Now(), Typeflag: tar.TypeReg}))
		_, err := tw.Write(e.data)
		must(err)
	}
	must(tw.Close())
	must(gz.Close())
}

func sha256File(p string) string {
	f, err := os.Open(p)
	must(err)
	defer f.Close()
	h := sha256.New()
	_, err = io.Copy(h, f)
	must(err)
	return hex.EncodeToString(h.Sum(nil))
}

func size(p string) int64 {
	st, err := os.Stat(p)
	must(err)
	return st.Size()
}

func must(err error) {
	if err != nil {
		fmt.Fprintln(os.Stderr, "release:", err)
		os.Exit(1)
	}
}

const installCmd = "@echo off\r\nchcp 65001 >nul\r\n\"%~dp0claude-switch.exe\" install\r\nif errorlevel 1 (echo. & echo Cai dat khong thanh cong.) else (start \"\" \"%LOCALAPPDATA%\\ClaudeSwitch\\app\\claude-switch.exe\")\r\npause\r\n"

const installSh = `#!/bin/sh
set -e
cd "$(dirname "$0")"
./claude-switch install
case ":$PATH:" in
  *":$HOME/.local/bin:"*) ;;
  *) echo "Lưu ý: thêm ~/.local/bin vào PATH để gõ được lệnh claude-switch." ;;
esac
`

const infoPlist = `<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Claude Switch</string>
  <key>CFBundleDisplayName</key><string>Claude Switch</string>
  <key>CFBundleIdentifier</key><string>io.github.fangdai.claudeswitch</string>
  <key>CFBundleExecutable</key><string>claude-switch</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>%s</string>
  <key>CFBundleVersion</key><string>%s</string>
  <key>LSMinimumSystemVersion</key><string>11.0</string>
  <key>LSUIElement</key><false/>
  <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
`
