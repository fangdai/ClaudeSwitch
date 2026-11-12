//go:build darwin && cgo

package window

/*
#cgo CFLAGS: -x objective-c
#cgo LDFLAGS: -framework Cocoa
#import <Cocoa/Cocoa.h>

static void csRaise(void *win) {
	[NSApp activateIgnoringOtherApps:YES];
	if (win) {
		NSWindow *w = (__bridge NSWindow *)win;
		if ([w isMiniaturized]) [w deminiaturize:nil];
		[w makeKeyAndOrderFront:nil];
	}
}
*/
import "C"

import (
	"unsafe"

	webview "github.com/webview/webview_go"
)

func available() bool { return true }

func run(o Options) error {
	w := webview.New(false)
	if w == nil {
		return ErrUnavailable
	}
	defer w.Destroy()
	w.SetTitle(o.Title)
	w.SetSize(380, 520, webview.HintMin)
	w.SetSize(o.Width, o.Height, webview.HintNone)
	win := w.Window()
	setHooks(func() { w.Dispatch(func() { C.csRaise(unsafe.Pointer(win)) }) }, func() { w.Dispatch(w.Terminate) })
	w.Navigate(o.URL)
	w.Dispatch(func() { C.csRaise(unsafe.Pointer(win)) })
	w.Run()
	return nil
}
