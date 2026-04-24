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
      <<-EOT
        ---
        apiVersion: v1alpha1
        kind: HostnameConfig
        auto: off
        hostname: ${each.value.hostname}

        ---
        apiVersion: v1alpha1
        kind: ResolverConfig
        nameservers:
          - address: ${var.nameserver}

        ---
        apiVersion: v1alpha1
        kind: LinkConfig
        name: enp2s0
        addresses:
          - address: ${each.value.ip}/24
        routes:
          - gateway: ${var.default_gateway}

        ---
        apiVersion: v1alpha1
        kind: LinkConfig
        name: lo
        addresses:
          - address: 169.254.116.108/32

        ---
        apiVersion: v1alpha1
        kind: Layer2VIPConfig
        name: ${var.endpoint_vip}
        link: enp2s0

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
    <<-EOT
      ---
      apiVersion: v1alpha1
      kind: HostnameConfig
      auto: off
      hostname: ${each.value.hostname}

      ---
      apiVersion: v1alpha1
      kind: ResolverConfig
      nameservers:
        - address: ${var.nameserver}

      ---
      apiVersion: v1alpha1
      kind: LinkConfig
      name: enp2s0
      addresses:
        - address: ${each.value.ip}/24
      routes:
        - gateway: ${var.default_gateway}

      ---
      apiVersion: v1alpha1
      kind: LinkConfig
      name: lo
      addresses:
        - address: 169.254.116.108/32

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
