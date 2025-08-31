output "schematic_id" {
  value = talos_image_factory_schematic.this.id
}

output "installer_image" {
  value = data.talos_image_factory_urls.this.urls.installer
}

output "talosconfig" {
  value = data.talos_client_configuration.talosconfig.talos_config
  sensitive = true
}

output "machineconfig_controlplane" {
  value = data.talos_machine_configuration.controlplane
  sensitive = true
}

output "machineconfig_worker" {
  value = data.talos_machine_configuration.worker
  sensitive = true
}

output "kubeconfig" {
  value = talos_cluster_kubeconfig.this.kubeconfig_raw
  sensitive = true
}