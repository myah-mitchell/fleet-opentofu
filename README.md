# opentofu

OpenTofu configuration that creates the fleet's VMs on Proxmox. Each VM is created blank, with the installer ISO in its CD-ROM drive, and boots into the installer. It is the first stage of the ansible repo's `site.yml`, which builds a host in one run. See [How a host is built](https://myah-mitchell.github.io/docs/fleet-bootstrap/concepts/how-a-host-is-built/).

Status: validated and planned offline, not yet applied to a Proxmox host. See [Not yet confirmed](#not-yet-confirmed).

## Contents

- [What a VM is made of](#what-a-vm-is-made-of)
- [Layout](#layout)
- [Runtime configuration](#runtime-configuration)
- [Usage](#usage)
- [Servers and clusters](#servers-and-clusters)
- [Driven from Ansible](#driven-from-ansible)
- [Scoped token](#scoped-token)
- [Apply returns before the host is installed](#apply-returns-before-the-host-is-installed)
- [Changing a VM that is installed](#changing-a-vm-that-is-installed)
- [Verified](#verified)
- [Not yet confirmed](#not-yet-confirmed)
- [License](#license)

## What a VM is made of

The module declares every drive, so nothing about a VM comes from outside this repo and its tfvars.

| Drive | Variable | Default | Holds |
| --- | --- | --- | --- |
| scsi0 | `os_disk_gb` | 20 | `/` and `/boot` |
| scsi1 | `docker_disk_gb` | 40 | `/var/lib/docker` |
| scsi2 | `extra_disks` | none | `/srv/persist`, the persistent disk |
| ide2 | `installer_iso` | `local:iso/nixos-fleet-installer.iso` | The installer ISO, as a CD-ROM |
| ide0 | `ipv4_address`, `ipv4_gateway`, `dns_servers` | none | The cloud-init drive |

The boot order is scsi0, then ide2. A blank VM finds nothing to boot on scsi0 and falls through to the installer. An installed VM boots its disk, with the ISO still in the drive for the next install. The ISO holds no secret, so leaving it there gives the VM nothing it should not have.

A host with the Docker feature needs the scsi2 entry in `extra_disks`. Nothing checks this before the apply, and the install stops once it finds no disk there.

Only the installer reads the cloud-init drive, to take the address it listens on. An installed host takes its address from its own configuration.

The module sets the rest of the hardware the same way for every VM:

| Setting | Value |
| --- | --- |
| SCSI controller | `virtio-scsi-single` |
| Disk options | raw, discard on, SSD emulation, one IO thread per disk |
| Console | A serial port, with the display on `serial0` |
| Guest agent | Enabled |
| OS type | `l26` |
| Firmware | SeaBIOS, the provider's default |
| Tags | `nixos`, `tofu`, and the VM's own `tags` |

See [Host layout](https://myah-mitchell.github.io/docs/fleet-bootstrap/concepts/host-layout/) for what the installer does with the three disks.

## Layout

```text
modules/vm/        one VM: drives, boot order, cores, memory, VLAN, static address
envs/prod/         the environment: providers, backend, encryption, VM map
  terraform.tfvars.example
```

Real values (servers, node names, addresses, VLANs) go in a tfvars file in the private repo, at `opentofu/prod.tfvars` in `fleet-private`, next to the Ansible inventory. `*.tfvars` is git-ignored here. No secret belongs in this repo or in the tfvars.

## Runtime configuration

Everything sensitive arrives as environment variables:

| Variable | Purpose |
| --- | --- |
| `TF_VAR_server_api_tokens` | JSON map of API tokens, one per server in `servers`, each `user@realm!tokenid=secret`: a scoped token, not `root@pam` |
| `PROXMOX_VE_API_TOKEN` | The token for a server missing from that map. Only one server can use it, since two servers never share a token |
| `PROXMOX_VE_ENDPOINT` | The API URL for a server whose `endpoint` is null |
| `PROXMOX_VE_INSECURE` | `true` only while the API certificate is not yet trusted, for a server whose `insecure` is null |
| `PG_CONN_STR` | Postgres connection string for the `pg` state backend |
| `TF_ENCRYPTION` | State and plan encryption config |

On ci01, `PG_CONN_STR` is `postgres://tofu:<password>@postgres:5432/tofu_state?sslmode=disable`. That is a second database on Semaphore's Postgres, on a network that does not leave ci01. See [The state database](https://myah-mitchell.github.io/docs/fleet-bootstrap/foundation/handover/#state-database).

`TF_ENCRYPTION` holds the key provider and method:

```hcl
key_provider "pbkdf2" "main" { passphrase = "<at least 16 characters>" }
method "aes_gcm" "main" { keys = key_provider.pbkdf2.main }
state { method = method.aes_gcm.main }
plan  { method = method.aes_gcm.main }
```

The code marks state and plan encryption as `enforced`, so OpenTofu refuses to plan or apply without it. When `TF_ENCRYPTION` is missing the error is `Invalid expression` on the `state {` line (OpenTofu 1.12) or `Missing encryption method` (1.9). That is the encryption check failing, not a syntax problem, and no state is written.

## Usage

```bash
cd envs/prod
tofu init
tofu plan  -var-file=../../../fleet-private/opentofu/prod.tfvars
tofu apply -var-file=../../../fleet-private/opentofu/prod.tfvars
```

The path assumes `fleet-private` is checked out next to this repo.

`prevent_destroy` is set on the VM resource. Removing a VM means editing `modules/vm/main.tf` on purpose.

Nothing here imports an existing VM. A VM made by hand stays out of the state, so a plan cannot touch it. To bring such a host under OpenTofu, rebuild it from a tfvars entry. See [Rebuilding a VM](https://myah-mitchell.github.io/docs/fleet-bootstrap/procedures/rebuild-a-vm/).

## Servers and clusters

`servers` lists every Proxmox API the VMs live behind, and each gets its own provider (provider `for_each`, new in OpenTofu 1.9). A standalone node is a server of its own. A cluster is one server, reached through any node.

| Key | Default | Meaning |
| --- | --- | --- |
| `endpoint` | `PROXMOX_VE_ENDPOINT` | The API URL |
| `insecure` | `PROXMOX_VE_INSECURE` | Skip the certificate check |
| `default_node` | none, required | The node a new VM is created on when it pins none |
| `installer_iso` | `local:iso/nixos-fleet-installer.iso` | The ISO every VM on this server boots until it is installed |
| `datastore_id` | `local-zfs` | The datastore for disks and the cloud-init drive |

Each VM names its `server`, and optionally a `node_name`:

- With `node_name`, the VM is pinned. It is created there, and a VM moved elsewhere in Proxmox is migrated back by the next apply that includes it.
- Without it, a new VM is created on the server's `default_node`, and after that it is left wherever it runs. A data source lists the VMs tagged `tofu` on each server, and the VM's current node is used as its `node_name`, so moving it in Proxmox, or HA doing so, causes no change.

### Where the ISO has to be

The ISO has to exist, under the name in `installer_iso`, on every node a VM is created on. `local` is a storage each node has for itself, so the file is copied to each node. The ansible repo's `pve` role builds the ISO and does that.

On a cluster, a CD-ROM on node-local storage can stop a VM from migrating. If it does, put the ISO on shared storage and name that storage in `installer_iso`.

### What a plan needs

Every plan reads each server's VM list, so it needs the API even when nothing changes, and the token needs `VM.Audit` on the VMs. The role under [Scoped token](#scoped-token) has it.

A node that is down is left out of the list with a warning, and an unpinned VM on it is then planned back onto the default node. That apply fails while the node is down, and a run against that VM would fail anyway.

Removing a server from `servers` while its VMs are still in the state leaves them without a provider, and the plan fails. Moving a VM to another server is a new VM, which `prevent_destroy` refuses.

## Driven from Ansible

The ansible repo's `site.yml` runs this configuration through its `vms` role. It checks this repo out, copies the private repo's `opentofu/prod.tfvars` in as `envs/prod/private.auto.tfvars`, and applies with `-target` for the hosts in that run only. Each host is matched to a VM by its `serverHostname` in lower case, and a host with no VM in the file matches nothing.

Every other VM is still in the input, so the plan leaves it alone, and the role refuses any plan that would destroy something. The tokens and the other environment variables are read from the `ansible-playbook` process. The role's `vms_backend: local` swaps in a local state file for trying it away from Semaphore.

The `vms` output lists every VM in the input, created or not:

| Key | Value |
| --- | --- |
| `server` | The VM's key in `servers` |
| `node_name` | The node it runs on, null until the VM exists |
| `vm_id` | Its VMID, null until the VM exists |
| `ipv4_address` | The address, without the prefix length |
| `ipv4_gateway` | The gateway |
| `ipv4_prefix_length` | The prefix length, as a number |

`site.yml` reads it after the apply, and stops when the address, prefix length or gateway differs from the host's entry in the inventory.

Running `tofu` by hand and running `site.yml` against the same state both work, as long as both use the same tfvars. A VM that is in the state but missing from the input is a VM the plan wants to destroy, which `prevent_destroy` stops.

## Scoped token

Each standalone server and each cluster needs its own user, role and token. Use a privilege-separated token that has no access on `/`, and grant the role to the user and the token on these paths:

| Path | For |
| --- | --- |
| `/vms` | The VMs |
| `/storage/local-zfs` | The datastore in `datastore_id` |
| `/storage/local` | The storage that holds the installer ISO |
| `/sdn/zones/localnetwork` | The bridge |

The role, here named `TofuVM`, has these privileges:

```text
Datastore.AllocateSpace Datastore.Audit SDN.Use Sys.Audit VM.Allocate VM.Audit
VM.Config.CDROM VM.Config.CPU VM.Config.Cloudinit VM.Config.Disk
VM.Config.HWType VM.Config.Memory VM.Config.Network VM.Config.Options
VM.GuestAgent.Audit VM.Migrate VM.PowerMgmt
```

`VM.GuestAgent.Audit` is what current Proxmox versions need to read the guest agent. `VM.Migrate` is for a VM that a plan moves to another node.

The token can act on every VM under `/vms`. A tighter setup puts managed VMs in a pool and grants on `/pool/<name>`, which needs a `pool_id` in the module.

## Apply returns before the host is installed

`tofu apply` completes when the guest agent in the VM reports an address, or when `agent_timeout` runs out, whichever comes first. The default is 5 minutes. Running out is a warning, not an error: the apply succeeds and the VM's addresses are left empty in the state.

At that point the VM is running the installer, not an installed host. Do not chain a follow-up job on apply completing. `site.yml` waits for SSH on the address in its wait stage, and installs the host in the stage after it.

## Changing a VM that is installed

No attribute of the VM is under `ignore_changes`. The provider applies each of these to the existing VM, and none of them plans a replacement:

| Change in the tfvars | What the apply does |
| --- | --- |
| `installer_iso` | Puts the other ISO in the CD-ROM drive |
| A disk size, made larger | Grows the disk. The filesystem on it is not grown |
| A disk size, made smaller | Fails. The provider does not shrink a disk |
| `ipv4_address`, `ipv4_gateway`, `dns_servers` | Rewrites the cloud-init drive and restarts the VM |
| `node_name` | Migrates the VM |

> [!WARNING]
> A changed address, gateway or nameserver restarts an installed host, although the host does not read the cloud-init drive. Change it in a run that expects the restart.

The drives are kept current on purpose. The next install of the VM boots the ISO and reads the address that the tfvars name at that time.

## Verified

Checked with OpenTofu 1.12.6 and 1.9.0, and version 0.113.1 of the bpg/proxmox provider, without a Proxmox server. 1.9.0 is the version in Semaphore's v2.13.13 image, so `required_version` is `>= 1.9.0`.

- `tofu fmt -check -recursive` is clean and `tofu validate` passes in `envs/prod`.
- An offline plan of the environment renders each VM with its disks, the CD-ROM on ide2 and the cloud-init drive on ide0. The VM list was overridden for that plan.
- In that plan an unpinned VM lands on `default_node`, a pinned one on its `node_name`, and one that is in the VM list stays on the node it runs on.
- The `vms` output carries the gateway, and the prefix length as a number.
- A plan against a state written by hand, run without a refresh, shows an update in place for a changed ISO, a larger disk, and a changed address or nameserver.
- An entry in `extra_disks` on scsi0 or scsi1 is rejected.

## Not yet confirmed

None of this has run against a Proxmox host.

- A real apply: that Proxmox accepts the VM as the module declares it, and that a blank VM falls through from scsi0 to the ISO.
- That the installer reads the address from the cloud-init drive on ide0, and that its guest agent reports the address before `agent_timeout` runs out.
- That a second plan after an apply, and after an install, reports no changes.
- The privileges under [Scoped token](#scoped-token) for a VM created blank, and `Datastore.Audit` on the ISO's storage being enough to attach the ISO.
- Migration of a VM whose CD-ROM holds an ISO from node-local storage.
- A pinned VM moved back after a manual migration, and an unpinned one left where it was.
- The restart after a changed address, on a host that is running stacks.
- The `pg` backend end to end, and a real run of `tofu` from inside Semaphore.
- A real apply through the ansible repo's `vms` role.

## License

Copyright (C) 2026 Myah Mitchell. Licensed under the [GNU Affero General Public License v3.0 or later](LICENSE). You can use, modify, and share this code, but any modified version you distribute or offer over a network must be released under the same license with this notice kept.
