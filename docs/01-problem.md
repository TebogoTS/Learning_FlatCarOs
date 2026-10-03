# 01 — The problem Flatcar solves

You run Kubernetes on vSphere and AWS and you already know what a node is for. This document is about the layer
underneath: why a general-purpose server distribution is a poor fit for that layer, what Flatcar does differently, and
what that changes about how you operate a fleet. It deliberately argues the design, not the feature list.

## A general-purpose distribution gives you an installer, and an installer gives you a history

A node built from Debian, Ubuntu or RHEL starts life as the output of an installer plus whatever your automation did
afterwards. From that point it is a mutable machine: any package can be installed, any file under `/usr`, `/etc` or
`/lib` can be edited by anyone with root, and the package manager's database is the only record of what is on disk. Every
change is a delta applied to the previous state. Two nodes that began identical become different the first time an
engineer fixes something by hand, a post-install script behaves differently because of a mirror change, or a
`dnf update` pulls a newer transitive dependency on one node than on its sibling.

This is configuration drift, and it is not mainly a discipline problem. It is a structural property of an operating
system whose update unit is the package and whose mutation surface is the whole filesystem. Configuration management
tools make drift detectable and sometimes correctable, but they work by converging a machine toward a description,
which means the machine's actual state is always "the last convergence plus whatever happened since". A fleet of such
machines accumulates snowflakes: nodes you cannot safely rebuild because nobody is sure what is on them, and which
therefore never get rebuilt.

The operational cost lands in three places. Patching becomes a per-package, per-node operation whose outcome depends on
the starting state, so "patched" is a statistic rather than a fact. Incident response becomes forensic, because you
must ask what a node is before you can ask what is wrong with it. And compliance evidence becomes a sampling exercise:
you demonstrate that a control exists in the baseline and then argue that the fleet matches it.

## The attack-surface argument, stated carefully

The usual claim is that a container-oriented OS has a smaller attack surface. That is true in a specific and limited
sense, and it is worth being exact about it because a regulated-estate reviewer will be.

Flatcar's own FAQ states the argument: the image "includes just the minimal amount of tools to run container
workloads", `/usr` is a read-only partition, and "there's no package manager to install packages", so there is "less
chance of both accidental and intentional breakage" ([FAQ][faq]). It is not a bare-bones image in the Alpine sense. The
base package list in the build repository (`coreos-base/coreos`) includes `vim`, `git`, `gnupg`, `tcpdump`, `strace`,
`bpftool`, `jq`, `curl`, `rsync`, `socat`, `iptables`, `nftables`, `etcd`, `cri-tools`, LVM, mdadm, SSSD and a good many
storage and network utilities ([ebuild][coreos-ebuild]). Docker and containerd are deliberately absent from that list:
they ship as separate system extensions (doc 06). So the argument is not "there is almost nothing on the host". It is three narrower claims:

First, the set of things on the host is fixed per release and identical on every node of that release, so the question
"what software is on this machine" has one answer per version rather than one per node. Second, there is no package
manager in the image, and the base package list names no compiler toolchain and no scripting runtime such as Python
(which exists only as an opt-in extension), which removes the usual post-exploitation path of installing or building
tooling on the host. Third, the executable and library content lives on a block device that the kernel refuses to write
to and verifies on every read, which makes persistent tampering with OS binaries detectable rather than merely
prohibited.

> ⚠️ Verify: the second claim comes from the top-level package list. Confirm on a running node
> (`which gcc python3 perl`), because transitive dependencies are not visible in that file.

The honest limit is that none of this constrains what runs in containers, what you put in `/opt` or `/var`, or what a
root user on the host can do to the running system's namespaces. The manual-rollback documentation, for example,
bind-mounts a writable copy over `/usr/share/coreos/release` to fake a version number ([manual rollbacks][rollbacks]).
The dm-verity layer protects the underlying partition, not the mount namespace. Immutability here means "the vendor's
content cannot be silently altered on disk", not "root is neutered".

## What Flatcar changes: the unit of change is the whole OS

Flatcar's central design decision is that the OS ships as complete images and complete update payloads, never as
packages. The supply-chain documentation states it as a foundational principle: "We ship whole OS images only; no
incremental updates or upgrades of individual OS binaries or packages are supported", and updates are "shipped as full
partition images" installed through an A/B scheme ([supply chain][supply-chain]). Everything else follows from that.

Because the OS is one versioned artifact, every node running version N has byte-identical `/usr`. Because `/usr` is on
its own partition, mounted read-only, the vendor's half of the machine and your half have a hard boundary. Because there
are two `/usr` partitions, an update is staged on the inactive one while the node keeps running, and activating it is a
reboot, not an in-place transformation. If the new version fails to come up, the bootloader falls back to the old one.
Doc 04 covers the mechanism; the operational consequence is that "patch the OS" becomes "move the fleet from version N
to version N+1", which is a state you can observe, gate and roll back as one thing.

This is the same shift you already made with container images, applied one layer down. You do not `apt upgrade` inside
a running pod; you roll out a new image. Flatcar asks you to treat the node the same way.

## The other half: configuration is supplied at first boot and then left alone

A read-only OS still needs machine-specific state: hostnames, users, SSH keys, certificates, systemd units. Flatcar's
answer is Ignition, which runs once in the initial RAM disk on a node's first boot, applies a declarative description,
and never runs again. The Ignition rationale document is explicit about the intent: "Ignition is designed to be used as
a provisioning tool, not as a configuration management tool. Ignition encourages immutable infrastructure, in which
machine modification requires that users discard the old node and re-provision the machine" ([Ignition
rationale][rationale]).

That sentence is the operational model. A node is created from an image plus a config. If the config needs to change, you
make a new node. There is no agent on the node that keeps pulling the machine toward a moving target, and no long-lived
drift to reason about, because the only things that change after first boot are what the OS update process changes (the
`/usr` image) and what your workloads write to `/var`. Doc 05 covers the mechanics.

## "The OS is just a substrate for containers" and what it does to operations

If you accept that framing, several operational habits flip.

Rebuild beats repair. When a node misbehaves, the default action is to replace it, because replacement is cheap and
deterministic and repair requires understanding a unique machine. Patching cadence becomes a function of the release
channel you follow and how you gate reboots, not of per-package advisories. Access becomes exceptional: there is a
`toolbox` for debugging, and SSH exists, but a node you routinely log into to fix things is a node you are using wrongly.
Evidence for auditors changes shape too: the question "what is installed on this node" is answered by "OS release X,
verified by dm-verity, plus config Y, which is in version control", both of which are artifacts, not observations.

None of this removes work. It moves it. You now own the first-boot configuration as code, the reboot-coordination policy,
the upgrade-ordering policy between OS and Kubernetes, and a decision about which extension mechanism you use for
anything not in the base image (doc 06). Doc 07 and doc 08 cover those, and doc 08 is also frank about when this trade is
not worth making.

## What this does not solve

Flatcar does not fix drift in the application layer, in Kubernetes objects, or in anything you write to `/var`. It does
not give you a compliance posture by itself; it gives you a smaller set of things to evidence. It does not make updates
safe for stateful workloads that cannot tolerate node reboots; it makes the reboot a controlled, frequent, boring event,
which is only valuable if your workloads are built to survive it. And it changes the failure mode of customization: a
tool you need that is not in the image has to arrive as a container, a sysext, or a custom image, and each of those has
a cost (docs 06 and 11).

## Key takeaways

- Drift and snowflakes come from a mutable OS whose update unit is the package; Flatcar changes the unit of change to the whole OS image.
- "Smaller attack surface" means a fixed, identical, tamper-evident host content set and no package manager, not a nearly empty host.
- Ignition applies configuration once at first boot, so machine modification means replace, not repair.
- The boundary is hard: the vendor owns the read-only `/usr`, you own configuration and state, and containers own workloads.
- The work does not disappear; it moves to first-boot config as code, reboot coordination and upgrade ordering.

## Sources

- Flatcar FAQ, "Why use a Container Linux instead of a general purpose Linux distribution?" and "If the image is immutable, how does it get updated?": [flatcar-website `content/faq.md`][faq]
- Supply chain security mechanisms (foundational concepts, whole-image updates, A/B, dm-verity): [`security/supply-chain.md`][supply-chain]
- Ignition rationale: [`coreos/ignition docs/rationale.md`][rationale]
- Base package list of the image: [`coreos-base/coreos/coreos-0.0.1.ebuild`][coreos-ebuild]
- Manual rollbacks (bind-mount over a read-only file, partition flags): [`diagnostics/manual-rollbacks.md`][rollbacks]

[faq]: https://github.com/flatcar/flatcar-website/blob/415d66a7b79efa4374b927a4cd6d7b5bd1bfeb9c/content/faq.md
[supply-chain]: https://github.com/flatcar/flatcar-website/blob/415d66a7b79efa4374b927a4cd6d7b5bd1bfeb9c/content/docs/latest/security/supply-chain.md
[rationale]: https://github.com/coreos/ignition/blob/94173720290741546ffc2cc1a677eb0ab5d0cb84/docs/rationale.md
[coreos-ebuild]: https://github.com/flatcar/scripts/blob/2189f1e166e28c06cdcd1b26fea47f05da78c139/sdk_container/src/third_party/coreos-overlay/coreos-base/coreos/coreos-0.0.1.ebuild
[rollbacks]: https://github.com/flatcar/flatcar-website/blob/415d66a7b79efa4374b927a4cd6d7b5bd1bfeb9c/content/docs/latest/diagnostics/manual-rollbacks.md
