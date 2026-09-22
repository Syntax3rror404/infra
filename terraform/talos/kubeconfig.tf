resource "talos_cluster_kubeconfig" "this" {
  depends_on = [
    talos_cluster.this
  ]
  client_configuration = talos_machine_secrets.this.client_configuration
  node                 = var.endpoint_vip
}
