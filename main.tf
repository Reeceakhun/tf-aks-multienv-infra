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
