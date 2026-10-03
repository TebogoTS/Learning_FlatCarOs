package main

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func tempFiles(t *testing.T) (stdout, stderr *os.File, read func() (string, string)) {
	t.Helper()
	dir := t.TempDir()
	so, err := os.Create(filepath.Join(dir, "out"))
	if err != nil {
		t.Fatal(err)
	}
	se, err := os.Create(filepath.Join(dir, "err"))
	if err != nil {
		t.Fatal(err)
	}
	return so, se, func() (string, string) {
		a, _ := os.ReadFile(so.Name())
		b, _ := os.ReadFile(se.Name())
		return string(a), string(b)
	}
}

func writeBU(t *testing.T, body string) string {
	t.Helper()
	p := filepath.Join(t.TempDir(), "c.bu")
	if err := os.WriteFile(p, []byte(body), 0o644); err != nil {
		t.Fatal(err)
	}
	return p
}

func TestRunExitCodes(t *testing.T) {
	good := writeBU(t, "variant: flatcar\nversion: 1.1.0\n")
	bad := writeBU(t, "variant: flatcar\nversion: 1.0.0\n")

	tests := []struct {
		name     string
		args     []string
		wantCode int
		wantOut  string
	}{
		{"good file", []string{good}, 0, "ok"},
		{"bad version", []string{bad}, 1, "[pin]"},
		{"bad version but pin disabled", []string{"--version", "", bad}, 0, "ok"},
		{"no args", nil, 2, ""},
		{"missing file", []string{filepath.Join(t.TempDir(), "nope.bu")}, 2, ""},
		{"json output", []string{"--json", good}, 0, `"findings"`},
	}
	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			so, se, read := tempFiles(t)
			defer so.Close()
			defer se.Close()
			if got := run(tc.args, so, se); got != tc.wantCode {
				out, errOut := read()
				t.Fatalf("exit code %d, want %d\nstdout: %s\nstderr: %s", got, tc.wantCode, out, errOut)
			}
			out, _ := read()
			if !strings.Contains(out, tc.wantOut) {
				t.Fatalf("stdout %q does not contain %q", out, tc.wantOut)
			}
		})
	}
}
