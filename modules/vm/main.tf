terraform {
  required_version = ">= 1.9.0"

  required_providers {
    proxmox = {
      source = "bpg/proxmox"
    }
  }
}

locals {
  # scsi0 and scsi1 are fixed by the host layout: the installer partitions
  # them by their by-id paths. Disks from extra_disks follow, in key order.
  disks = concat(
    [
      { interface = "scsi0", size_gb = var.os_disk_gb, datastore_id = var.datastore_id },
      { interface = "scsi1", size_gb = var.docker_disk_gb, datastore_id = var.datastore_id },
    ],
    [
      for disk in values(var.extra_disks) : {
        interface    = disk.interface
        size_gb      = disk.size_gb
        datastore_id = coalesce(disk.datastore_id, var.datastore_id)
      }
    ],
  )
}

resource "proxmox_virtual_environment_vm" "this" {
  name      = var.name
  node_name = var.node_name
  vm_id     = var.vm_id
  # The "tofu" tag marks VMs this configuration manages.
  tags    = sort(distinct(concat(["nixos", "tofu"], var.tags)))
  started = var.started
  on_boot = var.on_boot
  # A changed node_name migrates the VM within its cluster rather than
  # replacing it, which prevent_destroy would refuse anyway.
  migrate = true

  # The OS disk comes first, so an installed VM boots it. A blank one has
  # nothing to boot there and falls through to the installer ISO.
  boot_order    = ["scsi0", "ide2"]
  scsi_hardware = "virtio-scsi-single"

  operating_system {
    type = "l26"
  }

  # Set explicitly because the provider's own defaults (qemu64, no NUMA)
  # would otherwise apply.
  cpu {
    cores = var.cores
    type  = var.cpu_type
    numa  = var.numa
  }

  memory {
    dedicated = var.memory_mb
    floating  = var.balloon_mb
  }

  agent {
    enabled = true
    timeout = var.agent_timeout
  }

  # The console is the serial port, which is where the installer and an
  # installed host both put theirs.
  serial_device {
    device = "socket"
  }

  vga {
    type = "serial0"
  }

  network_device {
    bridge  = var.bridge
    vlan_id = var.vlan_id
  }

  dynamic "disk" {
    for_each = local.disks
    content {
      datastore_id = disk.value.datastore_id
      interface    = disk.value.interface
      size         = disk.value.size_gb
      file_format  = "raw"
      discard      = "on"
      iothread     = true
      ssd          = true
    }
  }

  cdrom {
    interface = "ide2"
    file_id   = var.installer_iso
  }

  # Only the installer reads the cloud-init drive. An installed host takes its
  # address from its own configuration.
  initialization {
    datastore_id = var.datastore_id
    interface    = "ide0"

    ip_config {
      ipv4 {
        address = var.ipv4_address
        gateway = var.ipv4_gateway
      }
    }

    dynamic "dns" {
      for_each = length(var.dns_servers) > 0 ? [1] : []
      content {
        servers = var.dns_servers
      }
    }
  }

  # Destroying a fleet VM has to be a deliberate edit of this file, not a
  # side effect of a plan.
  #
  # Nothing is listed under ignore_changes. The provider changes the ISO, the
  # boot order, the cloud-init values and a disk's size in place, so none of
  # them plans a replacement, and the drives stay correct for the next
  # install of the VM.
  lifecycle {
    prevent_destroy = true
  }
}
