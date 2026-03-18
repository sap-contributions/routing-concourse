locals {
  name      = "concourse-cfn-test"
  public_ip = data.terraform_remote_state.ip.outputs.public_ip
  ssh       = "ssh -i ${local_sensitive_file.ssh_private_key.filename} -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ServerAliveInterval=30 -o ServerAliveCountMax=10 ubuntu@${data.terraform_remote_state.ip.outputs.public_ip}"
  scp       = "scp -O -i ${local_sensitive_file.ssh_private_key.filename} -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ServerAliveInterval=30 -o ServerAliveCountMax=10"
}

# ── IP (reserved separately — see ip/ subdirectory) ──────────────────────────

data "terraform_remote_state" "ip" {
  backend = "local"
  config = {
    path = "${path.module}/ip/terraform.tfstate"
  }
}

# Auto-detect caller's public IP for SSH access restriction
data "http" "my_ip" {
  url = "https://checkip.amazonaws.com"
}

locals {
  ssh_cidr = var.ssh_allowed_cidr != null ? var.ssh_allowed_cidr : "${chomp(data.http.my_ip.response_body)}/32"
}

# ── SSH key pair ──────────────────────────────────────────────────────────────

resource "tls_private_key" "concourse" {
  algorithm = "RSA"
  rsa_bits  = 4096
}

resource "aws_key_pair" "concourse" {
  key_name   = "${local.name}-key"
  public_key = tls_private_key.concourse.public_key_openssh
}

resource "local_sensitive_file" "ssh_private_key" {
  content         = tls_private_key.concourse.private_key_pem
  filename        = "${path.module}/.ssh_key.pem"
  file_permission = "0600"
}

# ── Networking ────────────────────────────────────────────────────────────────

resource "aws_vpc" "concourse" {
  cidr_block           = "10.0.2.0/24"
  enable_dns_hostnames = true

  tags = { Name = "${local.name}-vpc" }
}

resource "aws_internet_gateway" "concourse" {
  vpc_id = aws_vpc.concourse.id

  tags = { Name = "${local.name}-igw" }
}

resource "aws_subnet" "concourse" {
  vpc_id            = aws_vpc.concourse.id
  cidr_block        = "10.0.2.0/24"
  availability_zone = var.availability_zone

  tags = { Name = "${local.name}-subnet" }
}

resource "aws_route_table" "concourse" {
  vpc_id = aws_vpc.concourse.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.concourse.id
  }

  tags = { Name = "${local.name}-rt" }
}

resource "aws_route_table_association" "concourse" {
  subnet_id      = aws_subnet.concourse.id
  route_table_id = aws_route_table.concourse.id
}

# ── Security groups ───────────────────────────────────────────────────────────

resource "aws_security_group" "concourse" {
  name   = "${local.name}-sg"
  vpc_id = aws_vpc.concourse.id

  # SSH — restricted to caller's IP (or var.ssh_allowed_cidr if set)
  ingress {
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = [local.ssh_cidr]
  }

  # HTTP (Concourse web UI + fly)
  ingress {
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  # HTTPS
  ingress {
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  # All outbound (needed for docker pulls, GitHub access)
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "${local.name}-sg" }

  lifecycle {
    # Prevent accidental destroy/recreate from dropping ingress rules
    create_before_destroy = true
  }
}

# ── Storage ───────────────────────────────────────────────────────────────────

resource "aws_ebs_volume" "concourse" {
  availability_zone = var.availability_zone
  size              = var.disk_size
  type              = "gp3"

  tags = { Name = "${local.name}-data" }
}

resource "aws_volume_attachment" "concourse" {
  device_name = "/dev/xvdf"
  volume_id   = aws_ebs_volume.concourse.id
  instance_id = aws_instance.concourse.id
}

# ── Compute ───────────────────────────────────────────────────────────────────

resource "aws_instance" "concourse" {
  ami                         = var.os_ver
  instance_type               = var.vm_size
  key_name                    = aws_key_pair.concourse.key_name
  subnet_id                   = aws_subnet.concourse.id
  vpc_security_group_ids      = [aws_security_group.concourse.id]
  associate_public_ip_address = true

  root_block_device {
    volume_size = 50
    volume_type = "gp3"
  }

  tags = { Name = local.name }
}

resource "aws_eip_association" "concourse" {
  instance_id   = aws_instance.concourse.id
  allocation_id = data.terraform_remote_state.ip.outputs.eip_allocation_id

  depends_on = [aws_instance.concourse]
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
    aws_instance.concourse.id,
    local_sensitive_file.concourse_env.content,
    data.local_file.nginx_conf.id,
    data.local_file.docker_compose.id,
    data.local_file.docker_versions.id,
    sha1(join("", [for f in fileset("../../scripts/", "*") : filesha1("../../scripts/${f}")]))
  ]

  depends_on = [
    local_sensitive_file.concourse_env,
    aws_eip_association.concourse,
    aws_volume_attachment.concourse
  ]

  provisioner "local-exec" {
    command = <<-CMD
      echo "Waiting for SSH on ${local.public_ip}..." ;
      until ${local.ssh} "echo ready" 2>/dev/null ; do
        echo "SSH not ready yet, retrying in 5s..." ;
        sleep 5 ;
      done ;
      ${local.ssh} "\
        sudo mkdir -p /concourse/scripts/ ;\
        sudo mkdir -p /concourse/db/ ;\
        sudo mkdir -p /concourse/nginx/ ;\
        sudo chmod -R a+rwx /concourse/"
    CMD
  }

  provisioner "local-exec" {
    command = "${local.scp} -r ../../scripts/ ubuntu@${local.public_ip}:/concourse"
  }


  provisioner "local-exec" {
    command = "${local.scp} ../../docker-compose.yml ../../docker-versions.sh .concourse.env ubuntu@${local.public_ip}:/concourse"
  }

  provisioner "local-exec" {
    command = "${local.scp} ../../nginx/nginx.conf.template ubuntu@${local.public_ip}:/concourse/nginx"
  }

  provisioner "local-exec" {
    command = <<-CMD
      ${local.ssh} "\
        echo 'Waiting for EBS data volume...' ;\
        until [ -b /dev/xvdf ] || [ -b /dev/nvme1n1 ] ; do sleep 2 ; done ;\
        DATA_DEV=\$([ -b /dev/xvdf ] && echo xvdf || echo nvme1n1) ;\
        echo \"Data volume ready at /dev/\$DATA_DEV\" ;\
        sudo rm -f /tmp/install_done /tmp/install_failed ;\
        sudo touch /tmp/install.log ;\
        sudo bash -c \"nohup /concourse/scripts/install.sh ${var.docker_ver} \$DATA_DEV >>/tmp/install.log 2>&1 && touch /tmp/install_done || touch /tmp/install_failed &\""
    CMD
  }

  provisioner "local-exec" {
    command = <<-CMD
      echo "Waiting for install.sh to complete..." ;
      ${local.ssh} "tail -f /tmp/install.log & TAIL_PID=\$! ; until [ -f /tmp/install_done ] || [ -f /tmp/install_failed ] ; do sleep 2 ; done ; kill \$TAIL_PID 2>/dev/null" ;
      if ${local.ssh} "test -f /tmp/install_failed" 2>/dev/null ; then
        echo "install.sh failed:" ;
        ${local.ssh} "cat /tmp/install.log" ;
        exit 1 ;
      fi ;
      echo "install.sh completed successfully"
    CMD
  }

  # Wait for SSH again in case start.sh triggered a reboot to switch to cgroups v2 (required by containerd runtime)
  provisioner "local-exec" {
    command = <<-CMD
      echo "Waiting for SSH after install..." ;
      sleep 10 ;
      until ${local.ssh} "echo ready" 2>/dev/null ; do
        echo "SSH not ready yet, retrying in 5s..." ;
        sleep 5 ;
      done ;
      ${local.ssh} "sudo rm -f /tmp/start_done /tmp/start_failed /tmp/start_rebooting" ;
      ${local.ssh} "sudo touch /tmp/start.log" ;
      ${local.ssh} "sudo bash -c 'CONCOURSE_EXTERNAL_DOMAIN=${local.public_ip} nohup /concourse/scripts/start.sh ${local.public_ip} >>/tmp/start.log 2>&1 && touch /tmp/start_done || ( [ -f /tmp/start_rebooting ] || touch /tmp/start_failed ) &'" ;
      echo "Waiting for start.sh to complete or reboot..." ;
      ${local.ssh} "tail -f /tmp/start.log & TAIL_PID=\$! ; until [ -f /tmp/start_done ] || [ -f /tmp/start_failed ] || [ -f /tmp/start_rebooting ] ; do sleep 2 ; done ; kill \$TAIL_PID 2>/dev/null" ;
      if ${local.ssh} "test -f /tmp/start_rebooting" 2>/dev/null ; then
        echo "System is rebooting for cgroupsv1, waiting for SSH to come back..." ;
        sleep 30 ;
        until ${local.ssh} "echo ready" 2>/dev/null ; do
          echo "Waiting for reboot to complete..." ;
          sleep 5 ;
        done ;
        echo "System back online, running start.sh again..." ;
        ${local.ssh} "sudo rm -f /tmp/start_done /tmp/start_failed /tmp/start_rebooting" ;
        ${local.ssh} "sudo touch /tmp/start.log" ;
        ${local.ssh} "sudo bash -c 'CONCOURSE_EXTERNAL_DOMAIN=${local.public_ip} nohup /concourse/scripts/start.sh ${local.public_ip} >>/tmp/start.log 2>&1 && touch /tmp/start_done || touch /tmp/start_failed &'" ;
        ${local.ssh} "tail -f /tmp/start.log & TAIL_PID=\$! ; until [ -f /tmp/start_done ] || [ -f /tmp/start_failed ] ; do sleep 2 ; done ; kill \$TAIL_PID 2>/dev/null" ;
      fi ;
      if ${local.ssh} "test -f /tmp/start_failed" 2>/dev/null ; then
        echo "start.sh failed:" ;
        ${local.ssh} "cat /tmp/start.log" ;
        exit 1 ;
      fi ;
      echo "start.sh completed successfully" ;
      ${local.ssh} "sudo ln -nfs /concourse/scripts/prune_workers.sh /etc/cron.weekly/prune_workers"
    CMD
  }
}
