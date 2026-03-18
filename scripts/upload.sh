#!/bin/bash -e
# Upload changed files to the running VM and restart affected services.
# Run from the repo root. Requires the SSH key written by Terraform.
# Usage: ./scripts/upload.sh [--restart]

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
TF_DIR="$REPO_ROOT/terraform/test-vm-aws"

KEY="$TF_DIR/.ssh_key.pem"
if [ ! -f "$KEY" ]; then
  echo "ERROR: SSH key not found at $KEY" >&2
  echo "       Run 'terraform apply' in $TF_DIR first." >&2
  exit 1
fi

# Read the public IP from Terraform state (ip/ sub-module)
PUBLIC_IP=$(cd "$TF_DIR/ip" && terraform output -raw public_ip 2>/dev/null)
if [ -z "$PUBLIC_IP" ]; then
  echo "ERROR: Could not read public_ip from Terraform state." >&2
  exit 1
fi

SSH="ssh -i $KEY -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ServerAliveInterval=30 ubuntu@$PUBLIC_IP"
SCP="scp -O -i $KEY -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null"

echo "### Uploading files to $PUBLIC_IP ..."

$SCP "$REPO_ROOT/docker-compose.yml"      ubuntu@"$PUBLIC_IP":/concourse/
$SCP "$REPO_ROOT/docker-versions.sh"      ubuntu@"$PUBLIC_IP":/concourse/
$SCP -r "$REPO_ROOT/scripts/"             ubuntu@"$PUBLIC_IP":/concourse/
$SCP "$REPO_ROOT/nginx/nginx.conf.template" ubuntu@"$PUBLIC_IP":/concourse/nginx/

echo "### Upload complete."

if [[ "$1" == "--restart" ]]; then
  echo "### Restarting Concourse services ..."
  $SSH "cd /concourse && source docker-versions.sh && source .concourse.env && sudo --preserve-env docker compose --env-file /concourse/.concourse.env pull && sudo --preserve-env docker compose --env-file /concourse/.concourse.env up -d"
  echo "### Restart complete."
else
  echo ""
  echo "Tip: run with --restart to also restart Docker Compose services on the VM."
fi

