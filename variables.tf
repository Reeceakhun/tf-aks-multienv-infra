variable "environment" {
  description = "Environment name: dev, staging, or prod"
  type        = string

  validation {
    condition     = contains(["dev", "staging", "prod"], var.environment)
    error_message = "environment must be one of: dev, staging, prod."
  }
}

variable "location" {
  description = "Azure region for all resources"
  type        = string
  default     = "eastus"
}

variable "node_count" {
  description = "Number of nodes in the default node pool"
  type        = number
}

variable "node_vm_size" {
  description = "VM SKU for the default node pool"
  type        = string
}

variable "ttl_minutes" {
  description = "Minutes before the reaper tears this environment down. Ignored for prod."
  type        = number
  default     = 20
}
