# 09 — Flatcar with Kubernetes: runtime, kubelet, Cluster API, and how images track Kubernetes versions

This document is about the seam between the OS and Kubernetes in general, before the RKE2-specific material in doc 10. You
know what a kubelet needs from a host. The questions here are where each of those things comes from on Flatcar, which of the
several ways of installing Kubernetes components fits which operating model, how Cluster API builds and bootstraps Flatcar
nodes on vSphere and AWS, and what "the node image version" even means when the OS and Kubernetes move on different schedules.

## What Flatcar provides to Kubernetes, and what it does not

Flatcar is a container host. It does not ship Kubernetes. The project tests "a Kubernetes basic scenario (deploy a simple Nginx)"
across channels and CNIs using vanilla components and Flatcar-provided software, and publishes a compatibility matrix: in the docs
snapshot Alpha, Beta, Stable and LTS (2024) are tested with Kubernetes 1.35, 1.36 and 1.37, with 1.32 through 1.34 marked as
"known for working" but no longer tested before a release. The tested CNIs are Cilium, Flannel and Calico; one known issue is that
Flannel newer than 0.17.0 does not work with enforced SELinux ([Kubernetes on Flatcar][k8s-doc]). "Tested" here means a smoke test
of installation and a simple workload; it is not a conformance or performance guarantee.

What the node image gives a kubelet:

- **A container runtime.** containerd ships as the `containerd-flatcar` system extension, enabled by default, and Docker as `docker-flatcar` (doc 06). The CRI plugin is enabled by default and the Flatcar docs state that recent Kubernetes versions "will prefer containerd over Docker automatically". The containerd socket is `/run/containerd/containerd.sock`, the root is `/var/lib/containerd`, and the shipped configuration at `/usr/share/containerd/config.toml` enables SELinux labelling and `SystemdCgroup = true` ([containerd config][containerd-config]). A copy at `/etc/containerd/config.toml` overrides it ([customizing Docker][customizing-docker]).
- **cgroup v2.** From Flatcar 2969.0.0 the unified hierarchy is the default; nodes updated from older releases were kept on cgroups v1 by a post-update script until you migrate them ([unified cgroups][cgroups]). kubelet, containerd and Docker must agree on the cgroup driver; Flatcar's containerd defaults to the systemd driver.
- **Host tools.** `crictl` (via `cri-tools`), `iptables` and `nftables`, `conntrack-tools`, `ipset`, `ipvsadm`, `socat`, `nfs-utils`, `open-iscsi`, LVM, mdadm and `wireguard-tools` are in the base package list ([ebuild][coreos-ebuild]), which removes a class of "install the prerequisite packages" steps from the kube-adm style docs.
- **A writable place for kubelet plugins.** The base layout links `/usr/libexec/kubernetes/kubelet-plugins/volume/exec` to `/var/kubernetes/kubelet-plugins/volume/exec`, so components expecting to write under `/usr/libexec` end up in `/var` ([baselayout][baselayout]). The official kubeadm examples additionally set `volume-plugin-dir` and `flex-volume-plugin-dir` to `/opt/libexec/kubernetes/...` for the non-sysext variant.
- **etcd, if you want it.** The base list includes `etcd` and `etcd-wrapper`, but nothing in the Kubernetes docs requires them.

What it does not give you: the kubelet, kubeadm, kubectl, CNI plugin binaries, or any cluster state. And it deliberately does not run
your reboot policy for you (doc 07).

## Where the kubelet and its siblings live

On a mutable distribution you install `kubelet` as a package. On Flatcar you have four ways to place it, and the choice is the
real design decision.

| Option | How | Update model | Fits when |
|---|---|---|---|
| `kubernetes` sysext (community bakery) | Ignition downloads `kubernetes-vX.Y.Z-x86-64.raw` to `/opt/extensions/kubernetes/`, links it at `/etc/extensions/kubernetes.raw`, ships `kubelet.service` and a kubeadm drop-in | `systemd-sysupdate` within a minor, flag file `/run/reboot-required`, reboot via kured; or replace the node | You want in-place patch updates and a versioned, hash-pinned artifact |
| Plain binaries in `/opt/bin` | Ignition `files` with `source:` (ideally with a `verification.hash`) plus unit files from the `kubernetes/release` templates | None in place; replace the node | Simple, no extension machinery; you rebuild nodes to change versions |
| Baked image (image-builder) | Packer and Ansible install into `/opt` and write the image | None in place; build a new image | You want immutable golden images and Cluster API |
| Distro tarball (RKE2, K3s) | Distro's own installer or sysext | See doc 10 | You run that distribution |

The Flatcar Kubernetes page gives both the sysext and `/opt/bin` variants for kubeadm. The sysext variant ships these notable details,
visible in the bakery's unit files: the extension's `kubelet.service` is `ExecStart=/usr/bin/kubelet`, and its kubeadm drop-in
runs `ExecStartPre` steps that create `/opt/cni/bin`, copy the CNI plugins from `/usr/local/bin/cni/.` into it, copy the version
file to `/etc/kubernetes-version`, and create the kubelet plugin directory, so the CNI binaries land on the writable root where
containerd looks for them ([bakery kubernetes sysext][bakery-k8s-unit]). The `/opt/bin` variant needs `Environment="PATH=...:/opt/bin"`
in units that call `kubeadm`, because `/opt/bin` is not on the default PATH of systemd units.

The kubelet-wrapper approach of the CoreOS era is gone: the 2020 announcement lists the `kubelet-wrapper` and `rkt` among legacy
components Flatcar would deprecate ([2020 post][eol-post]). Nothing in current Flatcar docs runs the kubelet in a container.

Two constraints about extension-delivered kubelets matter operationally. The bakery documents that "Updates are only supported within
the same minor release, e.g. v1.32.2 -> v1.32.3; never across releases", because "upstream Kubernetes does not support unattended
automated upgrades across minor releases". And an OS rollback does not roll back the extension (doc 06), so a sysupdate that moves
the kubelet from 1.36.3 to 1.36.5 followed by an OS rollback leaves the older OS with the newer kubelet, which is within skew policy
but is a state you did not plan for.

## Container runtime: Docker, containerd, and the CRI socket

Since Kubernetes 1.24 removed dockershim, the supported path is containerd directly. The Flatcar docs retain the older guidance for
kubelets that run in a container: bind-mount `/run/docker/libcontainerd/`, `/run/containerd/` and `/var/lib/containerd/`, expose the
`containerd-shim-runc-v1` and `-v2` binaries, and point the kubelet at `unix:///run/containerd/containerd.sock`
([Kubernetes on Flatcar][k8s-doc]). On a host kubelet you only need the socket, which is the default.

If you remove the `docker-flatcar` extension (symlink to `/dev/null`) to ensure nothing else uses the runtime, `containerd-flatcar` remains
unless you remove it too; remove both only if your Kubernetes distribution brings its own containerd, as RKE2 does (doc 10).

## Cluster API: building images with image-builder

Cluster API (CAPI) treats machines as immutable and replaceable, which matches Flatcar's model. Flatcar images for CAPI are built with
Kubernetes SIGs' image-builder, which has Flatcar targets for AWS (`build-ami-flatcar`, `build-ami-flatcar-arm64`), vSphere OVA
(`build-node-ova-vsphere-flatcar`, `build-node-ova-local-flatcar`), QEMU, OpenStack, Azure SIG, Nutanix, Proxmox, Hetzner, Outscale
and raw images ([image-builder Makefile][ib-makefile]). The Flatcar CAPI provider list in Flatcar's docs names AWS, Akamai/Linode, Azure,
KubeVirt, OpenStack, Proxmox and vSphere ([Kubernetes on Flatcar][k8s-doc]).

The way image-builder installs Kubernetes on Flatcar is revealing. Its Flatcar variable files set `kubernetes_source_type: http` and
`kubernetes_cni_source_type: http` (download binaries from upstream rather than a package manager), `sysusr_prefix` and
`sysusrlocal_prefix` to `/opt`, and `systemd_prefix` to `/etc/systemd`, with Ansible running under a Python interpreter placed in
`/opt/bin` ([AMI vars][ib-ami], [OVA vars][ib-ova], [Kubernetes version matrix notes][ib-matrix]). In other words, the CAPI Flatcar
images are not built with sysexts; they are conventional golden images whose Kubernetes content lives under `/opt`, which is
writable root. (The bakery describes the `kubernetes` sysext as used by the Flatcar project for Cluster API, with nodes "composited at
provisioning time" and optionally updated in place; that is a Flatcar-side option distinct from image-builder's default.)

The vSphere path boots a Flatcar ISO and runs `flatcar-install` with a bootstrap Ignition file, selecting the channel and version
from `FLATCAR_CHANNEL` and `FLATCAR_VERSION` (the latter resolved to the latest release of the channel by a helper script if not set)
and builds the OVA ([OVA vars][ib-ova], [Makefile][ib-makefile]). The AWS path finds the base AMI by filtering on the Flatcar
channel and version name pattern and a fixed owner account ID, then provisions with Ignition user data
([AMI vars][ib-ami]).

> ⚠️ Verify: image-builder's Flatcar files still carry traces of the older Docker-based layout: the OVA vars set
> `containerd_cri_socket` to `/run/docker/libcontainerd/docker-containerd.sock`, and the Flatcar README in the repository still
> describes the old config transpiler although the Makefile now generates the bootstrap Ignition with Butane. Build a trial image
> and check the resulting node rather than assuming the variable files reflect current Flatcar behavior.

## Cluster API: bootstrapping with Ignition on vSphere and AWS

CAPI's default bootstrap format is cloud-init. For Ignition-based distros you enable a feature flag so that the kubeadm bootstrap
provider produces Ignition instead.

**CAPV.** The CAPV Ignition guide uses Flatcar as its worked example. You need a Flatcar OVA template built with image-builder, and
you set `EXP_KUBEADM_BOOTSTRAP_FORMAT_IGNITION=true` before `clusterctl init -i vsphere`, then generate a cluster from the `ignition`
flavor ([CAPV Ignition guide][capv-ignition]). The provider writes the config into the VM's guestinfo as base64 with an encoding key,
exactly as in doc 05: `guestinfo.ignition.config.data` and `guestinfo.ignition.config.data.encoding`, with the provider code
setting the encoding to `base64` ([CAPV source][capv-extra]). The template in the guide is named
`flatcar-stable-3139.2.3-kube-v1.23.5`, which shows the convention that matters: the image name carries both the Flatcar version and
the Kubernetes version.

**CAPA.** AWS Ignition support is marked experimental behind two feature gates, `EXP_KUBEADM_BOOTSTRAP_FORMAT_IGNITION` and
`EXP_BOOTSTRAP_FORMAT_IGNITION`. The design is shaped by two limits the document states: cloud-init multi-part MIME is not supported by
Ignition, and EC2 user data "is also limited to 64 KB", which "might not always be enough to provision Kubernetes controlplane because
of the size of required certificates and configuration files". So by default the machine controller writes the Ignition user data to a
Cluster Object Store, an S3 bucket configured on `AWSCluster`, and the instance fetches it at provisioning; after provisioning the object
is deleted. An alternative `storageType` puts unencrypted user data directly in EC2 user data, which the CAPA docs discourage
([CAPA Ignition support][capa-ignition]). This is the same stub-and-merge pattern from doc 05, automated, and it keeps secrets out of IMDS-readable user data.

Both providers are the right shape for doc 05's secrets guidance: the control-plane bootstrap data contains certificates, so
prefer the S3 route on AWS, and on vSphere remember that guestinfo is readable by anything that can reach VMware tools RPC in the
guest, which is why Ignition deletes the config after provisioning on VMware unless you mask `ignition-delete-config.service`.

> ⚠️ Verify: both Ignition bootstrap paths are described in their own documentation as experimental or feature-gated at the version
> I read. Check the feature status for the exact CAPI, CAPV and CAPA releases you will deploy (VERSIONS.md lists the latest tags I
> found, not tested combinations) and read their release notes for Ignition changes.

## How node images are versioned against Kubernetes

There are three version axes on a node, and Flatcar plus Kubernetes make you manage them separately.

1. **Flatcar OS version** (`MAJOR.MINOR.PATCH`), which changes via `update_engine` unless you disable or gate it.
2. **Kubernetes version** (kubelet, and on control-plane nodes the control-plane components), which changes only when you change it (a new image, a sysupdate within a minor, or a distribution upgrade).
3. **Component versions bundled in the OS** (containerd, Docker, runc, systemd, kernel), which change with axis 1. Stable 4757.2.1 carries containerd 2.2.5 and kernel 6.12.111; LTS 4081.3.10 carries containerd 1.7.21 and kernel 6.6.150 (VERSIONS.md).

In Cluster API the unit of version is the *image*. The Kubernetes version is baked in (image-builder is parameterized by a Kubernetes
semver) and the Flatcar version is the base release plus whatever the node updates to. A `Machine`'s `version` is checked against the
node by the provider and the template; to change Kubernetes you roll Machines onto a new image. The community-published CAPA AMIs
illustrate the policy side: they cover "the latest release series and 2 previous release series", are "for non-production usage",
and "Existing AMIs are not updated for security fixes", so production should "build and maintain your own AMIs using the
image-builder project" ([CAPA AMIs][capa-amis]). Flatcar's own AMIs are un-published after nine months (doc 05), so any
autoscaling group or template pinned to an old AMI will eventually be unable to launch new instances.

The interaction that causes real incidents is between axis 1 and CAPI's rolling upgrades. A Flatcar node follows its update
channel on its own, so a CAPI-managed node pool whose machines were created from the same image on the same day will each stage
the same OS update and, unless you control reboots, reboot on whatever schedule your reboot manager imposes, independently of CAPI's
rollout. There are two coherent designs. Either disable Flatcar's own updates on CAPI nodes (`SERVER=disabled` in
`/etc/flatcar/update.conf`, or masking per doc 04's caveats) and let new images, built from a new Flatcar release, arrive through CAPI's
rolling replacement, which makes CAPI the only thing that changes nodes. Or keep Flatcar updates on and run FLUO or kured so reboots are
drained and rate-limited, and accept that node OS versions drift between CAPI rollouts. The first is cleaner for audit (a node's OS version
is the version of its image) and costs you a pipeline that rebuilds images every time you want OS patches. The second needs the
doc 07 machinery.

> ⚠️ Verify: the CAPI vSphere and AWS Flatcar templates I read do not, by themselves, disable Flatcar auto-update or install
> a reboot manager. Check what your generated manifests actually write to `/etc/flatcar/update.conf` and which reboot manager is
> installed in the cluster.

## Key takeaways

- Flatcar is tested with Kubernetes 1.35 to 1.37 across channels using Cilium, Flannel and Calico; it ships containerd as a sysext, cgroup v2 by default, and the host networking and storage tools the kubelet needs, but not the kubelet itself.
- Place the kubelet via a bakery sysext (in-place patch updates, reboot-gated), `/opt/bin` binaries (replace the node), or a baked image; `/opt/bin` is not on the default PATH for units.
- image-builder's Flatcar images install Kubernetes under `/opt` as ordinary golden images, with targets for AWS and vSphere (and others), not as sysexts.
- CAPV passes Ignition through guestinfo base64; CAPA stores Ignition in S3 by default because of user-data limits; both are feature-gated and described as experimental in their docs.
- Decide who owns OS changes on CAPI nodes: CAPI image rollouts only, or Flatcar's updates gated by FLUO or kured; mixing the two without a decision causes uncoordinated reboots.

## Sources

- Flatcar Kubernetes docs (compatibility matrix, kubeadm with sysext and `/opt/bin`, Cluster API providers): [`orchestrate/kubernetes/getting-started-with-kubernetes.md`][k8s-doc]
- containerd and cgroups: [`containerd/usr/share/containerd/config.toml`][containerd-config], [`customizing-docker.md`][customizing-docker], [`switching-to-unified-cgroups.md`][cgroups]
- Base package list and layout: [`coreos-0.0.1.ebuild`][coreos-ebuild], [`baselayout-9999.ebuild`][baselayout]
- Bakery Kubernetes extension: [`docs/kubernetes.md`][bakery-k8s], unit files [`kubelet.service.d/10-kubeadm.conf`][bakery-k8s-unit]
- image-builder: [`images/capi/Makefile`][ib-makefile], [`packer/ami/flatcar.json`][ib-ami], [`packer/ova/flatcar.json`][ib-ova], [Kubernetes version matrix notes][ib-matrix]
- CAPV: [Ignition guide][capv-ignition], [guestinfo code][capv-extra]; CAPA: [Ignition support][capa-ignition], [pre-built AMIs][capa-amis]
- 2020 end-of-life post (kubelet-wrapper and rkt deprecation): [`2020-02-24-…`][eol-post]

[k8s-doc]: https://github.com/flatcar/flatcar-website/blob/415d66a7b79efa4374b927a4cd6d7b5bd1bfeb9c/content/docs/latest/orchestrate/kubernetes/getting-started-with-kubernetes.md
[containerd-config]: https://github.com/flatcar/scripts/blob/2189f1e166e28c06cdcd1b26fea47f05da78c139/sdk_container/src/third_party/coreos-overlay/coreos/sysext/containerd/usr/share/containerd/config.toml
[customizing-docker]: https://github.com/flatcar/flatcar-website/blob/415d66a7b79efa4374b927a4cd6d7b5bd1bfeb9c/content/docs/latest/orchestrate/containers/customizing-docker.md
[cgroups]: https://github.com/flatcar/flatcar-website/blob/415d66a7b79efa4374b927a4cd6d7b5bd1bfeb9c/content/docs/latest/orchestrate/containers/switching-to-unified-cgroups.md
[coreos-ebuild]: https://github.com/flatcar/scripts/blob/2189f1e166e28c06cdcd1b26fea47f05da78c139/sdk_container/src/third_party/coreos-overlay/coreos-base/coreos/coreos-0.0.1.ebuild
[baselayout]: https://github.com/flatcar/scripts/blob/2189f1e166e28c06cdcd1b26fea47f05da78c139/sdk_container/src/third_party/coreos-overlay/sys-apps/baselayout/baselayout-9999.ebuild
[bakery-k8s]: https://github.com/flatcar/sysext-bakery/blob/445ccc99020d18b07c58c1217b0fcde43fe590c7/docs/kubernetes.md
[bakery-k8s-unit]: https://github.com/flatcar/sysext-bakery/blob/445ccc99020d18b07c58c1217b0fcde43fe590c7/kubernetes.sysext/files/usr/lib/systemd/system/kubelet.service.d/10-kubeadm.conf
[ib-makefile]: https://github.com/kubernetes-sigs/image-builder/blob/f18b988f05d99acedbddb9e12b23752931ac022c/images/capi/Makefile
[ib-ami]: https://github.com/kubernetes-sigs/image-builder/blob/f18b988f05d99acedbddb9e12b23752931ac022c/images/capi/packer/ami/flatcar.json
[ib-ova]: https://github.com/kubernetes-sigs/image-builder/blob/f18b988f05d99acedbddb9e12b23752931ac022c/images/capi/packer/ova/flatcar.json
[ib-matrix]: https://github.com/kubernetes-sigs/image-builder/blob/f18b988f05d99acedbddb9e12b23752931ac022c/docs/book/src/capi/kubernetes-version-matrix.md
[capv-ignition]: https://github.com/kubernetes-sigs/cluster-api-provider-vsphere/blob/4ad33925cc0f6bb15b7d47499f0599dc60e7cd4a/docs/ignition.md
[capv-extra]: https://github.com/kubernetes-sigs/cluster-api-provider-vsphere/blob/4ad33925cc0f6bb15b7d47499f0599dc60e7cd4a/pkg/services/govmomi/extra/config.go
[capa-ignition]: https://github.com/kubernetes-sigs/cluster-api-provider-aws/blob/0efa4cc1e6a008c995bac03c09209508877783d6/docs/book/src/topics/ignition-support.md
[capa-amis]: https://github.com/kubernetes-sigs/cluster-api-provider-aws/blob/0efa4cc1e6a008c995bac03c09209508877783d6/docs/book/src/topics/images/built-amis.md
[eol-post]: https://github.com/flatcar/flatcar-website/blob/415d66a7b79efa4374b927a4cd6d7b5bd1bfeb9c/content/blog/2020-02-24-flatcar-container-linux-enters-new-era-after-coreOS-end-of-life-announcement.md
