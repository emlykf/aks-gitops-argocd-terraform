terraform {
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 5.6.0"
    }
    helm = {
      source  = "hashicorp/helm"
      version = "~> 3.3.0"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 3.2.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.9"
    }
    time = {
      source  = "hashicorp/time"
      version = "~> 0.14"
    }
  }
  required_version = ">= 1.9.0"
}

# hashicorp/random = creates storng random password & it goes straight into Key Vault
# hashicorp/time   = some resources like AKS and things like role assignments in Azure take a moment to take affect after deploy. Without the time provider, things like ArgoCD or external secrets can fail, even though the code is correct

provider "azurerm" {
  features {
    key_vault {
      purge_soft_delete_on_destroy    = false           # on destroy, only soft-delete the Key Vault (recoverable) instead of permanently purging it (purge = emptying the recycle bin)
      recover_soft_deleted_key_vaults = true            # if a Key Vault with the same name is soft-deleted, recover it instead of failing on create
    }
    resource_group {
      prevent_deletion_if_contains_resources = false    # to allow deletion of rg even if they contain resources. If set to true, the resource group cannot be deleted if it contains any resources
    }
    virtual_machine_scale_set {
      roll_instances_when_required = true               # to allow updating the instances in a VMSS one at a time to minimize downtime (e.g., when updating the OS image or applying patches)
    } 
  }
}

# Kubernetes provider: lets Terraform create objects inside the AKS cluster
provider "kubernetes" {
  host                   = try(azurerm_kubernetes_cluster.main.kube_admin_config[0].host, "")                                         # cluster address (API server URL) - "the building's address"
  client_certificate     = try(base64decode(azurerm_kubernetes_cluster.main.kube_admin_config[0].client_certificate), "")             # proves who we are - "ID card"
  client_key             = try(base64decode(azurerm_kubernetes_cluster.main.kube_admin_config[0].client_key), "")                     # secret key for the certificate - "PIN"
  cluster_ca_certificate = try(base64decode(azurerm_kubernetes_cluster.main.kube_admin_config[0].cluster_ca_certificate), "")         # proves the cluster is really ours - "official seal"
}

# Helm provider: lets Terraform install Helm charts (e.g. Argo CD) into the AKS cluster
provider "helm" {
  kubernetes = {                                                                                                                      # Helm 3.x syntax 
    host                   = try(azurerm_kubernetes_cluster.main.kube_admin_config[0].host, "")                                       # same cluster address as above
    client_certificate     = try(base64decode(azurerm_kubernetes_cluster.main.kube_admin_config[0].client_certificate), "")           # same "ID card"
    client_key             = try(base64decode(azurerm_kubernetes_cluster.main.kube_admin_config[0].client_key), "")                   # same "PIN"
    cluster_ca_certificate = try(base64decode(azurerm_kubernetes_cluster.main.kube_admin_config[0].cluster_ca_certificate), "")       # same "official seal"
  }
}

# kube_admin_config = admin login details Azure provides for the AKS cluster
# base64decode()    = Azure delivers certificates/keys Base64-encoded; this turns them back into normal form
# try(..., "")      = if the cluster doesn't exist yet (first plan), use an empty value instead of an error