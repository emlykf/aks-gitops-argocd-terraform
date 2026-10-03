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

### Step 1: Get the Source Code
 
From the folder that contains your repo (e.g. `~/Documents/GitHub`):
 
```bash
git clone https://github.com/piyushsachdeva/Terraform-Full-Course-Azure.git source-temp
```
 
---
 
### Step 2: Set Up the Application Manifests (Kustomize base + overlays)
 
The Kubernetes manifests of the app live in `kubernetes/3tire-configs/`. They are split into a shared **base** and one **overlay** per environment, so each environment gets its own namespace, replicas and image tags. Argo CD watches the overlay of its environment and keeps the cluster in sync with it.
 
```
kubernetes/3tire-configs/
├── base/                       ← shared manifests
├── overlays/
│   ├── dev/                    ← namespace 3tirewebapp-dev
│   ├── test/                   ← namespace 3tirewebapp-test
│   └── prod/                   ← namespace 3tirewebapp-prod
└── argocd-application.yaml     ← manual fallback (see 2.5)
```
 
#### 2.1 Copy the manifests into `base/`

```bash
mkdir -p aks-gitops-argocd-terraform/kubernetes/3tire-configs/base
cp source-temp/lessons/day28/manifest-files/3tire-configs/{postgres,backend,frontend}-complete.yaml aks-gitops-argocd-terraform/kubernetes/3tire-configs/base/
cp source-temp/lessons/day28/manifest-files/3tire-configs/argocd-application.yaml aks-gitops-argocd-terraform/kubernetes/3tire-configs/
```

#### 2.2 Update the container images and the frontend port
 
- base/frontend-complete.yaml:
  ```yaml
  image: piyushsachdeva/frontend
  ...
  ports:
    - port: 80            # the port users connect to (no ":3000" in the URL)
      targetPort: 3000    # the port the app listens on inside the pod
  ```
- base/backend-complete.yaml:
  ```yaml
  image: piyushsachdeva/backend
  ```
 
#### 2.3 Create `base/kustomization.yaml`
 
```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
 
resources:
  - postgres-complete.yaml
  - backend-complete.yaml
  - frontend-complete.yaml
 
commonAnnotations:
  app.kubernetes.io/version: "1.0"
```
 
#### 2.4 Create the overlays
 
Each overlay has two files. Example for dev, `overlays/dev/kustomization.yaml`:
 
```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
 
resources:
  - ../../base
  - namespace.yaml
 
namespace: 3tirewebapp-dev
 
images:
  - name: piyushsachdeva/frontend
    newTag: v2
  - name: piyushsachdeva/backend
    newTag: latest
  - name: postgres
    newTag: "15"
 
replicas:
  - name: frontend
    count: 2
  - name: backend
    count: 2
  - name: postgres
    count: 1
```
 
`overlays/dev/namespace.yaml`:
 
```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: 3tirewebapp-dev
  labels:
    app: 3tirewebapp
```
 
`test` and `prod` use the same two files with their own namespace (`3tirewebapp-test`, `3tirewebapp-prod`). Prod runs **3** frontend and backend replicas. PostgreSQL stays at 1 replica, because its disk (`ReadWriteOnce`) can only be attached to one pod.
 
Notes:
- The backend image only has the `latest` tag (no `v1`/`v2`).
- The `name:` under `images:` in `overlays/<env>/kustomization.yaml` must match the `image:` line in the Deployments in `base/frontend-complete.yaml`, `base/backend-complete.yaml` and `base/postgres-complete.yaml` exactly, otherwise the tag isn't applied. Check that all overlays build:
 
```bash
kubectl kustomize kubernetes/3tire-configs/overlays/dev  > /dev/null && echo "dev OK"
kubectl kustomize kubernetes/3tire-configs/overlays/test > /dev/null && echo "test OK"
kubectl kustomize kubernetes/3tire-configs/overlays/prod > /dev/null && echo "prod OK"
```
 
#### 2.5 Update the Argo CD Application (manual fallback)
 
Terraform creates the Argo CD Application automatically. `argocd-application.yaml` is only a fallback that can be applied by hand (`kubectl apply -f argocd-application.yaml`) if that step fails. Point it to your repo and overlay:
 
```yaml
source:
  repoURL: https://github.com/emlykf/aks-gitops-argocd-terraform.git
  targetRevision: HEAD
  path: kubernetes/3tire-configs/overlays/dev
```

---

### Step 3: Set Up the Terraform Files for `dev/`
 
#### 3.1 Copy the original `dev/` folder
 
```bash
cp -r source-temp/lessons/day28/dev aks-gitops-argocd-terraform/dev
```
 
#### 3.2 `provider.tf`: newer provider versions, no `use_msi`
 
```hcl
terraform {
  required_providers {
    azurerm    = { source = "hashicorp/azurerm",    version = "~> 5.6.0" }
    helm       = { source = "hashicorp/helm",       version = "~> 3.3.0" }
    kubernetes = { source = "hashicorp/kubernetes", version = "~> 3.2.0" }
    random     = { source = "hashicorp/random",     version = "~> 3.9" }
    time       = { source = "hashicorp/time",       version = "~> 0.14" }
  }
  required_version = ">= 1.9.0"
}
```
 
- `use_msi = true` is removed: it only works on Azure resources with a Managed Identity. Locally, Terraform uses the `az login` session.
- In the Helm provider block, Helm 3.x uses `kubernetes = { ... }` instead of `kubernetes { ... }`.

#### 3.3 `backend.tf`: your own state storage
 
```hcl
terraform {
  backend "azurerm" {
    resource_group_name  = "rg-tfstate-westeu"
    storage_account_name = "stpoppy01"
    container_name       = "tfstate"
    key                  = "aks-gitops-argocd-dev.tfstate"
  }
}
```
 
#### 3.4 `terraform.tfvars` and the defaults in `variables.tf`
 
```hcl
environment             = "dev"
location                = "westeurope"
resource_group_name     = "rg-aks-gitops-argocd-dev-westeu"
kubernetes_cluster_name = "aks-gitops-argocd-cluster"
vm_size                 = "Standard_D2s_v4"
kubernetes_version      = "1.35.7"
 
app_repo_url  = "https://github.com/emlykf/aks-gitops-argocd-terraform.git"
app_repo_path = "kubernetes/3tire-configs/overlays/dev"
 
postgres_password = ""
```
 
Notes:
- Check the available Kubernetes versions with `az aks get-versions --location westeurope --output table`. The original `1.32.5` is no longer offered.
- The project resource group must be **different** from the state resource group (`rg-tfstate-westeu`). Otherwise `terraform destroy` would also delete the storage account holding the state files.
- `postgres_password = ""` makes Terraform generate a random password and store it in Key Vault, so no password is written in the code.

---
 
### Step 4: Update the Code for the Newer Providers
 
#### 4.1 `main.tf`
 
- Resource group name: use the variable as it is, so the environment isn't added twice:
```hcl
resource "azurerm_resource_group" "main" {
  name     = var.resource_group_name
  location = var.location
  tags     = local.common_tags
}
```

- AKS cluster: add the `node_provisioning_profile` block (required since azurerm v5, (see [Challenge 1](README.md#1-upgrading-the-original-code-to-azurerm-v5-step-41)).
```hcl
node_provisioning_profile {
  mode = "Manual"
}
```
- Key Vault: add `rbac_authorization_enabled` (required since azurerm v5):
```hcl
rbac_authorization_enabled = false
```
 
#### 4.2 `kubernetes-resources.tf`
 
- Helm provider 3.x: the `set { }` blocks of `helm_release.argocd` become one `set = [ ... ]` list (see [Challenge 2](README.md#2-helm-and-kubernetes-provider-3x-syntax-changes-step-42)).
- Kubernetes provider 3.x: rename `kubernetes_namespace` to `kubernetes_namespace_v1` in all three places.

#### 4.3 Windows users only: run the scripts with bash
 
On Windows, Terraform runs `local-exec` commands with `cmd.exe`, which can't run `.sh` scripts. Add `interpreter` to the `local-exec` blocks that call a script, in `kubernetes-resources.tf` (`goal_tracker_app`) and `external-secrets.tf` (`external_secrets_operator`):
 
```hcl
provisioner "local-exec" {
  interpreter = ["bash", "-c"]
  ...
}
```
 
Also check that `envsubst` is available. `deploy-argocd-app.sh` uses it to fill in your repo URL and path in the Argo CD Application manifest:
 
```bash
which envsubst   # should print a path, e.g. /usr/bin/envsubst
```
 
#### 4.4 Use your own SSH key
 
`main.tf` only adds an SSH key to the AKS nodes if the file exists. Point it to your key (it must be an RSA key):
 
```hcl
for_each = fileexists("~/.ssh/id_rsa.pub") ? [1] : []
...
key_data = file("~/.ssh/id_rsa.pub")
```
 
```bash
head -c 20 ~/.ssh/id_rsa.pub   # should start with "ssh-rsa"
```
 
---
 
### Step 5: Remove Unused Parts of the Original Code
 
The copied code contains a few things that have no effect in this setup. Removing them keeps every remaining part meaningful.
 
- **`node_count`** (in `variables.tf` and `terraform.tfvars`): the node pool uses the AKS cluster autoscaler (`min_count = 1`, `max_count = 5`), which starts at the minimum and adds nodes as needed, so a fixed count is never used.
- **`gitops_repo_url`** (in `variables.tf`, `terraform.tfvars` and the `environment` block in `kubernetes-resources.tf`): it duplicates `app_repo_url`, and `deploy-argocd-app.sh` never reads it.
- **Key Vault CSI driver** (`key_vault_secrets_provider` block in the AKS cluster, plus its `access_policy` in the Key Vault): the secrets are synced by External Secrets Operator instead. Removing it also removes an identity that had read access to the Key Vault without needing it.
- **`external-secrets-placeholder.yaml`** (not copied in Step 2.1): a ConfigMap with notes only; no pod reads it.

`scripts/cleanup-external-secrets.sh` is kept: it isn't called by Terraform, but can be run by hand to remove the External Secrets resources.
 
---
 
### Step 6: Initialize and Check
 
Push the repo to GitHub first, because Argo CD reads the manifests from GitHub, not from your laptop. Check that they're publicly accessible:
 
```bash
curl -s https://raw.githubusercontent.com/emlykf/aks-gitops-argocd-terraform/main/kubernetes/3tire-configs/overlays/dev/namespace.yaml
```
 
Then, in `dev/`:
 
```bash
terraform init
terraform validate
terraform plan
```
 
The plan should end with `Plan: 17 to add, 0 to change, 0 to destroy.`
 
---
 
### Step 7: Deploy and Verify
 
#### 7.1 Deploy
 
```bash
terraform apply
```
 
#### 7.2 Connect kubectl to the cluster
 
```bash
az aks get-credentials \
  --resource-group $(terraform output -raw resource_group_name) \
  --name $(terraform output -raw aks_cluster_name) \
  --admin --overwrite-existing
 
kubectl get nodes
kubectl get namespaces
```
 
#### 7.3 Log in to Argo CD
 
```bash
kubectl get svc argocd-server -n argocd
kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d; echo
```
 
Open `http://<argocd-server EXTERNAL-IP>` and log in as `admin`. The app `3tirewebapp-dev` should be **Synced** and **Healthy**.
 
#### 7.4 Open the app with your own domain
 
```bash
kubectl get svc frontend -n 3tirewebapp-dev
```
 
I use my own domain from GoDaddy. In DNS → DNS-Records, add an **A** record: name `goals-dev`, value = the frontend's EXTERNAL-IP. Then check and open it:
 
```bash
nslookup goals-dev.poppy-gmbh.site 8.8.8.8
```
 
`http://goals-dev.poppy-gmbh.site`
 
Note: the IP changes with every new `apply`, so the A record has to be updated after each deployment.
 
#### 7.5 Check the secrets
 
```bash
kubectl get secretstore,externalsecret -n 3tirewebapp-dev
kubectl get secret postgres-credentials-from-kv -n 3tirewebapp-dev
```
 
The `ExternalSecret` should show `SecretSynced` / `True`.
 
---
 
### Step 8: Test GitOps Self-Healing

```bash
kubectl scale deployment frontend -n 3tirewebapp-dev --replicas=5
kubectl get pods -n 3tirewebapp-dev
```

Argo CD (`selfHeal: true`) scales it back to the replica count defined in Git.
 
---
 
### Step 9: Add the `test` and `prod` Environments
 
```bash
cp -r dev test
cp -r dev prod
rm -rf test/.terraform prod/.terraform
```
 
Change these values in each copy:
 
| File | test | prod |
|---|---|---|
| `backend.tf` → `key` | `aks-gitops-argocd-test.tfstate` | `aks-gitops-argocd-prod.tfstate` |
| `terraform.tfvars` + `variables.tf` → `environment` | `test` | `prod` |
| `terraform.tfvars` + `variables.tf` → `resource_group_name` | `rg-aks-gitops-argocd-test-westeu` | `rg-aks-gitops-argocd-prod-westeu` |
| `terraform.tfvars` + `variables.tf` → `app_repo_path` | `.../overlays/test` | `.../overlays/prod` |
 
Everything else (cluster name, Key Vault name, namespace, Argo CD app name) is built from `environment` automatically.
 
Then run Steps 6–7 in `test/` and `prod/`, with the namespaces `3tirewebapp-test` / `3tirewebapp-prod` and the subdomains `goals-test` / `goals`.
 
---
 
### Step 10: Clean Up
 
In each environment folder:
 
```bash
terraform destroy
```
 
The Key Vault is only soft-deleted (`purge_soft_delete_on_destroy = false`) and stays recoverable for 7 days under **Key vaults → Manage deleted vaults**. The next `apply` creates a new random Key Vault name, so there is no conflict.