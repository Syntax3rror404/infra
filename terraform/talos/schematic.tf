resource "talos_image_factory_schematic" "this" {
  schematic = yamlencode(
    {
      customization = {
        systemExtensions = {
          officialExtensions = var.talos_extensions
        }
        # Drops Talos' forced pti=on; the kernel's auto mode then skips PTI on
        # AMD (meltdown: Not affected).
        extraKernelArgs = ["-selinux", "selinux=0", "-pti"]
      }
    }
  )
}

data "talos_image_factory_urls" "this" {
  talos_version = "v${var.talos_version}"
  schematic_id  = talos_image_factory_schematic.this.id
  platform      = "metal"
}
