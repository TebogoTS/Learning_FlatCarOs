# Lab 01 — First boot under QEMU

## Goal

Boot Flatcar `4757.2.1` (Stable, pinned in `versions.env`) from a verified image with a minimal Ignition config, then look at the things docs 03 and 04 describe: the partition layout, the read-only dm-verity `/usr`, the A/B slots and their GPT attributes, what Ignition wrote, and the merged extensions.

Concepts exercised: [03 How it is built](../../docs/03-how-its-built.md), [04 Runtime](../../docs/04-runtime.md), [05 Provisioning](../../docs/05-provisioning.md).

## Prerequisites

Common host tools from [../README.md](../README.md) (QEMU, `curl`, `gpg`, `ssh`). No root. About 1 GB of cache for the image. KVM strongly recommended.

```sh
make tools butane
```

## Steps

1. **Render, boot, wait for SSH.** The script verifies the image signature, renders `butane/node.bu.tmpl` with your lab SSH key, transpiles it strictly, creates a copy-on-write overlay and starts QEMU with the config passed through `fw_cfg`.
   ```sh
   make lab01-up
   ```
   Read the template first (`butane/node.bu.tmpl`): a user key, `/etc/hostname`, a marker file, `update.conf` with `SERVER=disabled`, `locksmithd` masked, and one oneshot unit.
2. **Look around.** `make lab01-explore` runs the commands below and prints their output; or run them yourself with `make lab01-ssh`.
   - `lsblk -o NAME,SIZE,FSTYPE,PARTLABEL,MOUNTPOINTS`: the partitions `EFI-SYSTEM`, `BIOS-BOOT`, `USR-A`, `USR-B`, `OEM`, `OEM-CONFIG`, `ROOT`.
   - `sudo cgpt show "$(rootdev -d)"`: priority, tries and successful for each USR slot.
   - `rootdev -s /usr` and `mount | grep -w /usr`: `/usr` is a `dm-verity` device mounted read-only.
   - `sudo touch /usr/should-fail`: fails with a read-only filesystem error.
   - `cat /proc/cmdline`: note `mount.usrflags=ro` and the verity hash.
   - `cat /etc/lab/provisioned-by-ignition /var/lib/lab/hello`: what Ignition and your unit wrote.
   - `systemd-sysext status`: Docker and containerd are extensions merged into `/usr`.
3. **Prove Ignition runs once.** Change something Ignition wrote (`sudo sh -c 'echo changed > /etc/lab/provisioned-by-ignition'`), `sudo reboot`, reconnect: the change persists, because `/etc` is on the writable root and Ignition is not re-run (doc 05).
4. **Rebuild instead of repair.** To see "replace, not patch" concretely, edit the template (for example the marker text), then `make lab01-destroy lab01-up`. The new config applies from scratch.

## Verification

```sh
make lab01-verify
```

It asserts fourteen properties over SSH: Flatcar `4757.2.1`, hostname and marker from Ignition, `/usr` read-only, on a verity device, the partition labels, a USR slot marked successful, ROOT writable and grown, the first-boot flag removed, `lab-hello.service` ran, `locksmithd` masked, updates frozen, and no package manager. **Expected shape** (not captured output):

```
[..] PASS  OS is Flatcar 4757.2.1
[..] PASS  /usr is mounted read-only
 ...
[..] lab 01: all checks passed
```

## Teardown

```sh
make lab01-down       # power off, keep the disk
make lab01-destroy    # delete the VM and all lab state
```

## Validated and not validated

Validated here: the template renders and transpiles with the pinned Butane `--strict` and passes the policy checks (`make check`); the scripts pass `shellcheck`; the image-signature path was exercised for the key import and fingerprint check, and the QEMU command line was checked in dry-run mode (`labs/lib/selftest.sh`).

**Not validated:** the boot itself, and therefore every command in "Look around" and every assertion in `verify.sh`. Some assertions depend on release details I could not observe (for example the exact partition labels, the `cgpt` output format, and which `/etc` mechanism this release uses). If a check fails, treat it as a possible error in my script before a problem with your host.
