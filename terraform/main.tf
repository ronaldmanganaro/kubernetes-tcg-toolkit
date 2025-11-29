terraform {
  required_providers {
    linode = {
      source  = "linode/linode"
      version = "~> 2.0"
    }
  }
}

provider "linode" {
  token = var.linode_token
}

###############################################
# 1) FIREWALL
###############################################

resource "linode_firewall" "dev_fw" {
  label           = "dev-firewall"
  inbound_policy  = "DROP"
  outbound_policy = "ACCEPT"

  inbound {
    label    = "ssh"
    action   = "ACCEPT"
    protocol = "TCP"
    ports    = "22"
    ipv4     = ["0.0.0.0/0"]
  }

  inbound {
    label    = "k3s"
    action   = "ACCEPT"
    protocol = "TCP"
    ports    = "6443, 6444"
    ipv4     = ["0.0.0.0/0"]
  }

  inbound {
    label    = "k3s-udp"
    action   = "ACCEPT"
    protocol = "UDP"
    ports    = "6443, 6444"
    ipv4     = ["0.0.0.0/0"]
  }

  inbound {
    label    = "http-https"
    action   = "ACCEPT"
    protocol = "TCP"
    ports    = "80,443"
    ipv4     = ["0.0.0.0/0"]
  }

  inbound {
    label    = "nodeport"
    action   = "ACCEPT"
    protocol = "TCP"
    ports    = "30000-32767"
    ipv4     = ["0.0.0.0/0"]
  }

  inbound {
    label    = "internal"
    action   = "ACCEPT"
    protocol = "TCP"
    ports    = "1-65535"
    ipv4     = ["0.0.0.0/0"]
  }

  inbound {
    label    = "internal-udp"
    action   = "ACCEPT"
    protocol = "UDP"
    ports    = "1-65535"
    ipv4     = ["0.0.0.0/0"]
  }
}

###############################################
# 2) K3S SERVER
###############################################

resource "linode_instance" "server" {
  label           = "k3s-server-test"
  region          = "us-southeast"
  type            = "g6-nanode-1"
  image           = "linode/ubuntu24.04"
  private_ip      = true
  firewall_id     = linode_firewall.dev_fw.id
  root_pass       = var.root_pass
  authorized_keys = [var.ssh_key]

  metadata {
    user_data = base64encode(
      templatefile("${path.module}/cloud-init-server.yaml", {
        K3S_TOKEN     = tostring(var.k3s_token)
        K3S_NODE_NAME = "k3s-server-test"
      })
    )
  }

  tags = ["dev"]
}

locals {
  server_ips_sorted = sort(linode_instance.server.ipv4)
  server_public_ip  = local.server_ips_sorted[0]
  server_private_ip = local.server_ips_sorted[1]
}

output "server_ip" {
  value = local.server_public_ip
}

###############################################
# 3) WORKER NODES
###############################################

resource "linode_instance" "worker" {
  depends_on = [linode_instance.server]
  count      = 3
  label      = "k3s-worker-${count.index}"
  region     = "us-southeast"
  type       = "g6-nanode-1"
  image      = "linode/ubuntu24.04"
  private_ip = true
  firewall_id = linode_firewall.dev_fw.id
  root_pass   = var.root_pass
  authorized_keys = [var.ssh_key]

  metadata {
    user_data = base64encode(
      templatefile("${path.module}/cloud-init-agent.yaml", {
        SERVER_IP     = local.server_private_ip
        K3S_TOKEN     = tostring(var.k3s_token)
        K3S_NODE_NAME = "k3s-worker-${count.index}"
      })
    )
  }

  tags = ["dev"]
}

output "worker_ips" {
  value = [for w in linode_instance.worker : sort(w.ipv4)[0]]
}

###############################################
# 5) FETCH TOKEN + CA + SERVER
###############################################

resource "null_resource" "fetch_kubeconfig" {
  depends_on = [linode_instance.server]
  
  connection {
    type        = "ssh"
    host        = local.server_public_ip
    user        = "root"
    private_key = file(var.private_key_path)
  }

  # 2. Download the files from remote → local machine running Terraform
  provisioner "file" {
    source      = "/etc/rancher/k3s/k3s.yaml"
    destination = "${path.root}/out/k3s-yaml"
  }
}
