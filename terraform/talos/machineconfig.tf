resource "talos_machine_secrets" "this" {
}

locals {
  cluster_endpoint = "https://${var.endpoint_vip}:6443"
}

data "talos_machine_configuration" "controlplane" {
  for_each = { for m in var.controlplanes : m.hostname => m }

  cluster_name       = var.cluster_name
  machine_type       = "controlplane"
  cluster_endpoint   = local.cluster_endpoint
  machine_secrets    = talos_machine_secrets.this.machine_secrets
  talos_version      = var.talos_version
  kubernetes_version = var.kubernetes_version
  config_patches = concat(
    [
      var.sysctls_patch,
      var.sysfs_patch,
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
            diskSelector:
              model: "${each.value.install_diskSelector}"
          features:
            kubernetesTalosAPIAccess:
              enabled: true
              allowedRoles:
                - os:reader
                - os:operator
              allowedKubernetesNamespaces:
                - kube-system
            hostDNS:
              enabled: true
              forwardKubeDNSToHost: true
              resolveMemberNames: true
        cluster:
          allowSchedulingOnControlPlanes: false
          proxy:
            disabled: true
          discovery:
            enabled: false
          coreDNS:
            disabled: true
          apiServer:
            extraArgs:
              event-ttl: 15m
          network:
            dnsDomain: cluster.local
            podSubnets:
              - ${var.pod_subnet}
            serviceSubnets:
              - ${var.service_subnet}
            cni:
              name: none
      EOT
      ,
      local.controlplane_network_patch[each.key],
    ],
    var.oidc != null ? [
      <<-EOT
        machine:
          files:
            - path: /var/etc/kubernetes/oidc/auth-config.yaml
              permissions: 0o644
              op: create
              content: |
                apiVersion: apiserver.config.k8s.io/v1
                kind: AuthenticationConfiguration
                jwt:
                  - issuer:
                      url: "${var.oidc.issuer_url}"
                      audiences:
                        - "${var.oidc.client_id}"
                      audienceMatchPolicy: MatchAny
                    claimMappings:
                      username:
                        claim: "${var.oidc.username_claim}"
                        prefix: "${var.oidc.username_prefix}"
                      groups:
                        claim: "${var.oidc.groups_claim}"
                        prefix: "${var.oidc.groups_prefix}"
        cluster:
          apiServer:
            extraArgs:
              authentication-config: /etc/kubernetes/oidc/auth-config.yaml
            extraVolumes:
              - hostPath: /var/etc/kubernetes/oidc
                mountPath: /etc/kubernetes/oidc
                readonly: true
      EOT
    ] : []
  )
}

data "talos_machine_configuration" "worker" {
  for_each = { for w in var.workers : w.hostname => w }

  cluster_name       = var.cluster_name
  machine_type       = "worker"
  cluster_endpoint   = local.cluster_endpoint
  machine_secrets    = talos_machine_secrets.this.machine_secrets
  talos_version      = var.talos_version
  kubernetes_version = var.kubernetes_version
  config_patches = [
    var.sysctls_patch,
    var.sysfs_patch,
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
          diskSelector:
            model: "${each.value.install_diskSelector}"
        features:
          hostDNS:
            enabled: true
            forwardKubeDNSToHost: true
            resolveMemberNames: true
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
    ,
    local.worker_network_patch[each.key],
  ]
}

resource "talos_machine_configuration_apply" "controlplanes" {
  for_each = { for m in var.controlplanes : m.hostname => m }

  node                        = each.value.ip
  client_configuration        = talos_machine_secrets.this.client_configuration
  machine_configuration_input = data.talos_machine_configuration.controlplane[each.key].machine_configuration
}

resource "talos_machine_configuration_apply" "workers" {
  depends_on = [
    talos_machine_configuration_apply.controlplanes
  ]
  for_each = { for w in var.workers : w.hostname => w }

  node                        = each.value.ip
  client_configuration        = talos_machine_secrets.this.client_configuration
  machine_configuration_input = data.talos_machine_configuration.worker[each.key].machine_configuration
}

resource "talos_machine_bootstrap" "this" {
  depends_on = [
    talos_machine_configuration_apply.controlplanes
  ]
  node                 = var.controlplanes[0].ip
  client_configuration = talos_machine_secrets.this.client_configuration
}
