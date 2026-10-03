# Kubernetes resources in separate file for better organization
# This should be applied after the AKS cluster is stable

# ArgoCD namespace
resource "kubernetes_namespace_v1" "argocd" {
  metadata {
    name = var.argocd_namespace
    labels = {
      "app.kubernetes.io/name" = "argocd"
      environment              = var.environment
    }
  }

  depends_on = [time_sleep.wait_for_cluster]
}

# Install ArgoCD using Helm with better error handling
resource "helm_release" "argocd" {
  name       = "argocd"
  repository = "https://argoproj.github.io/argo-helm"
  chart      = "argo-cd"
  namespace  = kubernetes_namespace_v1.argocd.metadata[0].name
  version    = "6.0.1"

  # Timeout for installation
  timeout = 600

  # Wait for dependencies
  wait          = true
  wait_for_jobs = true

  set = [ 
    {
      name  = "server.service.type"
      value = "LoadBalancer"
    },
    {
      name  = "server.service.loadBalancerSourceRanges"
      value = "{0.0.0.0/0}"
    },
    {
      name  = "configs.params.server\\.insecure"
      value = "true"
    },
    {
      name  = "server.extraArgs"
      value = "{--insecure}"
    },
    {
      name  = "server.resources.limits.cpu"   # Resource limits for stability
      value = "500m"
    },
    {
      name  = "server.resources.limits.memory"
      value = "512Mi"
    }
  ]  

  depends_on = [kubernetes_namespace_v1.argocd]
}

# Create ArgoCD Application using null_resource with external script
resource "null_resource" "goal_tracker_app" {
  # Triggers to recreate the resource when cluster or ArgoCD changes
  triggers = {
    cluster_id       = azurerm_kubernetes_cluster.main.id
    argocd_ready     = helm_release.argocd.status
    script_hash      = filemd5("${path.module}/scripts/deploy-argocd-app.sh")
    manifest_hash    = filemd5("${path.module}/manifests/argocd-app-manifest.yaml")
    environment      = var.environment
    argocd_namespace = var.argocd_namespace
  }

  provisioner "local-exec" {
    interpreter = ["bash", "-c"]   # I'm using Windows: Terraform would run this with cmd.exe, which can't run .sh scripts, so I use bash (Git Bash) instead 
    working_dir = path.module
    command     = "./scripts/deploy-argocd-app.sh"

    environment = {
      ENVIRONMENT      = var.environment
      ARGOCD_NAMESPACE = var.argocd_namespace
      APP_REPO_URL     = var.app_repo_url
      APP_REPO_PATH    = var.app_repo_path
    }
  }

  # Cleanup when destroying
  provisioner "local-exec" {
    when    = destroy
    command = "kubectl delete application 3tirewebapp-${self.triggers.environment} -n ${self.triggers.argocd_namespace} --ignore-not-found=true"
  }

  depends_on = [helm_release.argocd]
}