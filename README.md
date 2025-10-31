# Quick Demo of the Vault SCEP Integration

## Introduction


The goal is to provide a simple implementation of scep in Vault and to show with a linux scep client how it works.

This repo is made of a folder (scep-data) and some terraform files, and a dockerfile.

Note: this configuration is NOT designed for production.

## Prerequisites
Before moving forward you should:
 - fork the current git repo
 - init, unseal your vault enterprise server
    - export your root token
 - `cd`in the directory of the terraform files
 - create a `scep-data`repo in this current dir

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

4. The client creates and sends a csr
- with `openssl` a command like the following will be enough:
`openssl req -new -newkey rsa:2048 -keyout client.key -out client.csr`. 
**Please note answering the questions that you MUST provide a challenge password that matches the one configured in the terraform variables**
- or you can also use the `mkrequest`command from certnanny (see above). In this case, you will get as outputs the files `local.csr`, `local.key`

- to send the csr to the scep server the 'general' scep command used is:
`./sscep enroll -u http://vault:8201/v1/pki_int/scep -c ca.crt -k local.key -r local.csr -l local.crt`
  - -c: where to find the CA certificate
  - -k: what is the local key used to sign
  - -r: where to find the csr
  - -l: where to write the signed certificate

At that point, the *delegated authentication mechanism* in vault takes place.
The workflow is the following:
 - the scep client sends its CSR (encrypted with the intermediate CA pub key)
 - this CSR contains the `challengePassword``
 - the `/pki_int/scep`endpoint receives the request
 - vault decrypts the CSR, and because it is configured, it sends an auth request to the `auth/scep` auth backend. The *challengePassword* is included in the request
 - vault can then validate the auth request, and if everything is ok, its sends back a token with policies attached. In our example, the policy is *scep-auth-policy* and allows to `read, create, update` the `pki_int/scep` endpoint.
 - additionnally the token comes with a TTL and max_TTL: that's another guarantee that if not used quickly, the token will not be usefull.
 - then, if everything is ok (ie if the token allows for the cert signature, ...) the vault scep engine validates the request.
 - then it passes the csr to the pki_int mount, which signs it with what is specified in its associated role (in our case the role is pretty generic and allows for all signatures)
 - at the end, the scep server sends back the certificate to the client.


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

