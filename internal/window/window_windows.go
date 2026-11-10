//go:build windows

package window

import (
	"syscall"
	"unsafe"

	webview2 "github.com/jchv/go-webview2"
	"github.com/jchv/go-webview2/webviewloader"
	"golang.org/x/sys/windows/registry"
)

var (
	user32                 = syscall.NewLazyDLL("user32.dll")
	shell32                = syscall.NewLazyDLL("shell32.dll")
	procSetDpiAwareContext = user32.NewProc("SetProcessDpiAwarenessContext")
	procSetDPIAware        = user32.NewProc("SetProcessDPIAware")
	procGetDpiForSystem    = user32.NewProc("GetDpiForSystem")
	procSendMessage        = user32.NewProc("SendMessageW")
	procShowWindow         = user32.NewProc("ShowWindow")
	procIsIconic           = user32.NewProc("IsIconic")
	procSetForeground      = user32.NewProc("SetForegroundWindow")
	procExtractIconEx      = shell32.NewProc("ExtractIconExW")
	procDwmSetAttribute    = syscall.NewLazyDLL("dwmapi.dll").NewProc("DwmSetWindowAttribute")
)

// darkTitleBar matches the title bar to the Windows app theme (the page follows it too).
func darkTitleBar(hwnd uintptr) {
	k, err := registry.OpenKey(registry.CURRENT_USER, `Software\Microsoft\Windows\CurrentVersion\Themes\Personalize`, registry.QUERY_VALUE)
	if err != nil {
		return
	}
	defer k.Close()
	if v, _, err := k.GetIntegerValue("AppsUseLightTheme"); err != nil || v != 0 {
		return
	}
	on := int32(1)
	if procDwmSetAttribute.Find() == nil {
		procDwmSetAttribute.Call(hwnd, 20, uintptr(unsafe.Pointer(&on)), 4) // DWMWA_USE_IMMERSIVE_DARK_MODE
	}
}

func available() bool {
	v, err := webviewloader.GetInstalledVersion()
	return err == nil && v != "" && v != "0.0.0.0"
}

func dpiScale() float64 {
	if procSetDpiAwareContext.Find() == nil {
		procSetDpiAwareContext.Call(^uintptr(3)) // DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2 (-4)
	} else if procSetDPIAware.Find() == nil {
		procSetDPIAware.Call()
	}
	if procGetDpiForSystem.Find() == nil {
		if d, _, _ := procGetDpiForSystem.Call(); d >= 96 {
			return float64(d) / 96
		}
	}
	return 1
}

func setIcon(hwnd uintptr) {
	path, _ := syscall.UTF16PtrFromString(`C:\Windows\System32\imageres.dll`)
	var large, small uintptr
	if n, _, _ := procExtractIconEx.Call(uintptr(unsafe.Pointer(path)), 109, uintptr(unsafe.Pointer(&large)), uintptr(unsafe.Pointer(&small)), 1); n == 0 {
		return
	}
	const wmSetIcon = 0x0080
	if large != 0 {
		procSendMessage.Call(hwnd, wmSetIcon, 1, large)
	}
	if small != 0 {
		procSendMessage.Call(hwnd, wmSetIcon, 0, small)
	}
}

func run(o Options) error {
	scale := dpiScale()
	w := webview2.NewWithOptions(webview2.WebViewOptions{
		DataPath:  o.DataDir,
		AutoFocus: true,
		WindowOptions: webview2.WindowOptions{
			Title:  o.Title,
			Width:  uint(float64(o.Width) * scale),
			Height: uint(float64(o.Height) * scale),
			Center: true,
		},
	})
	if w == nil {
		return ErrUnavailable
	}
	defer w.Destroy()
	hwnd := uintptr(w.Window())
	setIcon(hwnd)
	darkTitleBar(hwnd)
	w.SetSize(int(380*scale), int(520*scale), webview2.HintMin)
	setRaise(func() {
		w.Dispatch(func() {
			if r, _, _ := procIsIconic.Call(hwnd); r != 0 {
				procShowWindow.Call(hwnd, 9) // SW_RESTORE
			}
			procSetForeground.Call(hwnd)
		})
	})
	w.Navigate(o.URL)
	w.Run()
	return nil
}
