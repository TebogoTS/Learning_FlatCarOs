// Package main implements butanecheck: policy checks for Butane configs that
// `butane --strict` does not make. It transpiles through the same library path
// the rest of the repository uses, then inspects the resulting Ignition JSON.
package main

import (
	"bytes"
	"compress/gzip"
	"encoding/json"
	"fmt"
	"io"
	"net/url"
	"regexp"
	"strings"

	"github.com/tebogots/flatcar-deep-dive/tools/internal/transpile"
	"github.com/vincent-petithory/dataurl"
	"gopkg.in/yaml.v3"
)

// Severity of a finding. Only Error findings fail a run.
type Severity string

const (
	// Error findings make the command exit non-zero.
	Error Severity = "error"
	// Warn findings are reported but do not fail.
	Warn Severity = "warn"
)

// Finding is one policy result.
type Finding struct {
	Check    string   `json:"check"`
	Severity Severity `json:"severity"`
	Path     string   `json:"path,omitempty"`
	Message  string   `json:"message"`
}

// Policy configures which checks run and their thresholds.
type Policy struct {
	// Variant and Version pin the Butane header. Empty disables the check.
	Variant string
	Version string
	// FilesDir is passed to Butane for `local:` resources.
	FilesDir string
	// SkipRemoteHashCheck disables the "remote sources need a hash" check.
	SkipRemoteHashCheck bool
	// AllowPrivateKeys permits private key material in file contents. Even when
	// allowed, such files must not be readable by group or other.
	AllowPrivateKeys bool
	// MaxIgnitionBytes bounds the size of the transpiled Ignition JSON. 0 disables.
	MaxIgnitionBytes int
}

var privateKeyRE = regexp.MustCompile(`-----BEGIN [A-Z0-9 ]*PRIVATE KEY-----`)

type header struct {
	Variant string `yaml:"variant"`
	Version string `yaml:"version"`
}

// Check runs every enabled check against one Butane config. The name is used
// only for messages. The error return is reserved for unexpected failures
// (not for policy violations, which are Findings).
func Check(name string, butane []byte, p Policy) ([]Finding, error) {
	var findings []Finding
	add := func(check string, sev Severity, path, format string, args ...any) {
		findings = append(findings, Finding{Check: check, Severity: sev, Path: path, Message: fmt.Sprintf(format, args...)})
	}

	var h header
	if err := yaml.Unmarshal(butane, &h); err != nil {
		add("header", Error, "", "cannot parse YAML header: %v", err)
		return findings, nil
	}
	if p.Variant != "" && h.Variant != p.Variant {
		add("pin", Error, "variant", "variant is %q, policy requires %q", h.Variant, p.Variant)
	}
	if p.Version != "" && h.Version != p.Version {
		add("pin", Error, "version", "version is %q, policy requires %q", h.Version, p.Version)
	}

	res, err := transpile.Bytes(butane, transpile.Options{FilesDir: p.FilesDir, Strict: true})
	if err != nil {
		add("transpile", Error, "", "%v", err)
		return findings, nil
	}

	var ign map[string]any
	if err := json.Unmarshal(res.Ignition, &ign); err != nil {
		return findings, fmt.Errorf("%s: transpiled output is not JSON: %w", name, err)
	}

	if p.MaxIgnitionBytes > 0 && len(res.Ignition) > p.MaxIgnitionBytes {
		add("size", Error, "", "Ignition JSON is %d bytes, budget is %d", len(res.Ignition), p.MaxIgnitionBytes)
	}

	findings = append(findings, checkRemoteSources(ign, p)...)
	findings = append(findings, checkPrivateKeys(ign, p)...)
	return findings, nil
}

// resource is a fetchable thing in an Ignition config.
type resource struct {
	path        string
	source      string
	compression string
	hash        string
}

func asMap(v any) map[string]any {
	m, _ := v.(map[string]any)
	return m
}

func asList(v any) []any {
	l, _ := v.([]any)
	return l
}

func str(v any) string {
	s, _ := v.(string)
	return s
}

func toResource(path string, v any) (resource, bool) {
	m := asMap(v)
	if m == nil {
		return resource{}, false
	}
	r := resource{path: path, source: str(m["source"]), compression: str(m["compression"])}
	r.hash = str(asMap(m["verification"])["hash"])
	return r, true
}

// collectResources lists every resource Ignition may fetch or embed.
func collectResources(ign map[string]any) []resource {
	var out []resource
	add := func(path string, v any) {
		if r, ok := toResource(path, v); ok {
			out = append(out, r)
		}
	}
	files := asList(asMap(ign["storage"])["files"])
	for i, f := range files {
		fm := asMap(f)
		add(fmt.Sprintf("storage.files[%d](%s).contents", i, str(fm["path"])), fm["contents"])
		for j, a := range asList(fm["append"]) {
			add(fmt.Sprintf("storage.files[%d](%s).append[%d]", i, str(fm["path"]), j), a)
		}
	}
	cfg := asMap(asMap(ign["ignition"])["config"])
	for i, m := range asList(cfg["merge"]) {
		add(fmt.Sprintf("ignition.config.merge[%d]", i), m)
	}
	add("ignition.config.replace", cfg["replace"])
	cas := asList(asMap(asMap(asMap(ign["ignition"])["security"])["tls"])["certificateAuthorities"])
	for i, c := range cas {
		add(fmt.Sprintf("ignition.security.tls.certificateAuthorities[%d]", i), c)
	}
	return out
}

func checkRemoteSources(ign map[string]any, p Policy) []Finding {
	if p.SkipRemoteHashCheck {
		return nil
	}
	var out []Finding
	for _, r := range collectResources(ign) {
		if r.source == "" || strings.HasPrefix(r.source, "data:") {
			continue
		}
		u, err := url.Parse(r.source)
		if err != nil {
			out = append(out, Finding{Check: "remote-hash", Severity: Error, Path: r.path, Message: fmt.Sprintf("unparsable source %q", r.source)})
			continue
		}
		if r.hash != "" {
			if !validHashFormat(r.hash) {
				out = append(out, Finding{Check: "remote-hash", Severity: Error, Path: r.path, Message: fmt.Sprintf("verification hash %q is not sha256-<64 hex> or sha512-<128 hex>", r.hash)})
			}
			continue
		}
		switch u.Scheme {
		case "http", "https", "tftp":
			out = append(out, Finding{Check: "remote-hash", Severity: Error, Path: r.path, Message: fmt.Sprintf("remote source %s has no verification.hash", r.source)})
		default:
			out = append(out, Finding{Check: "remote-hash", Severity: Warn, Path: r.path, Message: fmt.Sprintf("source %s (%s) has no verification.hash", r.source, u.Scheme)})
		}
	}
	return out
}

var (
	sha256HashRE = regexp.MustCompile(`^sha256-[0-9a-f]{64}$`)
	sha512HashRE = regexp.MustCompile(`^sha512-[0-9a-f]{128}$`)
)

func validHashFormat(h string) bool {
	return sha256HashRE.MatchString(h) || sha512HashRE.MatchString(h)
}

// decodeData returns the bytes of an embedded `data:` resource.
func decodeData(r resource) ([]byte, bool) {
	if !strings.HasPrefix(r.source, "data:") {
		return nil, false
	}
	d, err := dataurl.DecodeString(r.source)
	if err != nil {
		return nil, false
	}
	b := d.Data
	if r.compression == "gzip" {
		zr, err := gzip.NewReader(bytes.NewReader(b))
		if err != nil {
			return nil, false
		}
		defer zr.Close()
		b, err = io.ReadAll(zr)
		if err != nil {
			return nil, false
		}
	}
	return b, true
}

func checkPrivateKeys(ign map[string]any, p Policy) []Finding {
	var out []Finding
	for i, f := range asList(asMap(ign["storage"])["files"]) {
		fm := asMap(f)
		path := fmt.Sprintf("storage.files[%d](%s)", i, str(fm["path"]))
		var resources []resource
		if r, ok := toResource(path+".contents", fm["contents"]); ok {
			resources = append(resources, r)
		}
		for j, a := range asList(fm["append"]) {
			if r, ok := toResource(fmt.Sprintf("%s.append[%d]", path, j), a); ok {
				resources = append(resources, r)
			}
		}
		hasKey := false
		for _, r := range resources {
			if b, ok := decodeData(r); ok && privateKeyRE.Match(b) {
				hasKey = true
			}
		}
		if !hasKey {
			continue
		}
		if !p.AllowPrivateKeys {
			out = append(out, Finding{Check: "private-key", Severity: Error, Path: path, Message: "contains private key material; pass --allow-private-keys only for lab configs"})
			continue
		}
		mode := 0o644 // Ignition's default for files
		if m, ok := fm["mode"].(float64); ok {
			mode = int(m)
		}
		if mode&0o077 != 0 {
			out = append(out, Finding{Check: "private-key", Severity: Error, Path: path, Message: fmt.Sprintf("private key file has mode %04o, must not be group or world accessible", mode)})
		}
	}
	return out
}
