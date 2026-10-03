package main

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"
)

func TestParseOSRelease(t *testing.T) {
	in := `# comment
NAME="Flatcar Container Linux by Kinvolk"
ID=flatcar
ID_LIKE=coreos
VERSION_ID=4757.2.1

BADLINE
EMPTY=
QUOTED='single'
`
	got := parseOSRelease(strings.NewReader(in))
	want := map[string]string{
		"NAME":       "Flatcar Container Linux by Kinvolk",
		"ID":         "flatcar",
		"ID_LIKE":    "coreos",
		"VERSION_ID": "4757.2.1",
		"EMPTY":      "",
		"QUOTED":     "single",
	}
	for k, v := range want {
		if got[k] != v {
			t.Errorf("%s = %q, want %q", k, got[k], v)
		}
	}
	if _, ok := got["BADLINE"]; ok {
		t.Error("line without = must be ignored")
	}
}

func TestLoadOSReleaseMissingFile(t *testing.T) {
	if m := loadOSRelease("/nonexistent/os-release"); len(m) != 0 {
		t.Fatalf("expected empty map, got %v", m)
	}
}

func TestGreeting(t *testing.T) {
	old := version
	defer func() { version = old }()
	version = "v9"
	if g := greeting(map[string]string{"ID": "flatcar", "VERSION_ID": "1.2.3"}); !strings.Contains(g, "v9") || !strings.Contains(g, "flatcar 1.2.3") {
		t.Errorf("unexpected greeting %q", g)
	}
	if g := greeting(nil); !strings.Contains(g, "unknown unknown") {
		t.Errorf("greeting without os-release should say unknown, got %q", g)
	}
}

func TestEndpoints(t *testing.T) {
	old := version
	defer func() { version = old }()
	version = "v2"
	started := time.Date(2026, 10, 3, 12, 0, 0, 0, time.UTC)
	srv := httptest.NewServer(newMux(map[string]string{"ID": "flatcar", "VERSION_ID": "4757.2.1"}, started))
	defer srv.Close()

	resp, err := http.Get(srv.URL + "/healthz")
	if err != nil {
		t.Fatal(err)
	}
	resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		t.Errorf("/healthz status %d", resp.StatusCode)
	}

	resp, err = http.Get(srv.URL + "/info")
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()
	if ct := resp.Header.Get("Content-Type"); ct != "application/json" {
		t.Errorf("content type %q", ct)
	}
	var got info
	if err := json.NewDecoder(resp.Body).Decode(&got); err != nil {
		t.Fatal(err)
	}
	want := info{Program: "flatcar-hello", Version: "v2", OSID: "flatcar", OSVersionID: "4757.2.1", Started: "2026-10-03T12:00:00Z"}
	if got != want {
		t.Errorf("info = %+v, want %+v", got, want)
	}

	resp2, err := http.Get(srv.URL + "/nope")
	if err != nil {
		t.Fatal(err)
	}
	resp2.Body.Close()
	if resp2.StatusCode != http.StatusNotFound {
		t.Errorf("unknown path status %d, want 404", resp2.StatusCode)
	}
}
