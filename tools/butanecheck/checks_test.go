package main

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

const (
	hash256 = "sha256-0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
	pemBody = "-----BEGIN EC PRIVATE KEY-----\nMHcCAQEE\n-----END EC PRIVATE KEY-----\n"
)

func basePolicy() Policy {
	return Policy{Variant: "flatcar", Version: "1.1.0"}
}

// has reports whether any finding matches the check name and severity.
func has(fs []Finding, check string, sev Severity) bool {
	for _, f := range fs {
		if f.Check == check && f.Severity == sev {
			return true
		}
	}
	return false
}

func errorsOf(fs []Finding) []Finding {
	var out []Finding
	for _, f := range fs {
		if f.Severity == Error {
			out = append(out, f)
		}
	}
	return out
}

func TestCheck(t *testing.T) {
	tests := []struct {
		name      string
		butane    string
		policy    Policy
		wantErr   []string // "check" names expected as Error findings
		wantClean bool
	}{
		{
			name: "minimal valid config",
			butane: `variant: flatcar
version: 1.1.0
storage:
  files:
    - path: /etc/hostname
      contents:
        inline: node-1
`,
			policy:    basePolicy(),
			wantClean: true,
		},
		{
			name: "wrong spec version",
			butane: `variant: flatcar
version: 1.0.0
`,
			policy:  basePolicy(),
			wantErr: []string{"pin"},
		},
		{
			name: "wrong variant",
			butane: `variant: fcos
version: 1.5.0
`,
			policy:  basePolicy(),
			wantErr: []string{"pin"},
		},
		{
			name: "pins disabled allows other versions",
			butane: `variant: flatcar
version: 1.0.0
`,
			policy:    Policy{},
			wantClean: true,
		},
		{
			name: "misspelled key fails strict transpile",
			butane: `variant: flatcar
version: 1.1.0
storage:
  files:
    - path: /etc/x
      contnts:
        inline: a
`,
			policy:  basePolicy(),
			wantErr: []string{"transpile"},
		},
		{
			name: "http source without hash",
			butane: `variant: flatcar
version: 1.1.0
storage:
  files:
    - path: /opt/bin/tool
      mode: 0755
      contents:
        source: http://example.invalid/tool
`,
			policy:  basePolicy(),
			wantErr: []string{"remote-hash"},
		},
		{
			name: "https source with hash passes",
			butane: `variant: flatcar
version: 1.1.0
storage:
  files:
    - path: /opt/bin/tool
      mode: 0755
      contents:
        source: https://example.invalid/tool
        verification:
          hash: ` + hash256 + `
`,
			policy:    basePolicy(),
			wantClean: true,
		},
		{
			name: "malformed hash rejected by Butane",
			butane: `variant: flatcar
version: 1.1.0
storage:
  files:
    - path: /opt/bin/tool
      contents:
        source: https://example.invalid/tool
        verification:
          hash: sha256-tooshort
`,
			policy:  basePolicy(),
			wantErr: []string{"transpile"},
		},
		{
			name: "remote hash check can be disabled",
			butane: `variant: flatcar
version: 1.1.0
storage:
  files:
    - path: /opt/bin/tool
      contents:
        source: http://example.invalid/tool
`,
			policy:    Policy{Variant: "flatcar", Version: "1.1.0", SkipRemoteHashCheck: true},
			wantClean: true,
		},
		{
			name: "merge from https without hash",
			butane: `variant: flatcar
version: 1.1.0
ignition:
  config:
    merge:
      - source: https://example.invalid/child.ign
`,
			policy:  basePolicy(),
			wantErr: []string{"remote-hash"},
		},
		{
			name: "enabled unit without Install section is caught by strict transpile",
			butane: `variant: flatcar
version: 1.1.0
systemd:
  units:
    - name: hello.service
      enabled: true
      contents: |
        [Unit]
        Description=hello
        [Service]
        ExecStart=/usr/bin/true
`,
			policy:  basePolicy(),
			wantErr: []string{"transpile"},
		},
		{
			name: "enabled unit with Install section",
			butane: `variant: flatcar
version: 1.1.0
systemd:
  units:
    - name: hello.service
      enabled: true
      contents: |
        [Unit]
        Description=hello
        [Service]
        ExecStart=/usr/bin/true
        [Install]
        WantedBy=multi-user.target
`,
			policy:    basePolicy(),
			wantClean: true,
		},
		{
			name: "dropin-only enabled unit has no contents to check",
			butane: `variant: flatcar
version: 1.1.0
systemd:
  units:
    - name: sshd.service
      enabled: true
      dropins:
        - name: 10-x.conf
          contents: |
            [Service]
            Restart=always
`,
			policy:    basePolicy(),
			wantClean: true,
		},
		{
			name: "private key not allowed by default",
			butane: `variant: flatcar
version: 1.1.0
storage:
  files:
    - path: /etc/k.pem
      mode: 0600
      contents:
        inline: |
          ` + strings.ReplaceAll(strings.TrimSpace(pemBody), "\n", "\n          ") + `
`,
			policy:  basePolicy(),
			wantErr: []string{"private-key"},
		},
		{
			name: "private key allowed with 0600",
			butane: `variant: flatcar
version: 1.1.0
storage:
  files:
    - path: /etc/k.pem
      mode: 0600
      contents:
        inline: |
          ` + strings.ReplaceAll(strings.TrimSpace(pemBody), "\n", "\n          ") + `
`,
			policy:    Policy{Variant: "flatcar", Version: "1.1.0", AllowPrivateKeys: true},
			wantClean: true,
		},
		{
			name: "private key allowed but world readable",
			butane: `variant: flatcar
version: 1.1.0
storage:
  files:
    - path: /etc/k.pem
      mode: 0644
      contents:
        inline: |
          ` + strings.ReplaceAll(strings.TrimSpace(pemBody), "\n", "\n          ") + `
`,
			policy:  Policy{Variant: "flatcar", Version: "1.1.0", AllowPrivateKeys: true},
			wantErr: []string{"private-key"},
		},
		{
			name: "private key with default mode is world readable",
			butane: `variant: flatcar
version: 1.1.0
storage:
  files:
    - path: /etc/k.pem
      contents:
        inline: |
          ` + strings.ReplaceAll(strings.TrimSpace(pemBody), "\n", "\n          ") + `
`,
			policy:  Policy{Variant: "flatcar", Version: "1.1.0", AllowPrivateKeys: true},
			wantErr: []string{"private-key"},
		},
		{
			name: "size budget exceeded",
			butane: `variant: flatcar
version: 1.1.0
storage:
  files:
    - path: /etc/hostname
      contents:
        inline: node-1
`,
			policy:  Policy{Variant: "flatcar", Version: "1.1.0", MaxIgnitionBytes: 10},
			wantErr: []string{"size"},
		},
		{
			name:    "invalid YAML",
			butane:  "variant: [unterminated\n",
			policy:  basePolicy(),
			wantErr: []string{"header"},
		},
	}

	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			fs, err := Check(tc.name, []byte(tc.butane), tc.policy)
			if err != nil {
				t.Fatalf("unexpected error: %v", err)
			}
			if tc.wantClean {
				if len(fs) != 0 {
					t.Fatalf("expected no findings, got %+v", fs)
				}
				return
			}
			for _, want := range tc.wantErr {
				if !has(fs, want, Error) {
					t.Errorf("expected an error finding %q, got %+v", want, fs)
				}
			}
			if len(tc.wantErr) > 0 && len(errorsOf(fs)) == 0 {
				t.Errorf("expected failure but no error findings: %+v", fs)
			}
		})
	}
}

func TestCheckLocalFileKeyDetection(t *testing.T) {
	dir := t.TempDir()
	if err := os.WriteFile(filepath.Join(dir, "k.pem"), []byte(pemBody), 0o600); err != nil {
		t.Fatal(err)
	}
	butane := `variant: flatcar
version: 1.1.0
storage:
  files:
    - path: /etc/k.pem
      mode: 0600
      contents:
        local: k.pem
`
	fs, err := Check("local", []byte(butane), Policy{Variant: "flatcar", Version: "1.1.0", FilesDir: dir})
	if err != nil {
		t.Fatal(err)
	}
	if !has(fs, "private-key", Error) {
		t.Fatalf("expected private-key error for local: file, got %+v", fs)
	}
	fs, err = Check("local", []byte(butane), Policy{Variant: "flatcar", Version: "1.1.0", FilesDir: dir, AllowPrivateKeys: true})
	if err != nil {
		t.Fatal(err)
	}
	if len(fs) != 0 {
		t.Fatalf("expected clean with allow + 0600, got %+v", fs)
	}
}

func TestCheckLargeInlineIsCompressedAndStillScanned(t *testing.T) {
	// Butane gzip-compresses large inline resources; the key scan must see through it.
	big := strings.Repeat("A", 4096) + "\n" + pemBody
	butane := "variant: flatcar\nversion: 1.1.0\nstorage:\n  files:\n    - path: /etc/big\n      mode: 0600\n      contents:\n        inline: |\n"
	for _, l := range strings.Split(big, "\n") {
		butane += "          " + l + "\n"
	}
	fs, err := Check("big", []byte(butane), basePolicy())
	if err != nil {
		t.Fatal(err)
	}
	if !has(fs, "private-key", Error) {
		t.Fatalf("expected private-key error through compression, got %+v", fs)
	}
}

func TestValidHashFormat(t *testing.T) {
	good := []string{hash256, "sha512-" + strings.Repeat("a", 128)}
	bad := []string{"", "sha256-xyz", "md5-abc", "sha256-" + strings.Repeat("A", 64), hash256 + "0"}
	for _, g := range good {
		if !validHashFormat(g) {
			t.Errorf("expected %q valid", g)
		}
	}
	for _, b := range bad {
		if validHashFormat(b) {
			t.Errorf("expected %q invalid", b)
		}
	}
}
