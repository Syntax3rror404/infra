resource "talos_machine_secrets" "this" {
}

data "talos_machine_configuration" "controlplane" {
  for_each = { for m in var.controlplanes : m.hostname => m }

  cluster_name       = var.cluster_name
  machine_type       = "controlplane"
  cluster_endpoint   = "https://${var.endpoint_vip}:6443"
  machine_secrets    = talos_machine_secrets.this.machine_secrets
  talos_version      = var.talos_version
  kubernetes_version = var.kubernetes_version
  config_patches = concat(
    [
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
          sysctls:
            # --- User namespaces ---
            user.max_user_namespaces: 11255  # Allow many user namespaces (needed for UserNamespaces feature; gVisor)
            # --- Inotify / filesystem watchers ---
            fs.inotify.max_user_instances: 8192  # Max inotify instances per user
            fs.inotify.max_user_watches: 1048576  # Max number of files that can be watched (high workloads, watchdogs)
            # --- Queuing disciplines & network buffers ---
            net.core.default_qdisc: fq  # Use Fair Queuing (better latency & throughput for 10Gbps+)
            net.core.rmem_max: 67108864  # Max receive buffer size (64 MB, high-throughput apps e.g. QUIC)
            net.core.wmem_max: 67108864  # Max send buffer size (64 MB, high-throughput apps e.g. QUIC)
            # --- TCP performance tuning ---
            net.ipv4.tcp_congestion_control: bbr  # Use BBR congestion control (better throughput/latency than CUBIC)
            net.ipv4.tcp_fastopen: 3  # Enable TCP Fast Open (send/recv data in SYN for faster handshakes)
            net.ipv4.tcp_mtu_probing: 1  # Enable MTU probing (handles jumbo frames, avoids blackholing)
            net.ipv4.tcp_rmem: 4096 87380 33554432  # TCP read buffer: min / default / max (32 MB max)
            net.ipv4.tcp_wmem: 4096 65536 33554432  # TCP write buffer: min / default / max (32 MB max)
            net.ipv4.tcp_window_scaling: 1  # Enable TCP window scaling (needed for >64KB throughput)
            # --- Memory management ---
            vm.nr_hugepages: 2048  # Preallocate 2048x 2MB hugepages (Longhorn, OpenEBS, PostgreSQL)
            vm.max_map_count: 262144  # Required by OpenSearch/Elasticsearch for mmap() usage
            # --- Connection queue / backlog ---
            net.core.somaxconn: 65535  # Max number of connections in listen() backlog
            net.core.netdev_max_backlog: 4096  # Max number of packets queued on interface input
            # --- TCP keepalive & timeouts ---
            net.ipv4.tcp_keepalive_intvl: 60  # Interval (s) between keepalive probes
            net.ipv4.tcp_keepalive_time: 600  # Time (s) before sending keepalive probes
            net.ipv4.tcp_fin_timeout: 10  # Time (s) to wait for FIN-WAIT-2 before closing
            net.ipv4.tcp_tw_reuse: 1  # Allow reuse of TIME-WAIT sockets (reduces port exhaustion)
            # --- NFS / RPC performance tuning ---
            sunrpc.tcp_slot_table_entries: 128  # Number of concurrent RPC requests per TCP connection (higher = better throughput for NFS)
            sunrpc.tcp_max_slot_table_entries: 128  # Maximum allowed RPC slots (caps dynamic scaling, improves stability under load)
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
  cluster_endpoint   = "https://${var.endpoint_vip}:6443"
  machine_secrets    = talos_machine_secrets.this.machine_secrets
  talos_version      = var.talos_version
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
        sysctls:
          # --- User namespaces ---
          user.max_user_namespaces: 11255  # Allow many user namespaces (needed for UserNamespaces feature; gVisor)
          # --- Inotify / filesystem watchers ---
          fs.inotify.max_user_instances: 8192  # Max inotify instances per user
          fs.inotify.max_user_watches: 1048576  # Max number of files that can be watched (high workloads, watchdogs)
          # --- Queuing disciplines & network buffers ---
          net.core.default_qdisc: fq  # Use Fair Queuing (better latency & throughput for 10Gbps+)
          net.core.rmem_max: 67108864  # Max receive buffer size (64 MB, high-throughput apps e.g. QUIC)
          net.core.wmem_max: 67108864  # Max send buffer size (64 MB, high-throughput apps e.g. QUIC)
          # --- TCP performance tuning ---
          net.ipv4.tcp_congestion_control: bbr  # Use BBR congestion control (better throughput/latency than CUBIC)
          net.ipv4.tcp_fastopen: 3  # Enable TCP Fast Open (send/recv data in SYN for faster handshakes)
          net.ipv4.tcp_mtu_probing: 1  # Enable MTU probing (handles jumbo frames, avoids blackholing)
          net.ipv4.tcp_rmem: 4096 87380 33554432  # TCP read buffer: min / default / max (32 MB max)
          net.ipv4.tcp_wmem: 4096 65536 33554432  # TCP write buffer: min / default / max (32 MB max)
          net.ipv4.tcp_window_scaling: 1  # Enable TCP window scaling (needed for >64KB throughput)
          # --- Memory management ---
          vm.nr_hugepages: 2048  # Preallocate 2048x 2MB hugepages (Longhorn, OpenEBS, PostgreSQL)
          vm.max_map_count: 262144  # Required by OpenSearch/Elasticsearch for mmap() usage
          # --- Connection queue / backlog ---
          net.core.somaxconn: 65535  # Max number of connections in listen() backlog
          net.core.netdev_max_backlog: 4096  # Max number of packets queued on interface input
          # --- TCP keepalive & timeouts ---
          net.ipv4.tcp_keepalive_intvl: 60  # Interval (s) between keepalive probes
          net.ipv4.tcp_keepalive_time: 600  # Time (s) before sending keepalive probes
          net.ipv4.tcp_fin_timeout: 10  # Time (s) to wait for FIN-WAIT-2 before closing
          net.ipv4.tcp_tw_reuse: 1  # Allow reuse of TIME-WAIT sockets (reduces port exhaustion)
          # --- NFS / RPC performance tuning ---
          sunrpc.tcp_slot_table_entries: 128  # Number of concurrent RPC requests per TCP connection (higher = better throughput for NFS)
          sunrpc.tcp_max_slot_table_entries: 128  # Maximum allowed RPC slots (caps dynamic scaling, improves stability under load)
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
