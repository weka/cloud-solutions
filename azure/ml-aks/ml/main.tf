provider "azurerm" {
  subscription_id = var.subscription_id
  features {
  }
}

data "azurerm_resource_group" "rg" {
  name = var.rg_name
}

resource "azurerm_storage_account" "sa" {
  name                     = "${var.prefix}mlsa2"
  location                 = data.azurerm_resource_group.rg.location
  resource_group_name      = var.rg_name
  account_tier             = "Standard"
  account_replication_type = "GRS"
  lifecycle {
    ignore_changes = all
  }
}

resource "azurerm_application_insights" "insights" {
  name                = "${var.prefix}-workspace-insights2"
  location            = data.azurerm_resource_group.rg.location
  resource_group_name = var.rg_name
  application_type    = "web"
}

data "azurerm_key_vault" "vault" {
  name                = var.key_vault_name
  resource_group_name = var.rg_name
}

resource "azurerm_machine_learning_workspace" "ml" {
  name                          = "${var.prefix}-workspace-ml33"
  location                      = data.azurerm_resource_group.rg.location
  resource_group_name           = var.rg_name
  application_insights_id       = azurerm_application_insights.insights.id
  key_vault_id                  = data.azurerm_key_vault.vault.id
  storage_account_id            = azurerm_storage_account.sa.id
  public_network_access_enabled = true

  identity {
    type = "SystemAssigned"
  }
  lifecycle {
    ignore_changes = all
  }
}
