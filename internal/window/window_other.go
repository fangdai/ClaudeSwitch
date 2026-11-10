//go:build !windows && !(darwin && cgo)

package window

func available() bool { return false }

func run(Options) error { return ErrUnavailable }
