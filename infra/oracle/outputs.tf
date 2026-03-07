output "instance_public_ip" {
  value = oci_core_instance.ubuntu.public_ip
}

output "instance_id" {
  value = oci_core_instance.ubuntu.id
}

output "image_name" {
  value = data.oci_core_images.ubuntu.images[0].display_name
}
