#!/bin/sh
set -eu

# TLS bootstrap for the self-managed PostgreSQL container. ArtifactFlow's
# production boot gate requires DB_SSLMODE=verify-full (CA chain + hostname
# match). This entrypoint keeps a deployment-private CA on the database volume
# and re-issues a short-lived server certificate for DB_SERVER_DOMAIN on every
# boot, so a container rename self-heals after the matching quadlet edit.
#
# The CA private key lives beside the database files on the same volume:
# anyone who can read it already has the data itself, and it never needs to
# leave this container. The CA *certificate* (public key material) is what
# clients pin; extract it after first boot:
#
#   podman exec artifactflow-postgres \
#     cat /var/lib/postgresql/data/certs/root.crt > /etc/artifactflow/db-ca.pem

cert_dir=/var/lib/postgresql/data/certs
domain="${DB_SERVER_DOMAIN:-artifactflow-postgres}"

mkdir -p "${cert_dir}"

if [ ! -s "${cert_dir}/root.crt" ] || [ ! -s "${cert_dir}/root.key" ]; then
  openssl req -new -x509 -days 3650 -nodes \
    -subj "/CN=artifactflow-podman-db-ca" \
    -keyout "${cert_dir}/root.key" \
    -out "${cert_dir}/root.crt"
fi

cat > "${cert_dir}/san.cnf" <<EOF
[v3_req]
subjectAltName = DNS:${domain},DNS:localhost
EOF

openssl req -new -nodes \
  -subj "/CN=${domain}" \
  -keyout "${cert_dir}/server.key" \
  -out "${cert_dir}/server.csr"
openssl x509 -req -days 825 \
  -in "${cert_dir}/server.csr" \
  -CA "${cert_dir}/root.crt" \
  -CAkey "${cert_dir}/root.key" \
  -CAcreateserial \
  -extfile "${cert_dir}/san.cnf" \
  -extensions v3_req \
  -out "${cert_dir}/server.crt"
rm -f "${cert_dir}/server.csr" "${cert_dir}/san.cnf"

chown -R postgres:postgres "${cert_dir}"
chmod 0600 "${cert_dir}/server.key" "${cert_dir}/root.key"
chmod 0644 "${cert_dir}/server.crt" "${cert_dir}/root.crt"

echo "================================================================"
echo "ArtifactFlow database CA certificate (public key material). Save"
echo "it as /etc/artifactflow/db-ca.pem for the app-image units, or run:"
echo "  podman exec artifactflow-postgres cat ${cert_dir}/root.crt"
echo "Server certificate issued for: ${domain}"
echo "================================================================"
cat "${cert_dir}/root.crt"
echo "================================================================"

exec docker-entrypoint.sh "$@" \
  -c ssl=on \
  -c ssl_cert_file="${cert_dir}/server.crt" \
  -c ssl_key_file="${cert_dir}/server.key"
