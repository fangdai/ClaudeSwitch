// Package window shows the UI in a native application window using the WebView that
// ships with the operating system (WebView2 on Windows, WKWebView on macOS). Unlike a
// browser window it has no profile, extensions, sync or address bar.
package window

import (
	"errors"
	"runtime"
	"sync"
)

func init() {
	// GUI toolkits require the event loop on the main OS thread.
	runtime.LockOSThread()
}

// Options describes the window.
type Options struct {
	URL     string
	Title   string
	DataDir string // WebView cache / storage folder
	Width   int    // logical pixels
	Height  int
}

// ErrUnavailable means no native WebView exists on this machine or build.
var ErrUnavailable = errors.New("không có WebView hệ thống")

var (
	raiseMu sync.Mutex
	raiseFn func()
	closeFn func()
)

func setRaise(f func()) { setHooks(f, nil) }

func setHooks(raise, close func()) {
	raiseMu.Lock()
	raiseFn, closeFn = raise, close
	raiseMu.Unlock()
}

// Close closes the open window, which makes Run return. It reports false when no window
// is open.
func Close() bool {
	raiseMu.Lock()
	f := closeFn
	raiseMu.Unlock()
	if f == nil {
		return false
	}
	f()
	return true
}

// Raise brings the open window to the front. It reports false when no window is open.
func Raise() bool {
	raiseMu.Lock()
	f := raiseFn
	raiseMu.Unlock()
	if f == nil {
		return false
	}
	f()
	return true
}

// Available reports whether Run can show a native window.
func Available() bool { return available() }

// Run shows the window and blocks until the user closes it. It must be called from the
// main goroutine.
func Run(o Options) error {
	if !available() {
		return ErrUnavailable
	}
	defer setRaise(nil)
	return run(o)
}
