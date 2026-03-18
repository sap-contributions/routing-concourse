#!/bin/bash -e
# Run with sudo.

domain="$1"
force=$2
rsa_key_size=4096
data_path="/workspace/certbot/conf/live/$domain"
export CONCOURSE_EXTERNAL_DOMAIN=$domain          # For nginx

cd "$(realpath "$(dirname "$0")")/.."

mkdir -p /workspace/worker-state

echo "### Loading docker container versions ..."
source docker-versions.sh

# Concourse worker uses the containerd runtime which requires cgroups v2.
# Check BEFORE starting any services so the worker doesn't fail immediately.
if [ ! -f /sys/fs/cgroup/cgroup.controllers ] ; then
  echo "### REBOOTING for cgroups v2 ###"
  GRUB_FILE=/etc/default/grub
  sed -i -e 's/ systemd\.unified_cgroup_hierarchy=[01]//g' -e 's/ cgroup_no_v1=all//g' "$GRUB_FILE"
  sed -i '/^GRUB_CMDLINE_LINUX\(_DEFAULT\)\?="/ s/"$/ systemd.unified_cgroup_hierarchy=1 cgroup_no_v1=all"/' "$GRUB_FILE"
  update-grub
  grub-mkconfig -o /boot/efi/EFI/ubuntu/grub.cfg || true
  shutdown -r now
fi

# Always generate keys  as there could be some change in updated concourse
echo "### Generating Keys ..."
./scripts/generate_keys.sh

if $force ; then
  echo "### Forcing certicate renewal, wiping all certs ..."
  rm -Rf /workspace/certbot/conf
  docker -l error compose stop certbot nginx   # Need to stop certbot and nginx to see new certs after restart
fi

# Initial obtain from scratch needs dummy certs to start nginx at all
path="/etc/letsencrypt/live/$domain"
if [ ! -f "$data_path/cert.pem" ] ; then
  echo "### Creating dummy certificate for $domain ..."
  mkdir -p "$data_path"
  docker -l error compose run --rm --entrypoint "\
    openssl req -x509 -nodes -newkey rsa:$rsa_key_size -days 1\
      -keyout '$path/privkey.pem' \
      -out '$path/fullchain.pem' \
      -subj '/CN=localhost'" certbot

  echo "### Starting nginx ..."
  docker -l error compose up -d nginx

  echo -n "### Waiting for nginx to start ..."
  while ! curl -fso /dev/null http://localhost/ ; do
    echo -n '.'
    sleep 1
  done

  echo "### Deleting dummy certificate for $domain ..."
  rm "$data_path/privkey.pem" "$data_path/fullchain.pem"
fi

if ! openssl s_client -servername "$domain" -connect 127.0.0.1:443 -brief -verify_return_error </dev/null ; then
  echo
  echo "### Could not verify cert for $domain, obtaining new one ..."
  echo

  echo "### Requesting Let's Encrypt certificate for $domain ..."
  docker -l error compose run --rm --entrypoint "\
    certbot certonly --webroot -w /var/www/certbot \
      -d '${domain}' \
      --rsa-key-size '${rsa_key_size}' \
      --agree-tos \
      -v -n \
      --register-unsafely-without-email" certbot
  echo
fi

docker compose --env-file "/concourse/.concourse.env" up -d

# retry for 30 seconds every second to reach the concourse api info endpoint
# to make sure that concourse is up.
curl -k --retry 30 --retry-delay 1 --max-time 1 --retry-all-errors --fail 'https://localhost/api/v1/info' || { echo "Concourse did not become healthy within 30 seconds."; exit 1; }

# Download and install the fly CLI from local Concourse instance
curl -o /usr/local/bin/fly -k 'https://localhost/api/v1/cli?arch=amd64&platform=linux' && chmod +x /usr/local/bin/fly
