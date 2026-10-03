# 06 — Extending an immutable OS: systemd-sysext, the bakery, and the custom-image alternative

A read-only `/usr` raises an obvious question: where do the things that are not in the image go? Flatcar's answer has
changed over time, and the current answer, system extensions, is one you will use constantly (Docker and containerd are
themselves extensions now). This document explains the mechanism, why it replaced the earlier approaches, how Flatcar's
own extensions and the community bakery differ, what the trust model is, and when baking a custom image is the better
choice. The most useful part is the last: extensions and the A/B update scheme do not compose automatically, and the
consequences are easy to miss.

## What systemd-sysext does

A system extension is a self-contained, read-only image (a squashfs, erofs, ext4 or btrfs filesystem image, or a plain
directory) containing a tree under `/usr`, and optionally `/opt`. At boot, or on `systemd-sysext refresh`, systemd merges
the trees into the running hierarchies with an overlayfs, so extension content appears directly under `/usr`.
Compatibility is decided by a metadata file inside the image, `usr/lib/extension-release.d/extension-release.NAME`, which
must match the host: `ID=flatcar` plus either `VERSION_ID` (tied to a specific OS version) or `SYSEXT_LEVEL` (looser).
Images are found in `/etc/extensions/` and `/var/lib/extensions/` among other places, and a `NAME.raw` file or a `NAME`
directory is picked up ([sysext][sysext-doc]).

Flatcar's documentation gives the rule for choosing between the two match fields. If your binaries link against Flatcar's
libraries, you must couple the image to the OS version with `VERSION_ID=MAJOR.MINOR.PATCH`, which "means that the sysext
image won't be loaded anymore after an OS update". The recommended path is static binaries with
`SYSEXT_LEVEL=1.0`, which decouples the extension from the OS version ([sysext][sysext-doc]).

The sibling feature is `systemd-confext`, the same overlay idea for `/etc`. It matters here because Flatcar now uses it
for itself: from Alpha 4628.0.0, `/etc` is composed with a mutable confext whose defaults come from the image, with
`/etc` as the writable upper layer (doc 04). The image preparation unit symlinks `/var/lib/extensions.mutable/etc` to
`/etc` to enable that ([init unit][confext-unit]).

> ⚠️ Verify: whether and how users should supply their own confext images on Flatcar. The initrd refreshes confext a second
> time "so that any user-supplied configuration extensions are present at boot" (bootengine source comment), but the
> user-facing docs I read describe only sysext. Check the current docs before relying on user confext.

## Why this replaced the earlier approaches

Flatcar's own explanation, in the sysext documentation, is that components in a release have fixed versions, so a user
needing a different version "needs to be supplied out of band and overwrite the built-in software copy". The previous
recommendation was to put binaries in `/opt/bin` and prefer them in `PATH`. systemd's portable services addressed deploying
a service but "only covered the service itself without making the client binaries available", and so did not fit. Sysext
fills the gap: it makes custom binaries available to the whole system through a `/usr` overlay, with one image per
component, atomic to add or remove, and with metadata that says which OS it fits.

The project also retired an earlier add-on mechanism called torcx; the blog post linked from the sysext page is titled
"Extending Flatcar: say goodbye to torcx and hello to systemd-sysext".

> ⚠️ Verify: I could not retrieve the blog post, so I am not describing torcx's mechanics or retirement date here. Read
> it if you need the migration history.

The design consequence worth absorbing: an `/opt/bin` binary and a sysext binary look similar on the node, but they differ in
three ways that matter operationally. A sysext is a single versioned file you can inventory, verify and replace atomically.
It is read-only once merged. And it can carry systemd units that are active as soon as the extension is merged, which an
`/opt/bin` file cannot.

## How Flatcar uses extensions itself

Flatcar ships two classes of "official" extensions, built in its CI and distributed from the release servers
([sysext][sysext-doc]). Some are enabled by default and "opt-out": Docker, containerd and the OEM extension. Others are
"opt-in", enabled by writing their names, one per line, to `/etc/flatcar/enabled-sysext.conf`. At the time of the docs
snapshot these are `incus`, NVIDIA drivers, `overlaybd`, `podman`, `python` and `zfs`, with availability starting at
named Flatcar versions. A `-NAME` entry disables an extension that `/usr/share/flatcar/enabled-sysext.conf` enabled.

The initrd logic that implements this (doc 04) is worth knowing in detail. For each enabled name it expects an image at
`/etc/flatcar/sysext/flatcar-NAME-VERSION.raw`, symlinked from `/etc/extensions/flatcar-NAME.raw`. If the image is missing,
it starts networking and downloads it from the release file server, verified against the update payload key, and if that
download fails the boot fails ([bootengine][bootengine-setup]). Two operational consequences follow. A node enabling an
opt-in extension needs a route to the release server (or your replacement for it) during first boot. And in an air-gapped
or proxy-restricted environment you must override the download location with the kernel argument
`flatcar.release_file_server_url`, which the docs show as a Butane `kernel_arguments` entry; the final URL is
`${YOUR_SERVER_URL}/${FLATCAR_BOARD}/${VERSION}/${name}` ([sysext][sysext-doc]).

When the OS updates, the post-install step downloads the matching extension payloads for the new version too, which is why
a private update server must host `flatcar-NAME.gz` and `oem-NAME.gz` payloads in addition to the base payload (doc 07).

To remove Docker or containerd, which is what you do on a Kubernetes node that brings its own runtime, point the
extension symlinks at `/dev/null`:

```yaml
variant: flatcar
version: 1.1.0
storage:
  links:
    - path: /etc/extensions/docker-flatcar.raw
      target: /dev/null
      overwrite: true
    - path: /etc/extensions/containerd-flatcar.raw
      target: /dev/null
      overwrite: true
```

The original targets can be found in `/usr/share/flatcar/etc/extensions/` if you want to revert. Note that removing the
`containerd-flatcar` extension also removes the containerd config at `/usr/share/containerd/config.toml`, which the
docs say is read-only; to customize it you copy it to `/etc/containerd/config.toml`
([customizing Docker][customizing-docker]). The shipped config enables SELinux labeling and `SystemdCgroup = true`
([containerd config][containerd-config]).

## Release-dependent behavior you will hit

Flatcar changed how extensions are loaded in the release that also moved `/etc` to confext. In the older arrangement a unit
named `ensure-sysext.service` reloaded unit files after the merge, and the documentation still describes it. A December
2025 changelog entry records that sysext mounting moved into the initrd, so `.wants` symlinks for systemd units now work as
expected and the `ensure-sysext.service` workaround was dropped; the project still recommends that extensions use `Upholds=`
drop-ins and keep late-loading workarounds, "to better support live reloading", and notes that extensions on a separate
`/var` filesystem cannot be loaded early ([changelog][confext-changelog]). Present in Alpha 4628.0.0 and Stable 4757.2.0
per the release data, absent in LTS 4081.x.

The practical rule: ship extensions that start their units with an `Upholds=` drop-in on `multi-user.target` (or
`sockets.target`, `timers.target`), exactly as the docs and the bakery do, and they behave the same on both generations.

```ini
# usr/lib/systemd/system/multi-user.target.d/10-myservice.conf
[Unit]
Upholds=myservice.service
```

## The community path: the sysext bakery

Beyond official extensions, the `flatcar/sysext-bakery` repository builds a catalogue of community extensions and hosts
them as GitHub releases. The catalogue in the snapshot includes `kubernetes`, `rke2`, `k3s`, `cilium`, `containerd`,
`crio`, `docker`, `nerdctl`, `falco`, `tailscale`, `vault`, `nomad`, `consul`, `haproxy`, `keepalived`, `chrony` and more.
They are described as "self-contained, i.e. do not have any dependencies on the host operating system" and can be updated
independently of the host OS version ([bakery docs][bakery-index]). Flatcar's project docs are explicit that they are
"not tested in CI", unlike the official ones ([sysext][sysext-doc]).

Consumption is by Ignition, which downloads the `.raw` file and links it into `/etc/extensions`. Flatcar's `kubernetes` and
`rke2` examples show the update pattern: store the image under `/opt/extensions/NAME/`, point `/etc/extensions/NAME.raw` at
it, ship a `/etc/sysupdate.NAME.d/` transfer config, and a drop-in on `systemd-sysupdate.service` that runs
`systemd-sysupdate -C NAME update`, compares the resolved symlink before and after, and `touch /run/reboot-required` if it
changed, so kured (or anything watching that file) schedules the reboot. A no-op transfer at `/etc/sysupdate.d/noop.conf`
satisfies the default configuration. Updates are limited to patch releases within a minor: "never across releases
(v1.31.x -> v1.32.x)", "because upstream Kubernetes does not support unattended automated upgrades across minor releases"
([rke2 sysext][bakery-rke2], [kubernetes sysext][bakery-k8s]).

The bakery repository, extension images and `extensions.flatcar.org` hostname work together as a small supply chain you should
understand before depending on it:

- Releases are per-extension and per-version, with a `SHA256SUMS` index. systemd-sysupdate needs all images beside the index, so the project runs a small web service that rewrites GitHub release URLs; Flatcar's instance is `extensions.flatcar.org`. The bakery docs describe self-hosting this with a Caddy configuration ([bakery README][bakery-readme]).
- The generated sysupdate transfer files contain `Verify=false`, a `url-file` source, `InstancesMax=3`, a target under `/opt/extensions/`, and `CurrentSymlink=/etc/extensions/NAME.raw` ([sysupdate template][sysupdate-tmpl]). `Verify=false` means sysupdate does not check a GPG signature on the `SHA256SUMS` index. Integrity therefore rests on TLS to the host plus the checksums fetched from that same host.
- The Ignition examples in the docs fetch images without a `verification.hash`.

For a regulated estate the sensible response is not to avoid sysexts but to close those gaps yourself: pin the exact image in
Ignition with `verification.hash: sha256-...`, or host a mirror you control (a fork of the bakery plus your own `SHA256SUMS`
and, if you want sysupdate to verify, a signing key and `Verify=true`). Doc 08 lists this under supply-chain controls.

> ⚠️ Verify: `Verify=true` requires the signing public key to be available to `systemd-sysupdate` on the node (systemd's
> import keyring). I did not confirm where Flatcar expects that key. Treat verified sysupdate as a design task to prove in a
> lab, not a flag to flip.

## Building your own extension

The format is small enough to build by hand, which is what lab 03 does. In outline: lay out a directory tree under `usr/`,
add `usr/lib/extension-release.d/extension-release.NAME` with `ID=flatcar` and `SYSEXT_LEVEL=1.0` (or `VERSION_ID` if you link
against OS libraries), put binaries in `usr/bin` and units in `usr/lib/systemd/system`, add an `Upholds=` drop-in, and
run `mksquashfs` over the directory, which, as the docs note, "simply takes a directory as input and doesn't need loop
devices and mounting of an image file" ([sysext][sysext-doc]). For binaries with library dependencies on the host the bakery
provides `flix` and `flatwrap` helpers that rewrite library paths or run the content in a private root ([bakery README][bakery-readme]).

Debugging is with `systemd-dissect` (summary, `--list`, `--with IMAGE cat ...`) and
`SYSTEMD_LOG_LEVEL=debug systemd-sysext refresh`, which reports incompatibilities found during merging.

## Trust: what is signed and what is not

A November 2025 changelog entry records that Flatcar's OS-dependent extensions (docker, containerd, podman, ZFS, NVIDIA and
OEM images) are now "cryptographically signed using dm-verity roothash signatures", changed from squashfs to erofs
Discoverable Disk Images, and that this "provides a foundation for verifying user-provided extensions in future releases"
([changelog][signed-sysext]). Read that last clause literally: today the signing covers Flatcar's own extensions, and
extensions you supply are not subject to signature verification by default.

> ⚠️ Verify: whether the Flatcar release you run can enforce a policy requiring signed extensions, and what key it trusts
> for user extensions. The changelog describes groundwork, not an enforcement feature.

## The trap: extensions are not in the A/B scheme

This is the point that surprises people. The A/B partitions hold `/usr` as released. Extensions you add live on ROOT, under
`/opt/extensions` or `/etc/extensions`, which updates do not touch (doc 04). Therefore:

- An OS update is atomic and reversible; an extension update is not part of that. If `systemd-sysupdate` upgrades your Kubernetes extension and the node later rolls back the OS, the rolled-back OS boots with the newer extension, as long as the extension's `extension-release` still matches.
- `VERSION_ID`-coupled extensions stop loading after an OS update and, if the new OS boots into a state where a required extension is absent, the node comes up without it. That is safe but needs a plan (rebuild per OS version, or use static binaries and `SYSEXT_LEVEL`).
- Version skew between OS and extension is now a thing to control. Doc 10 shows how this plays out for RKE2: a sysext-delivered RKE2 changes version by changing which image the symlink points at, which happens at boot, which means it should be gated by the same reboot coordination as OS updates.

Official extensions avoid this because their payloads are tied to the OS version and updated by `update_engine` together
with `/usr`. User extensions only get that treatment if you build them into your own image or version them yourself.

## Extension, custom image, or neither

| Option | Best when | Cost | Rollback with the OS |
|---|---|---|---|
| Container | You can run it as a container or DaemonSet | Needs a runtime and orchestration; not for host-level agents or the container runtime itself | Independent of the OS |
| Official sysext (opt-in) | The component is in the list and you want it tied to the OS version | Needs the release file server reachable (or a mirror) | Yes, versioned with the OS |
| Bakery or custom sysext | A host-level binary or runtime not in the image, updated on its own cadence | You own provenance, hashing, version-coupling and reboot gating | No, unless you version it with the OS |
| `/opt/bin` binary | A single static tool, no units | No inventory or metadata; PATH handling is manual | No |
| Custom image (`bake_flatcar_image.sh` or SDK build) | Policy forbids first-boot downloads, you need everything in the image, or you need to change the base | You run the build, signing and update-server content for your version | Yes, if you ship it as your own update payload |

`bake_flatcar_image.sh` is the lighter custom-image path. It "will download a Flatcar OS release image, insert the desired
sysexts, and optionally create a vendor ... image", placing sysexts on the root or OEM partition, and uses the SDK container
for vendor images ([bakery docs][bakery-index]). Note what it does not do: it does not turn your extension into part of the
A/B `/usr` partition, so the rollback column above still says "not unless you version it." Full custom builds from the SDK
(doc 03, doc 11) do. The rule of thumb is to use extensions when the component changes faster than the OS or belongs to someone
else, and to bake an image when you need the result to be one auditable, versioned artifact.

## Key takeaways

- A sysext is a read-only image overlaid on `/usr` and `/opt`, matched to the host by `ID=flatcar` plus `VERSION_ID` or `SYSEXT_LEVEL`; static binaries with `SYSEXT_LEVEL` avoid coupling to OS versions.
- Docker and containerd are Flatcar sysexts enabled by default; opt-in official extensions come from `/etc/flatcar/enabled-sysext.conf` and are downloaded in the initrd, where a failed download fails the boot.
- Bakery extensions are community-built and untested by Flatcar CI, and their sysupdate configs ship with `Verify=false`; pin hashes in Ignition or run your own signed mirror.
- Extensions live on ROOT, outside the A/B scheme, so an OS rollback does not roll back an extension; gate extension changes behind the same reboot coordination as OS updates.
- Use extensions for host components that move on their own cadence; bake a custom image when you need one auditable, versioned artifact or no first-boot downloads.

## Sources

- System Extensions (official and community, format, Ignition examples, sysupdate, debugging): [`sys-ext/_index.md`][sysext-doc]
- Bakery overview, releases, baking images: [`sysext-bakery docs/index.md`][bakery-index], [`README.md`][bakery-readme]
- Bakery sysupdate template (`Verify=false`): [`lib/sysupdate.conf.tmpl`][sysupdate-tmpl]; RKE2 and Kubernetes extension docs and builds: [`docs/rke2.md`][bakery-rke2], [`docs/kubernetes.md`][bakery-k8s]
- Initrd extension setup: [`bootengine/dracut/99setup-root/initrd-setup-root-after-ignition`][bootengine-setup]
- Confext/mutable `/etc`: [`init systemd-confext.service.d`][confext-unit], [changelog 2025-12-12][confext-changelog]
- Signed OS-dependent sysexts: [changelog 2025-11-05][signed-sysext]
- containerd defaults: [`containerd/usr/share/containerd/config.toml`][containerd-config]; customizing Docker/containerd: [`customizing-docker.md`][customizing-docker]
- systemd man pages for `systemd-sysext` and `systemd-confext` (upstream reference): <https://www.freedesktop.org/software/systemd/man/systemd-sysext.html>

[sysext-doc]: https://github.com/flatcar/flatcar-website/blob/415d66a7b79efa4374b927a4cd6d7b5bd1bfeb9c/content/docs/latest/sys-ext/_index.md
[bakery-index]: https://github.com/flatcar/sysext-bakery/blob/445ccc99020d18b07c58c1217b0fcde43fe590c7/docs/index.md
[bakery-readme]: https://github.com/flatcar/sysext-bakery/blob/445ccc99020d18b07c58c1217b0fcde43fe590c7/README.md
[sysupdate-tmpl]: https://github.com/flatcar/sysext-bakery/blob/445ccc99020d18b07c58c1217b0fcde43fe590c7/lib/sysupdate.conf.tmpl
[bakery-rke2]: https://github.com/flatcar/sysext-bakery/blob/445ccc99020d18b07c58c1217b0fcde43fe590c7/docs/rke2.md
[bakery-k8s]: https://github.com/flatcar/sysext-bakery/blob/445ccc99020d18b07c58c1217b0fcde43fe590c7/docs/kubernetes.md
[bootengine-setup]: https://github.com/flatcar/bootengine/blob/7727ec78da72e700e8fa1ce2144cb2476448d186/dracut/99setup-root/initrd-setup-root-after-ignition
[confext-unit]: https://github.com/flatcar/init/blob/0765e955aca24034d66b9389e0d538e4c3ee543c/systemd/system/systemd-confext.service.d/prepare-mutable.conf
[confext-changelog]: https://github.com/flatcar/scripts/blob/2189f1e166e28c06cdcd1b26fea47f05da78c139/changelog/changes/2025-12-12-default-systemd-confext.md
[signed-sysext]: https://github.com/flatcar/scripts/blob/2189f1e166e28c06cdcd1b26fea47f05da78c139/changelog/changes/2025-11-05-signed-os-dependent-sysexts.md
[containerd-config]: https://github.com/flatcar/scripts/blob/2189f1e166e28c06cdcd1b26fea47f05da78c139/sdk_container/src/third_party/coreos-overlay/coreos/sysext/containerd/usr/share/containerd/config.toml
[customizing-docker]: https://github.com/flatcar/flatcar-website/blob/415d66a7b79efa4374b927a4cd6d7b5bd1bfeb9c/content/docs/latest/orchestrate/containers/customizing-docker.md
