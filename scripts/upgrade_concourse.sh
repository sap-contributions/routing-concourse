#!/bin/bash -e
# Upgrade Concourse to a new version on the running VM.
# Run from the repo root. Requires the SSH key written by Terraform.
# Usage: ./scripts/upgrade_concourse.sh <new_version>
# Example: ./scripts/upgrade_concourse.sh 8.1.0
#
# What this script does:
#   1. Updates concourse_version in docker-versions.sh locally.
#   2. Uploads docker-compose.yml, docker-versions.sh, scripts/ and nginx config to the VM.
#   3. Gracefully retires the worker (SIGUSR2) and waits for it to exit.
#   4. Pulls new Concourse images on the VM.
#   5. Ensures cgroups v2 is active (required by the containerd runtime); reboots if not.
#   6. Recreates web and worker containers with the new image.
#      db and nginx are left running — db is NOT restarted to avoid disrupting in-flight migrations.
#   7. Waits for the web API to become healthy (includes DB schema migration time).
#   8. Updates the fly CLI.
#   9. Prunes old images.
#
# NOTE: Keys are intentionally NOT regenerated during upgrade.
#       Regenerating keys would invalidate all existing worker registrations and
#       browser sessions. The same keys work across Concourse versions.

NEW_VERSION="${1:?Usage: $0 <new_version>  e.g. $0 8.1.0}"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
TF_DIR="$REPO_ROOT/terraform/test-vm-aws"
VERSIONS_FILE="$REPO_ROOT/docker-versions.sh"

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

# ── 1. Update docker-versions.sh locally ─────────────────────────────────────

CURRENT_VERSION=$(grep '^export concourse_version=' "$VERSIONS_FILE" | cut -d'"' -f2)
if [ "$CURRENT_VERSION" = "$NEW_VERSION" ]; then
  echo "Concourse is already at version $NEW_VERSION in docker-versions.sh."
  echo "Continuing anyway to ensure the VM is in sync..."
fi

NEW_MAJOR=$(echo "$NEW_VERSION" | cut -d. -f1)
CUR_MAJOR=$(echo "$CURRENT_VERSION" | cut -d. -f1)
if [ "$NEW_MAJOR" -gt "$CUR_MAJOR" ]; then
  echo "### NOTICE: Major version bump $CURRENT_VERSION → $NEW_VERSION"
  echo "    Concourse will run DB schema migrations automatically on first startup."
  echo "    Pipeline history and build logs will be preserved."
  echo "    Make sure you have a recent DB backup before continuing."
  echo ""
fi

echo "### Updating concourse_version: $CURRENT_VERSION → $NEW_VERSION in docker-versions.sh ..."
sed -i.bak "s/^export concourse_version=.*/export concourse_version=\"$NEW_VERSION\"/" "$VERSIONS_FILE"
rm -f "$VERSIONS_FILE.bak"

# ── 2. Upload all changed files to the VM ────────────────────────────────────
# Upload compose file, versions, scripts and nginx config so the VM is fully in sync.

echo "### Uploading files to $PUBLIC_IP ..."
$SCP "$REPO_ROOT/docker-compose.yml"          ubuntu@"$PUBLIC_IP":/concourse/
$SCP "$REPO_ROOT/docker-versions.sh"          ubuntu@"$PUBLIC_IP":/concourse/
$SCP -r "$REPO_ROOT/scripts/"                 ubuntu@"$PUBLIC_IP":/concourse/
$SCP "$REPO_ROOT/nginx/nginx.conf.template"   ubuntu@"$PUBLIC_IP":/concourse/nginx/

# ── 3. Gracefully stop the worker ────────────────────────────────────────────
# SIGUSR2 tells the Concourse worker to retire gracefully:
# it stops accepting new work and waits for running builds to finish.
# The container will exit on its own once drained.

echo "### Gracefully retiring Concourse worker (SIGUSR2) ..."
$SSH "cd /concourse && source docker-versions.sh && sudo --preserve-env docker compose kill -s SIGUSR2 worker" || true

echo -n "### Waiting for worker to finish in-flight builds ..."
TIMEOUT=300
ELAPSED=0
while true; do
  # Worker is gone when it no longer appears as 'running' (state = exited / not present)
  STATUS=$($SSH "cd /concourse && source docker-versions.sh && sudo --preserve-env docker compose ps --status running worker 2>/dev/null | tail -n +2 | wc -l" 2>/dev/null || echo "0")
  [ "$STATUS" = "0" ] && break
  echo -n '.'
  sleep 5
  ELAPSED=$((ELAPSED + 5))
  if [ $ELAPSED -ge $TIMEOUT ]; then
    echo ""
    echo "WARNING: Worker did not stop within ${TIMEOUT}s — forcing stop."
    $SSH "cd /concourse && source docker-versions.sh && sudo --preserve-env docker compose stop worker"
    break
  fi
done
echo ""

# ── 4. Pull new images ────────────────────────────────────────────────────────

echo "### Pulling Concourse $NEW_VERSION images ..."
$SSH "cd /concourse && source docker-versions.sh && sudo --preserve-env docker compose --env-file /concourse/.concourse.env pull web worker"

# ── 5. Ensure cgroups v2 is active (required by containerd runtime) ──────────
# Concourse worker uses containerd which requires the unified (v2) cgroup hierarchy.
# If the VM is still on v1 (no /sys/fs/cgroup/cgroup.controllers), switch and reboot.

echo "### Checking cgroup version on VM ..."
CGROUP_V2=$($SSH "[ -f /sys/fs/cgroup/cgroup.controllers ] && echo yes || echo no" 2>/dev/null || echo "no")
if [ "$CGROUP_V2" = "no" ]; then
  echo "### cgroups v1 detected — switching to v2 and rebooting ..."
  $SSH "sudo /concourse/scripts/switch_cgroup_v2.sh" || true
  echo -n "### Waiting for VM to reboot ..."
  sleep 20
  until $SSH "echo ready" 2>/dev/null; do
    echo -n '.'
    sleep 5
  done
  echo ""
  echo "### VM is back online with cgroups v2."
else
  echo "### cgroups v2 already active. No reboot needed."
fi

# ── 6. Restart web and worker with the new image ─────────────────────────────
# db and nginx are intentionally left running.
# web must start first so it can run DB migrations; worker connects after web is ready.

echo "### Restarting web with Concourse $NEW_VERSION (DB migrations will run now) ..."
$SSH "cd /concourse && source docker-versions.sh && sudo --preserve-env docker compose --env-file /concourse/.concourse.env up -d --no-deps web"

# ── 7. Wait for Concourse web to be healthy (incl. DB migration time) ─────────

echo -n "### Waiting for Concourse to become healthy (includes DB migration) ..."
TIMEOUT=600
ELAPSED=0
while ! $SSH "curl -fso /dev/null http://localhost/api/v1/info" 2>/dev/null; do
  echo -n '.'
  sleep 5
  ELAPSED=$((ELAPSED + 5))
  if [ $ELAPSED -ge $TIMEOUT ]; then
    echo ""
    echo "ERROR: Concourse did not become healthy within ${TIMEOUT}s." >&2
    echo "       Check logs with:" >&2
    echo "       ssh -i $KEY ubuntu@$PUBLIC_IP 'cd /concourse && sudo docker compose logs --tail=80 web'" >&2
    exit 1
  fi
done
echo ""

echo "### Starting worker with Concourse $NEW_VERSION ..."
$SSH "cd /concourse && source docker-versions.sh && sudo --preserve-env docker compose --env-file /concourse/.concourse.env up -d --no-deps worker"

# ── 8. Update fly CLI ────────────────────────────────────────────────────────

echo "### Updating fly CLI to $NEW_VERSION ..."
$SSH "sudo curl -fso /usr/local/bin/fly 'http://localhost/api/v1/cli?arch=amd64&platform=linux' && sudo chmod +x /usr/local/bin/fly"

# ── 9. Clean up old images ───────────────────────────────────────────────────

echo "### Pruning old Docker images ..."
$SSH "sudo docker image prune -f"

echo ""
echo "### Upgrade complete: Concourse $CURRENT_VERSION → $NEW_VERSION"
echo "    URL: http://$PUBLIC_IP"

