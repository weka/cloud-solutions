provider "azurerm" {
  subscription_id = var.subscription_id
  features {
  }
}

data "azurerm_resource_group" "rg" {
  name = var.rg_name
}

data "azurerm_subnet" "subnet" {
  name                 = var.subnet_name
  resource_group_name  = var.rg_name
  virtual_network_name = var.vnet_name
}


resource "azurerm_kubernetes_cluster" "k8s" {
  name                = "${var.prefix}-aks-cluster"
  location            = data.azurerm_resource_group.rg.location
  resource_group_name = var.rg_name
  dns_prefix          = "${var.prefix}-aks-dns"
  kubernetes_version  = "1.28.10"
  identity {
    type = "SystemAssigned"
  }

  default_node_pool {
    name                         = "agentpool"
    vm_size                      = var.instance_type
    node_count                   = 3
    vnet_subnet_id               = data.azurerm_subnet.subnet.id
    only_critical_addons_enabled = true
    os_sku                       = var.os_sku

  }
  linux_profile {
    admin_username = var.vm_username
    ssh_key {
      key_data = var.ssh_public_key
    }
  }
  network_profile {
    network_plugin      = "azure"
    load_balancer_sku   = "standard"
    network_policy      = "azure"
    network_plugin_mode = "overlay"
  }
  lifecycle {
    ignore_changes = all
  }
  depends_on = [data.azurerm_subnet.subnet]
}

resource "azurerm_kubernetes_cluster_node_pool" "pool" {
  name                  = "clients"
  kubernetes_cluster_id = azurerm_kubernetes_cluster.k8s.id
  vm_size               = var.instance_type
  node_count            = var.node_count
  vnet_subnet_id        = data.azurerm_subnet.subnet.id
  os_sku                = var.os_sku
  node_labels = {
    "node" = "weka-client"
  }

  orchestrator_version = azurerm_kubernetes_cluster.k8s.kubernetes_version
  lifecycle {
    ignore_changes = all
  }

  depends_on = [azurerm_kubernetes_cluster.k8s]
}
