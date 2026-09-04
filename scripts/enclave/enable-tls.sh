#!/usr/bin/env bash
# =========================================================================================
# enable-tls.sh - serve an existing nginx site over TLS with an enclave certificate.
#
#     MACHINE: the machine that runs the service.
#
#     sudo ./enable-tls.sh <name> <fullchain.crt> [--root <docroot>] [--proxy <url>]
#
#     sudo ./enable-tls.sh svc-repo-01 /tmp/svc-repo-01.fullchain.crt --root /srv/repo/mirror
#     sudo ./enable-tls.sh svc-mgmt-01 /tmp/svc-mgmt-01.fullchain.crt --proxy http://127.0.0.1:8484
#
# The private key is expected at /etc/ssl/enclave/<name>.key - where `ca.sh request` put it,
# on this machine, having never travelled.
#
# HTTP IS LEFT RUNNING. Switching a service to HTTPS-only in one step breaks every client
# between the server changing and each client being reconfigured. Migrate, then remove :80.
# =========================================================================================
set -euo pipefail

NAME=""; CHAIN=""; DOCROOT=""; PROXY=""
while [ $# -gt 0 ]; do
  case "$1" in
    --root)  DOCROOT="$2"; shift 2 ;;
    --proxy) PROXY="$2";  shift 2 ;;
    -h|--help) sed -n '2,18p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) if [ -z "$NAME" ]; then NAME="$1"; elif [ -z "$CHAIN" ]; then CHAIN="$1"; fi; shift ;;
  esac
done

say()  { printf '  %s\n' "$*"; }
ok()   { printf '  [ok] %s\n' "$*"; }
die()  { printf '\n  [x] %s\n\n' "$*" >&2; exit 1; }

[ "$(id -u)" -eq 0 ] || die "run with sudo"
[ -n "$NAME" ] && [ -r "$CHAIN" ] || die "usage: sudo $0 <name> <fullchain.crt> [--root DIR | --proxy URL]"
[ -n "$DOCROOT" ] || [ -n "$PROXY" ] || die "give either --root <docroot> or --proxy <url>"
command -v nginx >/dev/null || die "nginx is not installed"

KEY="/etc/ssl/enclave/$NAME.key"
[ -r "$KEY" ] || die "no private key at $KEY.
       It should have been generated HERE by:  sudo ./ca.sh request $NAME"

# A certificate that does not match the key is the classic TLS failure and it surfaces as an
# opaque handshake error, usually on a client, usually at the worst time.
a=$(openssl x509 -in "$CHAIN" -noout -pubkey | openssl sha256 | awk '{print $2}')
b=$(openssl rsa -in "$KEY" -pubout 2>/dev/null | openssl sha256 | awk '{print $2}')
[ "$a" = "$b" ] || die "$CHAIN does not match $KEY - wrong certificate for this machine"
ok "certificate matches the local key"

# Two certificates minimum: the leaf and the issuing CA. A client that trusts only the ROOT
# cannot build a chain without the intermediate, and the failure looks like an untrusted
# certificate rather than an incomplete one.
n=$(grep -c 'BEGIN CERTIFICATE' "$CHAIN")
[ "$n" -ge 2 ] || die "$CHAIN contains $n certificate(s) - expected the FULLCHAIN (leaf + issuing)"
ok "fullchain has $n certificates"

openssl verify -CAfile /etc/ssl/certs/ca-certificates.crt "$CHAIN" >/dev/null 2>&1 \
  && ok "verifies against this machine's trust store" \
  || say "  note: does not verify locally yet - is the enclave root installed? (ca.sh trust)"

install -d -m 0755 /etc/ssl/enclave /etc/nginx/enclave-tls
install -m 0644 "$CHAIN" "/etc/ssl/enclave/$NAME.fullchain.crt"
chgrp www-data "$KEY" 2>/dev/null || true
chmod 0640 "$KEY"
ok "installed /etc/ssl/enclave/$NAME.fullchain.crt"

{
  echo "# TLS for $NAME. Written by enable-tls.sh on $(date -Is)."
  echo "server {"
  echo "    listen 443 ssl;"
  echo "    listen [::]:443 ssl;"
  echo "    http2 on;"
  echo "    server_name $NAME ${NAME}.\${ENCLAVE_DOMAIN:-enclave.internal} _;"
  echo ""
  echo "    ssl_certificate     /etc/ssl/enclave/$NAME.fullchain.crt;"
  echo "    ssl_certificate_key $KEY;"
  echo ""
  echo "    # TLS 1.2 is the floor. 1.3 only would be cleaner, but apt, containerd and the"
  echo "    # pro client all have to work here and a handshake failure inside an air gap is"
  echo "    # expensive to diagnose. Revisit at step 05 with the STIG in hand."
  echo "    ssl_protocols       TLSv1.2 TLSv1.3;"
  echo "    ssl_prefer_server_ciphers off;"
  echo "    ssl_session_cache   shared:SSL:10m;"
  echo "    ssl_session_timeout 1d;"
  echo "    ssl_session_tickets off;"
  echo ""
  echo "    access_log /var/log/nginx/$NAME-tls.access.log;"
  echo "    error_log  /var/log/nginx/$NAME-tls.error.log;"
  echo ""
  if [ -n "$PROXY" ]; then
    echo "    location / {"
    echo "        proxy_pass $PROXY;"
    echo "        proxy_set_header Host \$host;"
    echo "        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;"
    echo "        proxy_set_header X-Forwarded-Proto https;"
    echo "    }"
  else
    echo "    root $DOCROOT;"
    echo "    autoindex on;"
    echo "    autoindex_exact_size off;"
    echo "    location ~* \\.(deb|udeb|tar\\.(gz|xz|zst)|ddeb)\$ {"
    echo "        default_type application/vnd.debian.binary-package;"
    echo "    }"
    echo "    location ^~ /keys/ { alias ${DOCROOT%/mirror}/keys/; autoindex on; }"
    echo "    location ^~ /debs/ { alias ${DOCROOT%/mirror}/debs/; autoindex on;"
    echo "                         default_type application/vnd.debian.binary-package; }"
    echo "    location / { try_files \$uri \$uri/ =404; }"
  fi
  echo "}"
} > "/etc/nginx/enclave-tls/$NAME.conf"
chmod 0644 "/etc/nginx/enclave-tls/$NAME.conf"
ok "wrote /etc/nginx/enclave-tls/$NAME.conf"

nginx -t || die "nginx config is invalid - NOT reloading. The site is still serving on :80."
systemctl reload nginx
ok "nginx reloaded - :80 still serving, :443 now available"

for i in $(seq 1 15); do
  c=$(curl -s -o /dev/null -w '%{http_code}' --max-time 4 "https://$NAME.${ENCLAVE_DOMAIN:-enclave.internal}/" || true)
  case "${c:-000}" in 000|"") sleep 1 ;; *) ok "https responds (HTTP $c)"; break ;; esac
  [ "$i" = 15 ] && say "  https did not answer yet - check: curl -v https://$NAME/"
done
