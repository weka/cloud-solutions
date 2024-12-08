provider "azurerm" {
  subscription_id = "d2f248b9-d054-477f-b7e8-413921532c2a" #var.subscription_id
  partner_id      = "f13589d1-f10d-4c3b-ae42-3b1a8337eaf1"
  features {
  }
}


terraform {
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 4.6.0"
    }
  }
  required_version = ">= 1.3.7"
}
