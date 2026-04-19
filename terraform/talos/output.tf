output "schematic_id" {
  value = talos_image_factory_schematic.this.id
}

output "installer_image" {
  value = data.talos_image_factory_urls.this.urls.installer
}

output "talosconfig" {
  value     = data.talos_client_configuration.talosconfig.talos_config
  sensitive = true
}

output "kubeconfig" {
  value     = talos_cluster_kubeconfig.this.kubeconfig_raw
  sensitive = true
}

# you can output a specific node with
# tofu output -json machineconfigs | jq -r '.["nodename"]'
output "machineconfigs" {
  value = merge(
    { for k, v in talos_machine_configuration_apply.controlplanes : k => v.machine_configuration },
    { for k, v in talos_machine_configuration_apply.workers      : k => v.machine_configuration },
  )
  sensitive = true
}

output "machineconfigs_controlplane" {
  value     = { for k, v in talos_machine_configuration_apply.controlplanes : k => v.machine_configuration }
  sensitive = true
}

output "machineconfigs_worker" {
  value     = { for k, v in talos_machine_configuration_apply.workers : k => v.machine_configuration }
  sensitive = true
}
