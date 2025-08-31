## local backend use for bootstrap
#terraform {
#  backend "local" {
#    path = "./terraform.tfstate"
#  }
#}

# k9s backend use after installation migrate local done with "terraform init -migrate-state"
terraform {
  backend "kubernetes" {
    secret_suffix     = "talos-install"
    config_path       = "~/.kube/config"
    namespace         = "kube-system"
  }
}
