#!/usr/bin/env bash
# =========================================================================================
# 06a-postgres-ha.sh - PostgreSQL HA on pg-01..03: etcd, then Patroni (backlog B-06a).
#
#     MACHINE: each pg guest (pg-01..03), which must already be hardened and finished
#     (03-compose-vm.sh --harden, then --finish). Runbook 9a is the design; 9a.2a the traps.
#
#     sudo ./06a-postgres-ha.sh etcd <fullchain.crt>   install and start this node's etcd member
#     sudo ./06a-postgres-ha.sh etcd-check             quorum, members, and the TLS it enforces
#     sudo ./06a-postgres-ha.sh patroni                PostgreSQL 16 under Patroni - pg-01 FIRST
#     sudo ./06a-postgres-ha.sh patroni-check          leader, sync standby, and the STIG traps
#     sudo ./06a-postgres-ha.sh monitor                postgres-exporter, local-only, no password
#                                                      - the PRIMARY first (it creates the role)
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

# =========================================================================================
# SLICE 3 - PATRONI AND POSTGRESQL 16 (runbook 9a.3; the traps are 9a.2a / backlog 6a.7)
#
#   Decided 2026-09-27 (HANDOFF 3): automatic failover, synchronous_mode on, strict OFF (an
#   alert will watch the degradation - slice 4), 5432 from the four K8S workers and the three pg
#   nodes only, and NODE-TO-NODE AUTHENTICATION BY CERTIFICATE: replication and rewind connect
#   with each node's enclave-CA identity from slice 2 (pg_hba `cert`, mapped to the roles by
#   pg_ident), the REST API needs a client certificate for anything that changes state. There
#   is no shared password anywhere - nothing to make, carry, keep or rotate.
#
#   TRAPS BUILT IN FROM THE START, not remediated later:
#     - Ubuntu's postgresql-16 creates and starts a "16 main" cluster on install. A drop-in in
#       /etc/postgresql-common/createcluster.d (read by the generated createcluster.conf) sets
#       create_main_cluster = false BEFORE postgresql-16 is installed, so it never exists. The
#       data directory is Patroni's own (PG_DATA), never Debian's 16/main.
#     - Patroni OWNS postgresql.conf and pg_hba.conf and rewrites them on restart: every setting
#       below lives in patroni.yml / the DCS, never in a file edited by hand (6a.7 trap 3).
#     - V-261892: no md5, password or trust line exists - peer locally, cert between nodes,
#       scram-sha-256 for applications, hostssl only.
#     - V-261967 vs 25 rules: log_destination 'stderr,syslog' + logging_collector on +
#       log_file_mode 0600 (6a.7 trap 2), and the union log_line_prefix (6a.2a section 6).
#     - pgaudit preloaded; patroni-check reads pg_settings.pending_restart, the false-pass
#       detector (a node can SHOW the right value and not have applied it).
#     - V-261857: explicit CONNECTION LIMITs on the replication and rewind roles (post_bootstrap).
#     - THE DATA DISK: mounted by LABEL (it moved vdc -> vdb when finish removed the seed), with
#       NO nofail, and patroni.service RequiresMountsFor it - a missing disk stops Patroni instead
#       of letting it initdb an empty database on the OS disk.
# =========================================================================================
PG_MNT="${PG_MNT:-/var/lib/postgresql}"
PG_LABEL="${PG_LABEL:-pgdata}"
PG_DATA="${PG_DATA:-$PG_MNT/16/enclave-pg}"
PG_BIN="${PG_BIN:-/usr/lib/postgresql/16/bin}"
PG_SCOPE="${PG_SCOPE:-enclave-pg}"
PATRONI_CONF="${PATRONI_CONF:-/etc/patroni/config.yml}"
PATRONI_PKI="${PATRONI_PKI:-/etc/patroni/pki}"
PG_MAX_CONN="${PG_MAX_CONN:-100}"
PG_REPL_CONN_LIMIT="${PG_REPL_CONN_LIMIT:-10}"
PG_WAIT="${PG_WAIT:-300}"
# The monitoring login (slice 4, decided 2026-09-28): a read-only role with pg_monitor, reached
# ONLY over the local socket by the exporter's OS account through a pg_ident map - no password.
PG_MON_ROLE="${PG_MON_ROLE:-pgmonitor}"
PG_MON_OSUSER="${PG_MON_OSUSER:-prometheus}"        # the account prometheus-postgres-exporter runs as
PG_MON_CONN_LIMIT="${PG_MON_CONN_LIMIT:-3}"
PG_EXPORTER_PORT="${PG_EXPORTER_PORT:-9187}"
PG_EXPORTER_ENV="${PG_EXPORTER_ENV:-/etc/default/prometheus-postgres-exporter}"

# The pg nodes, the K8S workers - from the address file, as `ip name` pairs.
addr_pairs() {   # addr_pairs PREFIX_REGEX
  local k
  for k in $(grep -oE "^($1)=" "$ADDRS" | tr -d '=' | sort); do printf '%s %s\n' "${!k}" "$(printf '%s' "$k" | tr 'A-Z_' 'a-z-')"; done
}

# patroni.yml, rendered. A function so it can be validated away from a pg node.
# render_patroni NAME ADDR
render_patroni() {
  local name="$1" addr="$2" ip n
  cat <<YML
# MANAGED by 06a-postgres-ha.sh patroni (backlog B-06a slice 3). Edits are overwritten by the
# next run - and Patroni itself rewrites postgresql.conf and pg_hba.conf from this file.
scope: $PG_SCOPE
namespace: /enclave/
name: $name
restapi:
  listen: $addr:8008
  connect_address: $addr:8008
  certfile: $PATRONI_PKI/node.crt
  keyfile: $PATRONI_PKI/node.key
  cafile: $PATRONI_PKI/ca.crt
  # optional = a client certificate is REQUIRED for every endpoint that changes state
  # (switchover, restart, reload, config); reads (/health, /primary, /metrics) stay open
  # to what ufw lets in: the three pg nodes and svc-obs-01.
  verify_client: optional
  allowlist:
YML
  while read -r ip n; do printf '    - %s\n' "$ip"; done < <(addr_pairs 'PG_[0-9]+')
  cat <<YML
ctl:
  cacert: $PATRONI_PKI/ca.crt
  certfile: $PATRONI_PKI/node.crt
  keyfile: $PATRONI_PKI/node.key
etcd3:
  protocol: https
  hosts:
YML
  while read -r ip n; do printf '    - %s:2379\n' "$ip"; done < <(addr_pairs 'PG_[0-9]+')
  cat <<YML
  cacert: $PATRONI_PKI/ca.crt
  cert: $PATRONI_PKI/node.crt
  key: $PATRONI_PKI/node.key
bootstrap:
  dcs:
    # CONSERVATIVE ON PURPOSE (runbook 9a.3): a promotion needs ~30 s of genuine leader loss.
    ttl: 30
    loop_wait: 10
    retry_timeout: 10
    maximum_lag_on_failover: 1048576
    # 9a.1 correction 2: synchronous replication is expressed HERE - Patroni overwrites a
    # hand-set synchronous_standby_names. strict is deliberately absent (off) - decided.
    synchronous_mode: true
    synchronous_node_count: 1
    postgresql:
      use_pg_rewind: true
      use_slots: true
      parameters:
        synchronous_commit: "on"
        max_connections: $PG_MAX_CONN
        password_encryption: scram-sha-256
        ssl: "on"
        ssl_min_protocol_version: TLSv1.2
        ssl_cert_file: $PATRONI_PKI/node.crt
        ssl_key_file: $PATRONI_PKI/node.key
        ssl_ca_file: $PATRONI_PKI/ca.crt
        wal_level: replica
        wal_log_hints: "on"
        hot_standby: "on"
        max_wal_senders: 10
        max_replication_slots: 10
        # 6a.7 trap 2 and 6a.2a section 6 - decided once, here
        log_destination: stderr,syslog
        logging_collector: "on"
        log_file_mode: "0600"
        log_line_prefix: "%m %a %u %d %r %p %s %c %h "
        log_connections: "on"
        log_disconnections: "on"
        shared_preload_libraries: pgaudit
        pgaudit.log: ddl,role,read,write
        pgaudit.log_catalog: "on"
  initdb:
    - encoding: UTF8
    - data-checksums
    - auth-local: peer
    - auth-host: scram-sha-256
  post_bootstrap: $PATRONI_PKI/../post-bootstrap.sh
postgresql:
  listen: $addr:5432
  connect_address: $addr:5432
  use_unix_socket: true
  data_dir: $PG_DATA
  bin_dir: $PG_BIN
  pgpass: $PG_MNT/.pgpass.patroni
  authentication:
    superuser:
      username: postgres
    replication:
      username: replicator
      sslmode: verify-full
      sslcert: $PATRONI_PKI/node.crt
      sslkey: $PATRONI_PKI/node.key
      sslrootcert: $PATRONI_PKI/ca.crt
    rewind:
      username: rewinder
      sslmode: verify-full
      sslcert: $PATRONI_PKI/node.crt
      sslkey: $PATRONI_PKI/node.key
      sslrootcert: $PATRONI_PKI/ca.crt
  parameters:
    unix_socket_directories: /var/run/postgresql
  # V-261892: peer locally, cert between nodes, scram for applications, hostssl only - no
  # md5, password or trust line exists. Nothing matches = rejected.
  pg_hba:
    - local all postgres peer
    # the exporter, as OS user $PG_MON_OSUSER, logs in as $PG_MON_ROLE - local socket only (slice 4)
    - local postgres $PG_MON_ROLE peer map=$PG_MON_ROLE
YML
  while read -r ip n; do
    printf '    - hostssl replication replicator %s/32 cert map=pgnodes\n' "$ip"
    printf '    - hostssl all rewinder %s/32 cert map=pgnodes\n' "$ip"
  done < <(addr_pairs 'PG_[0-9]+')
  while read -r ip n; do printf '    - hostssl all all %s/32 scram-sha-256\n' "$ip"; done < <(addr_pairs 'K8S_WK_[0-9]+')
  printf '  pg_ident:\n'
  printf '    - %s %s %s\n' "$PG_MON_ROLE" "$PG_MON_OSUSER" "$PG_MON_ROLE"
  while read -r ip n; do
    printf '    - pgnodes %s.%s replicator\n' "$n" "${ENCLAVE_DOMAIN:-enclave.internal}"
    printf '    - pgnodes %s.%s rewinder\n' "$n" "${ENCLAVE_DOMAIN:-enclave.internal}"
  done < <(addr_pairs 'PG_[0-9]+')
}

# Run once by Patroni on the primary after initdb (bootstrap.post_bootstrap). V-261857: no role
# the build creates may have rolconnlimit = -1.
# PATRONI RUNS THIS BEFORE IT CREATES THE REPLICATION AND REWIND ROLES - and creates them only if
# this succeeds (patroni/postgresql/bootstrap.py post_bootstrap). The first live bootstrap on pg-01,
# 2026-09-28, ALTERed a role that did not exist yet, exited 3, and Patroni cancelled the cluster.
# So CREATE them here, with their limits; Patroni's own create-or-alter then runs ALTER ROLE ...
# WITH LOGIN REPLICATION, which leaves CONNECTION LIMIT alone, and grants rewind its functions.
render_post_bootstrap() {
  cat <<SH
#!/bin/sh
# MANAGED by 06a-postgres-ha.sh - run once by Patroni after initdb, BEFORE it creates the
# replication and rewind roles (V-261857 connection limits - see the script for why).
set -e
psql -v ON_ERROR_STOP=1 -X -q -d postgres <<'SQL'
DO \$\$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_catalog.pg_roles WHERE rolname = 'replicator') THEN
    CREATE ROLE replicator WITH LOGIN REPLICATION CONNECTION LIMIT $PG_REPL_CONN_LIMIT;
  ELSE
    ALTER ROLE replicator CONNECTION LIMIT $PG_REPL_CONN_LIMIT;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_catalog.pg_roles WHERE rolname = 'rewinder') THEN
    CREATE ROLE rewinder WITH LOGIN CONNECTION LIMIT $PG_REPL_CONN_LIMIT;
  ELSE
    ALTER ROLE rewinder CONNECTION LIMIT $PG_REPL_CONN_LIMIT;
  END IF;
END
\$\$;
SQL
$(render_monitor_sql)
SH
}

# The monitoring role - read-only statistics (pg_monitor), a connection limit (V-261857), no
# password. Used by post_bootstrap on a new cluster and by `monitor` on an existing one.
render_monitor_sql() {
  cat <<SH
psql -v ON_ERROR_STOP=1 -X -q -d postgres <<'SQL'
DO \$\$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_catalog.pg_roles WHERE rolname = '$PG_MON_ROLE') THEN
    CREATE ROLE $PG_MON_ROLE WITH LOGIN CONNECTION LIMIT $PG_MON_CONN_LIMIT;
  ELSE
    ALTER ROLE $PG_MON_ROLE WITH LOGIN CONNECTION LIMIT $PG_MON_CONN_LIMIT;
  END IF;
END
\$\$;
GRANT pg_monitor TO $PG_MON_ROLE;
SQL
SH
}

# psql as the postgres OS user over the local socket (peer)
pg_sql() { runuser -u postgres -- psql -X -A -t -q -d postgres -c "$1"; }

cmd_patroni() {
  need_root; whoami_pg
  local name="$ME" key="$SSL_DIR/$ME.key"
  etcd_ctl endpoint health >/dev/null 2>&1 || die "this node's etcd is not healthy - slice 2 first: sudo $0 etcd-check"
  [ -r "$ETCD_PKI/member.crt" ] && [ -r "$key" ] || die "no node certificate/key from slice 2 ($ETCD_PKI/member.crt, $key)"

  # ---- the data disk, by label, never on the OS disk ----
  local dev cand n
  dev="$(blkid -L "$PG_LABEL" 2>/dev/null || true)"
  if [ -z "$dev" ]; then
    # exactly ONE whole disk with no partitions, no filesystem and no mount - or refuse
    cand="$(lsblk -dnpo NAME,TYPE | awk '$2=="disk"{print $1}' | while read -r d; do
              [ "$(lsblk -no NAME "$d" | wc -l)" -eq 1 ] || continue
              [ -z "$(blkid -o value -s TYPE "$d" 2>/dev/null)" ] || continue
              findmnt -rn -S "$d" >/dev/null 2>&1 && continue
              echo "$d"; done)"
    n="$(printf '%s\n' "$cand" | grep -c . || true)"
    [ "$n" -eq 1 ] || die "expected exactly ONE blank data disk, found $n: ${cand:-none}. Refusing to guess which disk to format."
    say "formatting $cand ($(lsblk -dno SIZE "$cand")) as ext4, label $PG_LABEL - it is blank"
    # -E nodiscard: mkfs TRIMs the whole device by default, and on 2026-09-28 that TRIM went
    # through the host's discard=unmap and released every reserved block of all three data
    # disks (backlog 3.42). The host now attaches data disks discard=ignore; this is the second
    # lock, so a disk attached the old way is still not un-reserved by being formatted.
    mkfs.ext4 -q -E nodiscard -L "$PG_LABEL" "$cand"
    dev="$cand"
  fi
  install -d -m 0755 "$PG_MNT"
  if ! grep -qE "^LABEL=${PG_LABEL}[[:space:]]" /etc/fstab; then
    cp -p /etc/fstab "/etc/fstab.bak-06a-$(date +%Y%m%d%H%M%S)"
    printf 'LABEL=%s  %s  ext4  defaults,nodev,nosuid,noexec  0 2\n' "$PG_LABEL" "$PG_MNT" >> /etc/fstab
    systemctl daemon-reload
  fi
  mountpoint -q "$PG_MNT" || mount "$PG_MNT"
  findmnt -n -S "LABEL=$PG_LABEL" -T "$PG_MNT" >/dev/null || [ "$(findmnt -n -o SOURCE "$PG_MNT")" = "$dev" ] \
    || die "$PG_MNT is not the $PG_LABEL disk"
  ok "data disk: $dev (LABEL=$PG_LABEL) mounted at $PG_MNT, $(df -h --output=size "$PG_MNT" | tail -1 | tr -d ' ')"

  # ---- packages, with Ubuntu's default cluster switched off BEFORE postgresql-16 ----
  install -d -m 0755 /etc/postgresql-common/createcluster.d
  printf '# 06a-postgres-ha.sh: Patroni owns the only cluster on this node\ncreate_main_cluster = false\n' \
    > /etc/postgresql-common/createcluster.d/00-no-main-cluster.conf
  DEBIAN_FRONTEND=noninteractive apt-get install -y postgresql-16 postgresql-16-pgaudit patroni python3-etcd \
    || die "apt could not install postgresql-16 postgresql-16-pgaudit patroni python3-etcd"
  if pg_lsclusters -h 2>/dev/null | grep -q .; then
    pg_lsclusters | sed 's/^/     /'
    die "a Debian-managed cluster exists - Patroni must be the only thing running PostgreSQL here. Look before removing it."
  fi
  systemctl disable --now postgresql >/dev/null 2>&1 || true
  chown postgres:postgres "$PG_MNT"
  ok "postgresql-16 $(dpkg-query -W -f='${Version}' postgresql-16), patroni $(dpkg-query -W -f='${Version}' patroni), pgaudit installed; no Debian cluster"

  # ---- the node's identity for postgres and patroni (slice 2's certificate) ----
  install -d -m 0750 -o root -g postgres "$PATRONI_PKI"
  install -m 0644 -o root -g root "$CA_ROOT" "$PATRONI_PKI/ca.crt"
  install -m 0644 -o root -g root "$ETCD_PKI/member.crt" "$PATRONI_PKI/node.crt"
  install -m 0640 -o root -g postgres "$key" "$PATRONI_PKI/node.key"
  render_post_bootstrap > /etc/patroni/post-bootstrap.sh
  chown root:postgres /etc/patroni/post-bootstrap.sh; chmod 0750 /etc/patroni/post-bootstrap.sh
  render_patroni "$name" "$ME_ADDR" > "$PATRONI_CONF.new"
  chown root:postgres "$PATRONI_CONF.new"; chmod 0640 "$PATRONI_CONF.new"; mv -f "$PATRONI_CONF.new" "$PATRONI_CONF"
  runuser -u postgres -- patroni --validate-config "$PATRONI_CONF" 2>&1 | sed 's/^/     /' | head -20 || true
  install -d -m 0755 /etc/systemd/system/patroni.service.d
  # StartLimit: a bootstrap that keeps failing STOPS after five tries in ten minutes. The package's
  # Restart=on-failure looped every few seconds on pg-01 (restart counter 34), each try running
  # initdb and leaving a *.failed data dir - the same rule as D7: never retry forever.
  printf '[Unit]\n# 06a: no data disk, no Patroni - never initdb an empty cluster on the OS disk\nRequiresMountsFor=%s\nAfter=etcd.service\nWants=etcd.service\nStartLimitIntervalSec=600\nStartLimitBurst=5\n[Service]\nRestartSec=15\n' "$PG_MNT" \
    > /etc/systemd/system/patroni.service.d/06a.conf
  systemctl daemon-reload
  ok "config: $PATRONI_CONF (member $name, scope $PG_SCOPE)"

  # ---- start, and wait for what this node should become ----
  systemctl enable patroni >/dev/null 2>&1
  systemctl reset-failed patroni >/dev/null 2>&1 || true   # a start limit hit by an earlier failed run
  systemctl restart patroni
  say "waiting up to ${PG_WAIT}s for $name to run (the first node bootstraps; the others clone from it)"
  # THE RIGHT ROLE, HELD. The first version accepted State 'running' and passed on pg-01 in the
  # middle of a bootstrap that then failed - the table printed under "[ok] pg-01 is up" said
  # "uninitialized ... Replica ... stopped". Now: Leader+running, or a replica STREAMING from a
  # leader, and three polls in a row (15 s), so a moment in passing does not count.
  local good=0
  for _ in $(seq 1 "$((PG_WAIT / 5))"); do
    if patronictl -c "$PATRONI_CONF" list -f json 2>/dev/null | python3 -c "
import sys, json
m = {x['Member']: x for x in json.load(sys.stdin)}
x = m.get('$name', {})
ok = (x.get('Role') == 'Leader' and x.get('State') == 'running') or \
     (x.get('Role') in ('Replica', 'Sync Standby') and x.get('State') == 'streaming')
sys.exit(0 if ok else 1)"; then good=$((good + 1)); else good=0; fi
    if [ "$good" -ge 3 ]; then ok "$name is up and has held it for 15 s"; patronictl -c "$PATRONI_CONF" list; return 0; fi
    sleep 5
  done
  journalctl -u patroni -n 30 --no-pager | sed 's/^/     /'
  # A STALE `initialize` KEY. Found 2026-09-28: Patroni was stopped in the middle of a bootstrap it
  # had claimed, so the claim stayed in etcd, and every later start sat on "waiting for leader to
  # bootstrap" with no leader anywhere. Patroni removes the key when a bootstrap FAILS, not when it
  # is killed. Say so - but never clear it automatically: another node may really be bootstrapping.
  if journalctl -u patroni -n 30 --no-pager 2>/dev/null | grep -q 'waiting for leader to bootstrap' \
     && ! etcd_ctl get "/enclave/$PG_SCOPE/leader" --keys-only 2>/dev/null | grep -q .; then
    say ""
    say "  'waiting for leader to bootstrap' with NO leader: if no other node is running Patroni, a"
    say "  bootstrap that was killed left its claim (/enclave/$PG_SCOPE/initialize) in etcd. Stop"
    say "  Patroni, confirm there is no leader key, then delete /enclave/$PG_SCOPE/ with etcdctl and"
    say "  remove $PG_DATA before re-running - the cluster never initialized, so nothing is lost."
  fi
  die "$name did not come up in ${PG_WAIT}s - the journal above says why"
}

cmd_patroni_check() {
  need_root; whoami_pg
  local bad=0 role v
  patronictl -c "$PATRONI_CONF" list || die "patronictl could not read the cluster"
  role="$(pg_sql "SELECT CASE WHEN pg_is_in_recovery() THEN 'replica' ELSE 'primary' END")"
  say "$ME is the $role"
  # 6a.7: pending_restart is the false-pass detector - the right value, not yet applied
  v="$(pg_sql "SELECT setting||' pending_restart='||pending_restart FROM pg_settings WHERE name='shared_preload_libraries'")"
  case "$v" in *pgaudit*"pending_restart=f"*) ok "shared_preload_libraries: $v" ;; *) warn "shared_preload_libraries: $v"; bad=1 ;; esac
  v="$(pg_sql "SELECT string_agg(DISTINCT auth_method, ',') FROM pg_hba_file_rules")"
  case ",$v," in *,md5,*|*,password,*|*,trust,*) warn "pg_hba has a weak method: $v (V-261892)"; bad=1 ;; *) ok "pg_hba methods: $v - no md5, password or trust" ;; esac
  v="$(pg_sql "SELECT string_agg(DISTINCT type, ',') FROM pg_hba_file_rules")"
  case ",$v," in *,host,*|*,hostnossl,*) warn "pg_hba has non-TLS host lines: $v"; bad=1 ;; *) ok "pg_hba line types: $v - TLS only over the network" ;; esac
  # V-261857: the roles the build creates carry an explicit CONNECTION LIMIT (post_bootstrap)
  v="$(pg_sql "SELECT string_agg(rolname||'='||rolconnlimit, ' ' ORDER BY rolname) FROM pg_roles WHERE rolname IN ('$PG_MON_ROLE','replicator','rewinder')")"
  case " $v " in
    *"=-1"*) warn "connection limits: $v - a role has none (V-261857)"; bad=1 ;;
    *" $PG_MON_ROLE="*" replicator="*" rewinder="*) ok "connection limits: $v (V-261857)" ;;
    *) warn "connection limits: '${v}' - $PG_MON_ROLE, replicator or rewinder is missing (V-261857; $PG_MON_ROLE comes from 'monitor')"; bad=1 ;;
  esac
  for s in ssl ssl_min_protocol_version password_encryption log_destination logging_collector log_file_mode synchronous_commit; do
    say "  $(pg_sql "SELECT name||' = '||setting FROM pg_settings WHERE name='$s'")"
  done
  if [ "$role" = primary ]; then
    # A real synchronous write, with no object left behind (6a.2a: no stig_test tables): emit a
    # WAL message, then require a SYNC standby to have replayed past it.
    local lsn
    lsn="$(pg_sql "SELECT pg_logical_emit_message(true, '06a', 'sync-check')")"
    pg_sql "SELECT application_name||' '||sync_state||' '||state||' replayed='||(replay_lsn >= '$lsn'::pg_lsn) FROM pg_stat_replication ORDER BY application_name" \
      | sed 's/^/     standby: /'
    [ "$(pg_sql "SELECT count(*) FROM pg_stat_replication WHERE sync_state='sync' AND replay_lsn >= '$lsn'::pg_lsn")" -ge 1 ] \
      && ok "a synchronous standby has replayed a commit made just now" || { warn "no synchronous standby has the commit"; bad=1; }
  fi
  [ "$bad" -eq 0 ] || exit 1
}

# =========================================================================================
# SLICE 4 - postgres-exporter (decided 2026-09-28: its own role, local peer, no password)
#
#   1. patroni.yml gains one local pg_hba line and one pg_ident map (OS user prometheus ->
#      role pgmonitor); Patroni applies them on reload - never an edit to pg_hba.conf.
#   2. On the PRIMARY: the role, idempotently. Replicas receive it by replication.
#   3. The exporter, installed with its self-start BLOCKED - its postinst starts it with an
#      empty connection string on every interface - then bound to this node's IP only.
# =========================================================================================
cmd_monitor() {
  need_root; whoami_pg
  local role v
  role="$(pg_sql "SELECT CASE WHEN pg_is_in_recovery() THEN 'replica' ELSE 'primary' END" 2>/dev/null || true)"
  [ -n "$role" ] || die "PostgreSQL is not answering on $ME - slice 3 first (patroni-check)"

  # ---- 1. the login path, through Patroni ----
  cp -p "$PATRONI_CONF" "$PATRONI_CONF.bak-06a-$(date +%Y%m%d%H%M%S)"
  render_patroni "$ME" "$ME_ADDR" > "$PATRONI_CONF.new"
  chown root:postgres "$PATRONI_CONF.new"; chmod 0640 "$PATRONI_CONF.new"; mv -f "$PATRONI_CONF.new" "$PATRONI_CONF"
  runuser -u postgres -- patroni --validate-config "$PATRONI_CONF" 2>&1 | sed 's/^/     /' | head -20 || true
  render_post_bootstrap > /etc/patroni/post-bootstrap.sh     # a rebuilt cluster gets the role at bootstrap
  systemctl reload patroni
  for _ in $(seq 1 12); do
    v="$(pg_sql "SELECT count(*) FROM pg_hba_file_rules WHERE type='local' AND '$PG_MON_ROLE'=ANY(user_name)")"
    [ "$v" = 1 ] && break; sleep 5
  done
  [ "$v" = 1 ] || die "Patroni did not apply the $PG_MON_ROLE pg_hba line within 60 s (journalctl -u patroni)"
  ok "pg_hba: local $PG_MON_ROLE by peer, mapped from OS user $PG_MON_OSUSER - applied by Patroni"

  # ---- 2. the role, on the primary only ----
  if [ "$role" = primary ]; then
    render_monitor_sql | runuser -u postgres -- sh -s || die "could not create $PG_MON_ROLE"
    ok "role $PG_MON_ROLE: pg_monitor, CONNECTION LIMIT $PG_MON_CONN_LIMIT, no password (created on the primary)"
  else
    [ "$(pg_sql "SELECT count(*) FROM pg_roles WHERE rolname='$PG_MON_ROLE'")" = 1 ] \
      || die "$ME is a replica and $PG_MON_ROLE does not exist yet - run 'monitor' on the primary first"
    ok "role $PG_MON_ROLE present (replicated from the primary)"
  fi

  # ---- 3. the exporter ----
  if ! dpkg -s prometheus-postgres-exporter >/dev/null 2>&1; then
    printf '#!/bin/sh\nexit 101\n' > /usr/sbin/policy-rc.d; chmod 0755 /usr/sbin/policy-rc.d
    DEBIAN_FRONTEND=noninteractive apt-get install -y prometheus-postgres-exporter \
      || { rm -f /usr/sbin/policy-rc.d; die "apt could not install prometheus-postgres-exporter"; }
    rm -f /usr/sbin/policy-rc.d
    ok "prometheus-postgres-exporter $(dpkg-query -W -f='${Version}' prometheus-postgres-exporter) installed, its self-start blocked"
  fi
  id "$PG_MON_OSUSER" >/dev/null 2>&1 || die "no OS user $PG_MON_OSUSER - the exporter package should have made it"
  [ -f "$PG_EXPORTER_ENV" ] && cp -p "$PG_EXPORTER_ENV" "/var/backups/$(basename "$PG_EXPORTER_ENV").$(date +%Y%m%dT%H%M%S)"
  {
    echo "# MANAGED by 06a-postgres-ha.sh monitor (B-06a slice 4). No password: peer over the local"
    echo "# socket, OS user $PG_MON_OSUSER mapped to role $PG_MON_ROLE by Patroni's pg_ident."
    echo "DATA_SOURCE_NAME='host=/var/run/postgresql user=$PG_MON_ROLE dbname=postgres'"
    echo "ARGS='--web.listen-address=$ME_ADDR:$PG_EXPORTER_PORT'"
  } > "$PG_EXPORTER_ENV.new"
  chown "root:$PG_MON_OSUSER" "$PG_EXPORTER_ENV.new"; chmod 0640 "$PG_EXPORTER_ENV.new"; mv -f "$PG_EXPORTER_ENV.new" "$PG_EXPORTER_ENV"
  systemctl enable prometheus-postgres-exporter >/dev/null 2>&1
  systemctl restart prometheus-postgres-exporter
  local up=""
  for _ in $(seq 1 12); do
    up="$(curl -s --max-time 5 "http://$ME_ADDR:$PG_EXPORTER_PORT/metrics" 2>/dev/null | awk '$1=="pg_up"{print $2}')"
    [ "$up" = 1 ] && break; sleep 5
  done
  [ "$up" = 1 ] || { journalctl -u prometheus-postgres-exporter -n 15 --no-pager | sed 's/^/     /'; die "the exporter is not reaching PostgreSQL (pg_up=${up:-no answer}) - the log above says why"; }
  ok "postgres-exporter on $ME_ADDR:$PG_EXPORTER_PORT: pg_up 1 - logged in as $PG_MON_ROLE with no password"
  ss -Htln "sport = :$PG_EXPORTER_PORT" | awk '{print "     listening: "$4}'
}

case "${1:-}" in
  etcd)       shift; cmd_etcd "$@" ;;
  etcd-check) cmd_etcd_check ;;
  patroni)       cmd_patroni ;;
  patroni-check) cmd_patroni_check ;;
  monitor)       cmd_monitor ;;
  *) sed -n '2,15p' "$0" | sed 's/^# \{0,1\}//'; exit 2 ;;
esac
