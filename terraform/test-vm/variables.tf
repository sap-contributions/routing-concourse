variable "project_id" {
  type        = string
  description = "GCP project ID"
  default     = "test-sap-cfn-test-project"
}

variable "zone" {
  type        = string
  description = "Zone where to deploy the test VM"
  default     = "europe-west1-b"
}

variable "region" {
  type        = string
  description = "Region where to deploy the test VM"
  default     = "europe-west1"
}


variable "vm_size" {
  type        = string
  description = "VM machine type"
  default     = "t2d-standard-4"
}

variable "os_ver" {
  type        = string
  description = "Deployment image"
  default     = "ubuntu-os-cloud/ubuntu-2204-lts"
}

variable "docker_ver" {
  type        = string
  description = "Docker version"
  default     = "5:27.2.0-1~ubuntu.22.04~jammy"
}

variable "disk_size" {
  type        = number
  description = "Size in GB for concourse data volume"
  default     = 200
}

variable "disk_type" {
  type        = string
  description = "Disk type for concourse data volume"
  default     = "pd-balanced"
}

variable "data_disk" {
  type        = string
  description = "Device name for concourse volume"
  default     = "sdb"
}

# Sensitive credentials - need input only on change, otherwise last value re-used
variable "GITHUB_CLIENT_ID" {
  description = "Github client ID from oAuth application config in git to allow concourse use git as auth"
  type        = string
  sensitive   = true
  default     = "Ov23lic22AVlwY2XxZKA"
}

variable "GITHUB_CLIENT_SECRET" {
  description = "Github client secret from oAuth application config in git to allow concourse use git as auth"
  type        = string
  sensitive   = true
  default     = ""
}
