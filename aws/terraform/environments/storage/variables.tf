variable "aws_region" { type = string }
variable "cluster_environment" { type = string }
variable "environment" { type = string }
variable "volumes" {
  description = "Application-supplied EFS claims. The storage class dynamically provisions access points by default; volume_handle selects existing storage and pv_name selects its physical PV name."
  type = map(object({
    size          = string
    volume_handle = optional(string)
    pv_name       = optional(string)
    access_modes  = optional(list(string), ["ReadWriteMany"])
  }))
  default = {}
  validation {
    condition     = alltrue([for volume in var.volumes : volume.pv_name == null || volume.volume_handle != null])
    error_message = "pv_name is only available for static storage with an explicit volume_handle."
  }
}
