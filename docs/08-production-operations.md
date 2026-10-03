# 08 — Production operations: observability, debugging, CVEs, compliance, comparison, and when not to use Flatcar

This document is the evaluation document. It covers how you see and debug a node you are not supposed to log into,
how security fixes reach you and how fast, what a compliance reviewer in a regulated financial-services estate will ask and
which of those questions Flatcar answers well, how it compares with Fedora CoreOS, Bottlerocket and Talos, and where it is
the wrong choice. The compliance material is deliberately generic: it frames controls and evidence, and does not claim that
Flatcar satisfies any specific regime, because nothing I could read upstream says so.

## Observability on a host you do not log into

Flatcar gives you the systemd baseline and leaves everything else to you. Logs go to the journal; the project documents
reading them with `journalctl`, and collecting kernel crash logs ([system log][syslog], [crash logs][crash]). The base image
includes `tcpdump`, `strace`, `bpftool`, `lsof`, `iproute2`, `ethtool`, `nvme-cli` and `mayday`, a diagnostic collection tool
([base package list][coreos-ebuild]). It does not ship a metrics agent; you run one as a container or a sysext.

What is worth instrumenting is specific to this model, because the OS has its own state machine:

- **OS version and channel per node.** `/usr/share/flatcar/os-release` and `/usr/share/flatcar/update.conf` give the running OS and the channel baked in; `/etc/flatcar/update.conf` shows the group for the next update ([channels][channels]). The question "which nodes are not on the target version" is the core of CVE reporting.
- **Update state.** `update_engine_client -status` reports the state machine and `journalctl -u update-engine` explains failures (doc 07). Export `UPDATE_STATUS_UPDATED_NEED_REBOOT` age: a node staged for days is a node that missed its window.
- **Slot health.** `cgpt show "$(rootdev -s /usr)"` shows `priority`, `tries` and `successful`; a slot with `successful=0` that is running is an update the node has not yet confirmed.
- **Reboot controller state.** FLUO publishes node annotations (`reboot-needed`, `status`, `new-version`, `last-checked-time`), and kured exports Prometheus metrics and supports alert-based blocking (doc 07).
- **Update server view.** If you run Nebraska, its group view of instance versions and update statuses is the fleet-wide picture ([Nebraska README][nebraska-readme]).
- **Extensions.** `systemd-sysext status` and the list in `/etc/extensions` tell you which extensions are merged and which version (doc 06). A node that fails to merge one logs it and continues booting, so a silent absence is possible.

A reasonable minimum is a node exporter plus a small textfile or custom collector that emits the first four as metrics, and
alerts for "staged longer than N hours", "version lag against target", and "slot not marked successful N minutes after boot".

## Debugging a minimal host

The base image is not hostile to debugging; it is hostile to *installing* debugging tools. Three tools cover most cases.

**Toolbox.** `/usr/bin/toolbox` launches a container (by default a Fedora image) with full system privileges and the host
filesystem mounted at `/media/root`, so you install `dnf` packages into the container, not the host. It uses `systemd-nspawn`,
keeps the exported image under `/var/lib/toolbox/USER-IMAGE-TAG` (so changes persist between sessions and take disk), and
accepts a custom image through `~/.toolboxrc` (`TOOLBOX_DOCKER_IMAGE`, `TOOLBOX_DOCKER_TAG`, `TOOLBOX_USER`), which you can
write from Butane ([debugging tools][toolbox]). For a regulated estate, point `TOOLBOX_DOCKER_IMAGE` at a vetted image in your
registry; the default pulls an unpinned public image onto a production node.

**What is already there.** Because strace, tcpdump, bpftool, lsof and the usual network and storage utilities are in the image,
many problems do not need toolbox at all.

**Emergency access when things break.** If Ignition fails, the node drops to an emergency shell in the initrd where
`journalctl -u 'ignition*'` shows the cause (doc 05). If the console is stuck, boot with
`systemd.journald.max_level_console=debug console=ttyS0`. For a node that will not boot after an update, the A/B scheme
already did the recovery: it fell back to the previous slot (doc 04).

**Access policy.** Flatcar has one default login user, `core`, which "by default has access to the wheel group which grants
sudo access" and the `docker` group, "which grants similar capabilities to sudo" on a node with Docker running. The hardening guide's
suggestions are to require a password for sudo but not set one, to set `core`'s shell to `/sbin/nologin`, to restrict the Docker
socket to root, and to stop `sshd.socket` entirely if you do not need SSH ([hardening guide][hardening]). The only service
listening by default is sshd on port 22 on all interfaces. A node you have configured with no SSH and no `core` login is the
closest Flatcar gets to the API-only posture of Talos, at the cost of having no way in except re-provisioning or a console.

## CVE response and patch cadence

Security work is owned by the Flatcar Security team, a subset of the maintainers, which meets fortnightly and rotates a
primary and secondary weekly. The primaries run a daily runbook against upstream trackers (Gentoo security advisories,
oss-security, Go and Rust announce lists) and file a GitHub issue per CVE labelled `security` and `advisory`. Fixes ship as new OS
images: "Security issues are addressed by releasing an updated OS image. Releases may be expedited depending on the issues'
severity. For each release, release notes contain a concise list of security issues fixed. Also, a separate, detailed report
on each of the issues addressed is part of every release" ([SECURITY.md][security-md]).

The planned cadence is a release every 14 days within each channel, with expedited releases for severe issues
([RELEASES.md][releases]). The effective patch latency for your estate is therefore the sum of three terms you can measure:
the time from CVE publication to a Flatcar release, the time from the release to your update server granting it, and the time from
staging to your reboot manager rebooting the last node. The first is the project's; the other two are yours, and the second is
a deliberate soak (doc 07). Your vulnerability-management SLA has to be written against the sum.

Two practical points. The release notes carry the CVE list, and the website data in the release feed is structured (YAML per release),
so you can build automated "is CVE-X fixed in the version I run" checks from it. And because every node of a version is
identical, a scanner result for one node is a result for the version, so scan images once, in the pipeline, instead of scanning every node.

LTS changes the trade: it "only gets bug fix releases" with critical security updates, on an 18-month stream (doc 03). Its components
are older (Stable 4757.2.1 carries kernel 6.12.111 and containerd 2.2.5; LTS 4081.3.10 carries kernel 6.6.150 and containerd 1.7.21), so
whether a given CVE is fixed in the LTS depends on backporting by the project.

> ⚠️ Verify: backporting policy. The LTS description says critical security fixes, but I did not find a published definition of
> "critical" or a service-level objective for time to fix. Ask the project, or check the release notes of recent LTS releases
> against a list of recent high-severity CVEs, before you put LTS in an SLA.

## Compliance considerations for a regulated financial-services estate

I am framing these as control families a reviewer asks about, with what Flatcar gives you as evidence and what you must still supply.
It is not a mapping to a framework, and nothing here says Flatcar is certified or compliant with anything.

**Change management and patch evidence.** Flatcar's strength: the host baseline is an artifact. The OS version is a single string
per node, the configuration is a document in version control, and updates are visible as discrete state transitions with logs and, with
Nebraska, a server-side record of who was offered what and when. You still need to capture the evidence: archive the Butane source,
the transpiled Ignition, and the release notes for each version you deploy.

**Integrity and supply chain.** What exists: signed release images (GPG, 4096-bit RSA, one-year key life), signed update payloads (a
separate HSM-held key), dm-verity on `/usr`, per-package SLSA provenance under `/usr/share/SLSA/`, a self-assessed SLSA Level 3,
Secure Boot support with signed kernel modules, and signed OS-dependent extensions (doc 03, doc 06). What you must add: image
signature verification in your provisioning pipeline, pinned hashes on anything fetched by Ignition, a controlled mirror for the update
server and extension hosts, and a decision about community sysexts, whose sysupdate configuration ships `Verify=false` (doc 06).
Where the project is candid about gaps (non-hermetic builds, no TPM-anchored chain, build-system changes needing no second
approver) you should list them in your risk register rather than discover them later.

**Access control and auditing.** The default is a single `core` user with sudo and the Docker socket, and password-less SSH key
login. Harden as the guide says. Auditing is off by default: `audit-rules.service` loads rules, but a default ignore rule suppresses the standard
ones and `auditd.service` does not run; the audit guide shows a Butane config that overrides the ignore rule and enables `auditd`
([audit][audit]). Ship the journal and audit log off the node, because the node is disposable.

**Data protection at rest.** Flatcar supports LUKS root and data volumes, with TPM2-backed unlock through `systemd-cryptenroll` or Clevis
(Tang or TPM2), supported from Flatcar 3913.0.1 for TPM2-backed root encryption. The project is blunt that binding to the full PCR state is
brittle because GRUB measures configuration and updates change the measured state; it works reliably "only when auto updates are disabled
and when the first-boot setup is not involved", and offers patterns that unbind during update reboots ([LUKS][luks]). Plan encryption
with your update model, not after it.

**Cryptography.** The FIPS page says it directly: "While Flatcar is not officially FIPS certified, it is possible to deploy it so that
it is compliant with two of these standards", FIPS 200 and FIPS 140-2: boot with `fips=1`, create `/etc/system-fips`, and enable the
OpenSSL 3 FIPS provider, which is built by default ([FIPS][fips]). If your regulator needs a validated cryptographic module attestation on the
whole OS from a vendor, read that sentence carefully before proceeding.

> ⚠️ Verify: the Flatcar trusted-computing page still describes TPM 1.2 support and says TPM 2.0 "will be added in a future release",
> while the LUKS page documents TPM2-backed encryption from 3913.0.1. The trusted-computing page appears stale. Treat the LUKS page as current
> and test on your hardware or hypervisor vTPM.

**Mandatory access control.** Flatcar implements SELinux but "does not enforce SELinux protections by default"; enforcing mode is a documented
procedure, with limitations (incompatible with btrfs volumes and with volumes shared between containers; some CNI issues with Flannel releases)
([SELinux][selinux]). If your baseline requires enforcing SELinux, you will configure and test it yourself, and RKE2's SELinux support (a
policy package the tarball install does not include) has to be sorted out too (doc 10).

**Benchmarks.** The only CIS reports in the project repository are from December 2020, produced with a community InSpec profile; the project
notes many results are "not applicable" for a single-purpose OS and some fail because of file-system layout ([CIS reports][cis]). They are not
a current attestation. Expect to author and maintain your own benchmark mapping for the immutable layout.

**Vendor support and continuity.** Flatcar is a community project. The 2022 post mentions earlier commercial "Pro" images and a subscription
by Kinvolk; I did not find in the sources I read what commercial support options exist today, nor who provides them.

> ⚠️ Verify: current commercial support and SLAs for Flatcar, and whether your auditors accept community-supported OS software for in-scope
> systems. This is a procurement and risk question the repositories cannot answer.

## How it compares

All facts below come from each project's own documentation in the snapshots listed in Sources. "—" means I did not verify it.

| Dimension | Flatcar | Fedora CoreOS | Bottlerocket | Talos Linux |
|---|---|---|---|---|
| Intended scope | General container host; Kubernetes optional | General container host, "optimized for Kubernetes but also great without it" | Host OS for containers, focused on EKS, ECS and VMware Kubernetes variants | Kubernetes only: it "also runs the Kubernetes control plane components including the etcd database" |
| OS update unit | Whole `/usr` partition image (A/B) via an Omaha client (`update_engine`) and Nebraska | OSTree deployments via `rpm-ostree`, driven by Zincati | Partition flips, images secured by TUF; API-driven; update operator for EKS | Installer image via API, A-B image scheme, previous kernel and OS retained |
| Who triggers the reboot | A reboot manager you choose (locksmith, FLUO, kured) | Zincati strategies: immediate, external lock manager, or weekly UTC maintenance windows | Bottlerocket update operator, or update API | You, via `talosctl upgrade` (API) |
| First-boot configuration | Ignition via Butane (`flatcar` variant) | Ignition via Butane (`fcos` variant) | Settings in TOML user data, modelled and migrated across updates | Machine configuration (YAML documents) applied through the API |
| Interactive access | SSH to `core` by default; can be disabled | SSH keys; password login off by default | No SSH server and not even a shell; control and admin containers on request | No shell or interactive console; API with mTLS |
| Adding host software | System extensions (sysext), bakery, custom image | `rpm-ostree install` layering (a documented, supported route), or Bootc | — (variant images; see their docs) | System extensions via an image factory |
| SELinux default | Implemented, permissive by default | Enforcing | — | — |
| Network config | systemd-networkd | NetworkManager | — | — |
| etcd on the host image | etcd and etcd-wrapper in the base package list | Not included (run as a container) | — | Runs etcd as part of Talos |
| Steward | CNCF project, maintainer council | Fedora Project | Amazon (README: "what we've learned building operating systems and services at Amazon") | Sidero Labs |

Facts behind the less obvious cells: Fedora CoreOS's own migration page says it is "the official successor of CoreOS Container Linux", that network
configuration moved to NetworkManager, that `etcd` is not included, and that locksmith's function is "rolled into" Zincati ([FCOS migration][fcos-migrate]).
Its SELinux page says it ships "in enforcing mode" ([FCOS SELinux][fcos-selinux]). Zincati's rollout wariness is a per-node value from 0.0 (most eager)
to 1.0 (most conservative) that lets the server stage a rollout across a fleet ([FCOS auto-updates][fcos-updates]). Bottlerocket's README states that
"there's no SSH server in a Bottlerocket image, and not even a shell", that its filesystem and dm-verity setup "will prevent most changes from persisting over
a restart", and that user data is TOML ([Bottlerocket README][bottlerocket]). Talos's docs say all management is by API with "no shell or interactive console"
and all API access uses mTLS ([Talos README][talos], [upgrading Talos][talos-upgrade]).

What this means in practice, by difference rather than by feature:

- **Flatcar versus Fedora CoreOS.** They share Ignition and Butane, so skills and many configs transfer, and both are generic container hosts. The substantive differences are the update mechanism (a whole-partition A/B image versus OSTree deployments), the extension model (sysext versus package layering, which is more flexible for adding arbitrary software and also weakens the "fixed content per release" property), SELinux posture (enforcing by default on FCOS), the network stack, and a built-in reboot-coordination story on FCOS (Zincati) versus Flatcar's pluggable one.
- **Flatcar versus Bottlerocket.** Bottlerocket is more opinionated and more locked down: no shell, a settings API, orchestrator-specific variants. If you run EKS or vSphere Kubernetes workers and want the smallest surface and have no need for host-level customization, it is a strong candidate. Flatcar is the better fit if you need a general OS with Ignition provisioning across platforms and room to add host software.
- **Flatcar versus Talos.** Talos removes the shell and SSH entirely and makes Kubernetes the OS's job, including control-plane management; that is the cleanest answer to "nobody logs in" and it also constrains you to Talos's model of managing Kubernetes. Flatcar leaves Kubernetes to you (kubeadm, RKE2, CAPI) and keeps ordinary Linux administration available.

> ⚠️ Verify: Bottlerocket's SELinux default, package and extension model, and Talos's exact A/B mechanics and secure-boot posture are not in
> the pages I read. Check their security documentation before you put either column into a formal option analysis.

## When not to use Flatcar

An honest list, in rough order of how often it applies to estates like yours:

1. **You need a vendor-supported OS with attestations your regulator will name.** FIPS-validated cryptographic modules for the whole OS, an official STIG or CIS-certified baseline, or a named commercial support contract with an SLA are things the project does not offer in the sources I read. RHEL, SLES, SLE Micro or Ubuntu Pro with a support contract are the conventional answers.
2. **Your Kubernetes distribution's vendor must support the OS.** For RKE2 and Rancher in production, check the SUSE support matrix before choosing Flatcar. The RKE2 requirements page says RKE2 "should work on any Linux distribution that uses systemd and iptables/nftables" and refers to the support matrix for validated OSes; I could not read that matrix, and nothing in the RKE2 repositories mentions Flatcar (doc 10). If SUSE support for the node OS is a requirement, you may be choosing between supported and convenient.
3. **Your workloads cannot take routine node reboots.** The model assumes nodes are replaceable and rebooted on a cadence (doc 07). Stateful workloads bound to local disk, long-running batch with no checkpointing, or license-bound appliances do not fit.
4. **You depend on host-level agents distributed as OS packages.** EDR, backup, monitoring and certificate-management agents that ship as RPM or DEB and expect to install into `/usr` and `/etc` will need containers, sysexts you build yourself, or a custom image, and some vendors will not support that.
5. **You need enforcing SELinux or a hardened-by-default baseline out of the box.** You can get there on Flatcar, but you do the work and carry the compatibility limits; Fedora CoreOS, Bottlerocket or Talos start closer.
6. **You have no capacity to own the pipeline.** Flatcar moves effort into first-boot configuration as code, update-server operation, reboot coordination, extension provenance and your own benchmark mapping. A team without that capacity will do better with a managed node service or a more opinionated OS with a vendor behind it.
7. **You need Kubernetes lifecycle managed as part of the OS.** If you want one tool to bootstrap, upgrade and replace nodes together, Talos (with its management plane) is closer to that than Flatcar plus separate tooling.
8. **Your vSphere estate relies on guest customization and static addressing at scale.** It works, with the constraints in doc 05 (guestinfo encoding, DHCP-in-initrd or `afterburn` kernel arguments for static IPs, no generic metadata agent), but expect more integration work than a cloud-init-based image gets.

## Key takeaways

- Observe the OS's own state machine (version, staged-update age, slot `successful` flag, reboot-controller state) in addition to ordinary metrics; there is no built-in agent.
- Debugging uses toolbox and the tools already in the image; the default `core` user has sudo and Docker-group access, so harden it and ship logs off the node.
- Patch latency is your measured sum of project release time, your rollout soak and your reboot cadence; the project cadence is every 14 days with expedited releases for severe issues.
- Flatcar provides strong integrity evidence (signed images and payloads, dm-verity, provenance) but is not FIPS certified, defaults to permissive SELinux, ships only 2020 CIS reports, and has audit off by default.
- Choose Flatcar for a general, Ignition-provisioned immutable host with extension room; choose differently if you need vendor-attested compliance, vendor-supported RKE2 on the node OS, or an API-only, no-shell posture.

## Sources

- Flatcar hardening, audit, FIPS, SELinux, LUKS/TPM, trusted computing: [`security/hardening/hardening-guide.md`][hardening], [`audit.md`][audit], [`fips.md`][fips], [`security/encryption/selinux.md`][selinux], [`luks.md`][luks]
- Security process: [`flatcar/Flatcar SECURITY.md`][security-md]; releases and cadence: [`RELEASES.md`][releases]; CIS reports: [`flatcar/Flatcar CIS`][cis]
- Debugging tools: [`diagnostics/install-debugging-tools.md`][toolbox], [system log][syslog], [crash logs][crash]
- Base package list: [`coreos-0.0.1.ebuild`][coreos-ebuild]; channels: [`switching-channels.md`][channels]; Nebraska: [README][nebraska-readme]
- Fedora CoreOS: [auto-updates][fcos-updates], [SELinux][fcos-selinux], [migrating from Container Linux][fcos-migrate], [OS extensions](https://github.com/coreos/fedora-coreos-docs/blob/1fec1acb5437220c559b8833e0ef1d643edd918b/modules/ROOT/pages/os-extensions.adoc), docs snapshot `1fec1ac`
- Bottlerocket: [README][bottlerocket], snapshot `b2e2bee`
- Talos: [README][talos], [upgrading Talos v1.14][talos-upgrade], [what is Talos](https://github.com/siderolabs/docs/blob/32d01902f6339c8cd0ac3a36eeb6ba39f2ba1f33/public/talos/v1.14/overview/what-is-talos.mdx), snapshot `3663614`
- RKE2 requirements (OS statement): [`install/requirements.md`](https://github.com/rancher/rke2-docs/blob/9780f57568e0e4a922403d2f0ce249cef503af2f/docs/install/requirements.md)

[syslog]: https://github.com/flatcar/flatcar-website/blob/415d66a7b79efa4374b927a4cd6d7b5bd1bfeb9c/content/docs/latest/diagnostics/reading-the-system-log.md
[crash]: https://github.com/flatcar/flatcar-website/blob/415d66a7b79efa4374b927a4cd6d7b5bd1bfeb9c/content/docs/latest/diagnostics/collecting-crash-logs.md
[toolbox]: https://github.com/flatcar/flatcar-website/blob/415d66a7b79efa4374b927a4cd6d7b5bd1bfeb9c/content/docs/latest/diagnostics/install-debugging-tools.md
[hardening]: https://github.com/flatcar/flatcar-website/blob/415d66a7b79efa4374b927a4cd6d7b5bd1bfeb9c/content/docs/latest/security/hardening/hardening-guide.md
[audit]: https://github.com/flatcar/flatcar-website/blob/415d66a7b79efa4374b927a4cd6d7b5bd1bfeb9c/content/docs/latest/security/hardening/audit.md
[fips]: https://github.com/flatcar/flatcar-website/blob/415d66a7b79efa4374b927a4cd6d7b5bd1bfeb9c/content/docs/latest/security/hardening/fips.md
[selinux]: https://github.com/flatcar/flatcar-website/blob/415d66a7b79efa4374b927a4cd6d7b5bd1bfeb9c/content/docs/latest/security/encryption/selinux.md
[luks]: https://github.com/flatcar/flatcar-website/blob/415d66a7b79efa4374b927a4cd6d7b5bd1bfeb9c/content/docs/latest/security/encryption/luks.md
[channels]: https://github.com/flatcar/flatcar-website/blob/415d66a7b79efa4374b927a4cd6d7b5bd1bfeb9c/content/docs/latest/updates-releases/releases/switching-channels.md
[security-md]: https://github.com/flatcar/Flatcar/blob/42d9daa78c15f0c2d8f370bb7516de95cfb23819/SECURITY.md
[releases]: https://github.com/flatcar/Flatcar/blob/42d9daa78c15f0c2d8f370bb7516de95cfb23819/RELEASES.md
[cis]: https://github.com/flatcar/Flatcar/tree/42d9daa78c15f0c2d8f370bb7516de95cfb23819/CIS
[coreos-ebuild]: https://github.com/flatcar/scripts/blob/2189f1e166e28c06cdcd1b26fea47f05da78c139/sdk_container/src/third_party/coreos-overlay/coreos-base/coreos/coreos-0.0.1.ebuild
[nebraska-readme]: https://github.com/flatcar/nebraska/blob/4c0f1759879206f80dbcf9943853cf4635429c1a/README.md
[fcos-updates]: https://github.com/coreos/fedora-coreos-docs/blob/1fec1acb5437220c559b8833e0ef1d643edd918b/modules/ROOT/pages/auto-updates.adoc
[fcos-selinux]: https://github.com/coreos/fedora-coreos-docs/blob/1fec1acb5437220c559b8833e0ef1d643edd918b/modules/ROOT/pages/selinux.adoc
[fcos-migrate]: https://github.com/coreos/fedora-coreos-docs/blob/1fec1acb5437220c559b8833e0ef1d643edd918b/modules/ROOT/pages/migrate-cl.adoc
[bottlerocket]: https://github.com/bottlerocket-os/bottlerocket/blob/b2e2beeaa3384c616c4cb0e2b05b7686cdd41253/README.md
[talos]: https://github.com/siderolabs/talos/blob/3663614ba772f02acce10ed0d06405d48e8f5b2d/README.md
[talos-upgrade]: https://github.com/siderolabs/docs/blob/32d01902f6339c8cad0ac3a36eeb6ba39f2ba1f33/public/talos/v1.14/configure-your-talos-cluster/lifecycle-management/upgrading-talos.mdx
