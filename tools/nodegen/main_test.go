package main

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestRunEndToEnd(t *testing.T) {
	out := filepath.Join(t.TempDir(), "out")
	so, _ := os.Create(filepath.Join(t.TempDir(), "so"))
	se, _ := os.Create(filepath.Join(t.TempDir(), "se"))
	defer so.Close()
	defer se.Close()
	code := run([]string{
		"-inventory", "testdata/inventory.yaml",
		"-template", "server=testdata/server.bu.tmpl",
		"-template", "worker=testdata/worker.bu.tmpl",
		"-out", out,
		"-var", "flavor=from-cli",
		"-transpile",
	}, so, se)
	if code != 0 {
		b, _ := os.ReadFile(se.Name())
		t.Fatalf("exit %d: %s", code, b)
	}
	for _, n := range []string{"server", "node-0", "node-1"} {
		for _, ext := range []string{".bu", ".ign"} {
			if _, err := os.Stat(filepath.Join(out, n+ext)); err != nil {
				t.Errorf("missing %s%s: %v", n, ext, err)
			}
		}
	}
	b, _ := os.ReadFile(filepath.Join(out, "node-1.bu"))
	if !strings.Contains(string(b), "flavor=from-cli") {
		t.Errorf("-var override not applied:\n%s", b)
	}
}

func TestRunUsageErrors(t *testing.T) {
	so, _ := os.Create(filepath.Join(t.TempDir(), "so"))
	se, _ := os.Create(filepath.Join(t.TempDir(), "se"))
	defer so.Close()
	defer se.Close()
	if code := run(nil, so, se); code != 2 {
		t.Errorf("no args: exit %d, want 2", code)
	}
	args := []string{"-inventory", "testdata/inventory.yaml", "-template", "testdata/server.bu.tmpl", "-out", t.TempDir(), "-var", "novalue"}
	if code := run(args, so, se); code != 2 {
		t.Errorf("bad -var: exit %d, want 2", code)
	}
}

func TestRunList(t *testing.T) {
	so, _ := os.Create(filepath.Join(t.TempDir(), "so"))
	se, _ := os.Create(filepath.Join(t.TempDir(), "se"))
	defer so.Close()
	defer se.Close()
	if code := run([]string{"-inventory", "testdata/inventory.yaml", "-list"}, so, se); code != 0 {
		b, _ := os.ReadFile(se.Name())
		t.Fatalf("exit %d: %s", code, b)
	}
	b, _ := os.ReadFile(so.Name())
	lines := strings.Split(strings.TrimSpace(string(b)), "\n")
	if len(lines) != 3 {
		t.Fatalf("want 3 lines, got %q", b)
	}
	for _, l := range lines {
		if len(strings.Split(l, "\t")) != 4 {
			t.Errorf("line %q is not 4 tab-separated fields", l)
		}
	}
	if !strings.HasPrefix(lines[0], "server\tserver\t") {
		t.Errorf("first line %q", lines[0])
	}
}
