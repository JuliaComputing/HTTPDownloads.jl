# Generate self-signed certificates for testing

using Dates

using OpenSSL_jll

days_validity = 365*100

openssl = OpenSSL_jll.openssl()

# Required ??
# $opensslcfg 

root_ca_cert_file = "root_ca.crt"
root_ca_key_file = "root_ca.key"
root_ca_serial_file = "root_ca.ser"

server_csr_file = "server.csr"
server_key_file = "server.key"
server_cert_file = "server.pem"

# OpenSSL_jll uses nonexistant default config location
opensslcfg = `-config /usr/lib/ssl/openssl.cnf`

# Generate self signed root CA cert + key
run(`$openssl req $opensslcfg
    -nodes
    -days $days_validity
    -x509
    -newkey rsa:2048
    -keyout $root_ca_key_file
    -out $root_ca_cert_file
    -subj "/OU=HttpDownloadsTest/CN=HttpDownloadsCA"
`)

# Generate server private key + cert to be signed
run(`$openssl req $opensslcfg
    -nodes
    -newkey rsa:2048
    -keyout $server_key_file
    -out $server_csr_file
    -subj "/OU=HttpDownloadsTest/CN=localhost"
`)

# Sign the server cert
run(`$openssl x509
    -req -in $server_csr_file
    -days $days_validity
    -CA $root_ca_cert_file
    -CAkey $root_ca_key_file
    -CAcreateserial
    -CAserial $root_ca_serial_file
    -out $server_cert_file
`)

# For the purposes of testing, we only need:
# - server: server cert + private key
# - client: root CA cert
#
# We can remove the other files as we won't be signing any more certificates
# with this CA.
rm(root_ca_key_file)
rm(root_ca_serial_file)
rm(server_csr_file)

