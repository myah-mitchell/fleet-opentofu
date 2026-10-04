variable "name" {
  description = "VM name. Proxmox writes it to the cloud-init drive as the hostname, so it must be a valid DNS label."
  type        = string

  validation {
    condition     = can(regex("^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$", var.name))
    error_message = "name must be a lowercase DNS label."
  }
}

variable "node_name" {
  description = "Proxmox node the VM is created on."
  type        = string
}

variable "vm_id" {
  description = "VMID for the VM. Null lets Proxmox pick the next free one."
  type        = number
  default     = null
}

variable "datastore_id" {
  description = "Datastore for the disks and the cloud-init drive."
  type        = string
}

variable "installer_iso" {
  description = "Installer ISO attached as the CD-ROM on ide2, as <datastore>:iso/<file name>. It has to exist on the node the VM is created on."
  type        = string
}

variable "cores" {
  description = "Number of vCPU cores."
  type        = number
  default     = 2
}

variable "cpu_type" {
  description = "CPU type the guest sees."
  type        = string
  default     = "x86-64-v2-AES"
}

variable "numa" {
  description = "Enable NUMA."
  type        = bool
  default     = true
}

variable "memory_mb" {
  description = "Dedicated memory in MB."
  type        = number
  default     = 2048
}

variable "balloon_mb" {
  description = "Balloon minimum in MB. 0 disables ballooning, which gives the VM a fixed amount of memory. Set it above 0 to let Proxmox reclaim memory from an idle guest under host pressure."
  type        = number
  default     = 0
}

variable "on_boot" {
  description = "Start the VM when the Proxmox node boots."
  type        = bool
  default     = true
}

variable "bridge" {
  description = "Bridge for the primary network device."
  type        = string
  default     = "vmbr0"
}

variable "vlan_id" {
  description = "VLAN tag for the primary network device. Null leaves it untagged."
  type        = number
  default     = null
}

variable "ipv4_address" {
  description = "Static address in CIDR form, for example 172.16.7.90/24."
  type        = string

  validation {
    condition     = can(cidrhost(var.ipv4_address, 0))
    error_message = "ipv4_address must be in CIDR form, for example 172.16.7.90/24."
  }
}

variable "ipv4_gateway" {
  description = "Gateway for the VLAN this VM sits on."
  type        = string
}

variable "dns_servers" {
  description = "Nameservers written to the cloud-init drive. Empty leaves the choice to Proxmox, which passes on the node's own."
  type        = list(string)
  default     = []
}

variable "os_disk_gb" {
  description = "Size of scsi0 in GB. The installer puts / and /boot on it."
  type        = number
  default     = 20
}

variable "docker_disk_gb" {
  description = "Size of scsi1 in GB. The installer puts /var/lib/docker on it."
  type        = number
  default     = 40
}

variable "extra_disks" {
  description = "Disks added after scsi0 and scsi1. The interface is explicit, for example scsi2. A host with the Docker feature needs scsi2, which the host mounts as its persistent disk, and the install stops without it."
  type = map(object({
    interface    = string
    size_gb      = number
    datastore_id = optional(string)
  }))
  default = {}

  validation {
    condition     = alltrue([for disk in values(var.extra_disks) : !contains(["scsi0", "scsi1"], disk.interface)])
    error_message = "extra_disks cannot use scsi0 or scsi1, which are the OS disk and the Docker disk."
  }
}

variable "tags" {
  description = "Proxmox tags added to the `nixos` and `tofu` tags."
  type        = list(string)
  default     = []
}

variable "started" {
  description = "Start the VM after creation."
  type        = bool
  default     = true
}

variable "agent_timeout" {
  description = "How long to wait for the QEMU guest agent to report an address. A VM without a running agent blocks for this long, so keep it short."
  type        = string
  default     = "5m"
}
