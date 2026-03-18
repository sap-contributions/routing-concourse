terraform {
  required_version = ">= 1.2.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }

  # Local state — isolated from production
}

provider "aws" {
  region     = var.region
  access_key = var.aws_access_key
  secret_key = var.aws_secret_key
}

variable "region" {
  type        = string
  description = "AWS region"
  default     = "eu-west-1"
}

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

resource "aws_eip" "concourse_cfn_test" {
  domain = "vpc"

  tags = {
    Name = "concourse-cfn-test-ip"
  }
}

output "public_ip" {
  description = "Reserved static public IP"
  value       = aws_eip.concourse_cfn_test.public_ip
}

output "eip_allocation_id" {
  description = "EIP allocation ID — used by main config to associate the EIP to the instance"
  value       = aws_eip.concourse_cfn_test.id
}

output "github_oauth_callback_url" {
  description = "Register this URL in your GitHub OAuth app before running the main terraform apply"
  value       = "http://${aws_eip.concourse_cfn_test.public_ip}/sky/issuer/callback"
}


# eip_allocation_id = "eipalloc-0cdfe4c59120a83b1"
# github_oauth_callback_url = "http://52.18.120.177/sky/issuer/callback"
# public_ip = "52.18.120.177"
