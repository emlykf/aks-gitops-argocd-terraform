# Introduction 

## Architecture Diagram

## Demo / lab

### Prerequisites

- Tools:
  
  On Windows, kubectl and helm can be installed with `winget`: 

  ```bash
  winget install -e --id Kubernetes.kubectl --source winget
  winget install -e --id Helm.Helm --source winget
  ```

- For Windows user, this repo includes a `.gitattributes` file:

  It makes sure the `.sh` scripts keep Linux line endings (LF) on Windows. Otherwise Git may convert them to Windows line endings (CRLF), and bash fails with errors like `$'\r': command not found`.

  ```bash
  echo "*.sh text eol=lf" > .gitattributes
  ```

- Login to Azure & set the Subscription that you want to use for this session:

  ```bash
  az login
  # or
  az login --use-device-code
  ```
  ```bash
  az account set --subscription "<SUBSCRIPTION-ID>"
  ```

  Check the current subscription that was set:

  ```bash
  az account show --query "{Name:name, SubscriptionId:id, Tenant:tenantId}" --output table
  ```

- Register the Resource Providers (required for azurerm v5)

  Check the status first:

  ```bash
  az provider list --query "[?namespace=='Microsoft.ContainerService' || namespace=='Microsoft.KeyVault' || namespace=='Microsoft.ManagedIdentity'].{Provider:namespace, State:registrationState}" --output table
  ```

  Run these commands to register them:

  ```bash
  az provider register --namespace Microsoft.ManagedIdentity
  az provider register --namespace Microsoft.ContainerService
  az provider register --namespace Microsoft.KeyVault
  ```

- Remote State Backend: 

  These resources have to exist before you do `terraform init`, because Terraform can't store its state in something it hasn't created yet.

  Check whether a name is still free before creating it:

  ```bash
  az storage account check-name --name <your_storage_account_name> --query nameAvailable
  ```

  If you don't have a resource group, storage account or container for state yet, you can create one like this:

  ```bash
  az group create --name rg-tfstate-westeu --location westeurope
  ```
  ```bash
  az storage account create \
  --name stpoppy01 \
  --resource-group rg-tfstate-westeu \
  --location westeurope \
  --sku Standard_LRS \
  --min-tls-version TLS1_2 \
  --allow-blob-public-access false
  ```
  ```bash
  az storage container create \
  --name tfstate \
  --account-name stpoppy01 \
  --auth-mode login
  ```
  Notes: 
  - The storage account job is to store Terraform state files (it's a shared infrastructure that can hold the state of all your project). If the storage account is defined inside the `main.tf`, it would only be created by `terraform apply`, which can't run before `terraform init`.
  - The `--allow-blob-public-access false` means nobody can read files anonymously. This is important because the state file contains secrets (e.g. passwords, cluster certificates).
  - The *container* is a folder inside the storage account, and the name "tfstate" says what's in it which is the Terraform state file. 
  - The `--auth-mode login` uses your Entra ID login (az login) to create the container, but it requires the **Storage Blob Data Contributor** role on the storage account (Owner alone is not enough). Without it, remove `--auth-mode login` to use the account key instead.

  To check what are resources you just created:
  
  ```bash
  az resource list --resource-group rg-tfstate-westeu --output table
  ```
  ```bash
  az storage container-rm list --storage-account stpoppy01 --output table
  ```

---

### Step 1: Add the Application Manifests (GitOps)

The Kubernetes manifests of the 3-tier web app (frontend, backend, PostgreSQL) live in `kubernetes/3tire-configs/`. Argo CD watches this folder and keeps the cluster in sync with it.

#### 1.1 Copy the Manifest files from the source repo below:

```bash
git clone https://github.com/piyushsachdeva/Terraform-Full-Course-Azure.git source-temp
mkdir -p aks-gitops-argocd-terraform/kubernetes
cp -r source-temp/lessons/day28/manifest-files/3tire-configs aks-gitops-argocd-terraform/kubernetes/
```

#### 1.2 Update the Argo CD Application

In `argocd-application.yaml`, point it to your own repo like this:

```yaml
source:
  repoURL: https://github.com/emlykf/aks-gitops-argocd-terraform.git
  targetRevision: HEAD
  path: kubernetes/3tire-configs
```

#### 1.3 Update the container images name

Point the frontend and backend to the public images from piyushsachdeva on Docker Hub:

- frontend-complete.yaml:
  ```yaml
  image: piyushsachdeva/frontend
  ```
- backend-complete.yaml:
  ```yaml
  image: piyushsachdeva/backend
  ```
- kustomization.yaml:
  ```yaml
  images:
    - name: piyushsachdeva/frontend
      newTag: v2
    - name: piyushsachdeva/backend
      newTag: latest
    - name: postgres
      newTag: "15"
  ```

### Step 2: Update Terraform Configuration Files

Note: for now, only the `dev/` environment will be updated. `test/` and `prod/` will be added later and will also need to be adjusted.

#### 2.1 Copy the variable files into `dev/`:

```bash
cp source-temp/lessons/day28/dev/variables.tf     aks-gitops-argocd-terraform/dev/
cp source-temp/lessons/day28/dev/terraform.tfvars aks-gitops-argocd-terraform/dev/
```

#### 2.2 Update both `terraform.tfvars` and the defaults in `variables.tf` with these changes:

```hcl
location                = "westeurope"
resource_group_name     = "rg-aks-gitops-argocd-dev-westeu"
kubernetes_cluster_name = "aks-gitops-argocd-cluster"
vm_size                 = "Standard_D2s_v4"
kubernetes_version      = "1.35.7"

gitops_repo_url = "https://github.com/emlykf/aks-gitops-argocd-terraform.git"
app_repo_url    = "https://github.com/emlykf/aks-gitops-argocd-terraform.git"
app_repo_path   = "kubernetes/3tire-configs"

postgres_password = ""
```
Notes:
- Only `dev/` is configured for now. The `test/` and `prod/` environments are incomplete (no Key Vault / External Secrets), so they will be created later.
- The project resource group must be **different** from the state resource group (`rg-tfstate-westeu`). Otherwise `terraform destroy` would also delete the storage account holding the state files.
- `postgres_password = ""` makes Terraform generate a random password and store it in Key Vault, so no password is written in the code.
- `node_count` probably will not be used, because the node pool uses autoscaling (min 1, max 5) set in `main.tf`.

### Step 3: Validate GitOps Repository Access

Check that the manifests are publicly accessible, so Argo CD can read them:

```bash
curl -s https://raw.githubusercontent.com/emlykf/aks-gitops-argocd-terraform/main/kubernetes/3tire-configs/namespace.yaml
```

This should return the content of `namespace.yaml`. If you get a `404`, check that:
- the repository name and path are correct
- the repository is public
- the files were pushed to the `main` branch

## Challenges & How I Resolved Them