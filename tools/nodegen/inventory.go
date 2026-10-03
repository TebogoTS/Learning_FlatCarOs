// Package main implements nodegen: it renders one Butane config per node from a
// template and an inventory, and can transpile each result with the repository's
// pinned, strict Butane path. Ignition cannot template at runtime, so anything
// that is known at provisioning time (names, addresses, certificates, hashes)
// is rendered here, before the config reaches a node.
package main

import (
	"fmt"
	"net"
	"net/netip"
	"os"

	"gopkg.in/yaml.v3"
)

// Cluster holds cluster-wide identity.
type Cluster struct {
	Name   string `yaml:"name"`
	Domain string `yaml:"domain"`
}

// Node is one machine in the inventory.
type Node struct {
	Name string         `yaml:"name"`
	Role string         `yaml:"role"`
	IP   string         `yaml:"ip"`
	MAC  string         `yaml:"mac"`
	Vars map[string]any `yaml:"vars"`
}

// FQDN returns name.domain, or just the name when no domain is set.
func (n Node) FQDN(domain string) string {
	if domain == "" {
		return n.Name
	}
	return n.Name + "." + domain
}

// Inventory is the parsed inventory file.
type Inventory struct {
	Cluster Cluster        `yaml:"cluster"`
	Vars    map[string]any `yaml:"vars"`
	Nodes   []Node         `yaml:"nodes"`
}

// LoadInventory reads and validates an inventory file.
func LoadInventory(path string) (*Inventory, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return nil, err
	}
	return ParseInventory(data)
}

// ParseInventory parses and validates inventory YAML. Unknown keys are errors so
// that typos do not silently drop configuration.
func ParseInventory(data []byte) (*Inventory, error) {
	var inv Inventory
	dec := yaml.NewDecoder(bytesReader(data))
	dec.KnownFields(true)
	if err := dec.Decode(&inv); err != nil {
		return nil, fmt.Errorf("parse inventory: %w", err)
	}
	if err := inv.Validate(); err != nil {
		return nil, err
	}
	return &inv, nil
}

// Validate checks node uniqueness and address syntax.
func (inv *Inventory) Validate() error {
	if len(inv.Nodes) == 0 {
		return fmt.Errorf("inventory has no nodes")
	}
	names := map[string]bool{}
	ips := map[string]string{}
	macs := map[string]string{}
	for i, n := range inv.Nodes {
		if n.Name == "" {
			return fmt.Errorf("node %d has no name", i)
		}
		if n.Role == "" {
			return fmt.Errorf("node %q has no role", n.Name)
		}
		if names[n.Name] {
			return fmt.Errorf("duplicate node name %q", n.Name)
		}
		names[n.Name] = true
		if n.IP != "" {
			a, err := netip.ParseAddr(n.IP)
			if err != nil {
				return fmt.Errorf("node %q: invalid ip %q: %w", n.Name, n.IP, err)
			}
			if other, dup := ips[a.String()]; dup {
				return fmt.Errorf("nodes %q and %q share ip %s", other, n.Name, n.IP)
			}
			ips[a.String()] = n.Name
		}
		if n.MAC != "" {
			hw, err := net.ParseMAC(n.MAC)
			if err != nil {
				return fmt.Errorf("node %q: invalid mac %q: %w", n.Name, n.MAC, err)
			}
			key := hw.String()
			if other, dup := macs[key]; dup {
				return fmt.Errorf("nodes %q and %q share mac %s", other, n.Name, n.MAC)
			}
			macs[key] = n.Name
		}
	}
	return nil
}

// NodesByRole returns the nodes with the given role, in inventory order.
func (inv *Inventory) NodesByRole(role string) []Node {
	var out []Node
	for _, n := range inv.Nodes {
		if n.Role == role {
			out = append(out, n)
		}
	}
	return out
}
