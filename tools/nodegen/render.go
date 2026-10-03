package main

import (
	"bytes"
	"crypto/sha256"
	"encoding/base64"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"text/template"

	"github.com/tebogots/flatcar-deep-dive/tools/internal/transpile"
)

// Data is what a template sees.
type Data struct {
	Cluster Cluster
	// Vars is the merge of inventory vars, then node vars, then command-line overrides.
	Vars map[string]any
	// Node is the node being rendered.
	Node Node
	// Nodes lists every node in the inventory.
	Nodes []Node
}

// Servers returns the nodes with the given role. It is a method so templates
// can write {{ range .NodesByRole "worker" }}.
func (d Data) NodesByRole(role string) []Node {
	var out []Node
	for _, n := range d.Nodes {
		if n.Role == role {
			out = append(out, n)
		}
	}
	return out
}

// FQDN of the current node.
func (d Data) FQDN() string { return d.Node.FQDN(d.Cluster.Domain) }

// Renderer renders node configs.
type Renderer struct {
	Inventory *Inventory
	// BaseDir is the only directory template file helpers may read from.
	BaseDir string
	// Overrides are command-line variables, applied last.
	Overrides map[string]any
	// Templates maps role to template path. The empty role is the default.
	Templates map[string]string
	// Partials are extra template files whose {{ define }} blocks are available to every template.
	Partials []string
}

func mergeVars(layers ...map[string]any) map[string]any {
	out := map[string]any{}
	for _, l := range layers {
		for k, v := range l {
			out[k] = v
		}
	}
	return out
}

// resolve returns an absolute path under BaseDir, rejecting escapes.
func (r *Renderer) resolve(p string) (string, error) {
	base, err := filepath.Abs(r.BaseDir)
	if err != nil {
		return "", err
	}
	full := p
	if !filepath.IsAbs(p) {
		full = filepath.Join(base, p)
	}
	full = filepath.Clean(full)
	rel, err := filepath.Rel(base, full)
	if err != nil || rel == ".." || strings.HasPrefix(rel, ".."+string(filepath.Separator)) {
		return "", fmt.Errorf("path %q is outside base directory %q", p, r.BaseDir)
	}
	return full, nil
}

func (r *Renderer) funcs() template.FuncMap {
	readFile := func(p string) ([]byte, error) {
		full, err := r.resolve(p)
		if err != nil {
			return nil, err
		}
		return os.ReadFile(full)
	}
	return template.FuncMap{
		"file": func(p string) (string, error) {
			b, err := readFile(p)
			return string(b), err
		},
		"b64file": func(p string) (string, error) {
			b, err := readFile(p)
			return base64.StdEncoding.EncodeToString(b), err
		},
		"sha256file": func(p string) (string, error) {
			b, err := readFile(p)
			if err != nil {
				return "", err
			}
			return fmt.Sprintf("%x", sha256.Sum256(b)), nil
		},
		"indent": func(n int, s string) string {
			pad := strings.Repeat(" ", n)
			lines := strings.Split(strings.TrimRight(s, "\n"), "\n")
			for i, l := range lines {
				if l != "" {
					lines[i] = pad + l
				}
			}
			return strings.Join(lines, "\n")
		},
		"quote":     func(s string) string { return fmt.Sprintf("%q", s) },
		"join":      strings.Join,
		"upper":     strings.ToUpper,
		"lower":     strings.ToLower,
		"trimspace": strings.TrimSpace,
		"required": func(msg string, v any) (any, error) {
			if v == nil {
				return nil, fmt.Errorf("required value missing: %s", msg)
			}
			if s, ok := v.(string); ok && s == "" {
				return nil, fmt.Errorf("required value missing: %s", msg)
			}
			return v, nil
		},
	}
}

func (r *Renderer) templateFor(role string) (string, error) {
	if p, ok := r.Templates[role]; ok {
		return p, nil
	}
	if p, ok := r.Templates[""]; ok {
		return p, nil
	}
	roles := make([]string, 0, len(r.Templates))
	for k := range r.Templates {
		roles = append(roles, k)
	}
	sort.Strings(roles)
	return "", fmt.Errorf("no template for role %q (have: %v)", role, roles)
}

// RenderNode renders the Butane config for one node.
func (r *Renderer) RenderNode(n Node) ([]byte, error) {
	tplPath, err := r.templateFor(n.Role)
	if err != nil {
		return nil, fmt.Errorf("node %q: %w", n.Name, err)
	}
	src, err := os.ReadFile(tplPath)
	if err != nil {
		return nil, fmt.Errorf("node %q: %w", n.Name, err)
	}
	t, err := template.New(filepath.Base(tplPath)).
		Option("missingkey=error").
		Funcs(r.funcs()).
		Parse(string(src))
	if err != nil {
		return nil, fmt.Errorf("node %q: parse %s: %w", n.Name, tplPath, err)
	}
	// Partials only contribute {{ define "name" }} blocks that the main template pulls in
	// with {{ template "name" . }}; their top-level text is never rendered.
	for _, p := range r.Partials {
		psrc, err := os.ReadFile(p)
		if err != nil {
			return nil, fmt.Errorf("node %q: %w", n.Name, err)
		}
		if _, err := t.New(filepath.Base(p)).Parse(string(psrc)); err != nil {
			return nil, fmt.Errorf("node %q: parse partial %s: %w", n.Name, p, err)
		}
	}
	data := Data{
		Cluster: r.Inventory.Cluster,
		Vars:    mergeVars(r.Inventory.Vars, n.Vars, r.Overrides),
		Node:    n,
		Nodes:   r.Inventory.Nodes,
	}
	var buf bytes.Buffer
	if err := t.Execute(&buf, data); err != nil {
		return nil, fmt.Errorf("node %q: render %s: %w", n.Name, tplPath, err)
	}
	return buf.Bytes(), nil
}

// Output is one rendered node.
type Output struct {
	Node     Node
	Butane   []byte
	Ignition []byte // nil unless transpiled
}

// RenderAll renders every node (or only the named one when only is non-empty).
func (r *Renderer) RenderAll(only string, doTranspile bool, filesDir string) ([]Output, error) {
	var outs []Output
	for _, n := range r.Inventory.Nodes {
		if only != "" && n.Name != only {
			continue
		}
		b, err := r.RenderNode(n)
		if err != nil {
			return nil, err
		}
		o := Output{Node: n, Butane: b}
		if doTranspile {
			res, err := transpile.Bytes(b, transpile.Options{FilesDir: filesDir, Strict: true, Pretty: true})
			if err != nil {
				return nil, fmt.Errorf("node %q: %w", n.Name, err)
			}
			// The butane CLI terminates its output with a newline; match it so the
			// library and CLI paths are byte-identical and POSIX tools behave.
			o.Ignition = append(bytes.TrimRight(res.Ignition, "\n"), '\n')
		}
		outs = append(outs, o)
	}
	if only != "" && len(outs) == 0 {
		return nil, fmt.Errorf("no node named %q in inventory", only)
	}
	return outs, nil
}

// WriteOutputs writes <node>.bu (and <node>.ign) into dir with mode 0600,
// because rendered configs may contain secrets.
func WriteOutputs(dir string, outs []Output) error {
	if err := os.MkdirAll(dir, 0o700); err != nil {
		return err
	}
	for _, o := range outs {
		if err := os.WriteFile(filepath.Join(dir, o.Node.Name+".bu"), o.Butane, 0o600); err != nil {
			return err
		}
		if o.Ignition != nil {
			if err := os.WriteFile(filepath.Join(dir, o.Node.Name+".ign"), o.Ignition, 0o600); err != nil {
				return err
			}
		}
	}
	return nil
}

func bytesReader(b []byte) io.Reader { return bytes.NewReader(b) }
