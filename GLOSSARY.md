# Glossary

Short definitions with a pointer to the document that explains each term properly. Where a term is used differently by different projects, the entry says whose meaning it is.

**A/B partitions (USR-A, USR-B).** Flatcar keeps two copies of the read-only OS partition. Updates are written to the inactive one and activated by a reboot; the old one remains for fallback. Docs 03, 04.

**Afterburn.** Flatcar's per-platform metadata agent (`coreos-metadata.service`), which reads cloud metadata (instance ID, IPs, SSH keys) and writes `/run/metadata/flatcar`. It also feeds network kernel arguments to the initrd on some platforms. Doc 05.

**AMI.** Amazon Machine Image. Flatcar publishes them per region and un-publishes old ones. Docs 05, 09.

**bakery (sysext-bakery).** Community repository of recipes and prebuilt system extensions (Kubernetes, RKE2, k3s, Cilium, and others) with a systemd-sysupdate-compatible release index. Doc 06.

**Butane.** The human-friendly YAML format that is transpiled to Ignition JSON. The `flatcar` variant at spec version `1.1.0` emits Ignition spec `3.4.0`. Doc 05.

**CAPI, CAPV, CAPA.** Cluster API, and its vSphere and AWS infrastructure providers. They bootstrap Flatcar nodes with Ignition behind feature flags. Doc 09, lab 06.

**cgpt.** The ChromeOS-derived tool for reading and setting GPT partition attributes (`priority`, `tries`, `successful`) that drive A/B selection. Docs 04, lab 02.

**confext.** systemd-confext: like a sysext but overlaying `/etc`. Recent Flatcar releases compose `/etc` with it by default. Docs 04, 06, `VERSIONS.md`.

**dm-verity.** Kernel device-mapper target that verifies each block of a read-only device against a hash tree as it is read. It protects Flatcar's `/usr`. Doc 04.

**`fw_cfg`.** QEMU's firmware configuration interface. Flatcar's QEMU wrapper passes Ignition through the `opt/org.flatcar-linux/config` entry. Doc 05, all labs.

**FLUO (flatcar-linux-update-operator).** A Kubernetes operator that coordinates Flatcar reboots with node annotations, a drain, and optional before- and after-reboot checks. Doc 07.

**GPT priority, tries, successful.** The three attributes per USR partition. The bootloader boots the highest priority with tries left; `update_engine` sets `successful` after a good boot. Docs 04, lab 02.

**gptprio.** The GRUB module that implements that selection. Doc 04.

**guestinfo.** VMware's mechanism for passing key-value configuration into a VM. Flatcar reads `guestinfo.ignition.config.data` (base64) and `.url`. Doc 05, lab 06.

**Ignition.** The provisioning tool that runs once, in the initrd, on first boot: it partitions, writes files, creates users and defines units from a JSON config, then never runs again on that disk. Doc 05.

**IMDS.** The EC2 instance metadata service, from which Ignition reads user data on AWS. Doc 05, lab 06.

**kola / mantle.** Flatcar's test harness and release tooling, in the `mantle` repository. Doc 11.

**KTHW.** *Kubernetes the Hard Way*, Kelsey Hightower's tutorial that installs every control-plane and node component by hand. Doc 12, lab 04.

**kured.** The Kubernetes Reboot Daemon: watches a sentinel file (Flatcar creates `/run/reboot-required` when an update is staged), then takes a cluster-wide lock, drains and reboots, one node at a time by default. Doc 07, lab 05.

**locksmith (`locksmithd`).** Flatcar's own reboot manager, with strategies such as `etcd-lock` and `reboot`. You mask it when kured or FLUO does the job. Doc 07.

**Nebraska.** The open-source Omaha-compatible update server for Flatcar, with groups, channels and rollout policy. Doc 07.

**Omaha.** The update protocol (from ChromeOS) that `update_engine` speaks to the update server. Doc 07.

**OEM partition.** The partition mounted at `/oem` (also visible as `/usr/share/oem`) holding platform-specific material; `update_engine`'s post-install also calls an optional hook there. Doc 04.

**RKE2.** SUSE/Rancher's hardened Kubernetes distribution, with embedded containerd, etcd, and its own installer and upgrade tooling. Doc 10, lab 05.

**ROOT.** Flatcar's writable root partition (`/etc`, `/var`, `/opt`, `/home`). It survives OS updates and is the only place state lives. Doc 04.

**rke2-upgrade.** The container image that system-upgrade-controller runs to replace the RKE2 binary in place and restart the service. Doc 10.

**Safe mode, floor packages.** Nebraska rollout controls. Safe mode caps the first rollout of a version at one node (a canary) and disables updates for the group if timed-out updates reach the maximum. Floor packages are mandatory intermediate versions clients must install before the target. Doc 07.

**SLSA.** Supply-chain Levels for Software Artifacts. Flatcar publishes a self-assessed level for its builds. Doc 03.

**SUC (system-upgrade-controller).** Rancher's Kubernetes controller that runs upgrade jobs on nodes selected by `Plan` objects. Doc 10, lab 05.

**sysext.** systemd system extension: a read-only image (squashfs in lab 03) merged over `/usr` using an `extension-release` file that names the compatible OS. Docker and containerd ship this way on Flatcar. Doc 06, lab 03.

**systemd-sysupdate.** The systemd tool that updates versioned artifacts (such as sysext images) from a transfer definition and a release index. Doc 06, lab 03.

**torcx.** An earlier Flatcar add-on mechanism that the project retired in favour of system extensions. I could not read the announcement, so doc 06 does not describe how it worked.

**update_engine.** The daemon that polls the update server, downloads payloads to the inactive partition, and marks a boot successful. Docs 04, 07.

**vSphere OVA.** The image format Flatcar publishes for VMware. Doc 05, lab 06.
