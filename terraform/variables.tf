variable "linode_token" {
    description = "API token for Linode"
    type        = string
}

variable "root_pass" {
    description = "Root password for the Linode instance"
    type        = string
}

variable "ssh_key" {
    description = "SSH public key for accessing the Linode instance"
    type        = string
}

variable "home_ip" {
  description = "Your home IP for SSH firewall allowlist"
}

variable "private_key_path" {
    description = "Path to the private SSH key for accessing the Linode instance"
    type        = string
}

variable "k3s_token" {
    description = "K3S cluster token for agent nodes to join the server"
    type        = string
}

variable "argocd_url" {
  type = string
}

variable "argocd_ip" {
  type = string
}

variable "argocd_password" {
  type = string
}

