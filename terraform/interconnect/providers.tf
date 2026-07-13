provider "aws" {
  region  = var.aws_region
  profile = var.aws_profile
}

provider "azurerm" {
  features {}
  subscription_id = var.azure_subscription_id
}
