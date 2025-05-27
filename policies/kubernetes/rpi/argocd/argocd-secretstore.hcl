path "secret/data/cloudflare/tunnel/argocd" {
  capabilities = ["read"]
}

path "secret/cloudflared/access/argocd-oidc/client-secret" {
  capabilities = ["read"]
}
