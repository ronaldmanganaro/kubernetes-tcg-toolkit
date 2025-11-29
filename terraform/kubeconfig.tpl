apiVersion: v1
kind: Config
clusters:
- name: k3s
  cluster:
    certificate-authority-data: ${CA_CERT_B64}
    server: ${SERVER}

users:
- name: argocd-bootstrap
  user:
    token: ${TOKEN}

contexts:
- name: k3s-context
  context:
    cluster: k3s
    user: argocd-bootstrap

current-context: k3s-context
