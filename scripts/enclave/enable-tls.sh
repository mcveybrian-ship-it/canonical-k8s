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

# -untrusted is REQUIRED for a fullchain file: without it openssl reads only the first
# certificate and cannot find the intermediate, so a perfectly good chain reports as
# unverifiable. That is what happened here, on a machine that did trust the root.
if openssl verify -CAfile /etc/ssl/certs/ca-certificates.crt \
     -untrusted "$CHAIN" "$CHAIN" >/dev/null 2>&1; then
  ok "verifies against this machine's trust store"
else
  say "  note: does not verify locally - is the enclave root installed? (ca.sh trust)"
fi

# /etc/nginx/conf.d/ is included by Ubuntu's stock nginx.conf already. Writing here means
# enable-tls.sh does not depend on the site vhost carrying a custom include - which it did,
# and svc-repo-01 was running a vhost installed before that include existed, so nginx came
# back cleanly on :80 and never listened on :443 at all.
install -d -m 0755 /etc/ssl/enclave
install -m 0644 "$CHAIN" "/etc/ssl/enclave/$NAME.fullchain.crt"
chgrp www-data "$KEY" 2>/dev/null || true
chmod 0640 "$KEY"
ok "installed /etc/ssl/enclave/$NAME.fullchain.crt"

# HTTP/2 is configured differently either side of nginx 1.25.1: the standalone `http2 on;`
# directive was introduced there, and before it the only form is `listen ... ssl http2`.
# Ubuntu 24.04 ships 1.24, where `http2 on;` is not a directive at all and nginx refuses to
# start. Emitting the form this nginx understands is cheaper than pinning a version.
NGINX_VER=$(nginx -v 2>&1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' || echo 0.0.0)
if [ "$(printf '%s\n1.25.1\n' "$NGINX_VER" | sort -V | head -1)" = "1.25.1" ]; then
  H2_LISTEN=""; H2_DIRECTIVE="    http2 on;"
else
  H2_LISTEN=" http2"; H2_DIRECTIVE=""
fi
say "nginx $NGINX_VER - http2 via $( [ -n "$H2_LISTEN" ] && echo 'listen directive' || echo 'http2 on;' )"

{
  echo "# TLS for $NAME. Written by enable-tls.sh on $(date -Is)."
  echo "server {"
  echo "    listen 443 ssl$H2_LISTEN;"
  echo "    listen [::]:443 ssl$H2_LISTEN;"
  [ -n "$H2_DIRECTIVE" ] && echo "$H2_DIRECTIVE"
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
} > "/etc/nginx/conf.d/$NAME-tls.conf"
chmod 0644 "/etc/nginx/conf.d/$NAME-tls.conf"
ok "wrote /etc/nginx/conf.d/$NAME-tls.conf"

nginx -t || die "nginx config is invalid - NOT reloading. The site is still serving on :80."
systemctl reload nginx
ok "nginx reloaded - :80 still serving, :443 now available"

for i in $(seq 1 15); do
  c=$(curl -s -o /dev/null -w '%{http_code}' --max-time 4 "https://$NAME.${ENCLAVE_DOMAIN:-enclave.internal}/" || true)
  case "${c:-000}" in 000|"") sleep 1 ;; *) ok "https responds (HTTP $c)"; break ;; esac
  [ "$i" = 15 ] && say "  https did not answer yet - check: curl -v https://$NAME/"
done
