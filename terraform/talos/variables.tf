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

