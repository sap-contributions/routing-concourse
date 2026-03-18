output "concourse_web_url" {
  description = "Concourse web UI URL"
  value       = "http://${local.public_ip}"
}

output "concourse_admin_password" {
  description = "Concourse local admin password"
  value       = random_password.concourse_admin.result
  sensitive   = true
}

output "fly_login_command" {
  description = "fly login command to connect to the test Concourse"
  value       = "fly -t test login -c http://${local.public_ip} -u admin_concourse -p <admin_password>"
}

output "github_oauth_callback_url" {
  description = "GitHub OAuth callback URL to register in your OAuth app"
  value       = "http://${local.public_ip}/sky/issuer/callback"
}
