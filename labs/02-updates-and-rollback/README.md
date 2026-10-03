# Lab 02 — Updates, A/B switch and rollback

## Goal

Watch a real Flatcar OS update from the old pinned release (`4593.2.5`) to the current pinned one (`4757.2.1`): staged to the passive USR slot, activated by a reboot, confirmed by `update_engine` only after a health check passes. Then roll back by hand with `cgpt prioritize`, and finally make an update fail and watch GRUB fall back to the previous slot on its own.

Concepts exercised: [04 Runtime](../../docs/04-runtime.md) (A/B, `cgpt`, `gptprio`), [07 Updates in production](../../docs/07-updates-in-production.md) (reboot managers, health gate). Diagram: [A/B update and rollback](../../docs/diagrams/ab-update-and-rollback.mmd).

## Prerequisites

Host tools from [../README.md](../README.md), no root, and **outbound access to the Flatcar release and update servers** (the VM downloads the update itself, about a few hundred MB). To run offline, mirror the images and point `FLATCAR_IMAGE_BASE_URL` and `update_server` in `inventory.yaml` at a Nebraska or other Omaha server (doc 07).

## Steps

1. **Boot the old release with the health gate.**
   ```sh
   make lab02-up                 # GATE=false make lab02-up   to run without the gate
   make lab02-verify-baseline
   make lab02-status
   ```
   The template (`butane/node.bu.tmpl`) installs the pattern from the Flatcar learning series: `update-engine` only starts once `/run/first-boot-healthy` exists, which a detect script creates only when `lab-critical.service` is up, and a timer reboots an unhealthy boot. Read the units; they are the lab's point.
2. **Stage the update.**
   ```sh
   make lab02-update
   ```
   The script polls `update_engine_client -status` until `UPDATE_STATUS_UPDATED_NEED_REBOOT`, then prints both slots. **Expected shape:** the passive slot now has the higher priority and one try left; `/run/reboot-required` exists (the sentinel kured watches).
3. **Activate and confirm.**
   ```sh
   make lab02-reboot
   make lab02-verify-updated
   ```
   The node boots from the other slot at the new version; the slot is marked `successful` only after the gate lets `update-engine` run (the script waits for it).
4. **Roll back by hand.**
   ```sh
   make lab02-rollback
   make lab02-verify-rolled-back
   ```
   The script freezes updates, finds the passive slot with `cgpt find -t flatcar-usr`, runs `cgpt prioritize` on it and reboots: the node is back on `4593.2.5`.
5. **Automatic rollback.** From a fresh start (`make lab02-destroy lab02-up`):
   ```sh
   make lab02-fail-update
   ```
   It stages the update, touches `/etc/lab/critical-fail` so the critical service refuses to start, and reboots. **Expected shape:** the node boots `4757.2.1`, the gate stays closed, the timer reboots it after `gate_timeout` seconds, and it comes back on `4593.2.5` because the new slot never became successful and ran out of tries.
6. **Optional: no gate.** `GATE=false make lab02-up`, then `make lab02-update lab02-reboot`. Without the gate nothing holds `update-engine` back, so the new slot is marked successful as soon as the service runs, whether or not your workload is healthy. The lab does not automate a failing update in this mode (`fail-update` requires the gate); compare the two unit sets in the rendered configs (`make render-ci` writes both to `build/lab02` and `build/lab02-nogate`).

## Verification

`verify-baseline`, `verify-updated` and `verify-rolled-back` assert version, slot, `successful` flag, frozen updates and gate state at each phase. Each prints `PASS`/`FAIL` lines and a final summary.

## Teardown

```sh
make lab02-down       # power off
make lab02-destroy    # delete the VM and state
```

## Validated and not validated

Validated here: both gate variants transpile with the pinned Butane `--strict` and pass the policy checks; the scripts pass `shellcheck`. While writing I corrected two bugs by reading the scripts against the unit files (a missing `first-usr` marker and an over-complex slot-wait command).

**Not validated:** everything dynamic: whether the public update servers serve this update path from `4593.2.5` today, the `update_engine_client -status` output format, the timing of `gate_timeout`, and the automatic rollback. Two assumptions are the likeliest to need adjusting: that `update-engine` will start through the `.path` unit exactly as the learning series describes, and that `cgpt find -t flatcar-usr` prints the device nodes the script parses. The `/etc` mechanism changes between these two releases (the script prints `findmnt` for `/etc` before and after), so expect to see both.
