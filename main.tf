resource "azurerm_resource_group" "main" {
  name     = "rg-app-${var.environment}"
  location = var.location

  tags = {
    environment = var.environment
    created-at  = timestamp()
    ttl-minutes = var.ttl_minutes
    managed-by  = "terraform"
  }
  lifecycle {
    ignore_changes = [
      tags["created-at"],
    ]
  }
}

resource "azurerm_kubernetes_cluster" "main" {
  name                = "aks-${var.environment}"
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name
  dns_prefix          = "aks-${var.environment}"

  oidc_issuer_enabled = true

  default_node_pool {
    name       = "default"
    node_count = var.node_count
    vm_size    = var.node_vm_size
    temporary_name_for_rotation = "temppool"
  }

  identity {
    type = "SystemAssigned"
  }

  tags = {
    environment = var.environment
    managed-by  = "terraform"
  }

  lifecycle {
    ignore_changes = [
      default_node_pool[0].node_count,
    ]
  }
}

resource "azurerm_kubernetes_cluster_node_pool" "workloads" {
  name                  = "workloads"
  kubernetes_cluster_id = azurerm_kubernetes_cluster.main.id
  vm_size                = var.node_vm_size
  node_count             = var.node_count

  tags = {
    environment = var.environment
    managed-by  = "terraform"
  }

  lifecycle {
    ignore_changes = [
      node_count,
    ]
  }
}