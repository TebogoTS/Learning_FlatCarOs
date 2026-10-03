package main

import (
	"encoding/json"
	"flag"
	"fmt"
	"os"
	"path/filepath"
)

func main() {
	os.Exit(run(os.Args[1:], os.Stdout, os.Stderr))
}

func run(args []string, stdout, stderr *os.File) int {
	fs := flag.NewFlagSet("butanecheck", flag.ContinueOnError)
	fs.SetOutput(stderr)
	var (
		p        Policy
		asJSON   bool
		noRemote bool
	)
	fs.StringVar(&p.Variant, "variant", "flatcar", "required Butane variant (empty disables)")
	fs.StringVar(&p.Version, "version", "1.1.0", "required Butane spec version (empty disables)")
	fs.StringVar(&p.FilesDir, "files-dir", "", "base directory for local: resources (default: each file's directory)")
	fs.BoolVar(&noRemote, "no-remote-hash-check", false, "do not require verification.hash on remote sources")
	fs.BoolVar(&p.AllowPrivateKeys, "allow-private-keys", false, "allow private key material (lab configs only); such files must still be mode 0600 or tighter")
	fs.IntVar(&p.MaxIgnitionBytes, "max-size", 0, "maximum size in bytes of the transpiled Ignition JSON (0 disables)")
	fs.BoolVar(&asJSON, "json", false, "emit findings as JSON")
	if err := fs.Parse(args); err != nil {
		return 2
	}
	p.SkipRemoteHashCheck = noRemote
	files := fs.Args()
	if len(files) == 0 {
		fmt.Fprintln(stderr, "usage: butanecheck [flags] FILE.bu...")
		return 2
	}

	type fileResult struct {
		File     string    `json:"file"`
		Findings []Finding `json:"findings"`
	}
	var results []fileResult
	failed := false
	for _, f := range files {
		data, err := os.ReadFile(f)
		if err != nil {
			fmt.Fprintf(stderr, "butanecheck: %v\n", err)
			return 2
		}
		pol := p
		if pol.FilesDir == "" {
			pol.FilesDir = filepath.Dir(f)
		}
		findings, err := Check(f, data, pol)
		if err != nil {
			fmt.Fprintf(stderr, "butanecheck: %v\n", err)
			return 2
		}
		results = append(results, fileResult{File: f, Findings: findings})
		for _, fi := range findings {
			if fi.Severity == Error {
				failed = true
			}
		}
	}

	if asJSON {
		enc := json.NewEncoder(stdout)
		enc.SetIndent("", "  ")
		_ = enc.Encode(results)
	} else {
		for _, r := range results {
			if len(r.Findings) == 0 {
				fmt.Fprintf(stdout, "ok    %s\n", r.File)
				continue
			}
			for _, fi := range r.Findings {
				loc := fi.Path
				if loc != "" {
					loc = " " + loc
				}
				fmt.Fprintf(stdout, "%-5s %s [%s]%s: %s\n", fi.Severity, r.File, fi.Check, loc, fi.Message)
			}
		}
	}
	if failed {
		return 1
	}
	return 0
}
