#1. Create the secret engine
resource "vault_mount" "pki_root" {
  namespace = vault_namespace.scep-example.path
  path        = "pki-root"
  type        = "pki"
  description = "ROOT PKI mount"

  #default_lease_ttl_seconds = 86400
}

#2.Create a self-signed root
resource "vault_pki_secret_backend_root_cert" "root" {
    namespace = vault_namespace.scep-example.path
    backend = vault_mount.pki_root.path
    type = "internal"
    common_name = "scep-example.com"
    issuer_name = "root-issuer"
    ttl = "87600h"
}
## Display the value of the self-signed root in the output
output "vault_pki_secret_backend_root_cert_root" {
  value = vault_pki_secret_backend_root_cert.root.certificate
}
##We're printing the cert in a file as it needs to be copied in the scep endpoint directory later
resource "local_file" "root_cert" {
  content  = vault_pki_secret_backend_root_cert.root.certificate
  filename = "root_ca.crt"
}
# used to update name and properties
# manages lifecycle of existing issuer
resource "vault_pki_secret_backend_issuer" "root" {
  namespace                      = vault_namespace.scep-example.path  
  backend                        = vault_mount.pki_root.path
  issuer_ref                     = vault_pki_secret_backend_root_cert.root.issuer_id
  issuer_name                    = vault_pki_secret_backend_root_cert.root.issuer_name
  revocation_signature_algorithm = "SHA256WithRSA"
}


# configuration of allow_any_name=true
# we'll change this setting later to show the power of vault integration

resource "vault_pki_secret_backend_role" "root_role" {
  namespace        = vault_namespace.scep-example.path  
  backend          = vault_mount.pki_root.path
  name             = "scep-clients-role"
  allow_ip_sans    = true
  key_type         = "rsa"
  key_bits         = 4096
  allow_subdomains = true
  allow_any_name   = true
}

# crl, ca and oscp urls configuration
resource "vault_pki_secret_backend_config_urls" "root-urls" {
  namespace               = vault_namespace.scep-example.path
  backend                 = vault_mount.pki_root.path
  issuing_certificates    = ["http://localhost:8200/v1/pki-root/ca"]
  crl_distribution_points = ["http://localhost:8200/v1/pki-root/crl"]
  ocsp_servers            = ["http://localhost:8200/va/pki-root/ocsp"  ]
}

## We're done for the root CA config

## Let's start with the intermediate CA now.

resource "vault_mount" "pki_int" {
  namespace = vault_namespace.scep-example.path
  path        = "pki_int"
  type        = "pki"
  description = "This is an example intermediate PKI mount"
  #default_lease_ttl_seconds = 43200
}
#Generate intermediate, save the CSR and sign it.
resource "vault_pki_secret_backend_intermediate_cert_request" "csr-request" {
  namespace   = vault_namespace.scep-example.path  
  backend     = vault_mount.pki_int.path
  type        = "internal"
  common_name = "scep-example.com Intermediate Authority"
}

resource "vault_pki_secret_backend_root_sign_intermediate" "intermediate" {
    namespace   = vault_namespace.scep-example.path 
    backend     = vault_mount.pki_root.path
    common_name = "scep-example.com Intermediate Authority"
    csr         = vault_pki_secret_backend_intermediate_cert_request.csr-request.csr
    format      = "pem_bundle"
    ttl         = "43800h"
    issuer_ref  = vault_pki_secret_backend_issuer.root.issuer_id 
}

resource "vault_pki_secret_backend_intermediate_set_signed" "intermediate" {
    namespace   = vault_namespace.scep-example.path 
    backend     = vault_mount.pki_int.path
    certificate =  vault_pki_secret_backend_root_sign_intermediate.intermediate.certificate
}
# Give a meaning full name to the intermediate issuer
resource "vault_pki_secret_backend_issuer" "intermediate" {
  namespace   = vault_namespace.scep-example.path   
  backend     = vault_mount.pki_int.path
  issuer_ref  = vault_pki_secret_backend_intermediate_set_signed.intermediate.imported_issuers[0]
  issuer_name = "scep-example-dot-com-intermediate"
}

# Let's also save the intermediate cert on a local file, as we will need it in the scep approval workflow
resource "local_file" "intermediate_ca_cert" {
  content  = vault_pki_secret_backend_root_sign_intermediate.intermediate.certificate
  filename = "intermediate.cert.pem"
}
# Let's now add the pki_int role

resource "vault_pki_secret_backend_role" "scep-role" {
  namespace        = vault_namespace.scep-example.path   
  backend          = vault_mount.pki_int.path
  name             = "scep-role"
  max_ttl          = "720h" 
  #allow_ip_sans    = true
  key_type         = "rsa"
  key_bits         = 4096
  allowed_domains  = ["*.scep-example.com"]
  #allow_subdomains = true
}


# Finally we will configure auth delegation in the pki-int engine
# As it depends on the auth backends declared in scep-auth.tf, and to make sure
# everything runs smoothly I add some depends_on cosntructs
resource "vault_pki_secret_backend_config_scep" "scep" {
  depends_on = [ vault_auth_backend.cert, vault_auth_backend.scep ]
  namespace                    = vault_namespace.scep-example.path  
  backend                      = vault_mount.pki_int.path
  enabled                      = true
  default_path_policy          = "sign-verbatim"
  restrict_ca_chain_to_issuer = true
  authenticators {
    scep = {
      accessor  = vault_auth_backend.scep.accessor
      scep_role = vault_scep_auth_backend_role.scep.name
    }
    cert = {
      accessor  = vault_auth_backend.cert.accessor
      cert_role = vault_cert_auth_backend_role.cert.name
  }
}
}