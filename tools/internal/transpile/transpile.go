// Package transpile wraps the Butane library so every tool in this repository
// converts Butane to Ignition through the same code path, with the same strictness
// as `butane --strict`.
package transpile

import (
	"errors"
	"fmt"

	"github.com/coreos/butane/config"
	"github.com/coreos/butane/config/common"
	"github.com/coreos/vcontext/report"
)

// Result is the outcome of a transpilation.
type Result struct {
	Ignition []byte
	Report   report.Report
}

// ErrWarnings is returned in strict mode when the transpiler produced any report
// entry (warning or error-level), mirroring `butane --strict`.
var ErrWarnings = errors.New("transpile produced warnings and strict mode is enabled")

// Options controls a transpilation.
type Options struct {
	// FilesDir is the base directory for `local:` resources. Empty disables them.
	FilesDir string
	// Strict fails on any report entry, like `butane --strict`.
	Strict bool
	// Pretty indents the Ignition JSON.
	Pretty bool
}

// Bytes converts a Butane config to an Ignition config.
func Bytes(butane []byte, opts Options) (Result, error) {
	out, rep, err := config.TranslateBytes(butane, common.TranslateBytesOptions{
		TranslateOptions: common.TranslateOptions{FilesDir: opts.FilesDir},
		Pretty:           opts.Pretty,
	})
	res := Result{Ignition: out, Report: rep}
	if err != nil {
		return res, fmt.Errorf("butane: %w\n%s", err, rep.String())
	}
	if rep.IsFatal() {
		return res, fmt.Errorf("butane: fatal report:\n%s", rep.String())
	}
	if opts.Strict && len(rep.Entries) > 0 {
		return res, fmt.Errorf("%w:\n%s", ErrWarnings, rep.String())
	}
	return res, nil
}
