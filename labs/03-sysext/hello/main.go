// Command flatcar-hello is the payload of the lab 03 system extension. It is a static
// binary, so the extension can be matched with SYSEXT_LEVEL instead of being tied to one
// Flatcar OS version.
package main

import (
	"bufio"
	"encoding/json"
	"flag"
	"fmt"
	"io"
	"net/http"
	"os"
	"strings"
	"time"
)

// version is set at build time: -ldflags "-X main.version=v1".
var version = "dev"

// parseOSRelease reads KEY=VALUE lines as found in /etc/os-release, trimming optional quotes.
func parseOSRelease(r io.Reader) map[string]string {
	out := map[string]string{}
	sc := bufio.NewScanner(r)
	for sc.Scan() {
		line := strings.TrimSpace(sc.Text())
		if line == "" || strings.HasPrefix(line, "#") {
			continue
		}
		k, v, ok := strings.Cut(line, "=")
		if !ok {
			continue
		}
		out[k] = strings.Trim(v, `"'`)
	}
	return out
}

func loadOSRelease(path string) map[string]string {
	f, err := os.Open(path)
	if err != nil {
		return map[string]string{}
	}
	defer f.Close()
	return parseOSRelease(f)
}

// info is what the HTTP endpoint reports.
type info struct {
	Program     string `json:"program"`
	Version     string `json:"version"`
	OSID        string `json:"os_id"`
	OSVersionID string `json:"os_version_id"`
	Started     string `json:"started"`
}

func newMux(osr map[string]string, started time.Time) *http.ServeMux {
	mux := http.NewServeMux()
	mux.HandleFunc("/healthz", func(w http.ResponseWriter, _ *http.Request) {
		w.WriteHeader(http.StatusOK)
		_, _ = io.WriteString(w, "ok\n")
	})
	mux.HandleFunc("/info", func(w http.ResponseWriter, _ *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		_ = json.NewEncoder(w).Encode(info{
			Program:     "flatcar-hello",
			Version:     version,
			OSID:        osr["ID"],
			OSVersionID: osr["VERSION_ID"],
			Started:     started.UTC().Format(time.RFC3339),
		})
	})
	return mux
}

func greeting(osr map[string]string) string {
	id, ver := osr["ID"], osr["VERSION_ID"]
	if id == "" {
		id, ver = "unknown", "unknown"
	}
	return fmt.Sprintf("flatcar-hello %s, running on %s %s, delivered by a system extension", version, id, ver)
}

func main() {
	showVersion := flag.Bool("version", false, "print the version and exit")
	serve := flag.String("serve", "", "listen address for the HTTP endpoint, e.g. 127.0.0.1:8088")
	osReleasePath := flag.String("os-release", "/etc/os-release", "path to os-release")
	flag.Parse()

	if *showVersion {
		fmt.Println(version)
		return
	}
	osr := loadOSRelease(*osReleasePath)
	if *serve == "" {
		fmt.Println(greeting(osr))
		return
	}
	srv := &http.Server{
		Addr:              *serve,
		Handler:           newMux(osr, time.Now()),
		ReadHeaderTimeout: 5 * time.Second,
	}
	fmt.Fprintln(os.Stderr, greeting(osr), "- serving on", *serve)
	if err := srv.ListenAndServe(); err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
}
