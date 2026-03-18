locals {
  vm_name   = "concourse-cfn-test"
  public_ip = data.terraform_remote_state.ip.outputs.public_ip
}

# ── IP (reserved separately — see ip/ subdirectory) ──────────────────────────

data "terraform_remote_state" "ip" {
  backend = "local"
  config = {
    path = "${path.module}/ip/terraform.tfstate"
  }
}

# ── Networking ────────────────────────────────────────────────────────────────

resource "google_compute_network" "vpc_network" {
  name                    = "concourse-cfn-test-vpc"
  auto_create_subnetworks = false
}

resource "google_compute_subnetwork" "default" {
  name          = "concourse-cfn-test"
  ip_cidr_range = "10.0.2.0/24"
  region        = var.region
  network       = google_compute_network.vpc_network.id
}


# ── Firewall ──────────────────────────────────────────────────────────────────

resource "google_compute_firewall" "ssh" {
  name    = "concourse-cfn-test-allow-ssh"
  network = google_compute_network.vpc_network.id

  allow {
    protocol = "tcp"
    ports    = ["22"]
  }

  direction     = "INGRESS"
  priority      = 1000
  source_ranges = ["0.0.0.0/0"]
  target_tags   = [local.vm_name]
}

resource "google_compute_firewall" "http" {
  name    = "concourse-cfn-test-allow-http"
  network = google_compute_network.vpc_network.id

  allow {
    protocol = "tcp"
    ports    = ["80"]
  }


  direction     = "INGRESS"
  priority      = 1000
  source_ranges = ["0.0.0.0/0"]
  target_tags   = [local.vm_name]
}

# ── Storage ───────────────────────────────────────────────────────────────────

resource "google_compute_disk" "concourse_volume" {
  name = "concourse-cfn-test-data"
  type = var.disk_type
  size = var.disk_size
  zone = var.zone
}

# ── Compute ───────────────────────────────────────────────────────────────────

resource "google_compute_instance" "concourse" {
  name                      = local.vm_name
  machine_type              = var.vm_size
  zone                      = var.zone
  allow_stopping_for_update = true
  tags                      = [local.vm_name]

  lifecycle {
    ignore_changes = [metadata]
  }

  boot_disk {
    initialize_params {
      image = var.os_ver
      size  = 50
    }
  }

  attached_disk {
    source      = google_compute_disk.concourse_volume.id
    device_name = "sdb" # Must match var.data_disk so mount.sh finds /dev/sdb
  }

  network_interface {
    subnetwork = google_compute_subnetwork.default.id

    access_config {
      nat_ip = local.public_ip
    }
  }
}

# ── Config files ──────────────────────────────────────────────────────────────

data "local_file" "nginx_conf" {
  filename = "${path.module}/../../nginx/nginx.conf.template"
}

data "local_file" "docker_compose" {
  filename = "${path.module}/../../docker-compose.yml"
}

data "local_file" "docker_versions" {
  filename = "${path.module}/../../docker-versions.sh"
}

# ── Provisioning ──────────────────────────────────────────────────────────────

resource "terraform_data" "provision_concourse" {
  triggers_replace = [
    google_compute_instance.concourse.id,
    local_sensitive_file.concourse_env.content,
    data.local_file.nginx_conf.id,
    data.local_file.docker_compose.id,
    data.local_file.docker_versions.id,
    sha1(join("", [for f in fileset("../../scripts/", "*") : filesha1("../../scripts/${f}")]))
  ]

  provisioner "local-exec" {
    command = <<-CMD
      sleep 30 ;
      gcloud compute ssh ${local.vm_name} --zone ${var.zone} --command "\
        sudo mkdir -p /concourse/scripts/ ;\
        sudo mkdir -p /concourse/db/ ;\
        sudo mkdir -p /concourse/nginx/ ;\
        sudo chmod -R a+rwx /concourse/" --verbosity=error
    CMD
  }

  provisioner "local-exec" {
    command = <<-CMD
      gcloud compute scp --recurse ../../scripts/ ${local.vm_name}:/concourse \
        --zone ${var.zone} --verbosity=error
    CMD
  }

  depends_on = [local_sensitive_file.concourse_env]

  provisioner "local-exec" {
    command = <<-CMD
      gcloud compute scp ../../docker-compose.yml ../../docker-versions.sh .concourse.env ${local.vm_name}:/concourse \
        --zone ${var.zone} --verbosity=error
    CMD
  }

  provisioner "local-exec" {
    command = <<-CMD
      gcloud compute scp ../../nginx/nginx.conf.template ${local.vm_name}:/concourse/nginx \
        --zone ${var.zone} --verbosity=error
    CMD
  }

  provisioner "local-exec" {
    command = <<-CMD
      gcloud compute ssh ${local.vm_name} --zone ${var.zone} --command "\
        sudo /concourse/scripts/install.sh ${var.docker_ver} ${var.data_disk} ;\
        sudo CONCOURSE_EXTERNAL_DOMAIN=${local.public_ip} /concourse/scripts/start.sh ${local.public_ip} ;\
        sudo ln -nfs /concourse/scripts/prune_workers.sh /etc/cron.weekly/prune_workers" --verbosity=error
    CMD
  }
}

resource "terraform_data" "update_postgres_pw" {
  triggers_replace = [
    random_password.postgres.result
  ]

  depends_on = [terraform_data.provision_concourse]
  provisioner "local-exec" {
    command = <<-CMD
      gcloud compute ssh ${local.vm_name} --zone ${var.zone} --command "\
        cd /concourse ; source docker-versions.sh ;\
        [ -f /run/systemd/shutdown/scheduled ] && exit 0 ;\
        sudo -E docker -l error compose exec db psql -U concourse_user -d concourse -c \
        \"ALTER USER concourse_user PASSWORD '${random_password.postgres.result}';\" " --verbosity=error
    CMD
  }
}
