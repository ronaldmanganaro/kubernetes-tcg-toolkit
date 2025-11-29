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
# 4) BOOTSTRAP SERVICE ACCOUNT + RBAC
###############################################

resource "null_resource" "bootstrap_sa" {
  depends_on = [linode_instance.server]

  connection {
    type        = "ssh"
    host        = local.server_public_ip
    user        = "root"
    private_key = file(var.private_key_path)
  }

  provisioner "remote-exec" {
    inline = [
      "kubectl -n kube-system get sa argocd-bootstrap || kubectl create sa argocd-bootstrap -n kube-system",
      "kubectl get clusterrolebinding argocd-bootstrap-admin || kubectl create clusterrolebinding argocd-bootstrap-admin --clusterrole=cluster-admin --serviceaccount=kube-system:argocd-bootstrap",
      "kubectl apply -f - <<'EOF'\napiVersion: v1\nkind: Secret\nmetadata:\n  name: argocd-bootstrap-token\n  namespace: kube-system\n  annotations:\n    kubernetes.io/service-account.name: argocd-bootstrap\ntype: kubernetes.io/service-account-token\nEOF"
    ]
  }
}


###############################################
# 5) FETCH TOKEN + CA + SERVER
###############################################


resource "null_resource" "fetch_sa_creds" {
  depends_on = [null_resource.bootstrap_sa]

  connection {
    type        = "ssh"
    host        = local.server_public_ip
    user        = "root"
    private_key = file(var.private_key_path)
  }

  # 1. Create files on the server
  provisioner "remote-exec" {
    inline = [
      "SECRET=$(kubectl get sa argocd-bootstrap -n kube-system -o jsonpath='{.secrets[0].name}')",
      "TOKEN=$(kubectl create token argocd-bootstrap -n kube-system)",
      "CA=$(kubectl get secret $SECRET -n kube-system -o jsonpath=\"{.data['ca.crt']}\")",
      
      "echo $TOKEN > /tmp/sa-token",
      "echo $CA > /tmp/sa-ca",

        # --- ADD THIS ---
      "sync",
      "sleep 2",
      "ls -l /tmp/sa-token /tmp/sa-ca"
      # ---------------
    ]
  }

  # 2. Download the files from remote → local machine running Terraform
  provisioner "file" {
    source      = "/tmp/sa-token"
    destination = "${path.root}/out/sa-token"
  }

  provisioner "file" {
    source      = "/tmp/sa-ca"
    destination = "${path.root}/out/sa-ca"
  }
}


###############################################
# 6) BUILD KUBECONFIG FROM TEMPLATE
###############################################




data "local_file" "sa_token" {
  depends_on = [null_resource.fetch_sa_creds]
  filename   = "${path.module}/out/sa-token"
}

data "local_file" "sa_ca" {
  depends_on = [null_resource.fetch_sa_creds]
  filename   = "${path.module}/out/sa-ca"
}


locals {
  sa_token  = trimspace(data.local_file.sa_token.content)
  sa_ca     = trimspace(data.local_file.sa_ca.content)
}


resource "local_file" "k3s_kubeconfig" {
  depends_on = [null_resource.fetch_sa_creds]

  filename = "${path.module}/out/k3s-kubeconfig.yaml"

  content = templatefile("${path.module}/kubeconfig.tpl", {
    TOKEN       = local.sa_token
    CA_CERT_B64 = local.sa_ca
    SERVER      = local.server_public_ip
  })
}

###############################################
# 7) SEND KUBECONFIG TO MGMT NODE AND REGISTER
###############################################

resource "null_resource" "send_kubeconfig_to_mgmt" {
  depends_on = [local_file.k3s_kubeconfig]

  connection {
    type        = "ssh"
    host        = var.argocd_ip
    user        = "root"
    private_key = file(var.private_key_path)
  }

  provisioner "file" {
    source      = "${path.module}/out/k3s-kubeconfig.yaml"
    destination = "/tmp/k3s-kubeconfig.yaml"
  }
}



resource "null_resource" "register_k3s_with_argocd" {
  depends_on = [null_resource.send_kubeconfig_to_mgmt]

  connection {
    type        = "ssh"
    host        = var.argocd_ip
    user        = "root"
    private_key = file(var.private_key_path)
  }

  provisioner "remote-exec" {
    inline = [
      "argocd login ${var.argocd_url} --username admin --password ${var.argocd_password} --insecure",
      "argocd cluster rm k3s --yes",
      "argocd cluster add k3s-context --kubeconfig /tmp/k3s-kubeconfig.yaml --name k3s --yes --insecure"
    ]
  }
}
