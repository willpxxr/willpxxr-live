locals {
  ovh_kubeconfig = yamldecode(ovh_cloud_project_kube.main.kubeconfig)
}

provider "kubernetes" {
  host                   = local.ovh_kubeconfig["clusters"][0]["cluster"]["server"]
  cluster_ca_certificate = base64decode(local.ovh_kubeconfig["clusters"][0]["cluster"]["certificate-authority-data"])
  client_certificate     = base64decode(local.ovh_kubeconfig["users"][0]["user"]["client-certificate-data"])
  client_key             = base64decode(local.ovh_kubeconfig["users"][0]["user"]["client-key-data"])
}

provider "helm" {
  kubernetes = {
    host                   = local.ovh_kubeconfig["clusters"][0]["cluster"]["server"]
    cluster_ca_certificate = base64decode(local.ovh_kubeconfig["clusters"][0]["cluster"]["certificate-authority-data"])
    client_certificate     = base64decode(local.ovh_kubeconfig["users"][0]["user"]["client-certificate-data"])
    client_key             = base64decode(local.ovh_kubeconfig["users"][0]["user"]["client-key-data"])
  }
}

resource "ovh_cloud_project_kube" "main" {
  service_name = ovh_cloud_project.main.project_id
  name         = "willpxxr-live"
  region       = var.ovh_kube_region
}

resource "ovh_cloud_project_kube_nodepool" "main" {
  service_name  = ovh_cloud_project.main.project_id
  kube_id       = ovh_cloud_project_kube.main.id
  name          = "default"
  flavor_name   = "d2-8"
  desired_nodes = 1
  min_nodes     = 1
  max_nodes     = 1
  autoscale     = false
}

module "flux_operator_bootstrap" {
  source  = "controlplaneio-fluxcd/flux-operator-bootstrap/kubernetes"
  version = "0.7.0"

  revision = 1

  gitops_resources = {
    instance_yaml = file("${path.root}/gitops/clusters/uk/ovh/cluster/flux-system/flux-instance.yaml")
  }

  depends_on = [ovh_cloud_project_kube_nodepool.main]
}
