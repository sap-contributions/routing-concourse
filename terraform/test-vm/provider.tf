terraform {
  required_version = ">= 1.2.0"

  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 5.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.0"
    }
    local = {
      source  = "hashicorp/local"
      version = "~> 2.0"
    }
  }

  # No backend block: Terraform uses local state by default
  # This keeps the test environment fully isolated from production state
}

provider "google" {
  project = var.project_id
  region  = var.region
}
