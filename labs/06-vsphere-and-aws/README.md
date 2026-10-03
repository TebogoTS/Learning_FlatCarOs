# Lab 06 — The same config on vSphere and AWS (documentation only)

This lab has no scripts and nothing here was run. It explains, step by step, how the Ignition configs from labs 04 and 05 reach a node on vSphere and on AWS, and which parts of those configs have to change. The mechanics are explained in [doc 05](../../docs/05-provisioning.md) and the Cluster API paths in [doc 09](../../docs/09-kubernetes-on-flatcar.md); this page is the checklist you would follow in a trial. Every command is **untested**; where a fact comes from Flatcar's own documentation I say so, and what I could not confirm is marked.

## Goal

Take `labs/05-rke2-on-flatcar` (the config you would actually run in production) and deliver it to a vSphere VM and an EC2 instance, knowing what differs from QEMU: how the config is delivered, how the node gets its network in the initrd, where artifacts come from, how secrets are handled, and what metadata exists.

## What stays the same, what changes

The rendered Ignition JSON is the same artifact on every platform: `make lab05-render` produces `labs/05-rke2-on-flatcar/.state/render/<node>.ign`. Lab 05's configs are small (about 3.5 KB each, since they reference artifacts by URL and hash rather than embedding them). Lab 04's are 35 to 56 KB because they embed certificates and keys, which matters below.

| Concern | QEMU (labs) | vSphere | AWS |
|---|---|---|---|
| Delivery | `-fw_cfg name=opt/org.flatcar-linux/config` | guestinfo `guestinfo.ignition.config.data` (+ `.encoding`) or `guestinfo.ignition.config.url` | EC2 user data, raw JSON, read from the instance metadata service |
| Encoding | none | base64 or gz+base64, **mandatory** on ESXi | none |
| Network in the initrd | DHCP from the lab's dnsmasq | DHCP, or `guestinfo.afterburn.initrd.network-kargs` | DHCP from the VPC |
| Size limit | none I know of | none stated in the Flatcar page | see the Verify note below |
| Dynamic data (IP, instance id) | not provided | none by default; write your own `coreos-metadata` unit | Afterburn writes `/run/metadata/flatcar` |
| Artifacts | jumpbox web server / GitHub | your mirror or GitHub | S3 via IAM, a mirror, or GitHub |
| Per-node values | nodegen inventory | nodegen inventory (or Terraform/CAPV templating) | nodegen/Terraform; instance id via Afterburn |
| Config removed after boot | no | Ignition deletes it from guestinfo unless `ignition-delete-config.service` is masked | stays in IMDS |

## vSphere

1. **Image.** Import the Flatcar vSphere OVA for the pinned release (for example from the release server's `flatcar_production_vmware_ova.ova`, as the Flatcar page names it) into a template, and verify its signature as the lab scripts do for the QEMU image. For Cluster API you need an OVA built with image-builder instead (doc 09).
2. **Render and encode.**
   ```sh
   make lab05-render
   base64 -w0 labs/05-rke2-on-flatcar/.state/render/rke2-agent-0.ign > /tmp/agent-0.b64
   ```
3. **Deliver it.** The Flatcar VMware page documents three ways: set the guestinfo properties in the OVF deployment wizard, set them on an existing VM in the vSphere UI, or use `ovftool`:
   ```sh
   ovftool --name=rke2-agent-0 --powerOn=True --net:"VM Network=VM Network" \
     --X:guest:ignition.config.data="$(cat /tmp/agent-0.b64)" \
     --X:guest:ignition.config.data.encoding=base64 \
     flatcar_production_vmware_ova.ova 'vi:///<user>:<password>@<host>'
   ```
   This is the form the Flatcar page shows (with its own datastore and flags; adapt them). To set the same properties from Terraform, PowerCLI or `govc` on a cloned VM you need the provider's mechanism for VMX `extraConfig`, which I did not look up.
4. **Network.** If your VMs get addresses from DHCP, nothing else is needed, and lab 05's Ignition downloads work as in QEMU. For static addressing, Flatcar's page says that from major version 3248 you supply `guestinfo.afterburn.initrd.network-kargs` so the initrd is configured before Ignition fetches remote files; the old `guestinfo.interface.*` and `guestinfo.dns.*` variables do not work with Ignition. Afterburn's documentation has the kargs syntax for VMware.
5. **Cloning from a template.** The config is read on first boot only (doc 05). A template you intend to clone must never have booted with a config applied, or you must reset it (`touch /boot/flatcar/first_boot` makes Ignition run again), and guestinfo set from inside the guest is volatile. Cloning a template and setting guestinfo on the clone before power-on is the clean path.
6. **Node IP and metadata.** The RKE2 lab config does not need the node's IP in Ignition, because RKE2 picks its default interface address. If you do need it at boot, there is no generic metadata agent on VMware, so write a `coreos-metadata.service` override as the Flatcar page shows, and note that its example writes `/run/metadata/coreos` while the dynamic-data page documents `/run/metadata/flatcar` (doc 05 has this as a Verify).
7. **Rancher.** Rancher's vSphere machine driver passes cloud-init user data in guestinfo, not Ignition (doc 10). Create the VMs yourself (Terraform or CAPV) and use Rancher's custom-cluster registration, or build the cluster with Cluster API (next section).
8. **Cluster API (CAPV).** Set `EXP_KUBEADM_BOOTSTRAP_FORMAT_IGNITION=true` before `clusterctl init -i vsphere` and use the CAPV Ignition flavor with an image-builder Flatcar OVA. CAPV writes the config into guestinfo as base64 with the encoding key (doc 09). That path is documented upstream as experimental; read the release notes of the versions you deploy.

## AWS

1. **AMI.** Pick the Flatcar AMI for your region and channel from the release feed named on the Flatcar AWS page (it also gives a `data "aws_ami"` Terraform example). Remember its warning that AMIs older than nine months are un-published, which matters for autoscaling groups pinned to an AMI ID.
2. **Delivery.** Pass the rendered JSON as user data, for instance `aws ec2 run-instances --image-id <ami> --user-data file://rke2-agent-0.ign ...`. The raw JSON is what Ignition expects; Ignition's AWS provider reads `2019-10-01/user-data` from the metadata service and handles IMDSv2.
3. **Size and secrets.** Lab 05's 3.5 KB configs fit. Lab 04's do not belong in user data at all: they contain private keys, and user data is readable from the instance by any process that can reach the metadata service. The pattern in doc 05 is a small stub config in user data with `ignition.config.merge` pointing at `s3://bucket/key`, fetched with the instance's IAM role, so the real config sits behind IAM. Cluster API for AWS does exactly this by default (doc 09).

   > ⚠️ Verify: the EC2 user data size limit, and whether the AWS provider accepts gzip-compressed user data. The Flatcar and Ignition sources I read do not state the limit; the CAPA Ignition document says 64 KB. Check the current AWS documentation before designing around either number.
4. **Network.** The initrd gets DHCP from the VPC, so remote artifact downloads (GitHub, S3 through a VPC endpoint, or a mirror) work like lab 05.
5. **Hostnames and keys.** Afterburn handles SSH keys from EC2 key pairs and writes `/run/metadata/flatcar` with `COREOS_EC2_*` variables for units that need the instance's IP or id.
6. **Updates.** Set `GROUP` and `SERVER` in `/etc/flatcar/update.conf` for your update server (doc 07), and decide who reboots (kured, as in lab 05).
7. **Cluster API (CAPA).** Feature gates `EXP_KUBEADM_BOOTSTRAP_FORMAT_IGNITION` and `EXP_BOOTSTRAP_FORMAT_IGNITION`; the controller stores the Ignition data in S3 and gives the instance a stub that merges it (doc 09). Read CAPA's Ignition document for the bucket and IAM settings.

## Trial checklist

A minimal trial that tests the parts the labs could not:

1. One vSphere VM from lab 05's `rke2-agent-0`-style config pointed at a server you already have, or the three-node cluster, using DHCP. Success: `rke2-install.service` ran and the node joins.
2. One EC2 instance with the same config as user data. Success is the same, plus `curl` of the metadata endpoint from the instance to see that your user data is visible to anything on the host (this is why secrets belong behind S3 and IAM).
3. For each platform, rebuild a node from scratch with a changed config and confirm that the old node's state does not matter (the "replace, don't patch" model).
4. Run a Flatcar update on one node of each, and confirm that kured and SUC behave as in lab 05.

## Validated and not validated

Nothing on this page was run. The mechanics are from Flatcar's VMware and AWS pages, Ignition's AWS provider source, and the CAPV and CAPA documents, each listed under Sources in docs 05 and 09. The `ovftool` line is the form Flatcar's page shows; the AWS CLI line is the obvious one for passing a file as user data and I did not verify its flags. Treat the whole page as a plan to test.

## Sources

- Flatcar on VMware, guestinfo, encodings, initrd network kargs, `ovftool`: [`deploy/cloud/vmware.md`](https://github.com/flatcar/flatcar-website/blob/415d66a7b79efa4374b927a4cd6d7b5bd1bfeb9c/content/docs/latest/deploy/cloud/vmware.md)
- Flatcar on AWS EC2, AMI feed, user data: [`deploy/cloud/aws-ec2.md`](https://github.com/flatcar/flatcar-website/blob/415d66a7b79efa4374b927a4cd6d7b5bd1bfeb9c/content/docs/latest/deploy/cloud/aws-ec2.md)
- Ignition AWS provider (IMDS user data, IMDSv2): [`internal/providers/aws/aws.go`](https://github.com/coreos/ignition/blob/94173720290741546ffc2cc1a677eb0ab5d0cb84/internal/providers/aws/aws.go)
- CAPV Ignition guide and guestinfo code: [`docs/ignition.md`](https://github.com/kubernetes-sigs/cluster-api-provider-vsphere/blob/4ad33925cc0f6bb15b7d47499f0599dc60e7cd4a/docs/ignition.md), [`extra/config.go`](https://github.com/kubernetes-sigs/cluster-api-provider-vsphere/blob/4ad33925cc0f6bb15b7d47499f0599dc60e7cd4a/pkg/services/govmomi/extra/config.go)
- CAPA Ignition support: [`ignition-support.md`](https://github.com/kubernetes-sigs/cluster-api-provider-aws/blob/0efa4cc1e6a008c995bac03c09209508877783d6/docs/book/src/topics/ignition-support.md)
- This repository: docs 05, 07, 09 and 10; labs 04 and 05
