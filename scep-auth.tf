# we will create 2 auth mounts:
# - the default scep with a static challenge (for initial authentication)
# - and then a cert auth for next authent (more robust)
resource "vault_auth_backend" "scep" {
    namespace   = vault_namespace.scep-example.path
    type        = "scep"
    path        = "scep" 
  }

resource "vault_auth_backend" "cert" {
    namespace   = vault_namespace.scep-example.path
    type        = "cert"
    path        = "cert"  
}
#let's add the roles for the 2 above auth:
resource "vault_cert_auth_backend_role" "cert" {
    namespace      = vault_namespace.scep-example.path
    name           = "cert-role"
    certificate    = vault_pki_secret_backend_root_sign_intermediate.intermediate.certificate
    backend        = vault_auth_backend.cert.path
    allowed_names  = ["scep-example.com", "printer.scep-example.com", "rtr.scep-example.com"]
    token_ttl      = 300
    token_max_ttl  = 600
    token_type     = "batch"
    token_policies = [vault_policy.scep-auth.name]
}

resource "vault_scep_auth_backend_role" "scep" {
    namespace      = vault_namespace.scep-example.path
    backend        = vault_auth_backend.scep.path
    name           = "scep_challenge_role"
    auth_type      = "static-challenge"
    challenge      = "${var.scep_password}"
    token_type     = "batch"
    token_ttl      = 300
    token_max_ttl  = 600
    token_policies = [vault_policy.scep-auth.name]
}