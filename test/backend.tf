terraform {
  backend "azurerm" {
    # resource group, storage account and container must exist before terraform init
    resource_group_name  = "rg-tfstate-westeu"
    storage_account_name = "stpoppy01"                
    container_name       = "tfstate"
    key                  = "aks-gitops-argocd-test.tfstate"   # you don't create this file yourself, Terraform creates it automatically the first time it writes state
  }
}