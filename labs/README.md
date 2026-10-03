# Labs

Six labs, in order. Labs 01 to 03 need one VM on QEMU user networking and no privileges. Labs 04 and 05 need a few VMs that talk to each other, so they use a host bridge and a DHCP service, which need root once. Lab 06 is documentation only.

| Lab | What you do | Needs |
|---|---|---|
| [01 First boot](01-first-boot-kvm/README.md) | Boot Flatcar with an Ignition config; inspect partitions, dm-verity, A/B slots | QEMU, no root |
| [02 Updates and rollback](02-updates-and-rollback/README.md) | Take a real OS update, switch slots, roll back by hand and automatically | QEMU, no root, internet |
| [03 System extension](03-sysext/README.md) | Build, load and upgrade your own sysext | QEMU, no root |
| [04 Kubernetes the Hard Way](04-kthw-on-flatcar/README.md) | KTHW on 3 VMs, configured entirely by Butane | QEMU, bridge + DHCP (root once), internet |
| [05 RKE2](05-rke2-on-flatcar/README.md) | RKE2 on 3 VMs, then an RKE2 upgrade and an OS update, coordinated | as lab 04 |
| [06 vSphere and AWS](06-vsphere-and-aws/README.md) | How the same configs reach vSphere and AWS (documentation) | none |

## What I could and could not test

Everything in these labs was written and checked on a machine with no KVM and no access to the Flatcar release servers, so **no VM was ever booted by me**. Each lab README ends with a precise list of what was validated and what was not. The short version:

- Validated for real: the Go tools and their tests; every Butane config transpiles with the pinned Butane in `--strict` mode and passes the policy checks (`make check`); every shell script passes `shellcheck` and the shared library has an offline self-test; the signing-key import and fingerprint check; the sysext image build (reproducible, the payload program runs); the lab 04 control plane and the lab 05 add-on manifests run against real pinned binaries and a real API server (`make lab04-native-test`); the RKE2 `install.sh` runs against the pinned tarball in a temporary prefix.
- Not validated: anything that needs a Flatcar boot. That is Ignition applying a config, the A/B update and rollback, sysext merging, networkd, the shipped containerd, CNI, kured and SUC acting on real nodes, and the vSphere and AWS paths.

Expected outputs in the READMEs are labelled **expected shape**: they describe what the commands should show based on the documentation I read, not captured output.

## Host prerequisites

Common to all labs: Linux x86-64, `qemu-system-x86_64` and `qemu-img`, `curl`, `gpg`, `ssh`, `ssh-keygen`, `openssl`, `python3`, Go 1.24 or newer (for the helper tools) and `make`. KVM makes the labs usable: `ls -l /dev/kvm` should show a device your user can read and write. Without it the scripts fall back to TCG emulation and print a warning; Flatcar still boots but slowly, and the multi-VM labs are not practical.

```sh
make tools butane        # build nodegen and butanecheck, download and verify the pinned Butane
make validate            # everything that needs no VM: tests, lint, transpile, policy checks
```

### Labs 04 and 05: bridge, QEMU permission and DHCP

These two labs put three VMs on a Linux bridge (`flcbr0`, 10.77.0.0/24, the host at 10.77.0.1) with outbound NAT. Once per boot of your host:

```sh
sudo labs/lib/net.sh up                                   # bridge + NAT
echo 'allow flcbr0' | sudo tee -a /etc/qemu/bridge.conf   # lets unprivileged QEMU attach to the bridge
```

`qemu-bridge-helper` must be installed and setuid root (packaged with QEMU on most distributions; the path varies). Then, for the lab you are running, give each VM its fixed address with DHCP. Flatcar configures every interface with DHCP in the initrd, which is when Ignition downloads remote files, so a DHCP answer must exist before first boot:

```sh
labs/04-kthw-on-flatcar/scripts/cluster.sh hosts > /tmp/lab-hosts     # or labs/05-rke2-on-flatcar/scripts/lab05.sh hosts
sudo labs/lib/net.sh dhcp-start /tmp/lab-hosts                        # needs dnsmasq
```

Start only one of labs 04 and 05 at a time on the bridge, or put both labs' lines in one hosts file (the addresses and MACs do not overlap).

**Firewall.** `net.sh` does not touch your filter rules. If your host has a default-drop FORWARD policy (Docker installs one), allow the bridge: `iptables -I FORWARD -i flcbr0 -j ACCEPT; iptables -I FORWARD -o flcbr0 -j ACCEPT`. The VMs also need to reach the host on 10.77.0.1 for DHCP and, in lab 04, TCP 8080.

Tear everything down with `sudo labs/lib/net.sh down`.

### Shared conventions

- Every lab creates its state under `labs/<lab>/.state/` (git-ignored): VM overlays, an SSH key pair, rendered configs. `make lab<NN>-destroy` removes the VMs.
- The Flatcar images come from the release servers, are cached under `.cache/`, and are verified with GPG against the signing key embedded in the pinned `flatcar-install`, with the key's fingerprint checked against `versions.env`. A verification failure deletes the image.
- Versions are pinned in `versions.env` (provenance in `../VERSIONS.md`). Change a version there, not in scripts.
