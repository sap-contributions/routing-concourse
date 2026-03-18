# To rotate password, use terraform taint random_password.<name> and then terraform apply
resource "random_password" "postgres" {
  length  = 16
  special = false
}

resource "random_password" "concourse_admin" {
  length  = 16
  special = false
}

resource "local_sensitive_file" "concourse_env" {
  lifecycle {
    precondition {
      condition     = var.GITHUB_CLIENT_ID != "" && var.GITHUB_CLIENT_SECRET != ""
      error_message = "You need to set both GITHUB_CLIENT_ID and GITHUB_CLIENT_SECRET variables."
    }
  }

  content  = <<-ENV
    CONCOURSE_POSTGRES_PASSWORD=${random_password.postgres.result}
    CONCOURSE_ADMIN_PWD=${random_password.concourse_admin.result}
    CONCOURSE_EXTERNAL_URL=http://${local.public_ip}
    CONCOURSE_GITHUB_CLIENT_ID=${var.GITHUB_CLIENT_ID}
    CONCOURSE_GITHUB_CLIENT_SECRET=${var.GITHUB_CLIENT_SECRET}
  ENV
  filename = "${path.module}/.concourse.env"
}
