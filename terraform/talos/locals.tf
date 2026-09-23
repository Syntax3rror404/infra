locals {
  cluster_endpoint = "https://${var.endpoint_vip}:6443"

  # One map for both roles: adding a worker means one entry in var.workers and
  # nothing else. "role" is the only per-role branch in this file.
  all_nodes = merge(
    { for n in var.controlplanes : n.hostname => merge(n, { role = "controlplane" }) },
    { for n in var.workers : n.hostname => merge(n, { role = "worker" }) },
  )

  controlplane_ips = [for n in var.controlplanes : n.ip]

  # Shared by both roles. Per-node only through install.diskSelector.
  base_patch = {
    for k, n in local.all_nodes : k => <<-EOT
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
            model: "${n.install_diskSelector}"
        features:
          hostDNS:
            enabled: true
            forwardKubeDNSToHost: true
            resolveMemberNames: false
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
  }

  controlplane_patch = <<-EOT
    machine:
      features:
        kubernetesTalosAPIAccess:
          enabled: true
          allowedRoles:
            - os:reader
            - os:operator
          allowedKubernetesNamespaces:
            - kube-system
    cluster:
      allowSchedulingOnControlPlanes: false
      proxy:
        disabled: true
      coreDNS:
        disabled: true
      apiServer:
        extraArgs:
          event-ttl: 15m
        env:
          GOGC: "75"
  EOT

  oidc_patch = var.oidc == null ? "" : <<-EOT
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
                  url: "${try(var.oidc.issuer_url, "")}"
                  audiences:
                    - "${try(var.oidc.client_id, "")}"
                  audienceMatchPolicy: MatchAny
                claimMappings:
                  username:
                    claim: "${try(var.oidc.username_claim, "")}"
                    prefix: "${try(var.oidc.username_prefix, "")}"
                  groups:
                    claim: "${try(var.oidc.groups_claim, "")}"
                    prefix: "${try(var.oidc.groups_prefix, "")}"
    cluster:
      apiServer:
        extraArgs:
          authentication-config: /etc/kubernetes/oidc/auth-config.yaml
        extraVolumes:
          - hostPath: /var/etc/kubernetes/oidc
            mountPath: /etc/kubernetes/oidc
            readonly: true
  EOT

  # Typed Talos 1.14 documents. Document order is reproduced verbatim in the
  # applied config, so Layer2VIPConfig stays between LinkConfig(lo) and
  # UserVolumeConfig -- moving it changes the config hash.
  network_patch = {
    for k, n in local.all_nodes : k => join("\n", concat(
      [<<-EOT
        ---
        apiVersion: v1alpha1
        kind: HostnameConfig
        auto: off
        hostname: ${n.hostname}

        ---
        apiVersion: v1alpha1
        kind: ResolverConfig
        nameservers:
          - address: ${var.nameserver}
        searchDomains:
          domains:
            - ${var.search_domain}

        ---
        apiVersion: v1alpha1
        kind: LinkConfig
        name: enp2s0
        addresses:
          - address: ${n.ip}/24
        routes:
          - gateway: ${var.default_gateway}

        ---
        apiVersion: v1alpha1
        kind: LinkConfig
        name: lo
        addresses:
          - address: 169.254.116.108/32
      EOT
      ],
      n.role == "controlplane" ? [<<-EOT
        ---
        apiVersion: v1alpha1
        kind: Layer2VIPConfig
        name: ${var.endpoint_vip}
        link: enp2s0
      EOT
      ] : [],
      [<<-EOT
        ---
        apiVersion: v1alpha1
        kind: UserVolumeConfig
        name: longhorn
        provisioning:
          diskSelector:
            match: "${n.data_diskSelector}"
          maxSize: 1800GB
        filesystem:
          type: xfs
      EOT
      ],
    ))
  }

  filesystem_trim_patch = <<-EOT
    ---
    apiVersion: v1alpha1
    kind: FilesystemTrimConfig
    interval: ${var.trim_interval}
  EOT

  config_patches = {
    for k, n in local.all_nodes : k => concat(
      [var.sysctls_patch, var.sysfs_patch, local.filesystem_trim_patch, local.base_patch[k]],
      n.role == "controlplane" ? [local.controlplane_patch] : [],
      [local.network_patch[k]],
      n.role == "controlplane" && var.oidc != null ? [local.oidc_patch] : [],
    )
  }
}
