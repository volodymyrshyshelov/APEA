terraform {
  required_version = ">= 1.7.0"

  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = ">= 4.0.1, < 5.0.0"
    }
    azapi = {
      source  = "azure/azapi"
      version = "~> 2.6.1"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.7.2"
    }
    modtm = {
      source  = "azure/modtm"
      version = "~> 0.3.5"
    }
  }
}
