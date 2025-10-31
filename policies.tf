resource "vault_policy" "engine-policy" {
  namespace = vault_namespace.scep-example.path
  name = "engine-policy"

  policy = <<EOT
# Enable secrets engine
path "sys/mounts/*" {
  capabilities = [ "create", "read", "update", "delete", "list" ]
}

# List enabled secrets engine
path "sys/mounts" {
  capabilities = [ "read", "list" ]
}

# Work with pki secrets engine
path "pki*" {
  capabilities = [ "create", "read", "update", "delete", "list", "sudo" ]
}
EOT
}

# This next policy is for the scep auth mechanism
resource "vault_policy" "scep-auth" {
    namespace = vault_namespace.scep-example.path
    name      = "scep-auth-policy"
    policy = <<EOT
path "pki_int/scep" {
  capabilities=["read", "update", "create"]
}
path "pki_int/roles/scep-clients/scep" {
  capabilities=["read", "update", "create"]
}
path "pki_int/scep/pkiclient.exe" {
  capabilities=["read", "update", "create"]
}
path "pki_int/roles/scep-clients/scep/pkiclient.exe" {
  capabilities=["read", "update", "create"]
}
EOT
}