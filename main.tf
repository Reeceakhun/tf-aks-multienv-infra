resource "azurerm_resource_group" "main" {
  name     = "rg-app-${var.environment}"
  location = var.location

  tags = {
    environment = var.environment
    created-at  = timestamp()
    ttl-minutes = var.ttl_minutes
    managed-by  = "terraform"
  }
}

resource "azurerm_kubernetes_cluster" "main" {
  name                = "aks-${var.environment}"
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name
  dns_prefix          = "aks-${var.environment}"

  default_node_pool {
    name       = "default"
    node_count = var.node_count
    vm_size    = var.node_vm_size
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