package main

deny[msg] {
  resource := input.resource_changes[_]
  resource.type == "azurerm_role_assignment"
  broad_roles := {"Owner", "Contributor"}
  role := resource.change.after.role_definition_name
  broad_roles[role]
  scope := resource.change.after.scope
  not contains(scope, "resourceGroups")

  msg := sprintf(
    "azurerm_role_assignment '%s' grants '%s' at subscription scope ('%s') — must be scoped to a resource group or narrower",
    [resource.address, role, scope]
  )
}
