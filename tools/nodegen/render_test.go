package main

import (
	"crypto/sha256"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func testRenderer(t *testing.T) *Renderer {
	t.Helper()
	inv, err := LoadInventory("testdata/inventory.yaml")
	if err != nil {
		t.Fatal(err)
	}
	return &Renderer{
		Inventory: inv,
		BaseDir:   "testdata",
		Templates: map[string]string{
			"server": "testdata/server.bu.tmpl",
			"worker": "testdata/worker.bu.tmpl",
		},
	}
}

func nodeByName(t *testing.T, r *Renderer, name string) Node {
	t.Helper()
	for _, n := range r.Inventory.Nodes {
		if n.Name == name {
			return n
		}
	}
	t.Fatalf("no node %s", name)
	return Node{}
}

func TestRenderNodeVariableMergeOrder(t *testing.T) {
	r := testRenderer(t)
	// inventory var applies when the node does not override it
	// (node-1 has no flavor of its own); node vars beat inventory vars;
	// command-line overrides beat both.
	tests := []struct {
		name      string
		node      string
		overrides map[string]any
		want      string
	}{
		{"inventory default", "node-1", nil, "flavor=base"},
		{"node overrides inventory", "node-0", nil, "flavor=worker-override"},
		{"cli overrides node", "node-0", map[string]any{"flavor": "cli"}, "flavor=cli"},
	}
	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			r.Overrides = tc.overrides
			out, err := r.RenderNode(nodeByName(t, r, tc.node))
			if err != nil {
				t.Fatal(err)
			}
			if !strings.Contains(string(out), tc.want) {
				t.Fatalf("output missing %q:\n%s", tc.want, out)
			}
		})
	}
}

func TestRenderNodeHelpers(t *testing.T) {
	r := testRenderer(t)
	out, err := r.RenderNode(nodeByName(t, r, "node-0"))
	if err != nil {
		t.Fatal(err)
	}
	s := string(out)
	sum := fmt.Sprintf("%x", sha256.Sum256([]byte("hello payload\n")))
	for _, want := range []string{
		"node-0.lab.test",    // FQDN
		"servers=10.77.0.10", // NodesByRole
		sum,                  // sha256file
		"pod_cidr=10.200.0.0/24",
	} {
		if !strings.Contains(s, want) {
			t.Errorf("output missing %q:\n%s", want, s)
		}
	}
	srv, err := r.RenderNode(nodeByName(t, r, "server"))
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(string(srv), "node-0=10.77.0.20;node-1=10.77.0.21;") {
		t.Errorf("server output missing worker list:\n%s", srv)
	}
}

func TestRenderMissingVariableFails(t *testing.T) {
	r := testRenderer(t)
	// server template does not use pod_cidr, but a worker without it must fail loudly.
	inv := *r.Inventory
	inv.Nodes = append([]Node(nil), r.Inventory.Nodes...)
	inv.Nodes[1].Vars = map[string]any{} // node-0 loses pod_cidr
	r.Inventory = &inv
	_, err := r.RenderNode(inv.Nodes[1])
	if err == nil {
		t.Fatal("expected error for missing pod_cidr")
	}
	if !strings.Contains(err.Error(), "node-0") {
		t.Errorf("error should name the node: %v", err)
	}
}

func TestFileHelperRejectsEscape(t *testing.T) {
	dir := t.TempDir()
	base := filepath.Join(dir, "base")
	if err := os.MkdirAll(base, 0o755); err != nil {
		t.Fatal(err)
	}
	secret := filepath.Join(dir, "secret.txt")
	if err := os.WriteFile(secret, []byte("top secret"), 0o600); err != nil {
		t.Fatal(err)
	}
	tpl := filepath.Join(dir, "t.tmpl")
	for _, name := range []string{"../secret.txt", secret} {
		if err := os.WriteFile(tpl, []byte(fmt.Sprintf(`{{ file %q }}`, name)), 0o600); err != nil {
			t.Fatal(err)
		}
		r := &Renderer{
			Inventory: &Inventory{Nodes: []Node{{Name: "a", Role: "x"}}},
			BaseDir:   base,
			Templates: map[string]string{"": tpl},
		}
		_, err := r.RenderNode(r.Inventory.Nodes[0])
		if err == nil || !strings.Contains(err.Error(), "outside base directory") {
			t.Errorf("file %q: expected escape rejection, got %v", name, err)
		}
	}
}

func TestTemplateSelection(t *testing.T) {
	r := testRenderer(t)
	delete(r.Templates, "worker")
	if _, err := r.RenderNode(nodeByName(t, r, "node-0")); err == nil || !strings.Contains(err.Error(), "no template for role") {
		t.Fatalf("expected missing-template error, got %v", err)
	}
	r.Templates[""] = "testdata/server.bu.tmpl"
	if _, err := r.RenderNode(nodeByName(t, r, "node-0")); err != nil {
		t.Fatalf("default template should apply: %v", err)
	}
}

func TestRenderAllTranspilesStrictly(t *testing.T) {
	r := testRenderer(t)
	outs, err := r.RenderAll("", true, "testdata")
	if err != nil {
		t.Fatal(err)
	}
	if len(outs) != 3 {
		t.Fatalf("got %d outputs", len(outs))
	}
	for _, o := range outs {
		if !strings.HasSuffix(string(o.Ignition), "}\n") {
			t.Errorf("%s: Ignition output should end with a single newline like the butane CLI", o.Node.Name)
		}
		if !strings.Contains(string(o.Ignition), `"version": "3.4.0"`) {
			t.Errorf("%s: Ignition is not spec 3.4.0:\n%s", o.Node.Name, o.Ignition)
		}
	}
	dir := t.TempDir()
	if err := WriteOutputs(dir, outs); err != nil {
		t.Fatal(err)
	}
	st, err := os.Stat(filepath.Join(dir, "server.ign"))
	if err != nil {
		t.Fatal(err)
	}
	if st.Mode().Perm() != 0o600 {
		t.Errorf("output mode %v, want 0600 because configs may hold secrets", st.Mode().Perm())
	}
}

func TestRenderAllOnly(t *testing.T) {
	r := testRenderer(t)
	outs, err := r.RenderAll("node-1", false, "testdata")
	if err != nil || len(outs) != 1 || outs[0].Node.Name != "node-1" {
		t.Fatalf("only filter failed: %v %v", outs, err)
	}
	if _, err := r.RenderAll("nope", false, "testdata"); err == nil {
		t.Fatal("expected error for unknown node")
	}
}

func TestRenderAllStrictTranspileFailureNamesNode(t *testing.T) {
	dir := t.TempDir()
	tpl := filepath.Join(dir, "bad.tmpl")
	// misspelled key => Butane warning => strict failure
	if err := os.WriteFile(tpl, []byte("variant: flatcar\nversion: 1.1.0\nstorage:\n  files:\n    - path: /etc/x\n      contnts:\n        inline: a\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	r := &Renderer{
		Inventory: &Inventory{Nodes: []Node{{Name: "n1", Role: "r"}}},
		BaseDir:   dir,
		Templates: map[string]string{"": tpl},
	}
	_, err := r.RenderAll("", true, dir)
	if err == nil || !strings.Contains(err.Error(), `node "n1"`) {
		t.Fatalf("expected strict failure naming node, got %v", err)
	}
}

func TestParseInventoryValidation(t *testing.T) {
	tests := []struct {
		name    string
		yaml    string
		wantErr string
	}{
		{"valid", "nodes:\n  - {name: a, role: r, ip: 10.0.0.1, mac: '52:54:00:00:00:01'}\n", ""},
		{"no nodes", "cluster: {name: x}\n", "no nodes"},
		{"missing name", "nodes:\n  - {role: r}\n", "no name"},
		{"missing role", "nodes:\n  - {name: a}\n", "no role"},
		{"duplicate name", "nodes:\n  - {name: a, role: r}\n  - {name: a, role: r}\n", "duplicate node name"},
		{"bad ip", "nodes:\n  - {name: a, role: r, ip: 10.0.0.999}\n", "invalid ip"},
		{"duplicate ip", "nodes:\n  - {name: a, role: r, ip: 10.0.0.1}\n  - {name: b, role: r, ip: 10.0.0.1}\n", "share ip"},
		{"bad mac", "nodes:\n  - {name: a, role: r, mac: zz}\n", "invalid mac"},
		{"duplicate mac case-insensitive", "nodes:\n  - {name: a, role: r, mac: 'AA:bb:cc:dd:ee:ff'}\n  - {name: b, role: r, mac: 'aa:BB:cc:dd:ee:ff'}\n", "share mac"},
		{"unknown key rejected", "nodes:\n  - {name: a, role: r, rol: typo}\n", "rol"},
	}
	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			_, err := ParseInventory([]byte(tc.yaml))
			if tc.wantErr == "" {
				if err != nil {
					t.Fatalf("unexpected error: %v", err)
				}
				return
			}
			if err == nil || !strings.Contains(err.Error(), tc.wantErr) {
				t.Fatalf("error %v does not contain %q", err, tc.wantErr)
			}
		})
	}
}

func TestIndentHelper(t *testing.T) {
	r := &Renderer{BaseDir: "."}
	f := r.funcs()["indent"].(func(int, string) string)
	got := f(4, "a\n\nb\n")
	if got != "    a\n\n    b" {
		t.Fatalf("indent produced %q", got)
	}
}

func TestPartialsProvideDefinesToMainTemplate(t *testing.T) {
	dir := t.TempDir()
	main := filepath.Join(dir, "main.tmpl")
	part := filepath.Join(dir, "part.tmpl")
	os.WriteFile(main, []byte(`host={{ .Node.Name }} {{ template "greet" . }}`), 0o600)
	os.WriteFile(part, []byte(`IGNORED TOP LEVEL{{ define "greet" }}hello-{{ .Node.Role }}{{ end }}`), 0o600)
	r := testRenderer(t)
	r.Templates = map[string]string{"": main}
	r.Partials = []string{part}
	out, err := r.RenderNode(nodeByName(t, r, "node-0"))
	if err != nil {
		t.Fatal(err)
	}
	if got, want := string(out), "host=node-0 hello-worker"; got != want {
		t.Fatalf("got %q want %q", got, want)
	}
	r.Partials = []string{filepath.Join(dir, "missing.tmpl")}
	if _, err := r.RenderNode(nodeByName(t, r, "node-0")); err == nil {
		t.Fatal("missing partial must fail")
	}
	// A template that calls an undefined partial must fail rather than render empty.
	r.Partials = nil
	if _, err := r.RenderNode(nodeByName(t, r, "node-0")); err == nil {
		t.Fatal("undefined template call must fail")
	}
}
