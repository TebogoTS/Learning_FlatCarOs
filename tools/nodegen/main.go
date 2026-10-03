package main

import (
	"flag"
	"fmt"
	"os"
	"path/filepath"
	"strings"
)

type listFlag []string

func (l *listFlag) String() string     { return strings.Join(*l, ",") }
func (l *listFlag) Set(v string) error { *l = append(*l, v); return nil }

func main() {
	os.Exit(run(os.Args[1:], os.Stdout, os.Stderr))
}

func run(args []string, stdout, stderr *os.File) int {
	fs := flag.NewFlagSet("nodegen", flag.ContinueOnError)
	fs.SetOutput(stderr)
	var (
		invPath   = fs.String("inventory", "", "inventory YAML file (required)")
		outDir    = fs.String("out", "", "output directory (required)")
		baseDir   = fs.String("base-dir", "", "directory the template file helpers may read from (default: the inventory's directory)")
		filesDir  = fs.String("files-dir", "", "Butane --files-dir for local: resources (default: base-dir)")
		only      = fs.String("only", "", "render only this node")
		list      = fs.Bool("list", false, "print the inventory as tab-separated name, role, ip, mac and exit (for shell scripts)")
		doTrans   = fs.Bool("transpile", false, "also write <node>.ign using strict Butane")
		templates listFlag
		partials  listFlag
		vars      listFlag
	)
	fs.Var(&templates, "template", "template path, or role=path (repeatable); a bare path is the default for all roles")
	fs.Var(&partials, "partial", "partial template file providing {{ define }} blocks to all templates (repeatable)")
	fs.Var(&vars, "var", "variable override key=value (repeatable)")
	if err := fs.Parse(args); err != nil {
		return 2
	}
	if *list && *invPath != "" {
		inv, err := LoadInventory(*invPath)
		if err != nil {
			fmt.Fprintf(stderr, "nodegen: %v\n", err)
			return 1
		}
		for _, n := range inv.Nodes {
			fmt.Fprintf(stdout, "%s\t%s\t%s\t%s\n", n.Name, n.Role, n.IP, n.MAC)
		}
		return 0
	}
	if *invPath == "" || *outDir == "" || len(templates) == 0 {
		fmt.Fprintln(stderr, "usage: nodegen -inventory inv.yaml -template [role=]tpl.bu.tmpl [-template ...] -out DIR [-var k=v] [-transpile] [-only NAME]")
		return 2
	}

	inv, err := LoadInventory(*invPath)
	if err != nil {
		fmt.Fprintf(stderr, "nodegen: %v\n", err)
		return 1
	}
	tpls := map[string]string{}
	for _, t := range templates {
		role, path := "", t
		if i := strings.Index(t, "="); i > 0 {
			role, path = t[:i], t[i+1:]
		}
		tpls[role] = path
	}
	over := map[string]any{}
	for _, v := range vars {
		k, val, ok := strings.Cut(v, "=")
		if !ok || k == "" {
			fmt.Fprintf(stderr, "nodegen: -var %q must be key=value\n", v)
			return 2
		}
		over[k] = val
	}
	base := *baseDir
	if base == "" {
		base = filepath.Dir(*invPath)
	}
	fd := *filesDir
	if fd == "" {
		fd = base
	}

	r := &Renderer{Inventory: inv, BaseDir: base, Overrides: over, Templates: tpls, Partials: partials}
	outs, err := r.RenderAll(*only, *doTrans, fd)
	if err != nil {
		fmt.Fprintf(stderr, "nodegen: %v\n", err)
		return 1
	}
	if err := WriteOutputs(*outDir, outs); err != nil {
		fmt.Fprintf(stderr, "nodegen: %v\n", err)
		return 1
	}
	for _, o := range outs {
		fmt.Fprintf(stdout, "rendered %s (%s)\n", o.Node.Name, o.Node.Role)
	}
	return 0
}
