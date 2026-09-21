#!/usr/bin/env bash
# =========================================================================================
# enable-tls.sh - serve an existing nginx site over TLS with an enclave certificate.
#
#     MACHINE: the machine that runs the service.
#
#     sudo ./enable-tls.sh <name> <fullchain.crt> [--root <docroot>] [--proxy <url>]
#     sudo ./enable-tls.sh --redirect-http [--crl <dir>]
#                                          serve NOTHING on :80 except an optional CRL,
#                                          301 everything else to https
#     sudo ./enable-tls.sh --restore-http      put the :80 sites back
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

# Helpers first. They used to sit BELOW the argument loop, which calls die() - and below the
# :80 mode dispatch added later, which calls all of them. A shell only knows a function after
# it has read the definition, so `--redirect-http` would have died with "say: command not
# found" and a bad argument would have done the same instead of printing the usage. Neither
# bash -n nor shellcheck catches this: both are happy with a call to a name defined later.
say()  { printf '  %s\n' "$*"; }
ok()   { printf '  [ok] %s\n' "$*"; }
warn() { printf '  [!]  %s\n' "$*"; }
die()  { printf '\n  [x] %s\n\n' "$*" >&2; exit 1; }


NAME=""; CHAIN=""; DOCROOT=""; PROXY=""
REDIR_CONF=/etc/nginx/conf.d/00-http-redirect.conf
DISABLED_DIR=/etc/nginx/sites-disabled-http

# ---- :80 modes -----------------------------------------------------------------------
# A redirect-only listener rather than no listener at all. It serves no content, so nothing
# crosses the wire in the clear - but anything still pointed at http keeps working and says
# so in the redirect log, instead of failing with connection-refused on a machine inside the
# gap that then cannot fetch a package until someone walks to it. apt follows 301s.
#
# The existing :80 server blocks are MOVED, not deleted, and --restore-http puts them back.
redirect_http() {
  [ "$(id -u)" -eq 0 ] || die "run with sudo"
  # --crl <dir> keeps /crl/ served over PLAIN HTTP instead of being redirected. That is not a
  # loophole, it is the standard design: fetching a CRL over HTTPS from the same CA is
  # circular - the client would need the CRL to validate the certificate it is using to fetch
  # the CRL. A 301 on /crl/ turns revocation checking into a loop that times out.
  local crldir=""
  case "${1:-}" in
    --crl) crldir="${2:?--crl needs a directory}"; shift 2 ;;
    --crl=*) crldir="${1#--crl=}"; shift ;;
  esac
  [ -z "$crldir" ] || [ -d "$crldir" ] || die "no such directory: $crldir"
  install -d -m 0755 "$DISABLED_DIR"
  local moved=0 f
  for f in /etc/nginx/sites-enabled/*; do
    [ -e "$f" ] || continue
    # Only sites that actually listen on 80. A site serving 443 only must stay put.
    if grep -qE '^\s*listen\s+(\[::\]:)?80(\s|;)' "$(readlink -f "$f")" 2>/dev/null; then
      mv "$f" "$DISABLED_DIR/$(basename "$f")"
      say "moved aside: $(basename "$f")"
      moved=$((moved + 1))
    fi
  done
  [ "$moved" -gt 0 ] || say "no :80 sites were enabled"

  cat > "$REDIR_CONF" <<'NGINX'
# Written by enable-tls.sh --redirect-http. Serves no content: every request on :80 gets a
# 301 to the same URL over https. Removing the listener entirely was the alternative; a
# redirect was chosen so that a machine still pointed at http is carried rather than broken.
server {
    listen 80 default_server;
    listen [::]:80 default_server;
    server_name _;
    access_log /var/log/nginx/http-redirect.access.log;
NGINX
  if [ -n "$crldir" ]; then
    cat >> "$REDIR_CONF" <<NGINX

    # Served in the clear on purpose - see enable-tls.sh --crl. A CRL is public data, signed
    # by the CA, and useless to tamper with: a modified one fails its signature check.
    location ^~ /crl/ {
        alias ${crldir%/}/;
        autoindex off;
        default_type application/pkix-crl;
    }
NGINX
  fi
  cat >> "$REDIR_CONF" <<'NGINX'

    location / {
        return 301 https://$host$request_uri;
    }
}
NGINX
  chmod 0644 "$REDIR_CONF"
  [ -n "$crldir" ] && ok "/crl/ exempt from the redirect, served from $crldir"
  ok "wrote $REDIR_CONF"
  nginx -t || die "nginx config is invalid - NOT reloading. Undo with: $0 --restore-http"
  systemctl reload nginx
  # RETRY: `nginx -s reload` IS ASYNCHRONOUS. A worker still running the old config can answer
  # the first request after a successful reload, so a single curl here reports a failure that
  # never happened - it said "expected 301 on :80, got 200" on svc-obs-01 while the redirect
  # was in fact working, and three curls a second later all returned 301.
  # A check that races the thing it is checking is a check that gets ignored.
  local c i
  for i in 1 2 3 4 5; do
    c=$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "http://localhost/" || true)
    [ "$c" = "301" ] && break
    sleep 1
  done
  [ "$c" = "301" ] && ok "http://localhost/ -> 301" \
                   || warn "expected 301 on :80, got '$c' after 5 tries - look at $REDIR_CONF"
  for i in 1 2 3 4 5; do
    c=$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "https://localhost/" -k || true)
    case "$c" in 2*|3*|4*) break ;; esac
    sleep 1
  done
  case "$c" in 2*|3*|4*) ok "https still serving (HTTP $c)" ;; *) warn "https returned '$c'" ;; esac
  exit 0
}

restore_http() {
  [ "$(id -u)" -eq 0 ] || die "run with sudo"
  rm -f "$REDIR_CONF"
  local f n=0
  for f in "$DISABLED_DIR"/*; do
    [ -e "$f" ] || continue
    mv "$f" "/etc/nginx/sites-enabled/$(basename "$f")"; n=$((n + 1))
  done
  ok "restored $n site(s), removed the redirect"
  nginx -t && systemctl reload nginx && ok "nginx reloaded"
  exit 0
}

case "${1:-}" in
  --redirect-http) shift; redirect_http "$@" ;;
  --restore-http)  restore_http ;;
esac

while [ $# -gt 0 ]; do
  case "$1" in
    --root)  DOCROOT="$2"; shift 2 ;;
    --proxy) PROXY="$2";  shift 2 ;;
    -h|--help) sed -n '2,18p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) if [ -z "$NAME" ]; then NAME="$1"; elif [ -z "$CHAIN" ]; then CHAIN="$1"; fi; shift ;;
  esac
done


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
# Re-running this script with the chain it already installed is a NORMAL thing to do -
# it is how you re-emit the nginx block after the script itself changes. `install` refuses
# when source and destination are the same file, which killed the run under `set -e` after
# every check had passed and before anything was written. A script that cannot be handed its
# own output is not idempotent.
if [ "$(readlink -f "$CHAIN")" = "$(readlink -f "/etc/ssl/enclave/$NAME.fullchain.crt")" ]; then
  say "chain is already at /etc/ssl/enclave/$NAME.fullchain.crt - leaving it"
else
  install -m 0644 "$CHAIN" "/etc/ssl/enclave/$NAME.fullchain.crt"
fi
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
  echo "    server_name $NAME ${NAME}.${ENCLAVE_DOMAIN:-enclave.internal} _;"
  echo ""
  echo "    ssl_certificate     /etc/ssl/enclave/$NAME.fullchain.crt;"
  echo "    ssl_certificate_key $KEY;"
  echo ""
  echo "    # TLS 1.2 is the floor. 1.3 only would be cleaner, but apt, containerd and the"
  echo "    # pro client all have to work here and a handshake failure inside an air gap is"
  echo "    # expensive to diagnose. Revisit at step 05 with the STIG in hand."
  echo "    ssl_protocols       TLSv1.2 TLSv1.3;"
  echo "    ssl_prefer_server_ciphers off;"
  # SV-206412: "minimize the identity of the web server ... in warning and error messages".
  # nginx advertises "Server: nginx/1.24.0 (Ubuntu)" until told not to, and the stock
  # nginx.conf ships the directive COMMENTED OUT. Set it here, in generated config, rather
  # than by editing a packaged file that an upgrade will replace.
  echo "    server_tokens off;"
  echo "    ssl_session_cache   shared:SSL:10m;"
  # SV-206414: "an absolute session timeout value of eight hours or less". The generator wrote
  # 1d, which fails by three hours. A parameter, because a site may want it tighter - and the
  # traffic here is machine-to-machine and short-lived, so shortening costs a few handshakes.
  echo "    ssl_session_timeout ${TLS_SESSION_TIMEOUT:-8h};"
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
    # SV-206411 is NOT "turn autoindex off" - DISA's fix text is "Place a default web page in
    # every web document directory". A listing tells an unauthenticated caller the exact
    # inventory of a mirror; a default page tells them nothing. apt never needs a listing, it
    # requests explicit paths from the Release file. Humans lose browsing, which is the trade
    # the rule intends. index.html files are written below.
    echo "    autoindex off;"
    echo "    index index.html;"
    # A DEFAULT PAGE FOR EVERY DIRECTORY, in one directive, and it is not optional politeness:
    # with listings off and no index, nginx answers a directory URL with 403 - and
    # `pro enable fips-updates` VERIFIES REPOSITORY ACCESS BY FETCHING ".../pool/", a directory.
    # Measured 2026-09-21 on a freshly rebuilt host-3: "403 Forbidden ... Could not enable FIPS
    # Updates". apt was unaffected - it requests explicit paths from the Release file - so the
    # regression passed every check made the night before. SV-206411 asks for a default page in
    # every document directory; this gives one to ALL of them, including directories a later
    # mirror sync creates, which scattered index.html files would miss.
    DIRPAGE="'<!doctype html><title>Enclave repository</title><h1>Enclave repository</h1><p>Machine-readable content. Directory listing is disabled; paths are documented in the enclave runbook.</p>'"
    echo "    location ~ /\$ {"
    echo "        try_files \$uri/index.html @dirdefault;"
    echo "    }"
    echo "    location @dirdefault {"
    echo "        default_type text/html;"
    echo "        return 200 $DIRPAGE;"
    echo "    }"
    echo "    location ~* \\.(deb|udeb|tar\\.(gz|xz|zst)|ddeb)\$ {"
    echo "        default_type application/vnd.debian.binary-package;"
    echo "    }"
    echo "    location ^~ /keys/ { alias ${DOCROOT%/mirror}/keys/; autoindex off; }"
    echo "    location ^~ /debs/ { alias ${DOCROOT%/mirror}/debs/; autoindex off;"
    echo "                         default_type application/vnd.debian.binary-package; }"
    # Snaps over TLS too. Omitting this from the 443 block while keeping it on 80 is exactly
    # the kind of asymmetry that survives until :80 is closed and then breaks the cluster
    # build with a 404 nobody expects.
    echo "    location ^~ /snaps/ { alias ${DOCROOT%/mirror}/snaps/; autoindex off;"
    echo "                          default_type application/octet-stream; }"
    # STIG tooling over TLS, for the same reason as /snaps/ - and this one was learned the
    # hard way twenty lines below the warning. /tools/ was added to the :80 vhost on
    # 2026-09-11 and omitted here, so every fetch got a 404 from a server that looked
    # correctly configured because the grep found the location in the OTHER file.
    # ⚠️ /tools/ KEEPS ITS LISTING, and it is the one exception on this server.
    # `stig-tools.sh fetch` mirrors the 390-file Evaluate-STIG tree with `wget -r`, which
    # DISCOVERS FILES BY FOLLOWING LINKS IN THE AUTOINDEX. With listings off there are no links,
    # so the fetch fails outright - measured on the host-3 rebuild 2026-09-21, hardening dead at
    # step 13. This is a scoped deviation from SV-206411 on ONE path, not a decision to allow
    # listings: the path is reachable only from inside the enclave, behind ufw, and serves a
    # public DISA download. **The real fix is to stop walking HTTP** - publish the tree as one
    # checksummed tarball and fetch that (backlog 6a.25), after which this line goes back to off.
    echo "    location ^~ /tools/ { alias ${DOCROOT%/mirror}/tools/; autoindex on;"
    echo "                          autoindex_exact_size off;"
    echo "                          default_type application/octet-stream; }"
    echo "    location / { try_files \$uri \$uri/ =404; }"
  fi
  echo "}"
} > "/etc/nginx/conf.d/$NAME-tls.conf"
chmod 0644 "/etc/nginx/conf.d/$NAME-tls.conf"

# SV-206411's fix text, performed: a default page in every document directory this server
# publishes. Written only where one is absent, so a site that wrote its own keeps it. The page
# says what the directory is FOR and nothing about what is in it or what serves it.
if [ -z "$PROXY" ] && [ -n "${DOCROOT:-}" ]; then
  for d in "$DOCROOT" "${DOCROOT%/mirror}/keys" "${DOCROOT%/mirror}/debs" \
           "${DOCROOT%/mirror}/snaps" "${DOCROOT%/mirror}/tools"; do
    [ -d "$d" ] || continue
    [ -e "$d/index.html" ] && continue
    printf '<!doctype html><title>Enclave repository</title>\n<h1>Enclave repository</h1>\n<p>Machine-readable content. Paths are documented in the enclave runbook; directory listing is disabled.</p>\n' > "$d/index.html"
    chmod 0644 "$d/index.html"
    say "wrote default page $d/index.html (SV-206411)"
  done
fi
ok "wrote /etc/nginx/conf.d/$NAME-tls.conf"

nginx -t || die "nginx config is invalid - NOT reloading. The site is still serving on :80."
systemctl reload nginx
ok "nginx reloaded - :80 still serving, :443 now available"

for i in $(seq 1 15); do
  c=$(curl -s -o /dev/null -w '%{http_code}' --max-time 4 "https://$NAME.${ENCLAVE_DOMAIN:-enclave.internal}/" || true)
  case "${c:-000}" in 000|"") sleep 1 ;; *) ok "https responds (HTTP $c)"; break ;; esac
  [ "$i" = 15 ] && say "  https did not answer yet - check: curl -v https://$NAME/"
done
