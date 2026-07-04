#!/bin/sh
# Genere des certs auto-signes JETABLES pour tester localement
# le docker-compose ou pour le job CI de validation des configs.
# JAMAIS a utiliser pour un vrai deploiement -- uniquement pour que
# Squid (SSL Bump) et HAProxy acceptent de demarrer/valider leur config.
set -eu

cd "$(dirname "$0")/.."

echo "== Squid SSL Bump (ssl_cert/) =="
mkdir -p etc/squid/ssl_cert
openssl req -x509 -newkey rsa:2048 -keyout /tmp/vyos-deploy-test-key.pem \
  -out /tmp/vyos-deploy-test-cert.pem -days 1 -nodes -subj "/CN=test" 2>/dev/null
cat /tmp/vyos-deploy-test-cert.pem /tmp/vyos-deploy-test-key.pem > etc/squid/ssl_cert/bump.pem
openssl dhparam -out etc/squid/ssl_cert/dhparam.pem 2048 2>/dev/null

echo "== HAProxy (WWW/) =="
mkdir -p etc/haproxy/WWW
for name in WILDCARD APP1 WWW; do
  openssl req -x509 -newkey rsa:2048 -keyout /tmp/vyos-deploy-test-key.pem \
    -out /tmp/vyos-deploy-test-cert.pem -days 1 -nodes -subj "/CN=test" 2>/dev/null
  cat /tmp/vyos-deploy-test-cert.pem /tmp/vyos-deploy-test-key.pem > "etc/haproxy/WWW/${name}.pem"
done

echo "== BIND9 (tsig.key) =="
TSIG_SECRET=$(dd if=/dev/urandom bs=64 count=1 2>/dev/null | base64 -w0)
cat > etc/bind/tsig.key <<TSIG
key "tsig-key" {
	algorithm hmac-sha512;
	secret "${TSIG_SECRET}";
};
TSIG

echo "== Suricata (rules/suricata.rules placeholder) =="
mkdir -p etc/suricata/rules
[ -f etc/suricata/rules/suricata.rules ] || \
  echo "# Placeholder -- genere normalement par suricata-update" > etc/suricata/rules/suricata.rules

rm -f /tmp/vyos-deploy-test-key.pem /tmp/vyos-deploy-test-cert.pem
echo "OK: certs/cles de test generes dans etc/ (jamais a committer, deja dans .gitignore)"
