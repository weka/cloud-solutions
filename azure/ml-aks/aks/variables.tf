variable "rg_name" {
  type        = string
  description = "A predefined resource group in the Azure subscription."
}

variable "vm_username" {
  type        = string
  description = "The user name for logging in to the virtual machines."
  default     = "weka"
}

variable "vnet_name" {
  type        = string
  description = "The virtual network name."
}

variable "subnet_name" {
  type        = string
  description = "The subnet names."
}

variable "ssh_public_key" {
  type        = string
  description = "Ssh public key to pass to vms."
}

variable "node_count" {
  type        = number
  description = "The initial quantity of nodes for the node pool."
  default     = 3
}

variable "instance_type" {
  type    = string
  default = "Standard_L8s_v3"
}

variable "subscription_id" {
  type        = string
  description = "Subscription id for deployment"
}

variable "prefix" {
  type        = string
  description = "Prefix for all resources"
}

variable "os_sku" {
  type        = string
  default     = "Ubuntu"
  description = "The OS sku to use for the vmss"
}

variable "client_frontend_cores" {
  type        = number
  default     = 1
  description = "Number of nics to set on each client vm"
}
