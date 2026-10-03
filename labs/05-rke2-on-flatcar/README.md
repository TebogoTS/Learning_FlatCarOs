# Lab 05 — RKE2 on Flatcar, then upgrade RKE2 and Flatcar without overlapping outages

## Goal

Run an RKE2 cluster (1 server, 2 agents) on Flatcar using the "Option A" layout from [doc 10](../../docs/10-rke2-on-flatcar.md): RKE2 under `/opt/rke2`, installed at first boot by the real `install.sh` from hash-pinned artifacts. Then do the part that matters in production: upgrade RKE2 from `v1.36.3+rke2r1` to `v1.36.5+rke2r1` with system-upgrade-controller (SUC) and take a Flatcar update, with **kured** coordinating the reboots so that an OS reboot and an RKE2 upgrade never overlap. Diagrams: [RKE2 node lifecycle](../../docs/diagrams/rke2-node-lifecycle.mmd), [update reboot coordination](../../docs/diagrams/update-reboot-coordination.mmd).

The VMs start on the *old* Flatcar release (`4593.2.5`) so a real OS update is available; RKE2 versions, SUC `v0.20.2` and kured `1.23.0` come from `versions.env` and `artifacts.env`.

## Prerequisites

- Common host tools ([../README.md](../README.md)), KVM, `dnsmasq`, the one-time bridge and DHCP setup from that file.
- Outbound internet from the VMs: they download the RKE2 tarball (about 40 MB), RKE2 pulls its images, and the OS update comes from the public update server. For an offline run you would mirror all three (doc 07, doc 10); this lab does not.
- At least 12 GB of free RAM for three VMs, and `make tools butane` run once.

## Steps

1. **Check the pins (optional, needs network).** `make lab05-pin-check` recomputes `artifacts.env` from upstream and fails if anything differs. The file holds the SHA-256 of `install.sh`, the RKE2 tarballs and checksum file, the SUC manifests and the kured RBAC.
2. **Network.** Same as lab 04, with this lab's host lines:
   ```sh
   sudo labs/lib/net.sh up
   labs/05-rke2-on-flatcar/scripts/lab05.sh hosts > /tmp/lab-hosts
   sudo labs/lib/net.sh dhcp-start /tmp/lab-hosts
   ```
3. **Boot the cluster.** `make lab05-up`. Ignition downloads three pinned files into `/opt/rke2-artifacts` (the config will not boot if any hash differs), writes `/etc/rancher/rke2/config.yaml` with a per-run pre-shared token, masks Flatcar's Docker and containerd extensions, and enables `rke2-install.service`. That unit runs the real `install.sh` with `INSTALL_RKE2_ARTIFACT_PATH`, `INSTALL_RKE2_TAR_PREFIX=/opt/rke2` and `INSTALL_RKE2_METHOD=tar`, which moves the unit to `/etc/systemd/system` and starts `rke2-server` or `rke2-agent`.
4. **Wait and verify.** `make lab05-status` shows each VM's OS and RKE2 version and `kubectl get nodes`; `make lab05-verify-cluster` waits for three Ready nodes and asserts the Flatcar-specific layout.
5. **Install the coordination tools.** `make lab05-addons` applies SUC and the kured RBAC from hash-checked downloads, and the kured DaemonSet from `manifests/kured-ds.yaml`. Read that file's header: `--concurrency=1` and a `--blocking-pod-selector` that holds reboots while SUC job pods run.
6. **Upgrade RKE2.** `make lab05-upgrade-rke2` applies `manifests/suc-plans.yaml`. Watch: `make lab05-kubectl ARGS='-n system-upgrade get plans,jobs -o wide'` and `make lab05-status`. The server plan runs first with `concurrency: 1`; the agent plan's `prepare` step waits for it. Each node: cordon, `rke2-upgrade` replaces `/opt/rke2/bin/rke2`, systemd restarts RKE2, uncordon. When finished: `make lab05-verify-rke2-upgraded`.
7. **Take a Flatcar update, one node.** `make lab05-os-update NODE=rke2-agent-0` removes the freeze (`SERVER=disabled`) on that node, restarts `update-engine` and stages the update. `/run/reboot-required` appears; within a minute kured takes its lock, drains the node and reboots it. Watch `make lab05-kubectl ARGS='get nodes -w'`.
8. **Take the rest, and test the blocker.** `make lab05-os-update-all` stages the update on all nodes. kured reboots them one at a time. To test the blocking selector, re-run step 6's plans (edit the plan or its `version`) while an update is staged and observe that kured does not reboot while SUC job pods exist. Then `make lab05-verify-os-updated`.

## Verification

- `verify-cluster`: three nodes Ready; RKE2 binary under `/opt/rke2`; units in `/etc/systemd/system`; Flatcar's Docker and containerd extensions linked to `/dev/null`; no host containerd running; every node at `v1.36.3+rke2r1`.
- `verify-rke2-upgraded`: every node's `kubeletVersion` and on-disk binary at `v1.36.5+rke2r1`; nodes Ready.
- `verify-os-updated`: every node runs a Flatcar version other than `4593.2.5`; RKE2 is active after the reboots; nothing left cordoned.

**Expected shape** (not captured): `PASS` lines per check and an exit status of 0.

## Teardown

```sh
make lab05-down       # power off
make lab05-destroy    # delete the VMs and the generated token
sudo labs/lib/net.sh down
```

## Validated and not validated

**Validated, for real:**

- Every config renders and transpiles with the pinned Butane `--strict`, byte-identical across the library and binary paths, and passes the policy checks, including that every remote file carries a hash (`make check`).
- All pinned hashes were computed from, and the three RKE2 files re-checked against, the real upstream release assets; `scripts/pin.sh` regenerates and `--check`s them.
- The real RKE2 `install.sh` ran against the pinned tarball and checksum file with this lab's environment variables, in a temporary prefix: it verified the tarball, unpacked it, rewrote the unit's paths to the prefix and moved the unit to `/etc/systemd/system`; the resulting `rke2 --version` reported `v1.36.3+rke2r1`. (It could not talk to systemd in my sandbox, which is the only error it printed.)
- The SUC CRD and controller manifests applied to a real v1.36.5 API server, the two plans (with their version placeholder substituted) were accepted by the CRD's schema, and the kured RBAC applied and the DaemonSet was accepted by server-side dry run (`make lab04-native-test`). That proves the manifests are well-formed, not that they behave.

**Not validated (needs a real boot):**

- Everything that runs on a node: Ignition fetching the artifacts, the installer unit on Flatcar (including that `/usr/bin/sh` and `systemctl enable --now --no-block` behave as expected), RKE2 starting, agents joining, Canal networking on Flatcar's kernel, SUC jobs actually replacing the binary under `/opt/rke2`, and kured acting on Flatcar's sentinel.
- The two hypotheses in doc 10: that SUC upgrade job pods carry the `upgrade.cattle.io/controller` label the kured blocking selector uses, and that the `rke2-upgrade` image's path match covers `/opt/rke2/bin/rke2` on a Flatcar host as the script suggests.
- That the public update server offers an update from `4593.2.5` today.

> ⚠️ Verify: kured `1.23.0` image tag exists on `ghcr.io` (I confirmed the registry returns a manifest for it) but I did not run it; the flags I use were checked against its source at commit `f2da2dc` (30 Sep 2026, possibly newer than the `1.23.0` tag), not against a running pod.
