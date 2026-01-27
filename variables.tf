variable "vault_addr" {
  type    = string
  default = "http://localhost:8200"
}

variable "scep_password" {
    type = string
    default = "test-scep-challenge"
    sensitive = true
}
variable "vault_scep_namespace" {
    type = string
    default = "scep"
}