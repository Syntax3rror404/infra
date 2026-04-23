### local backend use for bootstrap
#terraform {
#  backend "local" {
#    path = "./terraform.tfstate"
#  }
#}

### k8s backend use after installation migrate local done with "tofu init -migrate-state"
terraform {
  backend "kubernetes" {
    secret_suffix = "talos"
    config_path   = "~/.kube/config"
    namespace     = "kube-system"
  }
}
