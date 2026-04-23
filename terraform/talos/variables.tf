variable "cluster_name" {
  type    = string
  default = "talos"
}

variable "default_gateway" {
  type    = string
  default = "192.168.35.1"
}

variable "nameserver" {
  type    = string
  default = "192.168.33.1"
}

variable "endpoint_vip" {
  type    = string
  default = "192.168.35.40"
}

variable "service_subnet" {
  type    = string
  default = "10.245.0.0/16"
}

variable "pod_subnet" {
  type    = string
  default = "10.244.0.0/16"
}

variable "talos_version" {
  type    = string
  default = "1.10.7"
}

variable "kubernetes_version" {
  type    = string
  default = "1.33.4"
}

variable "talos_extensions" {
  type = list(string)
}

variable "workers" {
  type = list(object({
    hostname             = string
    ip                   = string
    install_diskSelector = string
    data_diskSelector    = string
  }))
}

variable "controlplanes" {
  type = list(object({
    hostname             = string
    ip                   = string
    install_diskSelector = string
    data_diskSelector    = string
  }))
}

variable "oidc" {
  default = null
  type = object({
    issuer_url      = string
    client_id       = string
    username_claim  = optional(string, "preferred_username")
    username_prefix = optional(string, "oidc:")
    groups_claim    = optional(string, "groups")
    groups_prefix   = optional(string, "oidc:")
  })
}

variable "sysctls_patch" {
  type        = string
  description = "Machine-level sysctls applied to both controlplane and worker nodes as a Talos config patch."
  default     = <<-EOT
    machine:
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
        # --- BBR companion tuning (critical for BBR to actually work well) ---
        net.ipv4.tcp_slow_start_after_idle: 0  # Prevents BBR from resetting to slow-start after idle (huge for long-lived gRPC/HTTP2)
        net.ipv4.tcp_notsent_lowat: 131072  # Caps send buffer bloat; lets BBR react to RTT changes quickly
        net.ipv4.tcp_no_metrics_save: 1  # Don't cache old CUBIC metrics that would handicap BBR reconnects
        # --- Memory management ---
        vm.nr_hugepages: 2048  # Preallocate 2048x 2MB hugepages (Longhorn, OpenEBS, PostgreSQL)
        vm.max_map_count: 262144  # Required by OpenSearch/Elasticsearch for mmap() usage
        vm.min_free_kbytes: 262144  # 256 MB reserve; protects atomic allocations in the network RX path under memory pressure
        # --- Connection queue / backlog ---
        net.core.somaxconn: 65535  # Max number of connections in listen() backlog
        net.core.netdev_max_backlog: 4096  # Max number of packets queued on interface input
        net.ipv4.tcp_max_syn_backlog: 8192  # SYN queue must scale with somaxconn, otherwise it drops first
        net.ipv4.tcp_max_tw_buckets: 1440000  # Prevents "time wait bucket table overflow" under load with tcp_tw_reuse=1
        # --- TCP keepalive & timeouts ---
        net.ipv4.tcp_keepalive_intvl: 60  # Interval (s) between keepalive probes
        net.ipv4.tcp_keepalive_time: 600  # Time (s) before sending keepalive probes
        net.ipv4.tcp_fin_timeout: 10  # Time (s) to wait for FIN-WAIT-2 before closing
        net.ipv4.tcp_tw_reuse: 1  # Allow reuse of TIME-WAIT sockets (reduces port exhaustion)
        # --- NFS / RPC performance tuning ---
        sunrpc.tcp_slot_table_entries: 128  # Number of concurrent RPC requests per TCP connection (higher = better throughput for NFS)
        sunrpc.tcp_max_slot_table_entries: 128  # Maximum allowed RPC slots (caps dynamic scaling, improves stability under load)
  EOT
}
