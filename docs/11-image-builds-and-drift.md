# 11 — Where Flatcar sits between "the hard way" and golden images: pipelines, drift, rebuild versus patch

You already operate in two modes and have seen a third. In *Kubernetes the Hard Way* you start from a stock Debian or Ubuntu host,
copy binaries onto it and write systemd units by hand. With Packer and image-builder you bake those same steps into a golden image and
launch clones of it. Flatcar is neither. This document puts the three side by side on one axis, "what is the artifact, and what
mutates after it exists", and then draws out what that does to your pipelines, to drift, and to the choice between rebuilding and patching.

## Three models, one question: what is "the image"?

**The hard way: no image, only history.** The current *Kubernetes the Hard Way* repository (13 chapters, a jumpbox and three target machines)
is the clearest example of the mutable-host model. The jumpbox downloads binaries, then the tutorial `scp`s them to each machine, moves them
into `/usr/local/bin`, moves unit files into `/etc/systemd/system`, runs `daemon-reload`, `enable` and `start`, and changes hostnames and `/etc/hosts` with
`sed` over SSH after enabling root login ([KTHW compute resources][kthw-03], [control plane][kthw-08]). That is a good way to learn, and it also shows
the structural property: the node's state is the sum of the commands that were run on it. Nothing in the machine says which version of which component is
supposed to be there, and nothing prevents two nodes that went through "the same" steps from diverging.

**Golden images: an image whose contents are a build output.** With image-builder the unit becomes an artifact: Packer boots a base OS, Ansible installs
Kubernetes components and tooling, and the result is saved as an AMI, OVA or template that you clone ([image-builder Makefile][ib-makefile]).
That fixes the identity problem (the image has a name and a version) and moves drift to build time. It does not fix what is *inside* the image: the base
is still a general-purpose OS with a package manager, so every OS security patch means a rebuild, and any process that logs into a running clone and changes it
reintroduces drift that the image no longer describes.

**Flatcar: the OS is someone else's image, and your artifact is a config.** The OS image is the upstream release; you do not build it. What you build is a
declarative document that is applied once at first boot (doc 05), plus, where needed, extensions (doc 06). So the three things you used to bundle in one place
are now separated by who owns them:

| Layer | Hard way | Golden image | Flatcar |
|---|---|---|---|
| Base OS content (`/usr`) | Distro packages, mutable | Distro packages baked at image build, still mutable at runtime | Vendor-built whole image, read-only, dm-verity protected |
| Kubernetes and component binaries | `scp` by hand | Installed by Ansible at image build | Hash-pinned downloads at first boot, a sysext, or baked into your own image |
| Host configuration | `sed` and `cat` over SSH | Baked, plus cloud-init at boot | Ignition at first boot only |
| Unit of change for the OS | Package | Image rebuild | New release of the vendor image, staged to the other partition |
| Who can change a running node | Anyone with root | Anyone with root | Anyone with root, but `/usr` cannot be altered on disk |
| Remediation for a bad node | Fix it | Replace it | Replace it |
| Your pipeline's artifact | Shell history | An image | A config (and optionally an image) |

## What this does to a pipeline

With golden images the pipeline's job is to produce an image, and everything else (promotion, scanning, rollout) hangs off that image. With Flatcar there are
two simpler outputs and one optional one.

1. **Lint and transpile the config.** Every Butane file goes through `butane --strict` (doc 05), and the policy checks in `tools/butanecheck` run on top: variant and version pinned, remote sources hash-verified, no stray private keys, size budget. A bad config fails here rather than at the node's first boot, where the symptom is an emergency shell.
2. **Render per-node values.** Hostnames, IPs, tokens and certificates are rendered into the Butane config before transpiling (the labs use `tools/nodegen`) because Ignition cannot template at runtime. Dynamic data that only exists on the node (instance ID, IP) comes from Afterburn at runtime instead.
3. **Pin every fetched artifact.** Anything an Ignition config downloads is a supply-chain input of your fleet. The pipeline should resolve versions to URLs and hashes once, commit the result, and fail if a hash does not match (doc 06 on `Verify=false`, doc 10 on RKE2).
4. **Test by booting.** The only real test of an Ignition config is booting it. The labs use plain QEMU with a copy-on-write overlay of the pinned image; Flatcar's own harness, `kola` in the `mantle` repository, runs tests on QEMU, AWS, vSphere and other platforms but describes itself as "primarily designed to operate within the Container Linux SDK" and as under heavy development with a changing interface ([mantle][mantle]), so I treat it as inspiration rather than a dependency.
5. **Optionally bake an image.** If boot-time downloads are unacceptable (autoscaling that must come up when GitHub or your mirror is unreachable, or a policy against first-boot internet access), bake the artifacts in: either with image-builder (as Cluster API does, with Kubernetes under `/opt`, doc 09) or with the bakery's `bake_flatcar_image.sh` (doc 06). That reintroduces an image pipeline, but a much thinner one, because the OS under it is still vendor-built and updated.

The consequence for CI cost and complexity: the Flatcar pipeline is mostly text and hashes and runs in seconds to minutes; there is no multi-hour OS build and no image to scan per commit.
The cost moves to runtime: each first boot depends on whatever hosts the config downloads from, which is why a mirror (doc 07) or a baked image is part of any serious design.

## Drift: what actually changes, and how you would notice

Immutability narrows drift; it does not abolish it. On a Flatcar node the places that can diverge from "image plus config" are:

- **`/etc` and `/var` edits by hand.** Anyone with root can write to ROOT. The upstream tooling gives you a way to see it: the update docs show `git diff --no-index /usr/share/flatcar/etc /etc` to list how a node's `/etc` differs from the OS defaults, valid for the overlay implementation (doc 04 notes that newer releases compose `/etc` differently).
- **Extensions and downloaded binaries.** A sysext updated by `systemd-sysupdate`, or a binary fetched to `/opt`, changes outside the A/B scheme (doc 06). Their versions are drift unless your config pins them.
- **Container state and RKE2 state.** Everything under `/var` is mutable by design.
- **The OS version itself.** With automatic updates on, node versions differ between rollouts, which is intentional but needs reporting (doc 08).
- **Ignition applied once.** A change in your config repository does not reach running nodes. The difference between repository and fleet is itself a drift measure.

The control is not detection and repair; it is a ceiling. Replace nodes on a schedule or whenever the config changes, so the age of the oldest node bounds how long any drift can live.
When a node must be reconfigured in place, `flatcar-reset` re-runs Ignition after cleaning selected state, which is a controlled reset rather than a patch (doc 04).

## Rebuild versus patch

The decision looks different under each model, and Flatcar offers a third option that is neither.

| Situation | Hard way | Golden image | Flatcar |
|---|---|---|---|
| OS security patch | `apt upgrade` on each node | Rebuild the image, roll nodes | Take the new vendor release: stage, then reboot (doc 07) |
| Kubernetes patch release | Replace binaries by hand | Rebuild image | New pinned artifacts and replace nodes; or in-place with SUC or sysupdate where supported (doc 10) |
| Config change (hostname scheme, sysctl, CA bundle) | Edit and restart | Rebuild or push via cloud-init | New config and replace node; `flatcar-reset` if you must keep the node |
| Emergency fix on one node | SSH and fix | SSH and fix, mark node tainted | `toolbox` or SSH to diagnose, then replace; the fix must land in the config or it will not survive |
| Roll back a bad OS update | Restore snapshot | Revert to prior image | Automatic fallback to the other partition, or `cgpt prioritize` (doc 04) |
| Roll back a bad config | Edit again | Revert image | Replace nodes with the prior config; running nodes are unchanged by definition |

The Flatcar-specific "patch" is the OS partition swap: it patches the whole OS atomically without a rebuild on your side, which is the thing golden images cannot do and the hard way does
only package by package. What you rebuild is the config.

## Where this leaves your tooling

If you run Packer and image-builder today, you do not stop; you change what they are for. For Flatcar they remain the right tool for Cluster API (Kubernetes baked under `/opt`, doc 09) and for any environment
that must not download at boot. They are no longer needed to keep the base OS patched, because the base OS is the vendor's. If you run Ansible against long-lived hosts today, the Flatcar equivalent of its
most valuable part (idempotent host configuration) is Ignition at first boot, and the part you lose is convergence on running nodes, which you replace with node replacement and a small set of
runtime agents you run yourself.

> ⚠️ Verify: first-boot download behavior at your scale. The labs download substantial artifacts per node (the RKE2 tarball, or the Kubernetes binaries in lab 04) from public hosts or from a local mirror you run. Measure boot time and failure modes (rate limits, DNS,
> proxy) for your environment before deciding between hash-pinned downloads and baked images.

## Key takeaways

- The three models differ in what the artifact is: shell history (hard way), a baked image (golden image), or a config applied to a vendor-built OS (Flatcar).
- A Flatcar pipeline lints, renders, pins and tests configs; optional image baking is for boot-time or no-download requirements, not for keeping the OS patched.
- Drift is narrowed, not eliminated: `/etc` and `/var` edits, extensions, container state and the one-time nature of Ignition all remain; the real control is a node-age ceiling and replacement.
- For OS patches, Flatcar replaces both "rebuild the image" and "`apt upgrade`" with staged partition swaps; for config changes you replace nodes; for emergencies you diagnose then fold the fix back into config.
- Keep image-builder for Cluster API and no-download environments; use Ignition where you used Ansible for first-time host setup.

## Sources

- Kubernetes the Hard Way, current chapters: [compute resources][kthw-03], [control plane][kthw-08]
- image-builder targets: [`images/capi/Makefile`][ib-makefile]; Flatcar CAPI variable files: [`packer/ami/flatcar.json`][ib-ami]
- Flatcar update docs (`/etc` diff, SERVER=disabled), boot process (`flatcar-reset`): [`update-strategies.md`][update-strategies], [`boot-process.md`][boot-process]
- Mantle and kola: [`flatcar/mantle` README][mantle]
- Docs 04, 05, 06, 07, 09 and 10 of this repository for the Flatcar mechanics referenced above

[kthw-03]: https://github.com/kelseyhightower/kubernetes-the-hard-way/blob/52eb26dad1a3e9e8083a899bc854421eb4842a73/docs/03-compute-resources.md
[kthw-08]: https://github.com/kelseyhightower/kubernetes-the-hard-way/blob/52eb26dad1a3e9e8083a899bc854421eb4842a73/docs/08-bootstrapping-kubernetes-controllers.md
[ib-makefile]: https://github.com/kubernetes-sigs/image-builder/blob/f18b988f05d99acedbddb9e12b23752931ac022c/images/capi/Makefile
[ib-ami]: https://github.com/kubernetes-sigs/image-builder/blob/f18b988f05d99acedbddb9e12b23752931ac022c/images/capi/packer/ami/flatcar.json
[update-strategies]: https://github.com/flatcar/flatcar-website/blob/415d66a7b79efa4374b927a4cd6d7b5bd1bfeb9c/content/docs/latest/updates-releases/releases/update-strategies.md
[boot-process]: https://github.com/flatcar/flatcar-website/blob/415d66a7b79efa4374b927a4cd6d7b5bd1bfeb9c/content/docs/latest/fb-provision/ignition/boot-process.md
[mantle]: https://github.com/flatcar/mantle/blob/cd7f79404e614cbd8c6536f899080bd633c27e97/README.md
