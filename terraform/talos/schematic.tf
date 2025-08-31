resource "talos_image_factory_schematic" "this" {
  schematic = yamlencode(
    {
      customization = {
        systemExtensions = {
          officialExtensions = var.talos_extensions
        }
      }
    }
  )
}

data "talos_image_factory_urls" "this" {
  talos_version = "v${var.talos_version}"
  schematic_id  = talos_image_factory_schematic.this.id
  platform      = "metal"
}

