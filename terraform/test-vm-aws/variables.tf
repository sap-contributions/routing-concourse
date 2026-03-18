variable "aws_access_key" {
  type        = string
  description = "AWS access key ID"
  sensitive   = true
}

variable "aws_secret_key" {
  type        = string
  description = "AWS secret access key"
  sensitive   = true
}

variable "region" {
  type        = string
  description = "AWS region"
  default     = "eu-west-1"
}

variable "availability_zone" {
  type        = string
  description = "AWS availability zone for the VM and EBS volume"
  default     = "eu-west-1a"
}

variable "vm_size" {
  type        = string
  description = "EC2 instance type"
  default     = "t3.xlarge"
}

variable "os_ver" {
  type        = string
  description = "Ubuntu 22.04 LTS AMI ID. Find region-specific IDs at https://cloud-images.ubuntu.com/locator/ec2/"
  # ubuntu/images/hvm-ssd/ubuntu-jammy-22.04-amd64-server in eu-west-1
  default     = "ami-09d0c9a85bf1b9ea7"
}

variable "docker_ver" {
  type        = string
  description = "Docker version"
  default     = "5:27.2.0-1~ubuntu.22.04~jammy"
}

variable "disk_size" {
  type        = number
  description = "Size in GB for concourse data volume (EBS)"
  default     = 200
}

variable "ssh_allowed_cidr" {
  type        = string
  description = "CIDR block allowed to SSH into the VM. Defaults to your current public IP (auto-detected). Override if your IP changes or you need a fixed range."
  default     = null
}

# Sensitive credentials - need input only on change, otherwise last value re-used
variable "GITHUB_CLIENT_ID" {
  description = "Github client ID from oAuth application config"
  type        = string
  sensitive   = true
}

variable "GITHUB_CLIENT_SECRET" {
  description = "Github client secret from oAuth application config"
  type        = string
  sensitive   = true
}

