variable "servers" {
  description = <<-EOT
    Proxmox servers, keyed by a short name the vms refer to. A standalone node
    is a server of its own; a cluster is one server, reached through any of its
    nodes. Each gets its own provider.
  EOT
  type = map(object({
    # Null falls back to PROXMOX_VE_ENDPOINT and PROXMOX_VE_INSECURE.
    endpoint = optional(string)
    insecure = optional(bool)
    # The node a new VM is created on when it pins none.
    default_node = string
    # The installer ISO every VM boots until it is installed. It has to be on
    # every node a VM is created on.
    installer_iso = optional(string, "local:iso/fleet-nixos-installer.iso")
    datastore_id  = optional(string, "local-zfs")
  }))

  validation {
    condition     = length(var.servers) > 0
    error_message = "servers needs at least one entry."
  }
}

variable "server_api_tokens" {
  description = <<-EOT
    API token per server, as user@realm!tokenid=secret, keyed like servers. A
    server missing here uses PROXMOX_VE_API_TOKEN.
  EOT
  type        = map(string)
  default     = {}
  sensitive   = true
}

variable "vms" {
  description = "VMs to create, keyed by name."
  type = map(object({
    server = string
    # Pins the VM to this node: every apply moves it back here. Null leaves it
    # wherever it is, and creates it on the server's default_node.
    node_name      = optional(string)
    datastore_id   = optional(string)
    vm_id          = optional(number)
    cores          = optional(number, 2)
    cpu_type       = optional(string, "x86-64-v2-AES")
    numa           = optional(bool, true)
    memory_mb      = optional(number, 2048)
    balloon_mb     = optional(number, 0)
    on_boot        = optional(bool, true)
    bridge         = optional(string, "vmbr0")
    vlan_id        = optional(number)
    ipv4_address   = string
    ipv4_gateway   = string
    dns_servers    = optional(list(string), [])
    tags           = optional(list(string), [])
    started        = optional(bool, true)
    agent_timeout  = optional(string, "5m")
    os_disk_gb     = optional(number, 20)
    docker_disk_gb = optional(number, 40)
    extra_disks = optional(map(object({
      interface    = string
      size_gb      = number
      datastore_id = optional(string)
    })), {})
  }))
  default = {}
}
