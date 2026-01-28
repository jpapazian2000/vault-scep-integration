# Vault SCEP Integration Demo

A Terraform-based demonstration of HashiCorp Vault Enterprise as a SCEP (Simple Certificate Enrollment Protocol) server.

> **Note**: This is a proof-of-concept/demo - not designed for production use without further hardening.

## Table of Contents

- [Overview](#overview)
- [Architecture](#architecture)
- [Prerequisites](#prerequisites)
- [Quick Start](#quick-start)
- [SCEP Workflow Explained](#scep-workflow-explained)
- [Demo Walkthrough](#demo-walkthrough)
- [Certificate Renewal](#certificate-renewal)
- [Troubleshooting](#troubleshooting)
- [References](#references)

## Overview

### What is SCEP?

SCEP (Simple Certificate Enrollment Protocol) allows devices to automatically request and receive certificates from a Certificate Authority. Common use cases include:
- Mobile Device Management (MDM) solutions like **Jamf** and **Intune**
- Network equipment (routers, printers)
- IoT devices

### What This Demo Provides

- Two-tier PKI hierarchy (Root CA + Intermediate CA)
- SCEP endpoint with delegated authentication
- Static challenge authentication for initial enrollment
- Certificate-based authentication for renewals
- Dockerized SCEP client for testing

## Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                    Vault Enterprise                         │
│  ┌─────────────────────────────────────────────────────┐    │
│  │                 Namespace: scep                     │    │
│  │                                                     │    │
│  │  ┌──────────────┐      ┌──────────────────────┐     │    │
│  │  │   pki-root   │      │       pki_int        │     │    │
│  │  │  (Root CA)   │─────▶│  (Intermediate CA)   │     │    │
│  │  │   10 years   │signs │      3 years         │     │    │
│  │  └──────────────┘      └──────────┬───────────┘     │    │
│  │                                   │                 │    │ 
│  │                        ┌──────────▼───────────┐     │    │
│  │                        │    SCEP Endpoint     │     │    │
│  │                        │  /pki_int/scep       │     │    │
│  │                        └──────────┬───────────┘     │    │
│  │                                   │                 │    │
│  │  ┌──────────────┐      ┌──────────▼───────────┐     │    │
│  │  │  auth/scep   │      │     auth/cert        │     │    │
│  │  │  (challenge) │      │  (renewal via cert)  │     │    │
│  │  └──────────────┘      └──────────────────────┘     │    │
│  └─────────────────────────────────────────────────────┘    │
└─────────────────────────────────────────────────────────────┘
                              │
                              │ SCEP Protocol
                              ▼
                    ┌─────────────────────┐
                    │    SCEP Client      │
                    │  (sscep in Docker)  │
                    └─────────────────────┘
```

### PKI Hierarchy & TTLs

| Level            | Mount     | TTL               | Purpose                          |
|------------------|-----------|-------------------|----------------------------------|
| Root CA          | `pki-root`| 10 years          | Offline root, signs intermediate |
| Intermediate CA  | `pki_int` | 3 years           | Signs end-entity certificates    |
| End-entity certs | via SCEP  | 30 days (default) | Device/client certificates       |

> **Important**: Each level must have a shorter TTL than its parent. The `max_lease_ttl_seconds` must be set on PKI mounts **before** generating certificates.

### Authentication Methods

SCEP uses **delegated authentication** - clients don't authenticate directly to Vault, but through the PKI mount's SCEP endpoint:

| Method           | Auth Mount  | Use Case                                 |
|------------------|-------------|------------------------------------------|
| Static Challenge | `auth/scep` | Initial enrollment with shared password  |
| Certificate Auth | `auth/cert` | Renewal using existing valid certificate |

## Prerequisites

- HashiCorp Vault Enterprise (SCEP is an Enterprise feature)
- Terraform >= 1.0
- Docker
- OpenSSL
- A running Vault instance at `http://localhost:8200`

## Quick Start

### 1. Setup Environment

```bash
# Clone the repo
git clone <repo-url>
cd tf_code

# Export Vault credentials
export VAULT_TOKEN="your-root-token"
export VAULT_ADDR="http://127.0.0.1:8200"

# Create working directory for certificates
mkdir -p scep-data
```

### 2. Build the SCEP Client

The Docker image uses [sscep](https://github.com/certnanny/sscep) (Simple SCEP Client) from certnanny.

```bash
docker build -t sscep .
```

### 3. Deploy Vault Configuration

```bash
terraform init
terraform plan
terraform apply -auto-approve
```

### 4. Configure Variables

Key variables in `variables.tf`:

| Variable               | Default                 | Description                            |
|------------------------|-------------------------|----------------------------------------|
| `vault_addr`           | `http://localhost:8200` | Vault server address                   |
| `scep_password`        | `test-scep-challenge`   | Challenge password for SCEP enrollment |
| `vault_scep_namespace` | `scep`                  | Vault namespace                        |

> **Important**: The `scep_password` must match the challenge password used when generating the CSR.

## SCEP Workflow Explained

### Delegated Authentication Flow

```
┌────────────┐                              ┌─────────────────┐
│SCEP Client │                              │  Vault Server   │
└─────┬──────┘                              └────────┬────────┘
      │                                              │
      │  1. GetCACaps (no auth)                      │
      │─────────────────────────────────────────────▶│
      │◀─────────────────────────────────────────────│
      │     SCEPStandard, SHA-512, Renewal           │
      │                                              │
      │  2. GetCACert (no auth)                      │
      │─────────────────────────────────────────────▶│
      │◀─────────────────────────────────────────────│
      │     Intermediate CA certificate              │
      │                                              │
      │  3. PKIOperation - Enroll                    │
      │     (CSR encrypted with CA pubkey)           │
      │     (Contains challengePassword)             │
      │─────────────────────────────────────────────▶│
      │                                              │
      │                    ┌─────────────────────────┤
      │                    │ 4. Decrypt CSR          │
      │                    │ 5. Extract challenge    │
      │                    │ 6. Auth to auth/scep    │
      │                    │ 7. Get token + policy   │
      │                    │ 8. Sign CSR with        │
      │                    │    intermediate CA      │
      │                    └────────────────────────▶┤
      │                                              │
      │◀─────────────────────────────────────────────│
      │     Signed certificate                       │
      │                                              │
```

### Key Points

1. **GetCACaps** and **GetCACert** are read-only operations - no authentication required
2. The CSR is encrypted with the intermediate CA's public key (confidentiality)
3. The request is signed by a self-signed client certificate (integrity)
4. Vault extracts the challenge password and validates it against `auth/scep`
5. A short-lived batch token is issued with the `scep-auth-policy`
6. The intermediate CA signs the CSR and returns the certificate

## Demo Walkthrough

### Step 1: Verify SCEP Endpoint

Check that Vault's SCEP endpoint is responding:

```bash
curl -s "http://127.0.0.1:8200/v1/scep/pki_int/scep?operation=GetCACaps"
```

Expected output:
```
SCEPStandard
SHA-512
Renewal
```

### Step 2: Get CA Certificate

Retrieve and validate the CA certificate:

```bash
docker run -it --rm \
  --network host \
  -v "$PWD/scep-data:/data" \
  sscep \
  getca \
  -v -u http://host.docker.internal:8200/v1/scep/pki_int/scep \
  -c /data/ca.pem
```

This downloads the intermediate CA certificate (and root if chain is returned).

Verify the certificate:
```bash
openssl x509 -in scep-data/ca.pem -noout -text
```

### Step 3: Generate Key Pair and CSR

Generate a private key and CSR using OpenSSL:

```bash
# Generate private key
openssl genrsa -out scep-data/local.key 2048

# Generate CSR with challenge password
openssl req -new \
  -key scep-data/local.key \
  -out scep-data/local.csr \
  -subj "/CN=app.scep-example.com" \
  -addext "subjectAltName=DNS:app.scep-example.com" \
  -addext "challengePassword=test-scep-challenge"
```

> **Important**: The `challengePassword` must match the `scep_password` variable configured in Terraform (default: `test-scep-challenge`).

### Step 4: Enroll (Request Certificate)

```bash
docker run -it --rm \
  --network host \
  -v "$PWD/scep-data:/data" \
  sscep \
  enroll \
  -v -d \
  -u http://host.docker.internal:8200/v1/scep/pki_int/scep \
  -c /data/ca.pem \
  -k /data/local.key \
  -r /data/local.csr \
  -l /data/local.crt
```

Options:
- `-v`: Verbose output
- `-d`: Debug output
- `-c`: CA certificate file
- `-k`: Client private key
- `-r`: Certificate signing request
- `-l`: Output file for signed certificate

### Step 5: Verify the Certificate

```bash
# View certificate details
openssl x509 -text -noout -in scep-data/local.crt

# Verify the signature chain
cat intermediate.cert.pem root_ca.crt > chain.pem
openssl verify -CAfile chain.pem scep-data/local.crt
```

You should see:
```
Issuer: CN = scep-example.com Intermediate Authority
```

## Certificate Renewal

SCEP supports renewal using an existing valid certificate for authentication instead of the challenge password.

### Why No Challenge Password for Renewal?

During **initial enrollment**, the client has no certificate yet, so it must prove its identity using the shared challenge password. Vault validates this against the `auth/scep` backend.

During **renewal**, the client already possesses a valid certificate that was issued by this CA. The SCEP client uses this existing certificate to **sign the renewal request** (via the `-O` and `-K` flags). Vault verifies this signature and authenticates the request via the `auth/cert` backend instead.

This is more secure because:
- No shared secret needs to be transmitted
- Only clients with valid, CA-issued certificates can renew
- The certificate proves the client was previously authorized

### Renewal Steps

```bash
# 1. Save current cert and key
mkdir -p scep-data/initial
cp scep-data/local.crt scep-data/initial/
cp scep-data/local.key scep-data/initial/

# 2. Generate NEW key and CSR for the renewed certificate
openssl genrsa -out scep-data/local.key 2048
openssl req -new \
  -key scep-data/local.key \
  -out scep-data/local.csr \
  -subj "/CN=app.scep-example.com" \
  -addext "subjectAltName=DNS:app.scep-example.com"
# Note: No challengePassword needed - we authenticate with the existing cert

# 3. Renew using existing certificate for authentication
docker run -it --rm \
  --network host \
  -v "$PWD/scep-data:/data" \
  sscep \
  enroll \
  -v -d \
  -u http://host.docker.internal:8200/v1/scep/pki_int/scep \
  -c /data/ca.pem \
  -k /data/local.key \
  -r /data/local.csr \
  -O /data/initial/local.crt \
  -K /data/initial/local.key \
  -l /data/local-renewed.crt
```

Options specific to renewal:
- `-O`: Path to the **existing** certificate (used for authentication)
- `-K`: Path to the **existing** private key (used to sign the request)

> **Important**: The existing certificate (`-O`) must still be valid (not expired) for renewal to work.

## Troubleshooting

### Error: "no enveloped recipient for provided certificate"

**Cause**: The `ca.pem` file doesn't match the current intermediate CA certificate (stale/wrong serial number).

**Fix**:
```bash
rm scep-data/ca.pem
docker run --rm --network host -v "$PWD/scep-data:/data" sscep \
  getca -u http://host.docker.internal:8200/v1/scep/pki_int/scep -c /data/ca.pem
```

### Error: "TTL would result in notAfter beyond CA expiration"

**Cause**: The intermediate CA has a short TTL, and the requested certificate would outlive it.

**Root Cause**: Missing `max_lease_ttl_seconds` on PKI mounts when generating certificates.

**Fix**: Add TTL settings to mounts in Terraform:
```hcl
resource "vault_mount" "pki_int" {
  max_lease_ttl_seconds     = 94608000   # 3 years
  default_lease_ttl_seconds = 2592000    # 30 days
  ...
}
```

Then destroy and recreate:
```bash
terraform destroy -auto-approve
terraform apply -auto-approve
# Don't forget to re-fetch ca.pem!
```

### Multiple/Orphan Issuers Accumulating

**Cause**: Repeated `terraform taint` without cleaning up old issuers.

**Fix**: Full destroy and recreate:
```bash
terraform destroy -auto-approve
terraform apply -auto-approve
```

### Debugging SCEP Responses

SCEP error details are embedded in the PKCS#7 response. To decode:

```bash
# Save the PKCS#7 response to a file, then:
openssl asn1parse -in response.pem

# Or extract text directly:
cat response.pem | base64 -d | strings | grep -i "failed\|error"
```

### Verification Commands

```bash
# Check intermediate CA expiration
curl -s "http://localhost:8200/v1/scep/pki_int/scep?operation=GetCACert" | \
  openssl x509 -inform DER -noout -dates

# Check SCEP capabilities
curl -s "http://localhost:8200/v1/scep/pki_int/scep?operation=GetCACaps"

# Count issuers (should be 2: intermediate + imported root)
VAULT_ADDR=http://127.0.0.1:8200 vault list -namespace=scep pki_int/issuers

# Compare ca.pem serial with GetCACert serial (must match!)
openssl x509 -in scep-data/ca.pem -noout -serial
curl -s "http://localhost:8200/v1/scep/pki_int/scep?operation=GetCACert" | \
  openssl x509 -inform DER -noout -serial
```

## Project Structure

```
tf_code/
├── README.md             # This file
├── providers.tf          # Vault provider configuration
├── variables.tf          # Input variables
├── namespace.tf          # Creates the 'scep' namespace
├── cert.tf               # PKI mounts, Root CA, Intermediate CA, SCEP config
├── policies.tf           # Vault policies for SCEP operations
├── scep-auth.tf          # SCEP and Cert auth backends
├── dockerfile            # SCEP client (sscep) container
└── scep-data/            # Working directory for certificates
    ├── local.key         # Client private key
    ├── local.csr         # Certificate signing request
    ├── ca.pem            # Intermediate CA certificate
    └── local.crt         # Issued certificate
```

## References

- [HashiCorp Vault PKI Secrets Engine](https://developer.hashicorp.com/vault/docs/secrets/pki)
- [Vault SCEP Documentation](https://developer.hashicorp.com/vault/docs/secrets/pki/scep)
- [sscep - Simple SCEP Client](https://github.com/certnanny/sscep)
- [SCEP RFC 8894](https://datatracker.ietf.org/doc/html/rfc8894)

## License

This demo project is provided as-is for educational purposes.
