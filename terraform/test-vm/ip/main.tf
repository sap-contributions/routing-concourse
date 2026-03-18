terraform {
  required_version = ">= 1.2.0"

  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 5.0"
    }
  }

  # Local state — isolated from production
}

provider "google" {
  project = var.project_id
  region  = var.region
}

variable "project_id" {
  type        = string
  description = "GCP project ID"
  default     = "test-sap-cfn-test-project"
}

variable "region" {
  type        = string
  description = "GCP region"
  default     = "europe-west1"
}

resource "google_compute_address" "concourse" {
  name         = "concourse-cfn-test-ip"
  address_type = "EXTERNAL"
  region       = var.region
}

output "public_ip" {
  description = "Reserved static public IP"
  value       = google_compute_address.concourse.address
}

output "github_oauth_callback_url" {
  description = "Register this URL in your GitHub OAuth app before running the main terraform apply"
  value       = "http://${google_compute_address.concourse.address}/sky/issuer/callback"
}

