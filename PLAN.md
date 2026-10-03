# PLAN.md — Flatcar deep-dive learning repo

Status: **draft for review. No docs or labs written yet.** I will not proceed until you approve or amend this.

## 1. What I found about my research environment (this affects accuracy)

This session runs in a cloud container with an egress allow-list. I probed it before planning.

| Source | Reachable? | Consequence |
|---|---|---|
| `raw.githubusercontent.com` (any public repo) | Yes | Primary source for Butane specs/docs, Ignition, sysext-bakery, Nebraska, FLUO, RKE2, image-builder, `flatcar/scripts`. |
| `git ls-remote` on github.com | Yes | Reliable tag/version pinning. |
| GitHub release asset downloads | Yes | Can fetch the pinned Butane binary. |
| `go install` / Go module proxy | Yes | Butane v0.29.0 builds here. Go 1.24.7 is installed. |
| WebSearch | Yes | Useful for discovery only. Snippets disagree with each other and with primary sources (see §3), so I won't cite them as fact. |
| **`www.flatcar.org`** (docs, releases) | **Blocked** | The official docs site is not directly readable. |
| **`docs.rke2.io`** | **Blocked** | RKE2 docs must come from the docs source repo in GitHub, if it's raw-fetchable. |
| **`coreos.github.io`** (Butane/Ignition rendered docs) | Blocked | Use the same Markdown from `coreos/butane` / `coreos/ignition` via raw GitHub. Fine. |
| `*.release.flatcar-linux.net` (release feed, images, signatures) | **Blocked** | Cannot read the authoritative per-channel current version or fetch images. |
| GitHub MCP tools | Scoped to this repo only | Not usable for upstream repos unless you ask me to `add_repo`. Raw access covers the need. |

Local tooling: no `/dev/kvm`, no `qemu`, no `libvirt`, no `shellcheck`, no `butane` preinstalled. So **I cannot boot a VM in this session.** Every lab will be written to run on your homelab; what I can validate here is listed in §6.

## 2. Open questions (need your decision)

1. **Network allow-list.** Can you add `www.flatcar.org`, `docs.rke2.io`, `*.release.flatcar-linux.net`, `extensions.flatcar.org` and `coreos.github.io` under Custom network access? That would let me read the official docs and pin real release numbers. If not, the plan below degrades gracefully, but more inline `> ⚠️ Verify:` markers are needed, especially in docs 3, 4, 7 and 10.
2. **RKE2 / Kubernetes pin.** `git ls-remote` shows the newest RKE2 tags are `v1.37.1+rke2r1` and `v1.36.5+rke2r1`. For the upgrade lab I need two adjacent versions. Default: start on the latest patch of the previous minor (1.36.x), upgrade to the latest 1.37.x. Tell me if your production estate is on a specific minor you'd rather mirror.
3. **Channel for labs.** Default: **Stable** for labs 01, 04, 05, and Beta→Stable-style comparisons only in docs. Lab 02 needs an older image plus a newer one on a reachable update server. Without release-host access I'll make lab 02 configurable via `FLATCAR_START_VERSION` and a local Nebraska option, not hardcode URLs I cannot test.
4. **Host OS for the homelab.** I'll assume a Linux host with libvirt/QEMU (`virsh`, `virt-install`, `qemu-img`) and use user-session-safe defaults (`qemu:///system`). Tell me if you use Fedora, Ubuntu, or something else, or want Vagrant or plain QEMU instead.
5. **Task tooling.** Makefile (default; present everywhere) versus `justfile`. I'll use Make unless you prefer `just`.
6. **Tone of the compliance content (doc 8).** I'll frame controls against generic regulated-FS expectations (change management, vulnerability SLAs, SBOM, access control, audit trails). I will not claim Flatcar is certified for any framework unless I verify it upstream. Please tell me if you want it mapped to a specific regime (e.g. PCI DSS, DORA, FCA/PRA, SOC 2, ISO 27001).

## 3. Version pinning status

Verified from primary sources in this session:

- **Butane**: latest tag `v0.29.0`. `docs/specs.md` lists Flatcar stable specs `v1.0.0` and `v1.1.0`, and experimental `v1.2.0-experimental`. **Pin: variant `flatcar`, version `1.1.0`.**
- **Ignition**: latest tag `v2.27.0`. What matters is the Ignition version *baked into the Flatcar image*, which is separate. ⚠️ Verify against the image.
- **RKE2**: tags `v1.37.1+rke2r1` and `v1.36.5+rke2r1` exist (see Q2).
- **Flatcar update operator**: latest tag `v0.10.0`. **Nebraska**: latest tag `4.0.0`. **Image-builder**: latest tag `v0.1.55` (Flatcar support is present upstream; I will cite exact provider docs).
- **Flatcar `main` branch**: `4841.0.0+nightly-20261002-2100` (that is a nightly, not a release; it only tells me the current version train).

**Not verified, and conflicting:** the current Alpha/Beta/Stable/LTS release numbers. WebSearch snippets and the `flatcar/Flatcar` release-issue pages give inconsistent numbers (e.g. August 2026 "Stable 4694.2.0" in one source and "Stable 4593.2.5" in another; one snippet claims Stable 4757.2.1 on 29 Sep). I will **not** write a release number into `VERSIONS.md` as fact until it comes from the release feed or a primary source I can read. `VERSIONS.md` will have a "verified / to-verify" column, and the labs take the version from a variable.

## 4. Source map (what I rely on, per doc)

Official sources only; blogs only when flagged as such.

- Flatcar docs: `flatcar.org/docs/latest` (blocked now; the Markdown source repo `flatcar/flatcar-docs` is archived and moved into `flatcar/flatcar-website`, whose docs are pulled in at build time. I need to find the live path via raw GitHub or request allow-listing).
- Flatcar repos: `flatcar/scripts` (build system, ebuilds, SDK), `flatcar/init` (systemd units, update_engine glue), `flatcar/Flatcar` (central issue tracker and release process), `flatcar/sysext-bakery`, `flatcar/nebraska`, `flatcar/flatcar-linux-update-operator`, `flatcar/update_engine`, `flatcar/bootengine` (initramfs), `flatcar/ignition` (Flatcar's fork/integration), `flatcar/mantle` (image and release tooling), `flatcar/afterburn`.
- Butane: `coreos/butane` docs (`config-flatcar-v1_1.md`, `examples.md`, `getting-started.md`). Ignition: `coreos/ignition` docs (`supported-platforms.md`, `operator-notes.md`, `specs.md`, `migrating-configs.md`).
- Upstream components: `systemd/systemd` sysext/confext man pages, `google/go-containerregistry` n/a.
- RKE2: `rancher/rke2` and the RKE2 docs source repo (to be located); `rancher/system-upgrade-controller`.
- Cluster API: `kubernetes-sigs/image-builder` (Flatcar/Ignition provider docs), CAPV and CAPA book pages on Ignition bootstrap format.
- History/governance: CNCF project page, the Kinvolk and Microsoft announcement posts, Red Hat/CoreOS Container Linux EOL announcement, `flatcar/Flatcar` governance docs. These need dated, linked primary sources; I will not write the history from memory.
- Comparisons: Fedora CoreOS, Bottlerocket, Talos docs (primary), compared on update model, config model, shell access, package extension.

## 5. Deliverables and build order

Structure exactly as specified (`flatcar-deep-dive/` contents at repo root, since the repo itself is already the project directory): `README.md`, `VERSIONS.md`, `GLOSSARY.md`, `docs/01…12`, `docs/diagrams/*.mmd`, `labs/01…06`, `tools/`, `Makefile`.

Order of work after approval:

1. `VERSIONS.md` skeleton, Go module, Makefile scaffold (including a pinned Butane fetch target).
2. Docs 01–12 in order. Each: prose-first, "what / why / why it works that way", inline `> ⚠️ Verify:`, ends with **Key takeaways** and **Sources**.
3. Diagrams (Mermaid, embedded in docs and also stored in `docs/diagrams/`): boot and Ignition flow; A/B update and rollback; update reboot coordination in a cluster; RKE2-on-Flatcar node lifecycle; plus a provisioning-flow diagram (requested in the tree).
4. Labs 01–06, each with README (goal, prerequisites, steps, verification, teardown) and all config files.
5. Go tools (module under `tools/`, with tests):
   - `butanecheck`: validate Butane configs offline against the pinned spec, with strict mode (fail on warnings) and a check that files referenced via `local:` exist.
   - `nodegen`: render per-node Butane from a template plus an inventory file (names, IPs, SSH keys, join tokens), used by labs 04 and 05.
   - Both use Butane as a library (`github.com/coreos/butane/config`), so the transpile path is the real one. Table-driven tests with golden files.

## 6. Validation plan and its limits

I will validate, after each lab:

- Transpile every `.bu` with Butane v0.29.0 (`--strict`) and capture the output.
- Run `go vet` and `go test ./...` for the tools.
- Lint shell with `shellcheck` (will try to obtain it via Go/GitHub release if reachable; otherwise `bash -n` and say so).
- Check unit syntax with `systemd-analyze verify` if available.

I **cannot** validate here (and will list this per lab in its README and in a final report):

- Booting any Flatcar image, Ignition applying correctly, partition layout output, update/rollback, sysext merge, KTHW cluster bring-up, RKE2 bring-up, upgrade coordination. These need KVM and release-host access.
- vSphere and AWS delivery (lab 06 is doc-only, as you allowed).

Labs will print expected output as *"expected shape"*, never as captured output I didn't produce. I'll label anything unproduced that way.

## 7. Risks I'm flagging early

- **Doc accuracy without flatcar.org.** If the allow-list isn't widened, docs about runtime details (partition table, `update_engine` behaviour, `locksmith`/`flatcar-update` flags, `update.conf` keys) will rest on source code in `flatcar/*` repos, which is strong evidence but slower. I'll prefer reading source for flags/paths/unit names and mark gaps.
- **Known-moving items** I'll mark with `> ⚠️ Verify:`: Flatcar Butane spec fields (v1.1.0 vs experimental v1.2.0), sysext "enable by default" handling and the `/etc/flatcar/enabled-sysext.conf` mechanism, bundled containerd/Docker versions, FLUO maturity, `kured` on Flatcar, RKE2 install-method paths on read-only `/usr` (including `INSTALL_RKE2_TAR_PREFIX` and `/opt/rke2` vs `/usr/local`), SELinux status on Flatcar, and CAPI image-builder provider specifics.
- **Scope.** This is a large body of work (12 docs, 6 labs, 2 tools). I'll deliver in the stated order and commit per phase on `claude/sweet-brown-brn6ff`, so you can stop and redirect after any phase.

## 8. What I need from you to proceed

Approve or amend this plan, and answer §2 (at minimum Q1, since it determines how verifiable the docs can be, and Q2).
