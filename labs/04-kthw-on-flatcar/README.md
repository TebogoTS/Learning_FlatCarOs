# Lab 04 — Kubernetes the Hard Way on Flatcar

## Goal

Run the thirteen chapters of [Kubernetes the Hard Way](https://github.com/kelseyhightower/kubernetes-the-hard-way) with Flatcar as the node OS, where the nodes are configured **entirely by Butane**: three VMs (`server` 10.77.0.10, `node-0` 10.77.0.20, `node-1` 10.77.0.21) boot with their final configuration and nobody logs in to set anything up. The host is the jumpbox. Commentary on every chapter, and what changes versus the original, is in [doc 12](../../docs/12-kthw-on-flatcar.md); read it alongside this.

Kubernetes v1.36.5, etcd v3.6.14 and CNI plugins v1.9.1 (pinned in `versions.env`), Flatcar Stable 4757.2.1.

## Prerequisites

- Common host tools ([../README.md](../README.md)), KVM, `dnsmasq`, and the one-time bridge and DHCP setup from that file (root).
- About 1 GB of downloads for the Kubernetes and etcd binaries.
- `make tools butane` run once at the repository root.

## Steps

Each target names the KTHW chapter it replaces.

1. **Chapter 02, jumpbox.** `make lab04-artifacts` downloads the six Kubernetes binaries, three CNI plugins and etcd and verifies every file against the checksum the upstream project publishes. A mismatch deletes the file and stops.
2. **Chapters 04, 05, 06.** `make lab04-pki` generates the CA and all certificates with `openssl` from `config/ca.conf`, the kubeconfigs, and the encryption configuration, under `.state/`. It is idempotent; `scripts/pki.sh --force` regenerates everything.
3. **Chapter 03 and the host network.**
   ```sh
   sudo labs/lib/net.sh up
   labs/04-kthw-on-flatcar/scripts/cluster.sh hosts > /tmp/lab-hosts
   sudo labs/lib/net.sh dhcp-start /tmp/lab-hosts
   ```
   (`make lab04-net-hint` prints these.) Without the DHCP answer, Ignition cannot download the binaries in the initrd.
4. **Chapters 03, 07, 08, 09 in one command.** `make lab04-up` renders the three Ignition configs (`make lab04-render` does only that; read `.state/render/*.bu`), starts the artifact web server on 10.77.0.1:8080, boots the three VMs, and waits for SSH. Then wait a minute or two: units start, kubelets register.
5. **Chapter 10.** `make lab04-access` prints the `KUBECONFIG` and `kubectl` to use from the jumpbox. Try `kubectl get nodes -o wide` and `kubectl get --raw /readyz`.
6. **Chapter 11.** On a worker: `make lab04-ssh-node-0`, then `ip route` and `networkctl status`. The route to the other node's pod subnet is there because of one networkd file, not a command.
7. **Look at what Flatcar did for you.** On `node-0`: `systemctl is-active containerd` (nobody enabled it), `sudo crictl info | grep -i systemdcgroup`, `ls /opt/bin /opt/cni/bin`, `findmnt -no OPTIONS /usr` (read-only), `systemctl status kubelet`.
8. **Chapter 12.** `make lab04-verify` runs the smoke test (below).
9. **Cluster-first-boot steps as units.** On `server`: `systemctl status kthw-bootstrap-rbac` and `ls /var/lib/kubernetes/.rbac-applied`; `journalctl -u kthw-bootstrap-rbac` shows it waiting for `/readyz`.

Optional, without any VMs: **`make lab04-native-test`** runs the control plane natively on your machine, see "Validated" below. It downloads the same binaries into `.cache/` and needs free ports 2379, 2380 and 6443.

## Verification

`make lab04-verify` is KTHW chapter 12 as a script: services active on all nodes; etcd healthy; `/readyz`; the RBAC cluster role exists; both nodes `Ready`; a secret stored with the `k8s:enc:aescbc:v1:key1` prefix; a two-replica nginx Deployment spread over both nodes; `curl` from each node to each pod IP; `kubectl logs` and `kubectl exec`; a NodePort on both nodes. **Expected shape:**

```
[..] PASS server: etcd, apiserver, controller-manager, scheduler active
[..] PASS node-0: containerd, kubelet, kube-proxy active
 ...
[..] PASS replicas landed on two different nodes
[..] PASS node-0 -> pod 10.200.1.x over the pod routes
 ...
```

The script exits non-zero if anything failed. Note that the first nginx pull needs outbound access from the nodes.

## Teardown

```sh
make lab04-down       # power off VMs and stop the artifact server (disks kept)
make lab04-destroy    # delete the VMs
sudo labs/lib/net.sh down
rm -rf labs/04-kthw-on-flatcar/.state   # also forget the generated PKI and downloads
```

## Validated and not validated

**Validated, for real:**

- All three Butane configs render from fixtures and transpile with the pinned Butane `0.29.0` in `--strict` mode, byte-identical to the library path, and pass `butanecheck` (variant and version, remote-hash policy, private-key policy and file modes, size budget). `make check`.
- `make lab04-native-test` passed in full: the real etcd and the real kube-apiserver, kube-controller-manager and kube-scheduler started with the exact flags from the transpiled units; the API server became ready; the RBAC manifest applied; both controllers took their leader leases; the admin, node and kube-proxy kubeconfigs authenticate as the intended users; a secret was stored with the `aescbc` prefix; a service-account token was issued; a Deployment produced a ReplicaSet; the kubelet and kube-proxy accepted their configurations. Along the way it caught a real bug in my test harness (Butane gzip-compresses inline contents) and showed that this machine uses cgroup v1, which kubelet 1.36 refuses by default (Flatcar uses cgroup v2; the test sets `failCgroupV1: false` for itself only).
- Downloads and the checksum logic ran against the real upstream files.
- All scripts pass `shellcheck`; the dnsmasq options pass `dnsmasq --test`.

**Not validated (needs a real boot):**

- Ignition applying any of this: the remote downloads in the initrd with DHCP, `fw_cfg` handling a ~55 KB config, `overwrite: true` on `/etc/hosts`, the networkd file taking precedence over `zz-default.network`, modules-load and sysctl ordering.
- Anything involving the shipped containerd, runc, crictl, CNI plugins, iptables and kube-proxy on real nodes; pod networking and the pod routes; the kubelets registering; `kthw-bootstrap-rbac.service` under systemd; the smoke test script itself (its logic is untested against live pods, so expect to fix small things).
- The bridge, NAT and DHCP helper scripts on a real host.

See "Check on first boot" in doc 12 for the order these would fail in.
