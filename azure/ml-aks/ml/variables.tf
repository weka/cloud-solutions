variable "prefix" {
  type        = string
  description = "Prefix for all resources"
}

variable "key_vault_name" {
  type        = string
  description = "Name of key vault"
}

variable "rg_name" {
  type        = string
  description = "A predefined resource group in the Azure subscription."
}

variable "subscription_id" {
  type        = string
  description = "Subscription id for deployment"
}