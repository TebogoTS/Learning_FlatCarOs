# Lab 03 — A custom system extension

## Goal

Build your own sysext (a small static Go program, `flatcar-hello`, plus a unit), have Ignition fetch it with a pinned SHA-256 and link it where `systemd-sysext` finds it, confirm it merges into the read-only `/usr`, then upgrade it from `v1` to `v2` in place by hand, and optionally with `systemd-sysupdate`.

Concepts exercised: [06 Extending the OS with system extensions](../../docs/06-extending-sysext.md), and the "pinned artifact" pattern from [05 Provisioning](../../docs/05-provisioning.md).

## Prerequisites

Host tools from [../README.md](../README.md), plus `go`, `mksquashfs` and `unsquashfs` (package `squashfs-tools`). No root, no KVM-specific setup. Internet only for the base image.

## Steps

1. **Build the images.** `make lab03-build` runs the payload's unit tests, then builds `out/flatcar-hello-v1.raw` and `-v2.raw` (squashfs, with `extension-release.flatcar-hello` using `ID=flatcar` and `SYSEXT_LEVEL=1.0`, and a drop-in that `Upholds=` the service from `multi-user.target`). The build fixes file times, so the same sources give the same hash; run it twice and compare `out/SHA256SUMS`.
2. **Boot with v1.** `make lab03-up` starts a small HTTP server on the host (`scripts/serve.sh`), renders the config with the hash of `v1` computed from the file on disk, and boots the VM. Ignition downloads `http://10.0.2.2:8089/flatcar-hello-v1.raw` (QEMU's name for the host loopback), refuses to continue if the hash differs, stores it under `/opt/extensions/flatcar-hello/` and links it at `/etc/extensions/flatcar-hello.raw`.
3. **Verify the merge.**
   ```sh
   make lab03-verify
   make lab03-ssh      # then: systemd-sysext status; findmnt /usr; flatcar-hello --version; curl -s localhost:8088/info
   ```
   `/usr` is now an overlay mount whose lowest layer is the verity-protected OS; your binary is in `/usr/bin` without having been written there.
4. **Upgrade by hand.** `make lab03-upgrade-manual` downloads `v2`, checks it against the hash from your build, repoints the link, restarts `systemd-sysext` and the service, and runs the verification for `v2`. This is the whole of what an upgrade of a non-OS component is in this model: a new file, a changed symlink, a refresh.
5. **Optional, experimental: sysupdate.** `make lab03-upgrade-sysupdate` runs `systemd-sysupdate -C flatcar-hello update` against the same server. The transfer file in the config copies the shape the bakery generates and sets `Verify=false`, meaning sysupdate does not check a signature on the `SHA256SUMS` index; here integrity rests on your own host. In production you sign the index and use `Verify=true` (doc 06).

## Verification

`make lab03-verify` (default `v1`) and the automatic run after each upgrade assert: Flatcar `4757.2.1`; the extension listed by `systemd-sysext`; `/usr` mounted as an overlay; the image on disk matches the pinned hash; the symlink points at the expected file; the binary reports the right version; the service is active; the service answers and reports the host OS version; and `/usr` is still not writable by the administrator. **Expected shape:** `lab 03 (v1): all checks passed`, then `lab 03 (v2): all checks passed` after the upgrade.

## Teardown

```sh
make lab03-down       # power off and stop the HTTP server
make lab03-destroy    # delete the VM, state and stop the server
```

## Validated and not validated

Validated here, for real: the payload's Go tests; the squashfs build and its reproducibility (two builds, same hash); the static binary runs and serves; the config transpiles with the pinned Butane `--strict` and passes the policy checks; the scripts pass `shellcheck`.

**Not validated:** that the image merges on Flatcar `4757.2.1` (it depends on the extension-release matching, which I chose conservatively with `SYSEXT_LEVEL`); that `systemctl restart systemd-sysext` is the right refresh command on this release (the doc I read describes it, but behaviour differs between the pre- and post-4628 initrd-sysext code paths); and the whole `systemd-sysupdate` path, which is the part I would trust least: the transfer-file keys and the `MatchPattern` form were copied from the bakery's generator, not run. If `upgrade-sysupdate` fails, the manual path is the one to rely on.

> ⚠️ Verify: whether the `url-file` source type and `@v` pattern in `/etc/sysupdate.flatcar-hello.d/flatcar-hello.conf` match the systemd version in this release; `systemd-sysupdate --help` and `man sysupdate.d` on the VM are the references.
