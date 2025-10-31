# Quick Demo of the Vault SCEP Integration

## Introduction

This repo is made of a folder (scep-data) and some terraform files, and a dockerfile.
The terraform files will be processed by `terraform init`, then `terraform plan` and finally `terraform apply -auto-approve` to configure your local VAULT ENTERPRISE server.
I assume you already have a valid license for VAULT ENTERPRISE.

## Prerequisites
Before moving forward you should:
 - fork the current git repo
 - init, unseal your vault enterprise server
    - export your root token
 - `cd`in the directory of the terraform files

## Building the docker scep image
The docker image comes from the sscep (simple scep client) from [certnanny](https://github.com/certnanny/sscep)

Build your Docker image with the following command:
`docker build -t sscep .`

it takes some time...

## Configuring Vault with Terraform

If you have not done it  already: export your `VAULT_TOKEN` and your `VAULT_ADDR` (`VAULT_TOKEN` for the terraform provisionning phase, and `VAULT_ADDR` in case you want to connect to vault to check some config items) :
````
export VAULT_TOKEN=........
export VAULT_ADDR=http://127.0.0.1:8200
````
Yyou also need to configure some variables.   
The most important one is `scep_password`(defaults to `test-scep-challenge`). It is used for the challenge auth in `auth/scep` endpoint.  

When later you issue a cert on your endpoint (either mkrequest or opennssl) don't forget to add the exact same challenge password.  

That's one of the weak points this integration aims at solving.  

Let's now provision the full configuration with the commands:
````
terraform init
terraform plan
terraform apply -auto-approve
````
make sure that the ouptut of the plan is correct before moving the the apply phase :-) 

## Vault <-> SCEP interactions (before playing)
1. Usefull or not, but you can check the scep server (here: vault enterprise) capabilities.  
That's the command `GetCaCaps`.  
It should return something like: 
````
SCEPStandard
SHA-512
Renewal
````
2. The second thing is for the client to get the Vault certificate corresponding to the authority who will sign the the CSRs.  
  - The client issues a `GetCACert`request to Vault.  
  - As Vault exposes the `/v1/pki_int/scep` endpoint, when he gets the request he answers to the client with the certificate corresponding to the current issuer.
  - note: either a single certificate or the full chain can be sent (in case of an intermediate CA).
  - important: `GetCACert`is a readonly operation. No need to authenticate at this point.  
3. Next the client checks / validates the certificates:
 - If a preinstalled certificate (in our demo example below it is the file `intermediate.cert.pem`) is present, it is compared against the certificate received (see step 2 above)
 - It a certificate is not preinstalled, it is a Trust On First Use: the client must trust the certificate he received from the initial request.

 **We do recommend the usage of a configuration management solution to properly configure scep endpoints with the expected certificate of the CA expected to sign the csr**


## Time to play

the scep protocol has multiple options, but in a traditionnal workflow the first thing you should do is make sure the CA you have the certificate (intermediate.cert.pm) is indeed the one you're talking to. 
That's what you do with the following command:
````
docker run -it --rm \
  --network host \
  -v "$PWD/scep-data:/data" \
  sscep \
  getca \
  -v -u http://host.docker.internal:8200/v1/pki_int/scep -c /data/ca.pem
  ````
the `-v` means verbose, the `-u` means to which host you want to talk, and the `-c` tells the client to write validated certifiate data in this directory
(note that the directory is mapped to /data in the container)
If your CA Chain is made of a root and an intermediate you should end up with 2 files in the `scep-data` directory: `ca.pem-0` and `ca.pem-1``
Now that this is done, you should generate a certificate, and then ask scep to enroll it.
To do this, multiple ways: either `openssl` or `mkrequest` from certnanny (I'm using this one). Here is the command:
 
`mkrequest -dns "scep-example.com" test-scep-challenge`
(the `test-scep-challenge` is configured in the scep auth method in the terraform files.)

the output of the above command is 2 files: the key and the csr. You are going to ask vault to sign the csr via an `enroll` command:
````
scep-data docker run -it --rm \
  --network host \
  -v "$PWD/scep-data:/data" \
  sscep \
  enroll \
  -d -v -u http://host.docker.internal:8200/v1/pki_int/scep -c /data/ca.pem -k /data/local.key -r /data/local.csr -l /data/local.crt
  ````
(run this command from the root diretory, not the scep-data directory)
the new options are:
`-k` : where your key is
`-r`: location of the csr
`-l`: where to write the certificate.
And indeed, when you run this command, your signed certificate is written to  the `scep-data` directory, as `local.crt`

