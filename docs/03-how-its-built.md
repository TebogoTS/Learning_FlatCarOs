# 03 — How Flatcar is built: SDK, images, payloads, channels, signing

An immutable OS is only as trustworthy as the pipeline that produces the immutable thing. This document follows an
artifact from source to the bytes on your node: the Gentoo-derived SDK that compiles everything, the image and update
payload formats, how a release moves through Alpha, Beta, Stable and LTS, and what is signed, by what, and checked by
whom. The design rationale is the point: each choice exists because Flatcar ships whole images and must therefore
control every input to them.

## Why a source-based, Gentoo-derived build

A package-based distribution assembles its images from binary packages built elsewhere, and you inherit that
distribution's build decisions package by package. Flatcar does the opposite. Its supply-chain documentation states the
first foundational rule: "We always build from source. All our artifacts are built from source; no pre-generated
binaries are used. Builds are performed by a validated SDK which is the result of a previous, validated, build."
([supply chain][supply-chain]).

Gentoo's Portage is a good substrate for that rule for three reasons. Packages are described by ebuilds that carry
cryptographic checksums of upstream source tarballs, so inputs are pinned by content. USE flags let the project compile
only the features it ships, which is how an image avoids carrying code it does not use. And Portage supports building
for a target root that is separate from the build host, which is how one SDK produces both amd64 and arm64 images.

The package definitions live in the `flatcar/scripts` repository in two ebuild trees. `portage-stable` is, in the
project's words, "a fork of Gentoo upstream's `portage-stable`" holding ebuilds "close to (or identical to) Gentoo
upstream"; `coreos-overlay` holds Flatcar-specific packages (Ignition, update_engine, mayday, toolbox) and Gentoo
packages that were "significantly modified for Flatcar, like the Linux kernel, or systemd"
([modifying Flatcar][sdk-modifying]). The repository is called `scripts` for historical reasons; the docs suggest
thinking of it as the SDK repository.

## The SDK is a container, and it is built by the previous SDK

The SDK is distributed as a container image (on GHCR), run through `./run_sdk_container`, with the local `scripts`
checkout bind-mounted. Inside it, OS packages get their own root, `/build/amd64-usr/` or `/build/arm64-usr/`, separate
from the SDK's own root, and are managed with `emerge-amd64-usr` and `emerge-arm64-usr` rather than `emerge`
([modifying Flatcar][sdk-modifying]). The core build sequence for an image is three commands: `./build_packages`,
`./build_image`, and `./image_to_vm.sh`, with `--board=arm64-usr` selecting ARM64.

The SDK itself is produced by `bootstrap_sdk` in four stages using Gentoo's catalyst, each in an isolated chroot with
the previous stage's output as its seed. Stage 1 builds a minimal toolchain from a previous Flatcar SDK; stage 2 builds
the full toolchain that will build the SDK, with strong library link isolation; stage 3 builds the base OS with
`emerge @world`; stage 4 adds the remaining SDK dependencies and the ARM and x86 cross-compilers
([SDK bootstrap][sdk-bootstrap]). Two consequences are worth noting. The chain is self-referential by design, so the
trust root is the last validated SDK, which is why the supply-chain document says the SDK container "is validated by its
container registry checksum". And a full SDK rebuild is expensive and rare: the release guide says the first Alpha of a
new major version must build a new SDK, and that this "takes 6-10 hours" including images for all formats and the test
suite ([release guide][release-guide]).

## What a build produces

`build_image` produces a generic disk image with the partition layout described in doc 04. `image_to_vm.sh` converts it
to vendor formats and, in the project's description, "will read the generic disk image, install any vendor specific
tools to the OEM partition where applicable (e.g. Azure VM tools for the Azure VM), and produce a vendor specific image"
(the QEMU, VMware OVA, AWS VMDK and other artifacts you download all come from this step). Several security-relevant
steps happen during image creation:

The dm-verity hash of the `/usr` partition is computed and "written into the kernel by the `build_image` script",
then injected into the kernel command line by GRUB ([disk layout][disk-layout]). The kernel and initrd for each slot
are stored in the EFI System Partition. The repository also contains an `sbsign_image` script and Secure Boot related
changelog entries: GRUB carries Red Hat's Secure Boot patches, there is a shim update path, and out-of-tree kernel
modules for the NVIDIA and ZFS extensions are signed with an ephemeral key so they work under Secure Boot
([changelog][changelog-grub], [module signing][changelog-oot]).

Optional components are built as system extension images by `build_sysext` and per-extension `sysext_mangle_*` scripts
(`docker-flatcar`, `containerd-flatcar`, `flatcar-podman`, `flatcar-zfs`, NVIDIA drivers and others). A November 2025
changelog entry records that OS-dependent sysexts are now "cryptographically signed using dm-verity roothash
signatures" and changed format "from squashfs to erofs-based Discoverable Disk Images"; OEM sysexts are signed in the
same way ([changelog][changelog-signed-sysext]). Doc 06 covers what that means for extensions you supply yourself.

> ⚠️ Verify: which release first carries signed, erofs-based OS-dependent sysexts. The changelog entry is dated
> November 2025 in the `scripts` repository; confirm in the release notes for the channel and version you run.

## Update payloads are whole partition images

The artifact an installed node consumes is not the disk image. It is `flatcar_production_update.gz`, a payload
containing the new `/usr` partition. The docs say updates are "shipped as full partition images", and the update
client's request in the PXE stub even states `delta_okay="false"` ([supply chain][supply-chain],
[update_engine_stub][ue-stub]). Optional payloads travel alongside: OEM payloads (`oem-NAME.gz`) and Flatcar extension
payloads (`flatcar-NAME.gz`), which is why a private update server must host them too (doc 07).

The payload is the single most security-critical artifact because many fleets apply it automatically. The project's
design therefore adds a separate, stronger signing step for it: after the build, "a core maintainer downloads the update
image from the secure build server, and validates the image and its server signature. The image is then signed with a
key stored on a hardware security module (HSM), in an air-gapped environment so the key is never exposed to the
internet" ([supply chain][supply-chain]). The release guide describes this step as manual: it "requires a person with a
Flatcar HSM key and physical access to a secure laptop with Tails" ([release guide][release-guide]). The node-side
counterpart is a baked-in public key at `/usr/share/update_engine/update-payload-key.pub.pem` on the verity-protected
partition; `flatcar-update` can even bind-mount a different key for developer builds, which is why that key sits behind
a flag called `--force-dev-key` ([flatcar-update][flatcar-update]).

For a regulated reviewer, the correct reading is that payload authenticity rests on one HSM-held key operated by a human
process. That is a deliberate air-gap, and it is also a bus-factor and key-custody question worth asking the project
about (doc 02 lists it).

## Versions, channels and how promotion works

The version number is `MMMM.m.p`. A new major number is introduced with every new Alpha release; the minor number
encodes the stabilisation level, where 0 is Alpha, 1 is Beta and 2 is Stable; the patch number counts incremental
releases within the same channel ([production images][sdk-production]). LTS releases carry minor 3 (for example
`4081.3.10`, `3510.3.8`, `3033.3.18` in the release data). The major number is derived from a date: the release guide
computes it as days since 2013-07-01, so `4841` corresponds to early October 2026.

> ⚠️ Verify: the release guide's example commands use `4564.3.0` for Stable and `4564.4.0` for LTS, which does not match
> the minor-number convention in the production-images doc or the actual LTS releases. Treat those examples as
> illustrative, not as the rule.

Promotion does not copy bits between channels. A major version is a branch, `flatcar-MAJOR`, in the `scripts` repository,
and in the project's own picture, "major releases as branches from `main`, while Alpha, Beta and Stable releases are
distinct points in the lifecycle of a release branch". The `tag-release` tool creates a release tag such as
`beta-4564.1.0` for the branch state in each repository, and the Jenkins pipeline builds that tag. So a Beta or Stable
release is a separate build from the branch, carrying whatever fixes landed since the Alpha, followed by its own full
test run ([release guide][release-guide]). That is why Stable's contents differ slightly from the Alpha it descends from,
and why a Stable patch release can ship a security fix without waiting for a new major.

The cadence is published in `RELEASES.md`. Releases within a channel are planned on a 14-day cadence; a new major Alpha is
targeted monthly, Alpha to Beta every two months, Beta to Stable every three to four months, and a new LTS yearly.
In the channels documentation's words, "Roughly every second major Alpha release is promoted to the Beta channel" and
"Roughly every second major Beta release is promoted to Stable", with Stable receiving "the bug fix release of a new major
release" rather than a brand new major ([switching channels][channels], [RELEASES][releases]).

Each LTS stream has an 18-month support cycle with six months of overlap, and the public `lts` group follows the newest
stream, which can cause a major version jump. The docs therefore recommend freezing to a named stream, such as
`GROUP=lts-2024`, and moving between streams deliberately ([switching channels][channels]).

| Channel | Role | Typical use |
|---|---|---|
| Alpha | New features and major upgrades land first | Developers and compatibility testing |
| Beta | Promoted Alpha, stabilising | A few canary nodes to validate your workloads |
| Stable | Promoted Beta, bug fixes only, default | Production |
| LTS | Cut from a long-proven Stable, 18 months, fixes only | Low-change, high-assurance estates |

## The release pipeline, step by step

Reading the release guide as a sequence shows where a human is in the loop and where automation is. Reference only; the
guide is written for maintainers and says so.

1. A maintainer creates release tags with `tag-release` on the `flatcar-MAJOR` branches.
2. Jenkins builds the tag (`container/packages_all_arches`, or `container/sdk` for a new major) for both architectures and generates images for all formats.
3. The test suites run for all vendor platforms; failing tests are re-run to separate infrastructure failures from real ones.
4. Reviewers compare the package diff and image size against the previous release; the guide names kernel, systemd and Docker as critical packages to check.
5. A go/no-go vote takes place asynchronously on Discord; more than half of the maintainers voting is enough.
6. The `container/release` job publishes cloud images and copies artifacts to the CDN behind the `{alpha,beta,stable}.release.flatcar-linux.net` hosts.
7. A person with the HSM key signs and uploads the update payload to the update service (Nebraska), before release notes are published.
8. A GitHub release is created, the website data is refreshed from it by a workflow, and announcements go out.

## Signing and verification, end to end

Every release image and related artifact is signed at build time with a 4096-bit RSA GPG key that is "always stored
encrypted" with a one-year lifetime; access is restricted to core maintainers. Installation images ship with `.DIGESTS`,
`.DIGESTS.sig` and `.DIGESTS.asc` files, and smaller artifacts ship a `.sig`. The public key is published on the
Flatcar website, and the `flatcar-install` script verifies images automatically. The verification guide shows the manual
route: import `Flatcar_Image_Signing_Key.asc`, check the key ID matches the website, then `gpg --verify` the
`.sig` next to the image ([verify images][verify-images]). The supply-chain document is candid that validation is
"strongly recommended" but "not enforced by the distribution": nothing prevents you installing an unverified image.

Per-package SLSA provenance is generated during the build and shipped in the image under `/usr/share/SLSA/`. The project
assesses itself at SLSA Level 3, and lists exactly where it falls short: builds are not hermetic (there is a tracking
issue), the common "security" requirement around a TPM-anchored chain of trust is not met, and changes to the build system
do not require a second administrator's approval ([supply chain][supply-chain]). At runtime the verity root hash baked into the
kernel is what dm-verity checks `/usr` against, so a block that does not match is rejected when it is read rather than
silently served, and `update_engine` verifies each payload against its baked-in public key before installing it.

What you should do with this in a regulated estate is verify at the two boundaries Flatcar leaves to you: verify image
signatures in your provisioning pipeline rather than trusting a download, and if you run a private update server, treat
the payloads you mirror as signed artifacts you re-verify at ingest, not as files you trust because they are on your
network (doc 07).

## Building your own images, and why you usually should not

Everything above is also available to you: you can build the whole OS, or a customized image with extra sysexts baked in,
from the same sources ([production images][sdk-production], [`bake_flatcar_image.sh`][bakery-bake]). The rationale for
doing so is strong in specific cases, such as shipping a hardened kernel configuration, adding a package into the base
image, or satisfying a policy that forbids any download at first boot. The cost is that you now own the build pipeline,
the signing, the SDK lifecycle and the update server content for your custom version, which is the exact set of
responsibilities Flatcar's own release guide shows to be heavy. Doc 11 treats that trade in detail.

## Key takeaways

- Flatcar builds everything from source with a Gentoo-derived containerised SDK that is itself built by the previous SDK; inputs are pinned by ebuild checksums.
- The OS ships as whole images, and updates as whole `/usr` partition payloads, signed separately by an HSM-held key operated through a manual process.
- Versions are `MAJOR.MINOR.PATCH` with minor 0/1/2/3 meaning Alpha/Beta/Stable/LTS; promotion is a new tag and a new build of the same `flatcar-MAJOR` branch, not a file copy.
- Image signing is GPG-based and verification is your job; the project self-assesses at SLSA Level 3 and documents its gaps (non-hermetic builds, no TPM chain).
- Customizing the image yourself is possible and sometimes right, but it transfers the pipeline, signing and update-server responsibilities to you.

## Sources

- Supply chain security mechanisms: [`security/supply-chain.md`][supply-chain]
- SDK bootstrap process: [`devguide/sdk-bootstrapping.md`][sdk-bootstrap]
- Building custom images and ebuild trees: [`devguide/sdk-modifying-flatcar.md`][sdk-modifying]
- Production images, versioning and stabilisation: [`devguide/sdk-building-production-images.md`][sdk-production]
- Release guide: [`devguide/release-guide.md`][release-guide]
- Disk layout and dm-verity: [`devguide/sdk-disk-partitions.md`][disk-layout]
- Channels and LTS: [`switching-channels.md`][channels], [`RELEASES.md`][releases]
- Verifying images: [`verify-images.md`][verify-images]
- `flatcar-update`: [`flatcar/init bin/flatcar-update`][flatcar-update]; PXE update stub: [`update_engine_stub`][ue-stub]
- Changelog entries: [signed sysexts][changelog-signed-sysext], [Secure Boot / GRUB][changelog-grub], [module signing][changelog-oot]
- Sysext bakery image baking: [`sysext-bakery` README][bakery-bake]

[supply-chain]: https://github.com/flatcar/flatcar-website/blob/415d66a7b79efa4374b927a4cd6d7b5bd1bfeb9c/content/docs/latest/security/supply-chain.md
[sdk-bootstrap]: https://github.com/flatcar/flatcar-website/blob/415d66a7b79efa4374b927a4cd6d7b5bd1bfeb9c/content/docs/latest/devguide/sdk-bootstrapping.md
[sdk-modifying]: https://github.com/flatcar/flatcar-website/blob/415d66a7b79efa4374b927a4cd6d7b5bd1bfeb9c/content/docs/latest/devguide/sdk-modifying-flatcar.md
[sdk-production]: https://github.com/flatcar/flatcar-website/blob/415d66a7b79efa4374b927a4cd6d7b5bd1bfeb9c/content/docs/latest/devguide/sdk-building-production-images.md
[release-guide]: https://github.com/flatcar/flatcar-website/blob/415d66a7b79efa4374b927a4cd6d7b5bd1bfeb9c/content/docs/latest/devguide/release-guide.md
[disk-layout]: https://github.com/flatcar/flatcar-website/blob/415d66a7b79efa4374b927a4cd6d7b5bd1bfeb9c/content/docs/latest/devguide/sdk-disk-partitions.md
[channels]: https://github.com/flatcar/flatcar-website/blob/415d66a7b79efa4374b927a4cd6d7b5bd1bfeb9c/content/docs/latest/updates-releases/releases/switching-channels.md
[releases]: https://github.com/flatcar/Flatcar/blob/42d9daa78c15f0c2d8f370bb7516de95cfb23819/RELEASES.md
[verify-images]: https://github.com/flatcar/flatcar-website/blob/415d66a7b79efa4374b927a4cd6d7b5bd1bfeb9c/content/docs/latest/updates-releases/releases/verify-images.md
[flatcar-update]: https://github.com/flatcar/init/blob/0765e955aca24034d66b9389e0d538e4c3ee543c/bin/flatcar-update
[ue-stub]: https://github.com/flatcar/update_engine/blob/f23d6ea848ffe2c8721bc49d2a9f77f4de038ad2/systemd/update_engine_stub
[changelog-signed-sysext]: https://github.com/flatcar/scripts/blob/2189f1e166e28c06cdcd1b26fea47f05da78c139/changelog/changes/2025-11-05-signed-os-dependent-sysexts.md
[changelog-grub]: https://github.com/flatcar/scripts/blob/2189f1e166e28c06cdcd1b26fea47f05da78c139/changelog/changes/2024-11-06-grub-2.12-flatcar3.md
[changelog-oot]: https://github.com/flatcar/scripts/blob/2189f1e166e28c06cdcd1b26fea47f05da78c139/changelog/changes/2025-05-13-oot-module-signing.md
[bakery-bake]: https://github.com/flatcar/sysext-bakery/blob/445ccc99020d18b07c58c1217b0fcde43fe590c7/README.md
