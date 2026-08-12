terraform {
  required_version = ">= 1.6"

  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 4.0"
    }
  }

  # State remoto no Azure Storage. Preencher via -backend-config no init
  # (o storage/container do state precisa existir antes — ver README §bootstrap).
  # Um state key POR AMBIENTE (doc 12 §5.5):
  #   dev : -backend-config="key=aprecamento-dev.tfstate"
  #   prod: -backend-config="key=aprecamento-prod.tfstate"
  # backend "azurerm" {
  #   resource_group_name  = "rg-tfstate"
  #   storage_account_name = "sttfstateburiti"
  #   container_name       = "tfstate"
  #   key                  = "aprecamento-dev.tfstate"
  # }
}

provider "azurerm" {
  features {}
  subscription_id = var.subscription_id
}
