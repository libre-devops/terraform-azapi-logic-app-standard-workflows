terraform {
  required_version = ">= 1.11.0, < 2.0.0"

  required_providers {
    azapi = {
      source  = "Azure/azapi"
      version = ">= 2.5.0, < 3.0.0"
    }
    azurerm = {
      source  = "hashicorp/azurerm"
      version = ">= 4.0.0, < 5.0.0"
    }
  }
}
