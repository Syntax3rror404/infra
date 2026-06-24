locals {
  # Per-worker network patch (hostname → YAML string).
  worker_network_patch = {
    for node in var.workers :
    node.hostname => <<-EOT
      ---
      apiVersion: v1alpha1
      kind: HostnameConfig
      auto: off
      hostname: ${node.hostname}

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
        - address: ${node.ip}/24
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
          match: "${node.data_diskSelector}"
        maxSize: 1800GB
      filesystem:
        type: xfs
    EOT
  }

  # Per-controlplane network patch (hostname → YAML string).
  # Layer2VIPConfig intentionally placed between LinkConfig(lo) and UserVolumeConfig
  # to match the original patch order and avoid a spurious config hash change.
  controlplane_network_patch = {
    for node in var.controlplanes :
    node.hostname => <<-EOT
      ---
      apiVersion: v1alpha1
      kind: HostnameConfig
      auto: off
      hostname: ${node.hostname}

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
        - address: ${node.ip}/24
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
          match: "${node.data_diskSelector}"
        maxSize: 1800GB
      filesystem:
        type: xfs
    EOT
  }
}
