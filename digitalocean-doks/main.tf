terraform {
  required_providers {
    digitalocean = {
      source = "digitalocean/digitalocean"
      version = "~> 2.0"
    }
  }
}

variable "coder_version" {
  default = "0.13.6"
}

# Change this password away from the default if you are doing
# anything more than a testing stack.
variable "db_password" {
  default = "coder"
}

###############################################################
# K8s configuration
###############################################################
# Set DIGITALOCEAN_TOKEN
provider "digitalocean" {
}

resource "digitalocean_kubernetes_cluster" "coder" {
  name   = "coder"
  region = "nyc1"
  version = "1.25"

  node_pool {
    name       = "default"
    size       = "s-2vcpu-4gb"
    node_count = 1
  }
}

provider "kubernetes" {
  host                   = digitalocean_kubernetes_cluster.coder.endpoint
  token                  = digitalocean_kubernetes_cluster.coder.kube_config[0].token
  cluster_ca_certificate = base64decode(digitalocean_kubernetes_cluster.coder.kube_config[0].cluster_ca_certificate)
}

resource "kubernetes_namespace" "coder_namespace" {
  metadata {
    name = "coder"
  }
}

###############################################################
# Coder configuration
###############################################################
provider "helm" {
  kubernetes {
    host                   = digitalocean_kubernetes_cluster.coder.endpoint
    token                  = digitalocean_kubernetes_cluster.coder.kube_config[0].token
    cluster_ca_certificate = base64decode(digitalocean_kubernetes_cluster.coder.kube_config[0].cluster_ca_certificate)
  }
}

resource "helm_release" "pg_cluster" {
  name      = "postgresql"
  namespace = kubernetes_namespace.coder_namespace.metadata.0.name

  repository = "https://charts.bitnami.com/bitnami"
  chart      = "postgresql"

  set {
    name  = "auth.username"
    value = "coder"
  }

  set {
    name  = "auth.password"
    value = "${var.db_password}"
  }

  set {
    name  = "auth.database"
    value = "coder"
  }

  set {
    name  = "persistence.size"
    value = "10Gi"
  }
}

resource "helm_release" "coder" {
  name      = "coder"
  namespace = kubernetes_namespace.coder_namespace.metadata.0.name

  chart = "https://github.com/coder/coder/releases/download/v${var.coder_version}/coder_helm_${var.coder_version}.tgz"

  values = [
    <<EOT
coder:
  env:
    - name: CODER_PG_CONNECTION_URL
      value: "postgres://coder:${var.db_password}@${helm_release.pg_cluster.name}.coder.svc.cluster.local:5432/coder?sslmode=disable"
    - name: CODER_EXPERIMENTAL
      value: "true"
    EOT
  ]

  depends_on = [
    helm_release.pg_cluster
  ]
}
