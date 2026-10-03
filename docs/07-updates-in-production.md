# 07 — Updates in production: update_engine, reboot coordination, rollout control, private update servers

Doc 04 explained how one node updates. This document is about a fleet: who decides which version a node may take, who
decides when it goes down, how those two decisions interact with Kubernetes, and how to run the whole thing inside a
network that cannot reach the internet. It also covers what I can and cannot say about each component's health, because
you are choosing which of them to depend on.

## Two independent decisions

Flatcar splits "update" into stages that different components own, and the separation is the key to operating it.

| Stage | What happens | Who decides | Where it is configured |
|---|---|---|---|
| Eligibility | Node is told a newer version exists and where its payload is | The update server (public Nebraska, or yours), by group and channel | `GROUP` and `SERVER` in `/etc/flatcar/update.conf`; Nebraska group policy |
| Staging | `update_engine` downloads, verifies, writes the passive slot, runs post-install | The node, automatically, when granted | `update_engine` (no knob except `SERVER=disabled`) |
| Activation | The node reboots into the new slot | The **reboot manager**, never `update_engine` | `locksmithd` strategy, FLUO, kured, or you |
| Confirmation | The new slot is marked successful | `update_engine`, after it has stayed up | Your health gate on `update-engine.service` (doc 04) |

`update_engine` states are `UPDATE_STATUS_IDLE`, `CHECKING_FOR_UPDATE`, `UPDATE_AVAILABLE`, `DOWNLOADING`, `VERIFYING`,
`FINALIZING`, `UPDATED_NEED_REBOOT` and `REPORTING_ERROR_EVENT`; `update_engine_client -status` reports them and
`journalctl -u update-engine` explains errors ([update strategies][update-strategies]). `UPDATED_NEED_REBOOT` is the hand-off
point to the reboot manager, and the node also drops `/run/reboot-required` at that moment ([postinst][ue-postinst]).

The two decisions need different controls. Eligibility is about **which version, when, and how many nodes at once**, and
belongs to the update server. Activation is about **which node goes down next without breaking the workloads on it**, and
belongs to something that knows about the cluster.

## The reboot manager: locksmith, FLUO, kured

**locksmithd** is the default. It runs on every node and acts after `update_engine` reports a staged update, according to
`REBOOT_STRATEGY` in `/etc/flatcar/update.conf`: `etcd-lock` (take a lock in etcd first), `reboot` (reboot right away),
or `off`. The default strategy is to use `etcd-lock` if etcd is running and `reboot` otherwise, and a `reboot` strategy
delays five minutes ([locksmith README][locksmith], [update strategies][update-strategies]). A maintenance window is two keys,
`LOCKSMITHD_REBOOT_WINDOW_START="Thu 04:00"` and `LOCKSMITHD_REBOOT_WINDOW_LENGTH=1h`. For a Kubernetes node this is not
enough: locksmith knows nothing about pods, so it will reboot a node that is serving traffic and has no replacement
capacity. Historically it fits etcd-backed clusters (take a lock, reboot, release); the number of simultaneous reboots is set
with `locksmithctl set-max`. In a Kubernetes estate you mask `locksmithd.service` and use one of the next two.

**FLUO**, the Flatcar Linux Update Operator, is the Flatcar-specific Kubernetes reboot controller. Its README describes it as a
"node reboot controller for Kubernetes running Flatcar", which drains the node before rebooting it. It has two parts:
`update-agent`, a DaemonSet that listens for `UPDATE_STATUS_UPDATED_NEED_REBOOT` over D-Bus and signals through node
annotations, and `update-operator`, a Deployment that watches those annotations and coordinates reboots "ensuring that not too
many are rebooting at once". Today the operator "only reboots one node at a time" ([FLUO README][fluo-readme]). The
requirements are specific: `update-engine.service` unmasked and enabled, and `locksmithd.service` masked and stopped.
FLUO's behavior is controlled by annotations under the prefix `flatcar-linux-update.v1.flatcar-linux.net/`
(`reboot-needed`, `reboot-ok`, `reboot-in-progress`, `reboot-paused`, `status`, `new-version`, and others), by
`--reboot-window-start` and `--reboot-window-length` (which also prevent pre-reboot checks running outside the window), and
by `--before-reboot-annotations` and `--after-reboot-annotations`, which let you require your own checks to succeed before a
node may reboot and before it may become schedulable again ([constants][fluo-constants], [reboot windows][fluo-windows],
[checks][fluo-checks]). Setting `reboot-paused` to `"true"` on a node is the documented administrator override that stops the
operator considering it. The agent drains with the Kubernetes drain helper (`DeleteOrEvictPods`); a `-force-drain` flag,
added in 0.10.0, allows removing pods that have no controller ([agent source][fluo-agent], [changelog][fluo-changelog]).

**kured** (Kubernetes Reboot Daemon) is the distribution-neutral option, and Flatcar supports it explicitly: the update
documentation says kured is supported "starting from Flatcar versions with a release number greater than `3067.0.0`" and that
to let it handle reboots you mask `locksmithd.service` ([update strategies][update-strategies]). It works because Flatcar's
post-install creates `/run/reboot-required`, the Ubuntu-style sentinel, and kured's default sentinel is
`/var/run/reboot-required` ([kured source][kured-main]). Its controls are richer than FLUO's on the scheduling side: a check
`--period` (default 60 minutes), `--reboot-days`, `--start-time`, `--end-time` and `--time-zone` for the window, a cluster-wide
lock held as an annotation on kured's own DaemonSet (`--lock-annotation`, `--lock-ttl`), `--concurrency` (default 1),
`--blocking-pod-selector` and Prometheus-based blocking (`--prometheus-url` with alert filters), drain tuning flags, and
notification hooks. It also reads a configurable sentinel command if a file is not enough.

There is no topology awareness in any of them. None of FLUO, kured or locksmith knows that you want control-plane nodes
rebooted one at a time before workers, or that etcd members must keep quorum; you express that with `PodDisruptionBudget`s, with
`concurrency: 1`, by running separate kured DaemonSets per node pool with different selectors, or with FLUO's before-reboot
checks. This is the design you have to own.

> ⚠️ Verify: project health. FLUO's changelog shows v0.9.0 on 2023-01-03 and v0.10.0 on 2026-09-15, a gap of almost
> three years between tagged releases; kured's repository is active in the snapshot (v1.23.0 tag; last commit 30 Sep 2026).
> Both work with Flatcar per the documentation, but if reboot coordination is a control you will evidence to an auditor,
> check each project's current maintainers, open issues and supported Kubernetes versions before choosing, and say which
> you chose and why.

```mermaid
sequenceDiagram
    autonumber
    participant N as Nebraska (private update server)
    participant UE as update_engine (node)
    participant A as reboot signal on node
    participant R as reboot manager in cluster
    participant K as kube-apiserver
    participant W as workloads (PDBs)

    UE->>N: Omaha check-in (appid, version, track=GROUP)
    N->>N: enforceRolloutPolicy: updates enabled? office hours? max per period? in progress? safe mode?
    alt policy allows
        N-->>UE: update granted + payload locations
        UE->>UE: write full /usr image to passive slot, verify signature, postinst
        UE->>A: UPDATE_STATUS_UPDATED_NEED_REBOOT, touch /run/reboot-required
    else policy blocks
        N-->>UE: no update (instance on hold)
    end

    alt FLUO (locksmithd masked, update-engine enabled)
        A->>R: update-agent sees D-Bus status, sets annotation reboot-needed=true
        R->>R: update-operator picks ONE node, checks reboot window and before-reboot annotations
        R->>K: annotation reboot-ok=true
        R->>K: agent cordons and drains (evict, honours PDBs; optional force-drain)
        K->>W: evict pods respecting PodDisruptionBudgets
        R->>A: agent reboots node
    else kured (locksmithd masked)
        A->>R: kured polls sentinel /var/run/reboot-required every period
        R->>K: acquire cluster lock (DaemonSet annotation), concurrency default 1
        R->>R: check window (days, start/end, time zone) and Prometheus alerts / blocking pods
        R->>K: cordon + drain
        K->>W: evict pods respecting PodDisruptionBudgets
        R->>A: systemctl reboot
    end

    A->>UE: node reboots into passive slot (tries=1 -> 0)
    UE->>UE: stays up 1-2 min, flatcar-setgoodroot marks slot successful
    R->>K: after-reboot checks, uncordon, release lock
    UE->>N: report update complete
```

## Maintenance windows live in four places

A window set in one place does not apply to the others. In particular, the update server's "office hours" is not a
maintenance window you can configure.

| Layer | Setting | What it gates |
|---|---|---|
| Nebraska group | `policy_office_hours` with `policy_timezone` | Whether the server **grants** an update. In the source it means Monday to Friday, 09:00 to 17:00 in the group's time zone, hard-coded |
| locksmith | `LOCKSMITHD_REBOOT_WINDOW_START` and `_LENGTH` | Reboots on that node |
| FLUO | `--reboot-window-start`, `--reboot-window-length` | Reboots (and pre-reboot checks) cluster-wide |
| kured | `--reboot-days`, `--start-time`, `--end-time`, `--time-zone` | Reboots cluster-wide |
| system-upgrade-controller | Plan `window` | Application-level upgrades (doc 10) |

(Nebraska source: `inOfficeHoursNow` in `runtime/updates.go`.) Because staging is separate from activation, a normal and
sensible design is: let nodes stage whenever the server grants an update (the download is not disruptive), and put the window on
the reboot manager. If you need staging itself confined, use the Nebraska policy knobs below, not office hours.

## Controlled rollout: channels, groups and the update server

For a fleet you rarely want every node following the public Stable feed the moment a release lands. Flatcar's own
guidance is to "follow releases in the Stable channel, with a few nodes on Beta for workload validation" ([switching
channels][channels]). To make that a controlled pipeline, run your own update server so that a group, not the public feed,
decides who may take what.

Nebraska models three things. A **channel** names a version (a package). A **group** is a set of machines with a rollout
policy, pointing at a channel. Machines pick a group with `GROUP=` in `update.conf`, either a name or a group UUID, against
`SERVER=https://your-nebraska/v1/update/`. Multiple groups can point at the same channel ([managing updates][nebraska-managing]).
The sync model matters: with `-enable-syncer` Nebraska keeps its Stable, Beta, Alpha and LTS channels in step with the
public server, and the guidance is explicit: "you should not modify the `stable` *channel* because this gets synced with the
public server and your changes are lost. You should rather create a new channel and let the `stable` *group* point to it"
([switching channels][channels]). That is the lever for soak: your `stable` group points at a channel you control, which your
pipeline advances (to the version that has soaked on canaries) rather than at whatever upstream just promoted.

The group policy fields in the database schema are `updates_enabled`, `safe_mode`, `office_hours`, `timezone`,
`max_updates_per_period`, `period_interval` and `update_timeout`. The enforcement logic in `enforceRolloutPolicy`
(`backend/pkg/api/runtime/updates.go`) behaves as follows:

- If updates are disabled for the group, nobody gets an update.
- If office hours are on and it is outside weekday 09:00 to 17:00 in the group time zone, nobody gets an update.
- If the number of updates granted in the last period, or currently in progress, has reached the effective maximum, the instance is put **on hold**.
- **Safe mode** acts as a circuit breaker. Until at least one update to the current version has been attempted, the effective maximum is forced to 1, so the first node is a canary. If the count of timed-out updates reaches the maximum, Nebraska **disables updates for the group** and holds further instances.

Two more features reduce risk on big jumps. **Floor packages** are mandatory intermediate versions that clients must install
before the target, which the changelog describes as enabling safe multi-step updates, and the package **blacklist**
removes a bad version from selection. Both appear in the changelog's *Unreleased* section, that is, after the 4.0.0 tag
pinned in VERSIONS.md, so confirm they exist in the build you deploy. Treat them as inputs to a runbook rather than
automations you have not exercised.

> ⚠️ Verify: that "update complete" is recorded when staging finishes, or only after the node has rebooted and reports the
> new version, matters for how `safe_mode` and `update_timeout` count progress on your fleet. I read the enforcement code
> but not the event-handling path. Test with two lab nodes and a short `update_timeout` before relying on safe mode in production.

Staged rollouts across the public channels are what you get without running anything. Beta nodes in each environment see a
release before Stable does, because a major version is promoted from Beta to Stable after "additional iterations"
(doc 03). That gives a lead time you can use; it does not give you a hold. The only way to hold a version in your estate is
to control the server your nodes ask, or to set `SERVER=disabled` and move nodes with `flatcar-update`.

## Running your own update server (air-gapped and regulated estates)

Nebraska is the open-source Omaha server; the public instance uses it too ([Nebraska README][nebraska-readme]). A private
deployment needs four decisions.

**What it stores.** By default it stores metadata only, and instructions to fetch payloads from the public servers, so the
nodes still need internet. To serve payloads yourself, run it with `-host-flatcar-packages=true`, a
`-flatcar-packages-path` and `-nebraska-url`; with `-enable-syncer` it downloads each payload as it syncs. For a fully
disconnected site, host without synchronization: download `flatcar_production_update.gz` from the release host on a connected
machine for each version you want, place it under the packages path, start Nebraska with the hosting options, register the
package in the UI with a matching URL and file name, and assign it to a channel ([managing updates][nebraska-managing]).
`-syncer-packages-url` overrides the download URL template for synchronized packages (`{{VERSION}}` and `{{ARCH}}` are
substituted, and the `-usr` suffix is required to match official layout).

**Everything that travels with a release.** A release is more than the base payload. The post-install step downloads OEM
and Flatcar-extension payloads (`oem-NAME.gz`, `flatcar-NAME.gz`) for the new version (doc 04, doc 06), and Nebraska's syncer
processes "extra files" in the manifest. The sysext docs warn that private-server operators "need to make sure that they have a
recent version that provides the OEM payloads" and the extension payloads. A mirror that has only `flatcar_production_update.gz`
works for a bare-metal or plain-QEMU node and fails for a cloud image whose OEM component is a sysext.

**Initial provisioning is separate from updates.** New nodes install from an image, and any opt-in official extension is
downloaded in the initrd from the release file server, so air-gapped sites also need `flatcar.release_file_server_url` pointing
at their mirror, with the path layout `${URL}/${FLATCAR_BOARD}/${VERSION}/${name}` (doc 06).

**Offline updates without any server.** `flatcar-update` can apply a payload you copy to the node: download
`flatcar_production_update.gz` (and `oem-NAME.gz` / `flatcar-NAME.gz` as needed) on a connected machine, then run
`flatcar-update --to-version VER --to-payload flatcar_production_update.gz` with `-E` for each extension payload. It starts a
temporary local update service, unmasks `update-engine`, and can write `SERVER=disabled` afterward with `--disable-afterwards`
([flatcar-update][flatcar-update], [update strategies][update-strategies]). This is also the supported way to roll back to a chosen version.

Operational properties to settle for a regulated deployment:

- **Transport.** The sample containers serve plain HTTP on port 8000, and the docs' examples set `SERVER=http://...`. The payload is signature-checked on the node, but the Omaha response is not integrity protected on HTTP; put Nebraska behind TLS and set `SERVER=https://...`.
- **Authentication and roles.** Nebraska supports OIDC and GitHub authentication modes. Version 4.0.0 made the OIDC audience a **required** setting (`--oidc-audience`) and now rejects tokens whose `aud` does not match and ID tokens used as access tokens; it also fixed an SQL injection in the group version timeline ([Nebraska changelog][nebraska-changelog]). Upgrade past 4.0.0 and treat this as an internet-facing management plane.
- **Availability.** If Nebraska is down, nodes simply fail the check and retry; nothing breaks, but no updates flow. The changelog's *Unreleased* section describes `control` and `edge` instance modes for a distributed deployment, which are not in the 4.0.0 tag.
- **Payload provenance.** Ingest payloads only from the official release host, and re-verify them. The update payload's authenticity is the HSM-held key on the node's side (doc 03), so an unmodified mirrored payload still verifies on the node; verify your mirroring did not alter it, and keep the original with the DIGESTS and signature next to it for audit.

> ⚠️ Verify: I did not confirm whether the node enforces anti-rollback (refuses an older, validly signed payload served by a
> malicious or misconfigured server). Test it in a lab: serve an older payload to a node on a newer version and observe.

## Putting it together: a reference design

For a Kubernetes estate on vSphere and AWS, the design I would evaluate is:

1. Pin `SERVER` to a private TLS Nebraska, and use `GROUP` to place nodes: a small `canary` group (safe mode on, max one at a time), then `staging`, then `prod` groups, each pointing at a channel you advance after a soak.
2. Mask `locksmithd`. Run kured or FLUO with `concurrency: 1`, a window outside business hours, PDBs on every stateful workload, and separate selectors so control-plane nodes are a distinct, slower pool.
3. Gate `update-engine` on the critical units (kubelet, container runtime, CNI, anything whose absence makes a node useless) with the first-boot-after-update pattern from the learning series, so a bad update rolls itself back (lab 02).
4. Alert on staged-but-not-rebooted nodes (status `UPDATED_NEED_REBOOT` for more than your window) and on nodes whose OS version lags the target; a node that stages and never reboots is a security lag you cannot see from Nebraska alone.
5. Keep a break-glass: `flatcar-update --to-version ... --disable-afterwards` and a documented `cgpt` rollback.

## Key takeaways

- Eligibility (update server), staging (`update_engine`), activation (reboot manager) and confirmation (`successful` flag) are separate decisions with separate owners; design each one deliberately.
- In Kubernetes mask `locksmithd` and use FLUO (annotations, one node at a time, before/after-reboot checks) or kured (sentinel file, lock, windows, Prometheus blockers); neither is topology-aware, so use PDBs and node-pool separation.
- Nebraska rollout policy is `max_updates_per_period`, `period_interval`, `update_timeout`, `safe_mode` and a fixed weekday 09:00-17:00 "office hours"; real maintenance windows belong to the reboot manager.
- For air-gapped use, host the base payload, OEM and extension payloads, and the initrd extension downloads (`flatcar.release_file_server_url`); put Nebraska behind TLS and verify its auth settings (4.0.0 changed OIDC requirements).
- Keep `flatcar-update` and a manual `cgpt` rollback as documented break-glass paths, and alert on nodes that staged an update but never rebooted.

## Sources

- Update and reboot strategies, `update.conf`, airgapped updates, kured support: [`update-strategies.md`][update-strategies], [`update-conf.md`][update-conf]
- Channels, LTS freeze, personal Nebraska: [`switching-channels.md`][channels]
- Nebraska docs and README: [`managing-updates.md`][nebraska-managing], [Nebraska README][nebraska-readme], [Nebraska CHANGELOG][nebraska-changelog]; rollout policy code: [`runtime/updates.go`][nebraska-updates]; group fields: [`types/group.go`][nebraska-group]
- FLUO: [README][fluo-readme], [constants][fluo-constants], [reboot windows][fluo-windows], [before/after checks][fluo-checks], [agent][fluo-agent], [CHANGELOG][fluo-changelog]
- locksmith: [README][locksmith]
- kured: [`cmd/kured/main.go`][kured-main]
- `update_engine` post-install: [`flatcar-postinst`][ue-postinst]; `flatcar-update`: [`bin/flatcar-update`][flatcar-update]

[update-strategies]: https://github.com/flatcar/flatcar-website/blob/415d66a7b79efa4374b927a4cd6d7b5bd1bfeb9c/content/docs/latest/updates-releases/releases/update-strategies.md
[update-conf]: https://github.com/flatcar/flatcar-website/blob/415d66a7b79efa4374b927a4cd6d7b5bd1bfeb9c/content/docs/latest/updates-releases/releases/update-conf.md
[channels]: https://github.com/flatcar/flatcar-website/blob/415d66a7b79efa4374b927a4cd6d7b5bd1bfeb9c/content/docs/latest/updates-releases/releases/switching-channels.md
[nebraska-managing]: https://github.com/flatcar/flatcar-website/blob/415d66a7b79efa4374b927a4cd6d7b5bd1bfeb9c/content/docs/latest/updates-releases/nebraska/managing-updates.md
[nebraska-readme]: https://github.com/flatcar/nebraska/blob/4c0f1759879206f80dbcf9943853cf4635429c1a/README.md
[nebraska-changelog]: https://github.com/flatcar/nebraska/blob/4c0f1759879206f80dbcf9943853cf4635429c1a/CHANGELOG.md
[nebraska-updates]: https://github.com/flatcar/nebraska/blob/4c0f1759879206f80dbcf9943853cf4635429c1a/backend/pkg/api/runtime/updates.go
[nebraska-group]: https://github.com/flatcar/nebraska/blob/4c0f1759879206f80dbcf9943853cf4635429c1a/backend/pkg/api/types/group.go
[fluo-readme]: https://github.com/flatcar/flatcar-linux-update-operator/blob/b3ac14453d8880adfdb839e36434dedc95b4fc01/README.md
[fluo-constants]: https://github.com/flatcar/flatcar-linux-update-operator/blob/b3ac14453d8880adfdb839e36434dedc95b4fc01/pkg/constants/constants.go
[fluo-windows]: https://github.com/flatcar/flatcar-linux-update-operator/blob/b3ac14453d8880adfdb839e36434dedc95b4fc01/doc/reboot-windows.md
[fluo-checks]: https://github.com/flatcar/flatcar-linux-update-operator/blob/b3ac14453d8880adfdb839e36434dedc95b4fc01/doc/before-after-reboot-checks.md
[fluo-agent]: https://github.com/flatcar/flatcar-linux-update-operator/blob/b3ac14453d8880adfdb839e36434dedc95b4fc01/pkg/agent/agent.go
[fluo-changelog]: https://github.com/flatcar/flatcar-linux-update-operator/blob/b3ac14453d8880adfdb839e36434dedc95b4fc01/CHANGELOG.md
[locksmith]: https://github.com/flatcar/locksmith/blob/6ea5e7c73bb83cf6c013ff191cc0646e08cb3240/README.md
[kured-main]: https://github.com/kubereboot/kured/blob/f2da2dcf4e160632e899f54f4fd322107730fd83/cmd/kured/main.go
[ue-postinst]: https://github.com/flatcar/update_engine/blob/f23d6ea848ffe2c8721bc49d2a9f77f4de038ad2/flatcar-postinst
[flatcar-update]: https://github.com/flatcar/init/blob/0765e955aca24034d66b9389e0d538e4c3ee543c/bin/flatcar-update
