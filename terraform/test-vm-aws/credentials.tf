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
    CONCOURSE_EXTERNAL_DOMAIN=${local.public_ip}
    CONCOURSE_GITHUB_CLIENT_ID=${var.GITHUB_CLIENT_ID}
    CONCOURSE_GITHUB_CLIENT_SECRET=${var.GITHUB_CLIENT_SECRET}
  ENV
  filename = "${path.module}/.concourse.env"
}

resource "terraform_data" "update_postgres_pw" {
  triggers_replace = [
    random_password.postgres.result
  ]

  depends_on = [terraform_data.provision_concourse]

  provisioner "local-exec" {
    command = <<-CMD
      ${local.ssh} "\
        cd /concourse ;\
        [ -f /run/systemd/shutdown/scheduled ] && exit 0 ;\
        set -a ; source docker-versions.sh ; set +a ;\
        sudo -E /usr/bin/docker compose --env-file /concourse/.concourse.env exec db psql -U concourse_user -d concourse -c \
        \"ALTER USER concourse_user PASSWORD '${random_password.postgres.result}';\""
    CMD
  }
}

