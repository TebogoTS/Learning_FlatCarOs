package transpile

import (
	"errors"
	"strings"
	"testing"
)

func TestBytes(t *testing.T) {
	tests := []struct {
		name     string
		in       string
		opts     Options
		wantErr  bool
		wantWarn bool
		contains string
	}{
		{
			name:     "valid flatcar 1.1.0 emits ignition 3.4.0",
			in:       "variant: flatcar\nversion: 1.1.0\n",
			contains: `"version":"3.4.0"`,
		},
		{
			name:     "pretty output is indented",
			in:       "variant: flatcar\nversion: 1.1.0\n",
			opts:     Options{Pretty: true},
			contains: "\n  \"ignition\"",
		},
		{
			name:    "unknown variant fails",
			in:      "variant: nope\nversion: 1.0.0\n",
			wantErr: true,
		},
		{
			name:     "warning passes without strict",
			in:       "variant: flatcar\nversion: 1.1.0\nstorage:\n  files:\n    - path: /etc/x\n      contnts:\n        inline: a\n",
			contains: "ignition",
		},
		{
			name:     "warning fails with strict",
			in:       "variant: flatcar\nversion: 1.1.0\nstorage:\n  files:\n    - path: /etc/x\n      contnts:\n        inline: a\n",
			opts:     Options{Strict: true},
			wantErr:  true,
			wantWarn: true,
		},
	}
	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			res, err := Bytes([]byte(tc.in), tc.opts)
			if tc.wantErr {
				if err == nil {
					t.Fatalf("expected error, got output %s", res.Ignition)
				}
				if tc.wantWarn && !errors.Is(err, ErrWarnings) {
					t.Fatalf("expected ErrWarnings, got %v", err)
				}
				return
			}
			if err != nil {
				t.Fatalf("unexpected error: %v", err)
			}
			if !strings.Contains(string(res.Ignition), tc.contains) {
				t.Fatalf("output %q does not contain %q", res.Ignition, tc.contains)
			}
		})
	}
}
