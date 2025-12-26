resource "talos_machine_secrets" "this" {
}

data "talos_machine_configuration" "controlplane" {
  cluster_name     = var.cluster_name
  machine_type     = "controlplane"
  cluster_endpoint = "https://${var.endpoint_vip}:6443"
  machine_secrets  = talos_machine_secrets.this.machine_secrets
  talos_version    = var.talos_version
  kubernetes_version = var.kubernetes_version
  config_patches = [
    <<-EOT
      machine:
        kubelet:
          extraArgs:
            rotate-server-certificates: true
        files:
          - path: /etc/cri/conf.d/20-customization.part
            op: create
            content: |
              [plugins."io.containerd.cri.v1.images"]
                discard_unpacked_layers = false
        install:
          image: ${data.talos_image_factory_urls.this.urls.installer}
          wipe: true
        features:
          kubernetesTalosAPIAccess:
            enabled: true
            allowedRoles:
              - os:reader
              - os:operator
            allowedKubernetesNamespaces:
              - kube-system
          hostDNS:
            enabled: false
            forwardKubeDNSToHost: false
      cluster:
        allowSchedulingOnControlPlanes: false
        proxy:
          disabled: true
        discovery:
          enabled: false
        coreDNS:
          disabled: true
        network:
          dnsDomain: cluster.local
          podSubnets:
            - ${var.pod_subnet}
          serviceSubnets:
            - ${var.service_subnet}
          cni:
            name: none
    EOT
  ]
}

data "talos_machine_configuration" "worker" {
  cluster_name     = var.cluster_name
  machine_type     = "worker"
  cluster_endpoint = "https://${var.endpoint_vip}:6443"
  machine_secrets  = talos_machine_secrets.this.machine_secrets
  talos_version    = var.talos_version
  kubernetes_version = var.kubernetes_version
  config_patches = [
    <<-EOT
      machine:
        kubelet:
          extraArgs:
            rotate-server-certificates: true
        files:
          - path: /etc/cri/conf.d/20-customization.part
            op: create
            content: |
              [plugins."io.containerd.cri.v1.images"]
                discard_unpacked_layers = false
        install:
          image: ${data.talos_image_factory_urls.this.urls.installer}
          wipe: true
        features:
          hostDNS:
            enabled: false
            forwardKubeDNSToHost: false
      cluster:
        discovery:
          enabled: false
        network:
          dnsDomain: cluster.local
          podSubnets:
            - ${var.pod_subnet}
          serviceSubnets:
            - ${var.service_subnet}
          cni:
            name: none
    EOT
  ]
}

resource "talos_machine_configuration_apply" "controlplanes" {
  for_each = { for m in var.controlplanes : m.hostname => m }

  node                  = each.value.ip
  client_configuration  = talos_machine_secrets.this.client_configuration
  machine_configuration_input = data.talos_machine_configuration.controlplane.machine_configuration

  config_patches = [
    <<-EOT
    machine:
      network:
        hostname: ${each.value.hostname}
        nameservers:
          - ${var.nameserver}
        interfaces:
          - interface: enp2s0
            addresses:
              - ${each.value.ip}/24
            routes:
              - network: 0.0.0.0/0
                gateway: ${var.default_gateway}
            dhcp: false
            vip:
              ip: ${var.endpoint_vip}

      install:
        wipe: true
        diskSelector:
          model: "${each.value.install_diskSelector}"

    ---
    apiVersion: v1alpha1
    kind: UserVolumeConfig
    name: longhorn
    provisioning:
      diskSelector:
        match: "${each.value.data_diskSelector}"
      maxSize: 1800GB
    filesystem:
      type: xfs
    EOT
  ]
}

resource "talos_machine_configuration_apply" "workers" {
  depends_on = [
    talos_machine_configuration_apply.controlplanes
  ]
  for_each = { for w in var.workers : w.hostname => w }

  node                  = each.value.ip
  client_configuration  = talos_machine_secrets.this.client_configuration
  machine_configuration_input = data.talos_machine_configuration.worker.machine_configuration

  config_patches = [
    <<-EOT
    machine:
      network:
        hostname: ${each.value.hostname}
        nameservers:
          - ${var.nameserver}
        interfaces:
          - interface: enp2s0
            addresses:
              - ${each.value.ip}/24
            routes:
              - network: 0.0.0.0/0
                gateway: ${var.default_gateway}
            dhcp: false

      install:
        wipe: true
        diskSelector:
          model: "${each.value.install_diskSelector}"

    ---
    apiVersion: v1alpha1
    kind: UserVolumeConfig
    name: longhorn
    provisioning:
      diskSelector:
        match: "${each.value.data_diskSelector}"
      maxSize: 1800GB
    filesystem:
      type: xfs
    EOT
  ]
}

resource "talos_machine_bootstrap" "this" {
  depends_on = [
    talos_machine_configuration_apply.controlplanes
  ]
  node                 = var.controlplanes[0].ip
  client_configuration = talos_machine_secrets.this.client_configuration
}