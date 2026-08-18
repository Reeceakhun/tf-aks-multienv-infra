terraform {
  required_version = ">= 1.7.0"

  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 3.100"
    }
  }

  # Remote state backend configured here in Commit 2 —
  # left out for now so `terraform init` doesn't fail before
  # the storage account actually exists.
}

provider "azurerm" {
  features {}
}

terraform {
  backend "azurerm" {
    resource_group_name  = "rg-tfstate"
    storage_account_name = "tfstateaksmultienv"
    container_name        = "tfstate"
    key                    = "dev.terraform.tfstate"
  }
}