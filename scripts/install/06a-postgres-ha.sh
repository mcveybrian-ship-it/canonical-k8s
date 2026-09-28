#!/usr/bin/env bash
# =========================================================================================
# 06a-postgres-ha.sh - PostgreSQL HA on pg-01..03: etcd, then Patroni (backlog B-06a).
#
#     MACHINE: each pg guest (pg-01..03), which must already be hardened and finished
#     (03-compose-vm.sh --harden, then --finish). Runbook 9a is the design; 9a.2a the traps.
#
#     sudo ./06a-postgres-ha.sh etcd <fullchain.crt>   install and start this node's etcd member
#          ./06a-postgres-ha.sh etcd-check             quorum, members, and the TLS it enforces
#
# SLICE 2 - THE DATABASE'S OWN etcd, WITH MUTUAL TLS
#
#   Three members, one per pg guest, static bootstrap from enclave-addresses.env. NOT the
#   Kubernetes cluster's etcd: that coupling is what runbook 9a exists to remove.
#
#   The certificate is made the way every enclave certificate is: the key on THIS node
#   (ca.sh request pg-0N - it never leaves), the CSR signed on svc-mgmt-01 with
#   `ca.sh sign-server --peer` (serverAuth AND clientAuth: every member is a server to its
#   peers and a client to them), the fullchain copied back. This script refuses a chain that
#   does not verify against the enclave root, lacks either purpose, does not name this node's
#   address, or does not match the key made here.
#
# FIPS - READ THIS BEFORE CLAIMING ANYTHING (decided 2026-09-27, backlog B-06a):
#
#   Ubuntu's etcd 3.4.30 is Go 1.22.2 built WITHOUT BoringCrypto (its embedded build info has
#   no GOEXPERIMENT, and it has no _goboringcrypto_ symbols). Its TLS is Go's own crypto, NOT
#   the host's FIPS-validated OpenSSL module. What this script can do - and does - is restrict
#   it to FIPS-APPROVED ALGORITHMS: TLS 1.2+, ECDHE-RSA with AES-GCM only, and GODEBUG turning
#   off the binary's legacy defaults (DefaultGODEBUG carries tls10server=1,tlsrsakex=1 - a
#   TLS 1.0 server and RSA key exchange). Approved algorithms in a non-validated module is an
#   SC-13 finding (POA&M ENG-68), not a pass. Patroni and PostgreSQL use OpenSSL (FIPS).
#   PROVEN OFFLINE 2026-09-27 against the real 3.4.30 binary with a non-FIPS OpenSSL client:
#   TLS 1.2 ECDHE-RSA AES-GCM accepted; RSA key exchange, CBC, ChaCha20, TLS 1.0 and 1.1 and a
#   client with no certificate all REFUSED, on both 2379 and 2380. ONE THING IT CANNOT DO: TLS 1.3
#   ChaCha20-Poly1305 (not approved) stays negotiable - Go never lets TLS 1.3 suites be set, and
#   3.4 predates --tls-max-version. Only an enclave-CA-certified client can connect, and the pg
#   nodes' own clients pick AES-GCM; it is in ENG-68, stated.
#
# TRAP: THE PACKAGE STARTS ITS OWN SINGLE-NODE etcd ON INSTALL (postinst enables and starts
#   etcd.service, name = hostname, data in /var/lib/etcd/default). A static three-member
#   bootstrap on top of that fails on a cluster-ID mismatch. So: install with policy-rc.d
#   blocking the start, and run from our OWN data dir (ETCD_DIR) so the default can never
#   collide - the same shape as postgresql-16 creating a cluster Patroni must not inherit.
# =========================================================================================
set -euo pipefail

SELF="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENC="$(cd "$SELF/../enclave" && pwd)"
ADDRS="$ENC/enclave-addresses.env"

ETCD_PKI="${ETCD_PKI:-/etc/etcd/pki}"
ETCD_DIR="${ETCD_DIR:-/var/lib/etcd/enclave-pg}"
ETCD_ENV="${ETCD_ENV:-/etc/default/etcd}"
ETCD_TOKEN="${ETCD_TOKEN:-enclave-pg-etcd}"
ETCD_WAIT="${ETCD_WAIT:-300}"                 # seconds to wait for quorum after starting
# ECDHE-RSA + AES-GCM only: FIPS-approved key exchange, cipher and MAC for RSA certificates
# (ca.sh issues RSA). No CBC, no ChaCha20 (not approved), no static-RSA key exchange.
ETCD_CIPHERS="${ETCD_CIPHERS:-TLS_ECDHE_RSA_WITH_AES_128_GCM_SHA256,TLS_ECDHE_RSA_WITH_AES_256_GCM_SHA384}"
ETCD_GODEBUG="${ETCD_GODEBUG:-tlsrsakex=0,tls10server=0}"
CA_ROOT="${CA_ROOT:-$ENC/trust-anchors/enclave-root.crt}"
SSL_DIR="${SSL_DIR:-/etc/ssl/enclave}"         # where `ca.sh request` put this node's key

say()  { printf '  %s\n' "$*"; }
ok()   { printf '  [ok] %s\n' "$*"; }
warn() { printf '  [!!] %s\n' "$*" >&2; }
die()  { printf '\n  [x] %s\n\n' "$*" >&2; exit 1; }
need_root() { [ "$(id -u)" -eq 0 ] || die "run with sudo"; }

[ -r "$ADDRS" ] || die "no address file at $ADDRS"
# shellcheck disable=SC1090
. "$ADDRS"

# WHICH pg node this is, from its address - the same rule as 05's guard: never a typed name.
ME=""; ME_ADDR=""
whoami_pg() {
  local k a mine
  mine="$(ip -4 -o addr show scope global 2>/dev/null | awk '{print $4}' | cut -d/ -f1)"
  for k in $(grep -oE '^PG_[0-9]+=' "$ADDRS" | tr -d '='); do
    a="${!k:-}"
    if [ -n "$a" ] && printf '%s\n' "$mine" | grep -qx "$a"; then
      ME="$(printf '%s' "$k" | tr 'A-Z_' 'a-z-')"; ME_ADDR="$a"; return 0
    fi
  done
  die "this machine ($(hostname -s)) holds no PG_* address in $ADDRS - 06a runs on pg-01..03 only"
}

# The member list, from the address file: pg-01=https://10.2.20.165:2380,...
initial_cluster() {
  local k out=""
  for k in $(grep -oE '^PG_[0-9]+=' "$ADDRS" | tr -d '=' | sort); do
    out="${out:+$out,}$(printf '%s' "$k" | tr 'A-Z_' 'a-z-')=https://${!k}:2380"
  done
  printf '%s' "$out"
}
client_endpoints() {
  local k out=""
  for k in $(grep -oE '^PG_[0-9]+=' "$ADDRS" | tr -d '=' | sort); do out="${out:+$out,}https://${!k}:2379"; done
  printf '%s' "$out"
}

# /etc/default/etcd, rendered. A function so it can be tested away from a pg node.
# render_etcd_env NAME ADDR CLUSTER
render_etcd_env() {
  cat <<ENV
# MANAGED by 06a-postgres-ha.sh etcd - the database's own etcd (backlog B-06a). Edits are
# overwritten by the next run; change the script or its parameters instead.
ETCD_NAME="$1"
ETCD_DATA_DIR="$ETCD_DIR"
ETCD_LISTEN_PEER_URLS="https://$2:2380"
ETCD_LISTEN_CLIENT_URLS="https://$2:2379"
ETCD_INITIAL_ADVERTISE_PEER_URLS="https://$2:2380"
ETCD_ADVERTISE_CLIENT_URLS="https://$2:2379"
ETCD_INITIAL_CLUSTER="$3"
ETCD_INITIAL_CLUSTER_STATE="new"
ETCD_INITIAL_CLUSTER_TOKEN="$ETCD_TOKEN"
ETCD_CERT_FILE="$ETCD_PKI/member.crt"
ETCD_KEY_FILE="$ETCD_PKI/member.key"
ETCD_TRUSTED_CA_FILE="$ETCD_PKI/ca.crt"
ETCD_CLIENT_CERT_AUTH="true"
ETCD_PEER_CERT_FILE="$ETCD_PKI/member.crt"
ETCD_PEER_KEY_FILE="$ETCD_PKI/member.key"
ETCD_PEER_TRUSTED_CA_FILE="$ETCD_PKI/ca.crt"
ETCD_PEER_CLIENT_CERT_AUTH="true"
ETCD_CIPHER_SUITES="$ETCD_CIPHERS"
# Go's TLS, not OpenSSL (see the script header): these switch off the binary's legacy
# defaults, TLS 1.0 on the server and RSA key exchange.
GODEBUG="$ETCD_GODEBUG"
ENV
}

# check_member_cert FULLCHAIN KEY ADDR ROOT - every way a wrong certificate has to be refused.
check_member_cert() {
  local fc="$1" key="$2" addr="$3" root="$4" tmp eku san
  tmp="$(mktemp -d)"
  # leaf first, then the issuing CA (sign-server writes them in that order)
  awk -v d="$tmp" '/BEGIN CERT/ {n++} n {print > (d "/c" n ".pem")}' "$fc"
  if [ ! -s "$tmp/c1.pem" ]; then rm -rf "$tmp"; die "$fc holds no certificate"; fi
  if [ -s "$tmp/c2.pem" ]; then
    openssl verify -CAfile "$root" -untrusted "$tmp/c2.pem" "$tmp/c1.pem" >/dev/null 2>&1 \
      || { rm -rf "$tmp"; die "$fc does not verify against the enclave root through its issuing CA"; }
  else
    openssl verify -CAfile "$root" "$tmp/c1.pem" >/dev/null 2>&1 \
      || { rm -rf "$tmp"; die "$fc does not verify against the enclave root (and carries no issuing CA)"; }
  fi
  eku="$(openssl x509 -in "$tmp/c1.pem" -noout -ext extendedKeyUsage 2>/dev/null | tail -n +2)"
  case "$eku" in
    *"Server Authentication"*"Client Authentication"*|*"Client Authentication"*"Server Authentication"*) ;;
    *) rm -rf "$tmp"; die "$fc is not a peer certificate (needs serverAuth AND clientAuth; has:${eku:- none}). Sign with: ca.sh sign-server --peer" ;;
  esac
  san="$(openssl x509 -in "$tmp/c1.pem" -noout -ext subjectAltName 2>/dev/null | tail -n +2)"
  case "$san" in *"IP Address:$addr"*) ;; *) rm -rf "$tmp"; die "$fc does not name this node's address $addr (SAN:$san)" ;; esac
  if [ "$(openssl x509 -in "$tmp/c1.pem" -noout -pubkey | sha256sum)" != "$(openssl pkey -in "$key" -pubout 2>/dev/null | sha256sum)" ]; then
    rm -rf "$tmp"; die "$fc was not made from $key - this node's key. Was the CSR from another node?"
  fi
  rm -rf "$tmp"
  ok "certificate: verifies to the enclave root, serverAuth+clientAuth, names $addr, matches this node's key"
}

cmd_etcd() {
  need_root; whoami_pg
  local fc="${1:-}" name="$ME"
  [ -n "$fc" ] && [ -r "$fc" ] || die "usage: sudo $0 etcd <$name.fullchain.crt from svc-mgmt-01>"
  [ -r "$CA_ROOT" ] || die "no enclave root at $CA_ROOT"
  local key="$SSL_DIR/$name.key"
  [ -r "$key" ] || die "no key at $key - make it on THIS node first: sudo $ENC/ca.sh request $name"

  # ---- the certificate, checked before anything is installed ----
  check_member_cert "$fc" "$key" "$ME_ADDR" "$CA_ROOT"

  # ---- the package, WITHOUT its self-start ----
  if ! dpkg -s etcd-server >/dev/null 2>&1; then
    printf '#!/bin/sh\nexit 101\n' > /usr/sbin/policy-rc.d; chmod 0755 /usr/sbin/policy-rc.d
    DEBIAN_FRONTEND=noninteractive apt-get install -y etcd-server etcd-client \
      || { rm -f /usr/sbin/policy-rc.d; die "apt could not install etcd-server etcd-client"; }
    rm -f /usr/sbin/policy-rc.d
    ok "etcd-server $(dpkg-query -W -f='${Version}' etcd-server) installed, its self-start blocked"
  fi
  systemctl stop etcd >/dev/null 2>&1 || true
  if [ -d /var/lib/etcd/default ]; then
    rm -rf /var/lib/etcd/default && say "removed the package's default single-node data (/var/lib/etcd/default)"
  fi

  # ---- files etcd (the user) can read ----
  install -d -m 0750 -o root -g etcd "$ETCD_PKI"
  install -m 0644 -o root -g root "$CA_ROOT" "$ETCD_PKI/ca.crt"
  install -m 0644 -o root -g root "$fc" "$ETCD_PKI/member.crt"
  install -m 0640 -o root -g etcd "$key" "$ETCD_PKI/member.key"
  install -d -m 0700 -o etcd -g etcd "$ETCD_DIR"
  render_etcd_env "$name" "$ME_ADDR" "$(initial_cluster)" > "$ETCD_ENV.new"
  chown root:etcd "$ETCD_ENV.new"; chmod 0640 "$ETCD_ENV.new"; mv -f "$ETCD_ENV.new" "$ETCD_ENV"
  ok "config: $ETCD_ENV (member $name at $ME_ADDR, cluster $(initial_cluster | tr ',' ' '))"

  # ---- start, and wait for QUORUM rather than for systemd ----
  # --no-block: with Type=notify the first member only reports ready once a quorum exists, so a
  # blocking start on pg-01 would time out waiting for pg-02 and pg-03. Start all three, then wait.
  systemctl enable etcd >/dev/null 2>&1
  systemctl restart --no-block etcd
  say "waiting up to ${ETCD_WAIT}s for a quorum (start this on all three pg nodes)"

  for _ in $(seq 1 "$((ETCD_WAIT / 5))"); do
    if etcd_ctl endpoint health >/dev/null 2>&1; then ok "etcd member $name is healthy - a quorum exists"; etcd_ctl member list -w table; return 0; fi
    sleep 5
  done
  journalctl -u etcd -n 20 --no-pager | sed 's/^/     /'
  die "no quorum after ${ETCD_WAIT}s - are the other pg nodes started? (the log above says what etcd sees)"
}

# etcdctl as this member - its own certificate is also a client certificate (clientAuth).
etcd_ctl() {
  ETCDCTL_API=3 etcdctl --endpoints="https://$ME_ADDR:2379" \
    --cacert "$ETCD_PKI/ca.crt" --cert "$ETCD_PKI/member.crt" --key "$ETCD_PKI/member.key" "$@"
}

cmd_etcd_check() {
  need_root; whoami_pg
  say "the database's etcd, seen from $ME"
  ETCDCTL_API=3 etcdctl --endpoints="$(client_endpoints)" \
    --cacert "$ETCD_PKI/ca.crt" --cert "$ETCD_PKI/member.crt" --key "$ETCD_PKI/member.key" \
    endpoint health -w table || die "not every member is healthy"
  etcd_ctl member list -w table
  # What a client WITHOUT a certificate gets - must be refused (client-cert-auth).
  if curl -s --max-time 5 --cacert "$ETCD_PKI/ca.crt" "https://$ME_ADDR:2379/health" >/dev/null 2>&1; then
    warn "a client with NO certificate was answered - client-cert-auth is not enforced"; exit 1
  fi
  ok "a client with no certificate is refused"
  local pid; pid="$(systemctl show -p MainPID --value etcd)"
  if [ -n "$pid" ] && [ "$pid" != 0 ] && tr '\0' '\n' < "/proc/$pid/environ" | grep -qx "GODEBUG=$ETCD_GODEBUG"; then
    ok "the running etcd carries GODEBUG=$ETCD_GODEBUG"
  else warn "the running etcd does NOT carry GODEBUG=$ETCD_GODEBUG"; exit 1; fi
  say "FIPS: approved algorithms in Go's TLS - NOT a validated module (SC-13, POA&M)."
}

case "${1:-}" in
  etcd)       shift; cmd_etcd "$@" ;;
  etcd-check) cmd_etcd_check ;;
  *) sed -n '2,11p' "$0" | sed 's/^# \{0,1\}//'; exit 2 ;;
esac
