//go:build windows

package platform

import (
	"fmt"
	"os"
	"os/exec"
	"strings"
	"syscall"
	"unsafe"
)

var (
	kernel32                       = syscall.NewLazyDLL("kernel32.dll")
	procQueryFullProcessImageNameW = kernel32.NewProc("QueryFullProcessImageNameW")
	procAttachConsole              = kernel32.NewProc("AttachConsole")
)

const (
	processQueryLimitedInformation = 0x1000
	createNoWindow                 = 0x08000000
	createNewConsole               = 0x00000010
)

func listProcesses() []Proc {
	snap, err := syscall.CreateToolhelp32Snapshot(syscall.TH32CS_SNAPPROCESS, 0)
	if err != nil {
		return nil
	}
	defer syscall.CloseHandle(snap)
	var e syscall.ProcessEntry32
	e.Size = uint32(unsafe.Sizeof(e))
	var out []Proc
	for err = syscall.Process32First(snap, &e); err == nil; err = syscall.Process32Next(snap, &e) {
		out = append(out, Proc{PID: int(e.ProcessID), Name: syscall.UTF16ToString(e.ExeFile[:])})
	}
	return out
}

func processPath(pid int) string {
	h, err := syscall.OpenProcess(processQueryLimitedInformation, false, uint32(pid))
	if err != nil {
		return ""
	}
	defer syscall.CloseHandle(h)
	buf := make([]uint16, 1024)
	size := uint32(len(buf))
	r, _, _ := procQueryFullProcessImageNameW.Call(uintptr(h), 0, uintptr(unsafe.Pointer(&buf[0])), uintptr(unsafe.Pointer(&size)))
	if r == 0 {
		return ""
	}
	return syscall.UTF16ToString(buf[:size])
}

// Stop asks a process tree to close (force=false sends WM_CLOSE) or kills it.
func Stop(pid int, force bool) error {
	args := []string{"/PID", fmt.Sprint(pid), "/T"}
	if force {
		args = append(args, "/F")
	}
	cmd := exec.Command("taskkill", args...)
	Hide(cmd)
	return cmd.Run()
}

// Hide keeps helper commands from flashing a console window.
func Hide(cmd *exec.Cmd) {
	cmd.SysProcAttr = &syscall.SysProcAttr{HideWindow: true, CreationFlags: createNoWindow}
}

// AttachParentConsole lets the GUI-subsystem binary print when started from a terminal.
func AttachParentConsole() {
	const attachParentProcess = ^uint32(0)
	r, _, _ := procAttachConsole.Call(uintptr(attachParentProcess))
	if r == 0 {
		return
	}
	if f, err := os.OpenFile("CONOUT$", os.O_WRONLY, 0); err == nil {
		os.Stdout = f
		os.Stderr = f
	}
}

func cmdQuote(s string) string {
	return `"` + strings.ReplaceAll(s, `"`, `""`) + `"`
}

// OpenTerminal runs argv in a new console window. When pauseOnFail is set the window
// stays open after a failure so the user can read the message.
func OpenTerminal(title string, env map[string]string, dir string, argv []string, pauseOnFail bool) (*os.Process, error) {
	parts := make([]string, len(argv))
	for i, a := range argv {
		parts[i] = cmdQuote(a)
	}
	line := "title " + title + " & " + strings.Join(parts, " ")
	if pauseOnFail {
		line += ` || (echo. & echo Chua xong. Nhan phim bat ky de dong cua so. & pause >nul)`
	}
	cmd := exec.Command("cmd.exe")
	cmd.SysProcAttr = &syscall.SysProcAttr{CmdLine: `cmd.exe /d /c "` + line + `"`, CreationFlags: createNewConsole}
	cmd.Dir = dir
	cmd.Env = os.Environ()
	for k, v := range env {
		cmd.Env = append(cmd.Env, k+"="+v)
	}
	if err := cmd.Start(); err != nil {
		return nil, err
	}
	return cmd.Process, nil
}
