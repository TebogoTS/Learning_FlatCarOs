# 12 — Kubernetes the Hard Way on Flatcar: the walkthrough, chapter by chapter

You have done *Kubernetes the Hard Way* (KTHW), so you know what each component needs. This document replays the same thirteen chapters on Flatcar
and records, chapter by chapter, what changes when the nodes cannot be logged into and edited, and what stays exactly as it was. The runnable
version is `labs/04-kthw-on-flatcar/`; this is the commentary. Everything the tutorial does with `scp`, `ssh` and `sed` becomes either a
file in an Ignition config or a step on the jumpbox that produces one.

The shape of the lab: your KVM host is the jumpbox. Three VMs boot the pinned Flatcar release: `server` (10.77.0.10, the control plane) and
`node-0` and `node-1` (10.77.0.20 and .21, workers). Each VM gets exactly one thing from the jumpbox, its Ignition config, and everything the
config needs is either inside it (certificates, kubeconfigs, unit files) or fetched by Ignition with a pinned SHA-256 (the Kubernetes and etcd
binaries). After first boot nothing is copied to the nodes and nobody types on them.

## What validation I could and could not do

I could not boot Flatcar where I wrote this (no KVM, and the Flatcar release hosts were unreachable), so no VM in this lab has ever been booted by me.
What I did run, for real, is the control plane itself. `make lab04-native-test` extracts the `ExecStart` lines of etcd, kube-apiserver,
kube-controller-manager and kube-scheduler from the *transpiled Ignition JSON*, rewrites only the paths, and runs them natively with the real
`v1.36.5` and etcd `v3.6.14` binaries, checksum-verified against the upstream-published digests, using the lab's generated certificates and
kubeconfigs. It checks that every flag is accepted, that the API server becomes ready, that the RBAC bootstrap applies, that both controllers win their leader
leases, that the admin, node and kube-proxy certificates authenticate as the identities KTHW intends, that a secret is stored with the `k8s:enc:aescbc:v1:key1`
prefix, that service-account tokens are issued, that a Deployment produces a ReplicaSet, and that the kubelet and kube-proxy configurations are
accepted by the real binaries. It does not exercise anything Flatcar-specific: Ignition, networkd, the shipped containerd, CNI, or iptables. Those
are the things the first real boot must prove, and the "check on first boot" list near the end names them.

## Differences from the original tutorial, in one table

| KTHW says | The lab does | Why |
|---|---|---|
| Debian host, root SSH enabled by `sed` on `sshd_config` | Flatcar, key-only `core` user from Ignition; no root login | Nothing in a Flatcar node asks for root SSH; the tutorial needs it only for `scp` |
| Hostnames and `/etc/hosts` edited over SSH | `/etc/hostname` and `/etc/hosts` written by Ignition | Same result, applied once, before the node boots |
| Download kubectl, apiserver, controller-manager, scheduler, kubelet, kube-proxy, crictl, runc, CNI, containerd, etcd to the jumpbox | Download the six Kubernetes binaries, three CNI plugins, and etcd/etcdctl; verify each against the upstream checksum | Flatcar already ships containerd, runc, crictl and iptables ([doc 09](09-kubernetes-on-flatcar.md)) |
| Install into `/usr/local/bin` | Install into `/opt/bin` (and `/opt/cni/bin`) | `/usr` is read-only on Flatcar; `/opt` is on the writable root |
| `scp` binaries and units, `mv`, `daemon-reload`, `enable`, `start` | Ignition downloads each binary with `verification.hash`, writes unit files, enables them | Ignition's job (doc 05); the node boots with the services already enabled |
| `containerd-config.toml`, `containerd.service` | Nothing: the shipped containerd is already running | The shipped config already sets `SystemdCgroup = true` ([doc 09](09-kubernetes-on-flatcar.md)) |
| `modprobe br-netfilter`, `sysctl -w` | `/etc/modules-load.d/kthw.conf` and `/etc/sysctl.d/90-kthw.conf` | Persistent by construction |
| `kubectl apply` of the API-server-to-kubelet RBAC from the jumpbox | A one-shot unit on the server waits for `/readyz`, applies it, and leaves a marker | No human in the loop; the whole bring-up is config |
| Pod routes with `ip route add` over SSH | Two `[Route]` sections in a networkd file per node | Survives reboot; no imperative step |
| API server `--service-cluster-ip-range` not set | Set to `10.32.0.0/24` | The API server certificate carries 10.32.0.1 as the `kubernetes` service address, so the range must be the one that address belongs to |
| Node certificates with SANs `DNS:node-0, IP:127.0.0.1` | Plus the node's lab IP and `node-0.lab.test` | The API server verifies kubelet serving certificates when it proxies logs and exec; the node's address must be in the certificate |
| `O = system:system:kube-scheduler` in `ca.conf` | `O = system:kube-scheduler` | Apparent typo upstream |

## Chapter by chapter

### 01 Prerequisites and 02 Jumpbox

The tutorial asks for four Debian machines. The lab needs a KVM-capable Linux host with QEMU, `openssl`, `curl`, `gpg`, `python3` and root once, for a bridge and a DHCP
service (`labs/README.md`). The jumpbox is that host. `make lab04-artifacts` is chapter 02: it downloads the binaries and refuses to keep any whose SHA-256 does
not match what the upstream project published, `<binary>.sha256` on `dl.k8s.io`, the `.sha256` beside the CNI plugin tarball, and the etcd release's `SHA256SUMS`. The versions come from `versions.env`
(Kubernetes v1.36.5, CNI plugins v1.9.1, etcd v3.6.14), so a bump is a one-line, reviewable change.

> ⚠️ Verify: that the etcd you want on the control plane is the pinned upstream binary rather than the one in the Flatcar image. The Flatcar build lists `dev-db/etcd` and `etcd-wrapper` in its base package list (doc 01), and I did not
> check which version Stable 4757.2.1 contains. The lab uses the pinned upstream binary because its version is then a property of the config; `etcd --version` on a booted node tells you what the image has.

### 03 Compute resources

KTHW provisions machines, sets hostnames and writes `/etc/hosts` over SSH. Here the inventory (`inventory.yaml`) is the source of truth for names, addresses and MAC addresses, and `tools/nodegen`
renders one Butane config per node from two templates (`server.bu.tmpl`, `worker.bu.tmpl`) plus a shared partial. The hostnames and the hosts file are Ignition files.

One Flatcar-specific constraint shapes this chapter. Ignition downloads remote files in the initrd, and in the initrd every network interface is configured with DHCP: the initrd includes `zz-default.network` ([bootengine `module-setup.sh`][bootengine-net]). Static addresses written
by Ignition into `/etc/systemd/network` apply only after the switch to the real root. So for the artifact downloads to work, something must answer DHCP on the lab network. The lab's helper (`labs/lib/net.sh dhcp-start`) runs `dnsmasq` on the bridge with one fixed lease per MAC address, so each VM
gets the address the inventory says before Ignition runs. On vSphere there is a supported alternative, passing initrd network kernel arguments through guestinfo (doc 05), which is the production answer for static addressing.

`make lab04-up` creates a copy-on-write overlay per VM on the verified Flatcar image, passes each Ignition file through QEMU `fw_cfg` (`opt/org.flatcar-linux/config`), and waits for SSH.

### 04 Certificate authority

Unchanged in substance: `config/ca.conf` is KTHW's file with the three edits in the table, and `scripts/pki.sh` runs the same `openssl` commands, a self-signed CA and one key and certificate per component. The KTHW text itself says a self-signed CA is not a production practice,
and on Flatcar the production-grade question is different from the tutorial's: how the private keys reach a node without being in a config that anything on the node can read. In this lab the keys are inlined into the Ignition config (so it is rendered with mode 0600 and never committed, and
`butanecheck` only allows private keys with an explicit `--allow-private-keys` and a file mode of 0600 or tighter). In production fetch them from a secret store at first boot, or give each node a short-lived credential and let it obtain its own certificate (doc 05, secrets).

### 05 Kubernetes configuration files, 06 Data encryption keys

`pki.sh` writes the kubeconfigs (admin, controller manager, scheduler, kube-proxy and one per worker, plus an admin copy for the jumpbox) and the encryption configuration. The kubeconfigs have the structure `kubectl config set-cluster`/`set-credentials`/`set-context` produces, with certificates embedded; writing them directly means this step does not need `kubectl` and can run in CI against fixtures. Controller manager, scheduler and admin
point at `127.0.0.1:6443` because they run on the server; kubelets and kube-proxy point at the server's lab address. The `aescbc` key is 32 random bytes generated per lab run. Ignition places both under `/var/lib/kubernetes` with modes of 0600 for anything secret.

### 07 etcd and 08 Controllers

On the server, `etcd.service`, `kube-apiserver.service`, `kube-controller-manager.service` and `kube-scheduler.service` are the KTHW units with three kinds of change: binary paths under `/opt/bin`, `--advertise-address` set from the inventory, and `--service-cluster-ip-range` added. `etcd` listens on loopback only,
without TLS, exactly as in KTHW; that is acceptable for a single-node lab and not for production, where etcd members need TLS between themselves and from the API server.

The tutorial finishes chapter 08 by running `kubectl apply -f kube-apiserver-to-kubelet.yaml` from the jumpbox. Here `kthw-bootstrap-rbac.service` does it: a oneshot that loops on `kubectl get --raw /readyz`, applies the manifest, and touches `/var/lib/kubernetes/.rbac-applied`, which the unit's `ConditionPathExists=!` then uses to skip later boots.
This is the general pattern for "first-boot steps that need the cluster": a unit, guarded by a marker, because Ignition itself cannot run commands.

### 09 Workers

The worker config is the shortest part of the lab because Flatcar already provides what KTHW downloads and installs by hand. containerd runs from the `containerd-flatcar` extension with `/run/containerd/containerd.sock`, runc and crictl are present, and the shipped config sets `SystemdCgroup = true`, matching `cgroupDriver: systemd`
in the kubelet configuration. A `/etc/crictl.yaml` points the built-in `crictl` at the socket. What Ignition adds is the kubelet and kube-proxy binaries, three CNI plugins (`bridge`, `host-local`, `loopback`, each hash-pinned individually, which avoids a tarball-extraction unit), the per-node `10-bridge.conf` with that node's pod subnet (`10.200.0.0/24` or `10.200.1.0/24`),
and the kubelet and kube-proxy units and configuration. The lab links `docker-flatcar.raw` to `/dev/null` so Docker's iptables handling cannot interfere with kube-proxy and CNI masquerading.

`resolvConf` stays `/etc/resolv.conf`, as in KTHW: on Flatcar that file is a symlink to `/run/systemd/resolve/resolv.conf`, systemd-resolved's non-stub file, so the kubelet hands pods real upstream nameservers rather than the 127.0.0.53 stub ([Flatcar DNS docs][flatcar-dns]). This lab runs no CoreDNS, as in KTHW, so pods resolve nothing cluster-internal.

> ⚠️ Verify: on a booted worker, `systemctl is-active containerd` is `active` without you having enabled it, and `sudo crictl info` shows `SystemdCgroup: true`. Both follow from the shipped sysext (doc 09) but are exactly the assumptions this chapter rests on and I have not seen them on a booted node.

### 10 Configuring kubectl

`make lab04-access` prints the commands: the jumpbox uses the pinned `kubectl` it downloaded with `admin-remote.kubeconfig`, which is the admin kubeconfig pointing at the server's lab address. The API server certificate carries `10.77.0.10`, `server.kubernetes.local` and the usual service names, so TLS verifies by address with no `/etc/hosts` edit on the jumpbox.

### 11 Pod network routes

KTHW adds one `ip route add` per other node on each machine. Here each node's `/etc/systemd/network/10-lab.network` matches its own MAC address, keeps DHCP, and adds a `[Route]` for every *other* node's pod subnet via that node's address (the server gets both). The bridge CNI plugin gives each pod an address from its node's subnet. With `ipMasq` on (as in KTHW's `10-bridge.conf`) it source-NATs traffic leaving that subnet, which includes traffic to another node's pod subnet, so a pod on `node-0` reaches a pod on `node-1` with the node's address as the source. That is acceptable for the tutorial and visible in the pod's access log; the point here is that delivery still depends on these routes, not on any overlay. This is the one place the lab uses Flatcar's network stack directly, and it is the smallest possible illustration of why Flatcar uses networkd: the routes are declarative, applied at boot, and visible with `networkctl status`.

> ⚠️ Verify: that the networkd file takes precedence over Flatcar's default DHCP file. The name `10-lab.network` sorts before `zz-default.network`, and networkd uses the first matching file, so it should; confirm with `networkctl status` and `ip route` on a booted node. If a route is missing, check the match first.

### 12 Smoke test

`make lab04-verify` is the tutorial's smoke test as a script: data encryption (`etcdctl get` of a secret, looking for the `aescbc` prefix), a two-replica Deployment spread across the two nodes by a topology constraint, `curl` to each pod IP *from each node* (which exercises the pod routes in both directions),
`kubectl logs` and `kubectl exec` (which exercise API server to kubelet traffic and therefore the chapter-08 RBAC and the node certificate SANs), and a NodePort service reached on both nodes.

### 13 Cleaning up

`make lab04-destroy` stops and deletes the VMs and their overlays. The generated PKI and downloads stay under `labs/04-kthw-on-flatcar/.state/` (git-ignored) until you delete that directory. Compare with KTHW, where cleanup means deleting the machines too: the difference is that a Flatcar node has nothing worth preserving, so deleting it is also how you reset it.

## Check on first boot

When you run the lab on a real host, these are the things that decide whether it works, in the order they would fail:

1. **Ignition downloaded the artifacts.** If the VM stops in the initrd or drops to an emergency shell, read the VM's serial console log, `labs/04-kthw-on-flatcar/.state/vms/<name>/console.log`. The usual causes are no DHCP answer on the bridge, the artifact server not running on `10.77.0.1:8080`, or a host firewall dropping DHCP or HTTP from the bridge.
2. **The Ignition config was accepted by `fw_cfg`.** The server's config is around 55 KB, mostly certificates. `fw_cfg` file transfer has no size limit I know of at this scale, but I did not test it.
3. **The hosts file and networkd file took effect.** `getent hosts node-1`, `networkctl status`, `ip route`.
4. **`br_netfilter` and the sysctls.** `lsmod | grep br_netfilter`, `sysctl net.bridge.bridge-nf-call-iptables`. If the sysctls are not applied, the order of `systemd-modules-load` and `systemd-sysctl` is the first suspect.
5. **The control plane.** `systemctl status etcd kube-apiserver kube-controller-manager kube-scheduler kthw-bootstrap-rbac` on `server`; `journalctl -u kube-apiserver` first if `/readyz` does not answer.
6. **Kubelets registering.** `kubectl get nodes` from the jumpbox. A node that never registers usually has a kubelet error about cgroups or the runtime in `journalctl -u kubelet`.

## What this lab is not

It is a learning environment, not a template. The single control-plane node and single etcd member with no TLS, the keys inlined in user data, the frozen OS updates (`SERVER=disabled`, `locksmithd` masked), the self-signed CA with ten-year certificates, the absent cluster DNS, and the artifact server on the jumpbox are all deliberate simplifications to keep the chapters visible.
The production versions of each are in other documents: updates and reboot coordination in doc 07, secrets in doc 05, Cluster API for vSphere and AWS in doc 09, and RKE2, which solves most of these for you, in doc 10 and lab 05.

## Key takeaways

- Each KTHW chapter maps to either a file in an Ignition config or a step on the jumpbox that produces one; after first boot nothing is copied to or typed on the nodes.
- Flatcar removes the container-runtime half of the worker chapter (containerd, runc, crictl, cgroup driver) and moves everything you install to `/opt`, because `/usr` is read-only.
- Ignition downloads in the initrd, where only DHCP is configured, so remote artifacts need a DHCP service (or vSphere's initrd network kernel arguments); static addressing and routes come afterwards from networkd files.
- First-boot steps that need the cluster, like the RBAC bootstrap, become guarded one-shot units; pod routes, kernel modules and sysctls become declarative files.
- The control-plane configuration was validated natively against the real pinned binaries; what remains unvalidated until a real boot is everything Flatcar-specific, listed above.

## Sources

- Kubernetes the Hard Way, all thirteen chapters, `ca.conf`, unit files and `configs/` at the commit this lab was derived from: [`docs/`][kthw-docs], [`ca.conf`][kthw-ca], [`units/`][kthw-units], [`configs/`][kthw-configs]
- Initrd networking (`zz-default.network` included in the initrd): [bootengine `50flatcar-network/module-setup.sh`][bootengine-net]
- Flatcar DNS (`/etc/resolv.conf` symlink to systemd-resolved's non-stub file): [`configuring-dns.md`][flatcar-dns]
- containerd shipped with Flatcar: [`containerd/usr/share/containerd/config.toml`][containerd-config]; docs 06 and 09 of this repository
- Provisioning mechanics (Ignition in the initrd, `fw_cfg`, guestinfo, user data): doc 05 of this repository
- Pinned artifacts and their checksums: `versions.env`, `VERSIONS.md`; the upstream-published digests are read by `labs/04-kthw-on-flatcar/scripts/artifacts.sh`

[kthw-docs]: https://github.com/kelseyhightower/kubernetes-the-hard-way/tree/52eb26dad1a3e9e8083a899bc854421eb4842a73/docs
[kthw-ca]: https://github.com/kelseyhightower/kubernetes-the-hard-way/blob/52eb26dad1a3e9e8083a899bc854421eb4842a73/ca.conf
[kthw-units]: https://github.com/kelseyhightower/kubernetes-the-hard-way/tree/52eb26dad1a3e9e8083a899bc854421eb4842a73/units
[kthw-configs]: https://github.com/kelseyhightower/kubernetes-the-hard-way/tree/52eb26dad1a3e9e8083a899bc854421eb4842a73/configs
[bootengine-net]: https://github.com/flatcar/bootengine/blob/7727ec78da72e700e8fa1ce2144cb2476448d186/dracut/50flatcar-network/module-setup.sh
[flatcar-dns]: https://github.com/flatcar/flatcar-website/blob/415d66a7b79efa4374b927a4cd6d7b5bd1bfeb9c/content/docs/latest/os-config/network/configuring-dns.md
[containerd-config]: https://github.com/flatcar/scripts/blob/2189f1e166e28c06cdcd1b26fea47f05da78c139/sdk_container/src/third_party/coreos-overlay/coreos/sysext/containerd/usr/share/containerd/config.toml
