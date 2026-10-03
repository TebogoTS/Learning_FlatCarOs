# Flatcar Container Linux: a deep dive for platform engineers

A learning repository for evaluating Flatcar Container Linux as the node OS of a regulated production Kubernetes estate (vSphere and AWS, Rancher and RKE2, Go tooling, a KVM homelab). It assumes you know Kubernetes well and have done *Kubernetes the Hard Way*. It is written to be accurate before it is comprehensive: every document ends with its sources, anything I could not verify upstream is marked inline as `> ⚠️ Verify:`, and every lab pins its versions.

## Read this first: what was and was not tested

I built this in a sandbox with **no KVM and no access to the Flatcar release servers**, so I never booted a Flatcar VM. Everything that can be checked without one was checked, and each lab README lists exactly which is which. In short:

- **Run for real:** Go tests (with mutation checks) for the two helper tools; every Butane config transpiles with the pinned Butane `0.29.0` in `--strict` mode and passes policy checks; every shell script passes `shellcheck`; the Flatcar image-signing-key import and fingerprint check; the sysext build (reproducible) and its payload; the real Kubernetes `v1.36.5` and etcd `v3.6.14` control plane started with the exact flags from the lab's Ignition configs; the RKE2 `install.sh` run against the pinned tarball; the add-on manifests (SUC, kured) applied to a real API server; the pinned hashes recomputed against upstream.
- **Not run:** any boot, Ignition application, A/B update or rollback, sysext merge, networkd/containerd/CNI on Flatcar, kured or SUC acting on real nodes, vSphere or AWS. When you run the labs, treat a failure as possibly my error first.
- **Marked in the text:** each `> ⚠️ Verify:` is a specific claim to check before relying on it.

## Learning path

Read the documents in order; do each lab after the document it names. Docs 01 to 06 are the mechanics, 07 to 08 are operating it, 09 to 12 are Kubernetes.

| # | Read | Then do |
|---|---|---|
| 1 | [01 The problem Flatcar solves](docs/01-problem.md) | |
| 2 | [02 History](docs/02-history.md) | |
| 3 | [03 How it is built](docs/03-how-its-built.md) | |
| 4 | [04 Runtime: partitions, A/B updates, boot](docs/04-runtime.md) | [Lab 01 First boot](labs/01-first-boot-kvm/README.md) |
| 5 | [05 Provisioning: Ignition and Butane](docs/05-provisioning.md) | (labs 01 to 03 use it) |
| 6 | [06 Extending with sysext](docs/06-extending-sysext.md) | [Lab 03 System extension](labs/03-sysext/README.md) |
| 7 | [07 Updates in production](docs/07-updates-in-production.md) | [Lab 02 Updates and rollback](labs/02-updates-and-rollback/README.md) |
| 8 | [08 Production operations, comparison, when not to use it](docs/08-production-operations.md) | |
| 9 | [09 Flatcar with Kubernetes](docs/09-kubernetes-on-flatcar.md) | |
| 10 | [11 Image builds, drift, rebuild versus patch](docs/11-image-builds-and-drift.md) | |
| 11 | [12 Kubernetes the Hard Way on Flatcar](docs/12-kthw-on-flatcar.md) | [Lab 04 KTHW](labs/04-kthw-on-flatcar/README.md) |
| 12 | [10 Flatcar with RKE2](docs/10-rke2-on-flatcar.md) | [Lab 05 RKE2](labs/05-rke2-on-flatcar/README.md) |
| 13 | | [Lab 06 vSphere and AWS](labs/06-vsphere-and-aws/README.md) (documentation) |

If you only have an evening: doc 04, doc 05, doc 07, doc 08's comparison and "when not to use", then doc 10. If you are deciding rather than learning: doc 08 and doc 10 first.

Reference: [GLOSSARY.md](GLOSSARY.md), [VERSIONS.md](VERSIONS.md) (every pin and its provenance), [PLAN.md](PLAN.md) (the original plan, kept for history).

## Diagrams

Mermaid sources are in [`docs/diagrams/`](docs/diagrams/) and embedded in the documents: [boot and Ignition flow](docs/diagrams/boot-and-ignition-flow.mmd), [A/B update and rollback](docs/diagrams/ab-update-and-rollback.mmd), [provisioning flow](docs/diagrams/provisioning-flow.mmd), [update reboot coordination in a cluster](docs/diagrams/update-reboot-coordination.mmd), [RKE2 node lifecycle](docs/diagrams/rke2-node-lifecycle.mmd).

## Using the repository

```sh
make help               # all targets
make tools butane       # build the Go helpers; download and verify the pinned Butane
make validate           # tests, lint, transpile every config, policy checks (no VM needed)
make check-mermaid      # parse every diagram (needs node and a Chromium)
make lab01-up           # labs: make lab<NN>-<target>; see each lab's README
```

Host prerequisites for the labs, including the bridge and DHCP setup for labs 04 and 05, are in [labs/README.md](labs/README.md).

```
docs/               the twelve documents and their diagrams
labs/               01 first boot · 02 updates · 03 sysext · 04 KTHW · 05 RKE2 · 06 vSphere/AWS (doc only) · lib/ shared shell
tools/nodegen       renders one Butane config per node from a template and an inventory
tools/butanecheck   policy checks on top of strict Butane (pinned variant, remote hashes, no stray keys, size)
tools/scripts       fetch-butane.sh (hash-verified), check-butane.sh
versions.env        every pin the scripts read
```

## Conventions

- **Sources:** every document ends with a Sources section linking the upstream files at the commit I read, listed in `VERSIONS.md`.
- **Verify markers:** `> ⚠️ Verify:` marks a claim I could not confirm from a primary source. I did not invent flags, paths, unit names or config keys; where I inferred, the text says so.
- **Pins:** versions live in `versions.env` and `labs/05-rke2-on-flatcar/artifacts.env`; change them there.
- **Secrets:** rendered Ignition configs in the labs contain private keys and tokens. They are written with mode 0600 under git-ignored directories and must never be committed.
