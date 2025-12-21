# terraform apply -var-file=terraform.tfvars

cluster_name             = "ich-talos"
default_gateway          = "192.168.35.1"
nameserver               = "192.168.33.1"
endpoint_vip             = "192.168.35.40"
talos_version            = "1.11.6"
kubernetes_version       = "1.34.3"

talos_extensions = [
  "siderolabs/amd-ucode",
  "siderolabs/amdgpu",
  "siderolabs/iscsi-tools",
  "siderolabs/util-linux-tools",
]

controlplanes = [
  {
    hostname             = "tokamak-m1"
    ip                   = "192.168.35.31"
    install_diskSelector = "SAMSUNG MZVLB512HAJQ-000L7"
    data_diskSelector    = "disk.transport == 'nvme' && disk.model == 'WD_BLACK SN770 2TB' && !system_disk"
  },
  {
    hostname             = "tokamak-m2"
    ip                   = "192.168.35.32"
    install_diskSelector = "SAMSUNG MZVLB512HAJQ-000L7"
    data_diskSelector    = "disk.transport == 'nvme' && disk.model == 'WD_BLACK SN770 2TB' && !system_disk"
  },
  {
    hostname             = "tokamak-m3"
    ip                   = "192.168.35.33"
    install_diskSelector = "SAMSUNG MZVLB512HAJQ-000L7"
    data_diskSelector    = "disk.transport == 'nvme' && disk.model == 'WD_BLACK SN770 2TB' && !system_disk"
  }
]

workers = [
  {
    hostname             = "tokamak-w1"
    ip                   = "192.168.35.41"
    install_diskSelector = "CT2000P5SSD8"
    data_diskSelector    = "disk.transport == 'nvme' && disk.model == 'WD_BLACK SN770 2TB' && !system_disk"
  },
  {
    hostname             = "tokamak-w2"
    ip                   = "192.168.35.42"
    install_diskSelector = "WD_BLACK SN770 1TB"
    data_diskSelector    = "disk.transport == 'nvme' && disk.model == 'WD_BLACK SN770 2TB' && !system_disk"
  },
  {
    hostname             = "tokamak-w3"
    ip                   = "192.168.35.43"
    install_diskSelector = "SAMSUNG MZVLW256HEHP-000L7"
    data_diskSelector    = "disk.transport == 'nvme' && disk.model == 'WD_BLACK SN770 2TB' && !system_disk"
  }
]