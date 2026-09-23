resource "talos_machine_secrets" "this" {
}

data "talos_machine_configuration" "node" {
  for_each = local.all_nodes

  cluster_name     = var.cluster_name
  machine_type     = each.value.role
  cluster_endpoint = local.cluster_endpoint
  machine_secrets  = talos_machine_secrets.this.machine_secrets
  # Generation contract, not the installed version -- see var.talos_contract.
  talos_version      = var.talos_contract
  kubernetes_version = var.kubernetes_version
  config_patches     = local.config_patches[each.key]
}

# Derived from the secrets rather than fetched from the cluster, so it carries no
# dependency on talos_cluster -- that would cycle through drain_on_upgrade below.
ephemeral "talos_cluster_kubeconfig" "this" {
  machine_secrets = talos_machine_secrets.this.machine_secrets
  cluster_name    = var.cluster_name
  endpoint        = local.cluster_endpoint
}

resource "talos_machine" "node" {
  for_each = local.all_nodes

  node                  = each.value.ip
  client_configuration  = talos_machine_secrets.this.client_configuration
  machine_configuration = data.talos_machine_configuration.node[each.key].machine_configuration

  # Bumping var.talos_version rewrites this URL and upgrades the node in place.
  image = data.talos_image_factory_urls.this.urls.installer

  # talos_cluster owns Kubernetes upgrades via upgrade-k8s; without this the five
  # component image fields would be re-applied here in parallel, bypassing it.
  ignore_kubernetes_upgrade_drift = true

  # kexec reboots hang these nodes; always a full power cycle through the firmware.
  reboot_mode = "POWERCYCLE"

  drain_on_upgrade = true
  kubeconfig_wo    = ephemeral.talos_cluster_kubeconfig.this.kubeconfig_raw
}

resource "talos_cluster" "this" {
  depends_on = [
    talos_machine.node
  ]

  node                 = var.controlplanes[0].ip
  control_plane_nodes  = local.controlplane_ips
  client_configuration = talos_machine_secrets.this.client_configuration
  kubernetes_version   = var.kubernetes_version
}
