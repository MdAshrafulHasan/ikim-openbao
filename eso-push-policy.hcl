path "kv-apps/data/*" {
  capabilities = ["create", "update", "read"]
}
path "kv-apps/metadata/*" {
  capabilities = ["read", "list"]
}
